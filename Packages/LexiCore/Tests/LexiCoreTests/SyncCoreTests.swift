import CloudKit
import Foundation
import GRDB
import Testing
@testable import LexiCore

/// 동기화 저변: UUIDv7, 쓰기 경로 저널링, CKRecord 왕복.
@Suite struct SyncCoreTests {
    // MARK: - UUIDv7

    @Test func UUIDv7은_버전과_변형_비트를_지킨다() {
        let uuid = UUIDv7.generate()
        let s = uuid.uuidString
        #expect(s.hasPrefix("0"))  // 2023년 이후 ms 타임스탬프는 48bit 상위 비트가 0
        #expect(s.contains("-"))
        // version 니블
        #expect(s[s.index(s.startIndex, offsetBy: 14)] == "7")
        // variant 상위 비트 10xx: 17번째 hex 문자가 8~b
        let variant = s[s.index(s.startIndex, offsetBy: 19)]
        #expect("89ab".contains(variant.lowercased()))
    }

    @Test func UUIDv7은_지정한_시각을_타임스탬프로_인코딩한다() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.25)
        let uuid = UUIDv7.generate(at: date)
        let bytes: [UInt8] = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        var millis: UInt64 = 0
        for i in 0..<6 { millis = (millis << 8) | UInt64(bytes[i]) }
        #expect(Int64(millis) == 1_700_000_000_250)  // .25초는 250ms로 유지된다
    }

    @Test func UUIDv7은_시각_순서대로_정렬된다() {
        let earlier = UUIDv7.generate(at: Date(timeIntervalSince1970: 1_000_000_000))
        let later = UUIDv7.generate(at: Date(timeIntervalSince1970: 1_000_000_001))
        #expect(earlier.uuidString < later.uuidString)
    }

    // MARK: - 쓰기 경로 저널링

    @Test func 저장하면_개념_개정본_별칭_저널이_같은_트랜잭션에_남는다() async throws {
        let db = try AppDatabase.makeInMemory()
        try db.migrate()
        let service = LookupService(database: db)

        try await service.saveConcept(
            preferredTerm: "셸링 포인트", aliases: ["Schelling point", "셸링 포인트"],
            field: "경제학", oneLine: "협상의 초점", easyExplanation: "조율되는 지점.",
            author: "user", provider: nil, termLanguage: .korean, explanationLanguage: .korean)

        let journal = try await journalRows(db)
        // 표제어와 동일한 별칭은 중복 기록되지 않는다. 별칭 2개 + 개념 + 개정본 = 4.
        #expect(journal.count == 4)
        #expect(Set(journal.map(\.kind)) == ["concept", "revision", "alias"])
        #expect(Set(journal.map(\.op)) == ["upsert"])
        #expect(try await db.pendingSyncCount() == 4)
    }

    @Test func 즐겨찾기를_바꾸면_개념_저널_하나가_갱신된다() async throws {
        let db = try AppDatabase.makeInMemory()
        try db.migrate()
        let service = LookupService(database: db)
        let conceptId = try await service.saveConcept(
            preferredTerm: "임계질량", aliases: [], field: nil, oneLine: "연쇄반응이 지속되는 최소 질량",
            easyExplanation: "핵분열 연쇄반응이 스스로 유지되는 질량.", author: "ai", provider: "test:model")

        let (_, conceptUUID) = try await conceptUUID(db, conceptId)
        try await service.setFavorite(conceptId: conceptId, true)
        try await service.setFavorite(conceptId: conceptId, false)

        let journal = try await journalRows(db)
        #expect(journal.count == 3)  // 초기 저장 3건 + 저널 갱신, 행은 (uuid, kind)별 1개
        #expect(journal.filter { $0.kind == "concept" && $0.uuid == conceptUUID }.count == 1)
    }

    @Test func 사용자_개정본을_추가하면_개정본과_개념_저널이_남는다() async throws {
        let db = try AppDatabase.makeInMemory()
        try db.migrate()
        let service = LookupService(database: db)
        let conceptId = try await service.saveConcept(
            preferredTerm: "베이즈 정리", aliases: [], field: nil, oneLine: "조건부 확률의 관계식",
            easyExplanation: "새 증거가 주어졌을 때 사전 확률을 갱신한다.", author: "ai", provider: nil)

        try await service.saveUserRevision(
            conceptId: conceptId, oneLine: "증거로 믿음을 갱신하는 규칙",
            easyExplanation: "P(H|E) = P(E|H)P(H)/P(E).", language: .korean)

        let journal = try await journalRows(db)
        // 초기(개념+개정본+별칭) + 개정본 + 개념(updatedAt 갱신은 같은 행 갱신)
        #expect(journal.filter { $0.kind == "revision" }.count == 2)
        #expect(journal.filter { $0.kind == "concept" }.count == 1)
    }

    @Test func 삭제하면_자식까지_묘비가_남는다() async throws {
        let db = try AppDatabase.makeInMemory()
        try db.migrate()
        let service = LookupService(database: db)
        let conceptId = try await service.saveConcept(
            preferredTerm: "가위집합", aliases: ["Nash equilibrium"], field: nil,
            oneLine: "참여자가 이탈 동기가 없는 상태", easyExplanation: "모두가 자기 전략에 만족한다.",
            author: "ai", provider: nil)
        let revisionId: Int64 = try await db.writer.read { db in
            try Int64.fetchOne(
                db, sql: "SELECT id FROM definitionRevision WHERE conceptId = ?",
                arguments: [conceptId])!
        }
        try await service.addSource(
            revisionId: revisionId, title: "위키", url: "https://example.com", excerpt: "발췌")
        try await service.deleteConcept(conceptId: conceptId)

        let journal = try await journalRows(db)
        #expect(Set(journal.map(\.kind)) == ["concept", "revision", "alias", "source"])
        #expect(Set(journal.map(\.op)) == ["delete"])
        let entries = try await service.lookupExact("가위집합")
        #expect(entries.isEmpty)
    }

    // MARK: - CKRecord 왕복

    @Test func 스냅샷은_CKRecord로_왕복해_동일하다() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_100)
        let records = [
            SyncRecord(
                kind: .concept, uuid: "C1", preferredTerm: "셸링 포인트", field: "경제학",
                isFavorite: true, lang: "ko", createdAt: date, updatedAt: date),
            SyncRecord(
                kind: .revision, uuid: "R1", parentUUID: "C1", lang: "ko", createdAt: date,
                oneLine: "협상의 초점", easyExplanation: "조율되는 지점.", author: "user", provider: nil),
            SyncRecord(kind: .alias, uuid: "A1", parentUUID: "C1", lang: "en", text: "Schelling point"),
            SyncRecord(
                kind: .source, uuid: "S1", parentUUID: "R1", title: "위키", url: "https://example.com",
                excerpt: "발췌", retrievedAt: date),
        ]
        for record in records {
            let cloudRecord = record.makeCKRecord()
            #expect(cloudRecord.recordType == record.kind.rawValue)
            #expect(cloudRecord.recordID.recordName == record.cloudRecordName)
            let restored = try #require(SyncRecord(cloudRecord: cloudRecord))
            #expect(restored == record)
            // 부모 참조는 위계 표시로 기록된다(action은 none).
            if let parentUUID = record.parentUUID {
                let reference = try #require(restored.makeCKRecord().parent)
                #expect(reference.recordID.recordName.hasPrefix(record.kind == .source ? "revision-" : "concept-"))
                #expect(reference.recordID.recordName.contains(parentUUID))
            }
        }
    }

    @Test func 모르는_recordType은_거부한다() throws {
        let record = CKRecord(recordType: "mystery", recordID: CKRecord.ID(recordName: "mystery-X"))
        #expect(SyncRecord(cloudRecord: record) == nil)
    }

    // MARK: - 도우미

    private func journalRows(_ db: AppDatabase) async throws -> [(kind: String, uuid: String, op: String)] {
        try await db.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT uuid, kind, op FROM syncJournal").map { row in
                (kind: row["kind"] as String, uuid: row["uuid"] as String, op: row["op"] as String)
            }
        }
    }

    private func conceptUUID(_ db: AppDatabase, _ conceptId: Int64) async throws -> (Int64, String) {
        try await db.writer.read { db in
            let row = try Row.fetchOne(
                db, sql: "SELECT id, uuid FROM concept WHERE id = ?", arguments: [conceptId])!
            return (row["id"] as Int64, row["uuid"] as String)
        }
    }
}

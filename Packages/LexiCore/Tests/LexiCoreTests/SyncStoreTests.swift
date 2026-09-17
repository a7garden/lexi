import Foundation
import GRDB
import Testing
@testable import LexiCore

/// SyncStore 병합 규칙: 최초 업로드, LWW, append-only, stash, 삭제 전파, 두 DB 수렴.
@Suite struct SyncStoreTests {
    // MARK: - 최초 업로드

    @Test func 최초_업로드는_한_번만_필요하다() async throws {
        let db = try AppDatabase.makeInMemory()
        try db.migrate()
        let store = SyncStore(database: db)

        #expect(try await store.needsInitialUpload())
        try await store.markInitialUploadDone()
        #expect(!(try await store.needsInitialUpload()))
    }

    @Test func 전체_스냅샷은_부모_UUID를_연결해_돌려준다() async throws {
        let db = try AppDatabase.makeInMemory()
        try db.migrate()
        let service = LookupService(database: db)
        let store = SyncStore(database: db)
        let conceptId = try await service.saveConcept(
            preferredTerm: "쉐도잉", aliases: ["shadowing"], field: nil,
            oneLine: "따라 말하기 연습", easyExplanation: "원어민 발화를 그대로 따라 한다.",
            author: "ai", provider: "test:model")
        let revisionId: Int64 = try await db.writer.read { db in
            try Int64.fetchOne(
                db, sql: "SELECT id FROM definitionRevision WHERE conceptId = ?",
                arguments: [conceptId])!
        }
        try await service.addSource(revisionId: revisionId, title: "위키", url: nil, excerpt: nil)

        let records = try await store.allRecords()

        #expect(records.filter { $0.kind == .concept }.count == 1)
        #expect(records.filter { $0.kind == .revision }.count == 1)
        #expect(records.filter { $0.kind == .alias }.count == 2)  // 표제어 + 별칭
        #expect(records.filter { $0.kind == .source }.count == 1)
        let concept = try #require(records.first { $0.kind == .concept })
        let revision = try #require(records.first { $0.kind == .revision })
        #expect(revision.parentUUID == concept.uuid)
        let source = try #require(records.first { $0.kind == .source })
        #expect(source.parentUUID == revision.uuid)
        for alias in records.filter({ $0.kind == .alias }) {
            #expect(alias.parentUUID == concept.uuid)
        }
    }

    // MARK: - 원격 적용

    @Test func 빈_DB에_원격_개념을_적용하면_새로_생긴다() async throws {
        let db = try AppDatabase.makeInMemory()
        try db.migrate()
        let store = SyncStore(database: db)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let report = try await store.applyRemote(
            upserts: [
                SyncRecord(
                    kind: .concept, uuid: "C-1", preferredTerm: "페르미 추정", field: nil,
                    isFavorite: false, lang: "ko", createdAt: date, updatedAt: date),
                // 조회는 alias를 통하므로 표제어 alias 레코드가 함께 온다.
                SyncRecord(
                    kind: .alias, uuid: "A-1", parentUUID: "C-1", lang: "ko",
                    text: "페르미 추정"),
            ],
            deletions: [])

        #expect(report.appliedUpserts == 2)
        let service = LookupService(database: db)
        let entries = try await service.lookupExact("페르미 추정")
        #expect(entries.count == 1)
        #expect(entries[0].isFavorite == false)
    }

    @Test func 더_새로운_원격_개념이_로컬을_덮고_저널을_비운다() async throws {
        let db = try AppDatabase.makeInMemory()
        try db.migrate()
        let service = LookupService(database: db)
        let store = SyncStore(database: db)
        let conceptId = try await service.saveConcept(
            preferredTerm: "낡은 표제어", aliases: [], field: nil,
            oneLine: "요약", easyExplanation: "설명.", author: "user", provider: nil)
        let uuid: String = try await db.writer.read { db in
            try String.fetchOne(db, sql: "SELECT uuid FROM concept WHERE id = ?", arguments: [conceptId])!
        }
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_086_400)
        let newest = Date(timeIntervalSince1970: 1_700_172_800)
        // 로컬 시각을 고정한다(saveConcept은 현재 시각을 쓰므로 테스트에서 덮어쓴다).
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE concept SET updatedAt = ? WHERE id = ?",
                arguments: [older, conceptId])
        }

        // 로컬이 더 오래됨 → 원격 승리: 내용 교체 + 미전송 표시 정리
        let report = try await store.applyRemote(
            upserts: [SyncRecord(
                kind: .concept, uuid: uuid, preferredTerm: "새 표제어", field: "물리학",
                isFavorite: true, lang: "ko", createdAt: older, updatedAt: newer)],
            deletions: [])
        #expect(report.appliedUpserts == 1)
        let entries = try await service.lookupExact("새 표제어")
        #expect(entries.count == 1)
        #expect(entries[0].isFavorite == true)
        var journal = try await journalRows(db)
        #expect(!journal.contains { $0.kind == "concept" && $0.uuid == uuid })

        // 로컬이 더 새로움 → 무시하고 저널 유지(푸시가 최종 수렴)
        try await service.setFavorite(conceptId: conceptId, false)  // 저널 생성
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE concept SET updatedAt = ? WHERE id = ?",
                arguments: [newest, conceptId])  // 로컬이 newest보다 새 상태로 고정
        }
        let report2 = try await store.applyRemote(
            upserts: [SyncRecord(
                kind: .concept, uuid: uuid, preferredTerm: "또 다른 표제어", field: nil,
                isFavorite: false, lang: "ko", createdAt: older, updatedAt: newer)],
            deletions: [])
        #expect(report2.ignored == 1)
        let entries2 = try await service.lookupExact("또 다른 표제어")
        #expect(entries2.isEmpty)  // 로컬 내용이 유지됨
        journal = try await journalRows(db)
        #expect(journal.contains { $0.kind == "concept" && $0.uuid == uuid })  // 푸시 대상으로 남음
    }

    @Test func 부모보다_개정본이_먼저_오면_보관했다가_적용한다() async throws {
        let db = try AppDatabase.makeInMemory()
        try db.migrate()
        let store = SyncStore(database: db)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        // 부모 없는 개정본 → stash
        let stashedReport = try await store.applyRemote(
            upserts: [SyncRecord(
                kind: .revision, uuid: "R-9", parentUUID: "C-9", lang: "ko", createdAt: date,
                oneLine: "아직 부모가 없다", easyExplanation: "보관 대상.", author: "ai", provider: nil)],
            deletions: [])
        #expect(stashedReport.stashed == 1)

        // 부모 도착 → 보관 항목 자동 적용
        let report = try await store.applyRemote(
            upserts: [
                SyncRecord(
                    kind: .concept, uuid: "C-9", preferredTerm: "모비우스 함수", field: nil,
                    isFavorite: false, lang: "ko", createdAt: date, updatedAt: date),
                SyncRecord(
                    kind: .alias, uuid: "A-9", parentUUID: "C-9", lang: "ko",
                    text: "모비우스 함수"),
            ],
            deletions: [])
        #expect(report.appliedUpserts >= 2)
        let pendingCount = try await db.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncPendingRemote")!
        }
        #expect(pendingCount == 0)
        let service = LookupService(database: db)
        let entries = try await service.lookupExact("모비우스 함수")
        #expect(entries.count == 1)
        #expect(entries[0].oneLine == "아직 부모가 없다")
    }

    @Test func 중복_별칭은_묘비로_수렴시킨다() async throws {
        let db = try AppDatabase.makeInMemory()
        try db.migrate()
        let service = LookupService(database: db)
        let store = SyncStore(database: db)
        let conceptId = try await service.saveConcept(
            preferredTerm: "게임 이론", aliases: [], field: nil,
            oneLine: "전략적 상호작용의 수학", easyExplanation: "참여자의 선택을 분석한다.",
            author: "user", provider: nil)
        let conceptUUID: String = try await db.writer.read { db in
            try String.fetchOne(db, sql: "SELECT uuid FROM concept WHERE id = ?", arguments: [conceptId])!
        }
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        // 같은 (concept, text, lang)을 다른 uuid로 재도착 → 패배 처리 + 묘비
        let report = try await store.applyRemote(
            upserts: [SyncRecord(
                kind: .alias, uuid: "A-loser", parentUUID: conceptUUID, lang: "ko",
                text: "게임 이론")],
            deletions: [])
        #expect(report.convergenceDeletes == 1)
        let push = try await store.pendingPush()
        #expect(push.deletes.contains(SyncRecordRef(kind: .alias, uuid: "A-loser")))
        // 로컬 alias 행 수는 변하지 않는다.
        let aliasCount = try await db.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM alias WHERE conceptId = ?", arguments: [conceptId])!
        }
        #expect(aliasCount == 1)
    }

    @Test func 원격_개념_삭제는_자식과_저널을_함께_정리한다() async throws {
        let db = try AppDatabase.makeInMemory()
        try db.migrate()
        let service = LookupService(database: db)
        let store = SyncStore(database: db)
        let conceptId = try await service.saveConcept(
            preferredTerm: "지워질 개념", aliases: ["지워질 별칭"], field: nil,
            oneLine: "요약", easyExplanation: "설명.", author: "ai", provider: nil)
        let conceptUUID: String = try await db.writer.read { db in
            try String.fetchOne(db, sql: "SELECT uuid FROM concept WHERE id = ?", arguments: [conceptId])!
        }
        try await service.setFavorite(conceptId: conceptId, true)
        // 저널에 미전송 upsert가 있는 상태에서 원격 삭제가 도착한다.
        let before = try await store.pendingPush()
        #expect(!before.isEmpty)

        let report = try await store.applyRemote(
            upserts: [], deletions: [.init(kind: .concept, uuid: conceptUUID)])

        #expect(report.appliedDeletes == 1)
        let entries = try await service.lookupExact("지워질 개념")
        #expect(entries.isEmpty)
        let after = try await store.pendingPush()
        #expect(after.isEmpty)  // 남은 미전송 표시도 모두 정리됨
    }

    // MARK: - 두 DB 수렴(기기 시뮬레이션)

    @Test func 두_DB가_CKRecord_왕복으로_수렴한다() async throws {
        let a = try AppDatabase.makeInMemory()
        try a.migrate()
        let b = try AppDatabase.makeInMemory()
        try b.migrate()
        let serviceA = LookupService(database: a)
        let serviceB = LookupService(database: b)
        let storeA = SyncStore(database: a)
        let storeB = SyncStore(database: b)

        try await serviceA.saveConcept(
            preferredTerm: "기회비용", aliases: ["opportunity cost"], field: "경제학",
            oneLine: "포기한 대안의 가치", easyExplanation: "선택하지 않은 최선의 대안이 지닌 가치다.",
            author: "user", provider: nil, termLanguage: .korean, explanationLanguage: .korean)

        // A → B: 최초 전체 업로드 시나리오
        let allRecords = try await storeA.allRecords()
        try await storeB.applyRemote(upserts: allRecords, deletions: [])
        let entries = try await serviceB.lookupExact("기회비용")
        #expect(entries.count == 1)
        #expect(entries[0].oneLine == "포기한 대안의 가치")
        #expect(entries[0].author == "user")

        // 같은 배치를 A에 재적용: 전부 무시(멱등)
        let replay = try await storeA.applyRemote(upserts: allRecords, deletions: [])
        #expect(replay.appliedUpserts == 0)
        #expect(replay.ignored == allRecords.count)

        // B에서 즐겨찾기 → A로 델타 푸시
        let conceptIdB: Int64 = try await b.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM concept WHERE preferredTerm = ?", arguments: ["기회비용"])!
        }
        try await serviceB.setFavorite(conceptId: conceptIdB, true)
        let delta = try await storeB.pendingPush()
        #expect(delta.upserts.count == 1)
        try await storeA.applyRemote(upserts: delta.upserts, deletions: delta.deletes)
        let entriesA = try await serviceA.lookupExact("기회비용")
        #expect(entriesA[0].isFavorite == true)  // A가 원격 즐겨찾기를 반영했다
        let unacked = try await storeB.pendingPush()
        #expect(!unacked.isEmpty)  // ack 전이므로 저널이 남아 있다
        try await storeB.acknowledgeUpserts(delta.upserts.map {
            SyncRecordRef(kind: $0.kind, uuid: $0.uuid)
        })
        #expect(try await storeB.pendingPush().isEmpty)

        // A에서 삭제 → B로 전파
        try await serviceA.deleteConcept(conceptId: conceptIdB)
        let deletions = try await storeA.pendingPush().deletes
        #expect(!deletions.isEmpty)
        try await storeB.applyRemote(upserts: [], deletions: deletions)
        let entriesAfterDelete = try await serviceB.lookupExact("기회비용")
        #expect(entriesAfterDelete.isEmpty)
    }

    // MARK: - 도우미

    private func journalRows(_ db: AppDatabase) async throws -> [(kind: String, uuid: String, op: String)] {
        try await db.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT uuid, kind, op FROM syncJournal").map { row in
                (kind: row["kind"] as String, uuid: row["uuid"] as String, op: row["op"] as String)
            }
        }
    }
}

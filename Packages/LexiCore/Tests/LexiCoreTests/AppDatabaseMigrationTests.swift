import Testing
import Foundation
import GRDB
@testable import LexiCore

/// Schema 변경은 이전 schema에서의 up-test를 함께 검증한다(저장소 규칙).
@Suite struct AppDatabaseMigrationTests {
    @Test func v1에서_v2로_올라가면_기존_행의_언어를_되메운다() async throws {
        let db = try AppDatabase.makeInMemory()
        // v1 스키마에 언어 컬럼 없이 데이터를 남긴 뒤(구버전 사용자의 DB와 동일 상태) v2로 올린다.
        try AppDatabase.makeMigrator().migrate(db.writer, upTo: "v1")
        try await db.writer.write { db in
            try db.execute(sql: "INSERT INTO concept (preferredTerm) VALUES (?)", arguments: ["임베딩"])
            let conceptId = try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM concept")!
            try db.execute(
                sql: "INSERT INTO alias (conceptId, text) VALUES (?, ?)",
                arguments: [conceptId, "임베딩"])
            try db.execute(
                sql: "INSERT INTO definitionRevision (conceptId, oneLine, easyExplanation, author) VALUES (?, ?, ?, 'user')",
                arguments: [conceptId, "의미를 벡터로 표현한 것", "텍스트를 숫자 배열로 바꿔 거리를 계산한다."])
        }

        try db.migrate()

        // 기존 데이터는 그대로 남고, 한글 텍스트에서 언어가 되메워진다.
        let service = LookupService(database: db)
        let entries = try await service.lookupExact("임베딩")
        #expect(entries.count == 1)
        #expect(entries[0].oneLine == "의미를 벡터로 표현한 것")
        #expect(entries[0].termLanguage == .korean)
        #expect(entries[0].explanationLanguage == .korean)
    }

    @Test func 마이그레이션은_멱등하게_한_번만_적용된다() throws {
        let db = try AppDatabase.makeInMemory()
        try db.migrate()
        try db.migrate()  // 두 번 불러도 오류 없음
    }
    @Test func v2에서_v3로_올라가면_모든_행에_동기화_UUID를_부여한다() async throws {
        let db = try AppDatabase.makeInMemory()
        // v2 상태에서 데이터를 남긴 뒤(동기화 이전 사용자의 DB와 동일) v3로 올린다.
        try AppDatabase.makeMigrator().migrate(db.writer, upTo: "v2")
        try await db.writer.write { db in
            try db.execute(sql: "INSERT INTO concept (preferredTerm) VALUES (?)", arguments: ["동기화"])
            let conceptId = try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM concept")!
            try db.execute(
                sql: "INSERT INTO alias (conceptId, text) VALUES (?, ?)",
                arguments: [conceptId, "동기화"])
            try db.execute(
                sql: "INSERT INTO definitionRevision (conceptId, oneLine, easyExplanation, author) VALUES (?, ?, ?, 'user')",
                arguments: [conceptId, "여러 기기에서 같은 사전", "iCloud로 개념을 동기화한다."])
        }

        try db.migrate()

        // 모든 행이 유일한 uuid를 얻고, 동기화 보조 테이블이 빈 채로 준비된다.
        try await db.writer.write { db in
            for table in ["concept", "alias", "definitionRevision", "sourceRef"] {
                let nulls = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE uuid IS NULL")
                #expect(nulls == 0, "\(table)에 uuid가 비는 행이 있다")
                let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")
                let distinct = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT uuid) FROM \(table)")
                #expect(total == distinct, "\(table)의 uuid가 유일하지 않다")
            }
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncJournal") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncPendingRemote") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncMeta") == 0)
        }
        // 기존 데이터는 그대로 보존된다.
        let service = LookupService(database: db)
        let entries = try await service.lookupExact("동기화")
        #expect(entries.count == 1)
        #expect(entries[0].oneLine == "여러 기기에서 같은 사전")
    }

    @Test func v1에서_v3로_한_번에_올라가도_UUID가_채워진다() async throws {
        let db = try AppDatabase.makeInMemory()
        try db.migrate()
        let service = LookupService(database: db)
        let conceptId = try await service.saveConcept(
            preferredTerm: "한번에", aliases: [], field: nil, oneLine: "요약",
            easyExplanation: "설명.", author: "user", provider: nil)
        let uuid = try await db.writer.read { db in
            try String.fetchOne(db, sql: "SELECT uuid FROM concept WHERE id = ?", arguments: [conceptId])
        }
        #expect(uuid != nil)
    }
}

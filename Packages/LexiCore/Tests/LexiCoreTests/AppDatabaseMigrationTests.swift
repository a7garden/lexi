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
}

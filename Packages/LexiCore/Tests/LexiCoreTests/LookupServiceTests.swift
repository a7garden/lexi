import Testing
import Foundation
@testable import LexiCore

@Suite struct LookupServiceTests {
    private func makeService() throws -> LookupService {
        let db = try AppDatabase.makeInMemory()
        try db.migrate()
        return LookupService(database: db)
    }

    @Test func 저장된_개념을_별칭_정확검색으로_찾는다() async throws {
        let service = try makeService()
        _ = try await service.saveConcept(
            preferredTerm: "RAG",
            aliases: ["검색 증강 생성", "Retrieval-Augmented Generation"],
            field: "AI",
            oneLine: "외부 지식을 검색해 그내용을 바탕으로 응답을 생성하는 방식",
            easyExplanation: "모델이 학습하지 않은 자료를 찾아 붙여 답한다.",
            author: "user", provider: nil
        )

        for query in ["RAG", "검색 증강 생성", "  RAG  "] {
            let entries = try await service.lookupExact(query)
            #expect(entries.count == 1)
            #expect(entries.first?.preferredTerm == "RAG")
            #expect(entries.first?.author == "user")
        }
    }

    @Test func 같은_표현의_다른_뜻은_모두_후보로_돌려준다() async throws {
        let service = try makeService()
        _ = try await service.saveConcept(
            preferredTerm: "토큰", aliases: [], field: "AI",
            oneLine: "모델이 처리하는 텍스트 조각", easyExplanation: "문장을 잘게 쪼갠 단위.",
            author: "user", provider: nil
        )
        _ = try await service.saveConcept(
            preferredTerm: "인증 토큰", aliases: ["토큰"], field: "보안",
            oneLine: "접근 권한을 증명하는 문자열", easyExplanation: "열쇠 역할의 문자열.",
            author: "user", provider: nil
        )

        let entries = try await service.lookupExact("토큰")
        #expect(entries.count == 2)
        #expect(Set(entries.map(\.field)) == ["AI", "보안"])
    }

    @Test func 없는_표현은_빈배열과_miss_기록() async throws {
        let service = try makeService()
        let entries = try await service.lookupExact("존재하지않는개념")
        #expect(entries.isEmpty)
        try await service.recordLookup("존재하지않는개념", conceptId: nil, status: .miss)

        let db = service.database
        let count = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM lookupRecord WHERE status = 'miss'") }
        #expect(count == 1)
    }

    @Test func 정확검색은_부분일치를_치지_않는다() async throws {
        let service = try makeService()
        _ = try await service.saveConcept(
            preferredTerm: "tokenizer", aliases: [], field: nil,
            oneLine: "텍스트를 토큰으로 분할하는 도구", easyExplanation: "문장을 조각으로 쪼갠다.",
            author: "user", provider: nil
        )
        #expect(try await service.lookupExact("tokeniz").isEmpty)
        #expect(try await service.lookupExact("tokenizers").isEmpty)
        #expect(try await service.lookupExact("tokenizer").count == 1)
    }

    @Test func 최신_개정본이_조회된다() async throws {
        let service = try makeService()
        let id = try await service.saveConcept(
            preferredTerm: "FTS5", aliases: [], field: "DB",
            oneLine: "구버전 설명", easyExplanation: "구버전",
            author: "ai", provider: "ollama:test"
        )
        // 사용자가 수정해도 conceptId는 동일 — 최신 개정본(user)이 보여야 한다.
        try await service.database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO definitionRevision (conceptId, oneLine, easyExplanation, author) VALUES (?, ?, ?, ?)",
                arguments: [id, "SQLite 전문 검색", "검색용 색인을 만드는 기능", "user"]
            )
        }
        let entries = try await service.lookupExact("FTS5")
        #expect(entries.count == 1)
        #expect(entries.first?.author == "user")
        #expect(entries.first?.oneLine == "SQLite 전문 검색")
    }
}

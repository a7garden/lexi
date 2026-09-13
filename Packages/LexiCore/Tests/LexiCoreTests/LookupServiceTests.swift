import Testing
import Foundation
import GRDB
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

    @Test func 저장과_조회는_DB생성시각이_아닌_실행시각을_기록한다() async throws {
        let service = try makeService()
        // v1 schema defaults were evaluated at migration time. Writes must override them.
        try await Task.sleep(for: .milliseconds(30))
        let earliest = Date.now.addingTimeInterval(-0.002)
        let id = try await service.saveConcept(
            preferredTerm: "시간 검증", aliases: [], field: nil,
            oneLine: "설명", easyExplanation: "", author: "ai", provider: "test"
        )
        try await service.recordLookup("시간 검증", conceptId: id, status: .hit)
        try await service.saveUserRevision(conceptId: id, oneLine: "수정", easyExplanation: "")
        let entry = try #require(try await service.lookupExact("시간 검증").first)
        try await service.addSource(revisionId: try #require(entry.revisionId), title: "출처", url: nil, excerpt: nil)
        let timestamps = try await service.database.writer.read { db in
            try Date.fetchAll(db, sql: """
                SELECT createdAt FROM concept
                UNION ALL SELECT updatedAt FROM concept
                UNION ALL SELECT createdAt FROM definitionRevision
                UNION ALL SELECT retrievedAt FROM sourceRef
                UNION ALL SELECT lookedUpAt FROM lookupRecord
                """)
        }
        #expect(timestamps.count == 6)
        // GRDB 기본 인코딩은 밀리초 TEXT("HH:MM:SS.SSS")라 반올림이 최대 +0.5ms 위로
        // 갈 수 있다. 상한에 저장 정밀도 여유를 둔다(하한은 기본값 비교용 그대로).
        #expect(timestamps.allSatisfy { $0 >= earliest && $0 <= Date.now.addingTimeInterval(0.01) })
    }

    @Test func 저장_시_용어_별칭_개정본의_언어를_기록한다() async throws {
        let service = try makeService()
        let conceptId = try await service.saveConcept(
            preferredTerm: "embedding",
            aliases: ["임베딩", "embeddings"],
            field: nil,
            oneLine: "An embedding represents meaning as a vector.",
            easyExplanation: "It maps text to numbers so similarity becomes distance.",
            author: "ai", provider: "mlx:test",
            explanationLanguage: .english
        )

        let entries = try await service.lookupExact("임베딩")
        #expect(entries.count == 1)
        #expect(entries[0].termLanguage == .english)  // 개념 언어는 표제어 기준
        #expect(entries[0].explanationLanguage == .english)

        // 별칭 언어는 별칭 텍스트별로 기록된다(PDC의 text+language 일치에 쓴다).
        let aliasLangs = try await service.database.writer.read { db in
            try String.fetchAll(
                db, sql: "SELECT lang FROM alias WHERE conceptId = ? ORDER BY text",
                arguments: [conceptId])
        }
        #expect(aliasLangs == ["en", "en", "ko"])
    }

    @Test func 요청한_설명_언어의_개정본을_우선한다() async throws {
        let service = try makeService()
        _ = try await service.saveConcept(
            preferredTerm: "토큰", aliases: [], field: nil,
            oneLine: "모델이 처리하는 텍스트 조각", easyExplanation: "문장을 잘게 쪼갠 단위.",
            author: "ai", provider: nil,
            termLanguage: .korean, explanationLanguage: .korean)
        try await service.saveUserRevision(
            conceptId: 1,
            oneLine: "A piece of text a model processes.",
            easyExplanation: "Sentences are split into small units called tokens.",
            language: .english)

        #expect(try await service.lookupExact("토큰", revisionLang: .korean).first?.explanationLanguage == .korean)
        #expect(try await service.lookupExact("토큰", revisionLang: .english).first?.explanationLanguage == .english)
        // 요청 언어의 개정본이 없으면 언어와 무관한 최신 개정본으로 떨어진다.
        #expect(try await service.lookupExact("토큰", revisionLang: .french).first?.explanationLanguage == .english)
        #expect(try await service.lookupExact("토큰").first?.explanationLanguage == .english)
    }

    @Test func 요청언어_불일치시_언어미상_최신개정본이_이긴다() async throws {
        let service = try makeService()
        let id = try await service.saveConcept(
            preferredTerm: "token", aliases: [], field: nil,
            oneLine: "토큰", easyExplanation: "구버전 한국어 설명",
            author: "ai", provider: "test",
            explanationLanguage: .korean
        )
        // 사용자 수정 개정본은 언어 판정에 실패해 lang이 NULL로 저장됐다.
        try await service.database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO definitionRevision (conceptId, oneLine, easyExplanation, author) VALUES (?, ?, ?, ?)",
                arguments: [id, "token", "latest explanation", "user"]
            )
        }
        // 요청 언어(영어) 개정본은 없으므로 언어와 무관한 최신 개정본이 보여야 한다.
        // NULL은 정렬에서 가장 낮으므로 COALESCE로 불일치(0)와 동급으로 만들지 않으면
        // 구버전이 이긴다.
        let entry = try await service.lookupExact("token", revisionLang: .english).first
        #expect(entry?.oneLine == "token")
    }

    @Test func 별칭_추정실패는_표제어_언어를_따른다() async throws {
        let service = try makeService()
        _ = try await service.saveConcept(
            preferredTerm: "token", aliases: ["1234!"], field: nil,
            oneLine: "a token", easyExplanation: "explanation",
            author: "ai", provider: "test",
            termLanguage: .japanese
        )
        let aliasLang = try await service.database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT lang FROM alias WHERE text = '1234!'")
        }
        // 판정에 실패한 별칭을 한국어로 몰아 적으면 PDC text+language 일치가 깨진다.
        #expect(aliasLang == "ja")
    }

}

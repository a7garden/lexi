import Testing
import Foundation
@testable import LexiCore

@Suite struct QueryCorrectionTests {
    // MARK: - 순수 보정 로직

    @Test func 한_글자_오타를_보정한다() {
        let candidates = ["데이터베이스", "머신러닝"]
        #expect(QueryCorrection.bestMatch(for: "데이터배이스", in: candidates) == "데이터베이스")
    }

    @Test func 전치는_한_번의_편집으로_친다() {
        #expect(QueryCorrection.restrictedEditDistance(Array("recieve"), Array("receive")) == 1)
        #expect(QueryCorrection.bestMatch(for: "recieve", in: ["receive"]) == "receive")
    }

    @Test func 대소문자만_달라도_후보가_된다() {
        #expect(QueryCorrection.bestMatch(for: "rag", in: ["RAG"]) == "RAG")
    }

    @Test func 저장_원문을_그대로_돌려준다() {
        // 폴딩은 후보 선정에만 쓰이고 결과는 발음 구별이 보존된 원문이다.
        #expect(QueryCorrection.bestMatch(for: "Cafe", in: ["Café"]) == "Café")
    }

    @Test func 짧은_질의는_두_글자_차이를_보정하지_않는다() {
        #expect(QueryCorrection.bestMatch(for: "나무", in: ["다수"]) == nil)
    }

    @Test func 한_글자_질의는_보정하지_않는다() {
        #expect(QueryCorrection.bestMatch(for: "R", in: ["RAG"]) == nil)
    }

    @Test func 가까운_후보가_여럿이면_길이가_가장_비슷한_것을_고른다() {
        // 둘 다 편집거리 1이지만 "헬로우"(길이 차 0)가 "헬로"(길이 차 1)를 이긴다.
        #expect(QueryCorrection.bestMatch(for: "헬로월", in: ["헬로", "헬로우"]) == "헬로우")
    }

    @Test func 멀리_떨어진_표현은_보정하지_않는다() {
        #expect(QueryCorrection.bestMatch(for: "완전다른질의어", in: ["데이터베이스"]) == nil)
    }

    @Test func 빈_후보는_보정하지_않는다() {
        #expect(QueryCorrection.bestMatch(for: "데이터베이스", in: []) == nil)
    }

    // MARK: - 조회 파이프라인 통합

    @Test func 오타_질의를_보정해_찾고_보정을_알려준다() async throws {
        let service = try makeService()
        let conceptId = try await 저장(service: service, term: "데이터베이스")

        let result = try await service.lookup("데이터배이스")
        #expect(result.entries.map(\.conceptId) == [conceptId])
        #expect(result.correction?.original == "데이터배이스")
        #expect(result.correction?.replacement == "데이터베이스")
    }

    @Test func 정확_검색은_보정_정보를_달지_않는다() async throws {
        let service = try makeService()
        let conceptId = try await 저장(service: service, term: "RAG", aliases: ["검색 증강 생성"])

        let result = try await service.lookup("  RAG  ")
        #expect(result.entries.map(\.conceptId) == [conceptId])
        #expect(result.correction == nil)
    }

    @Test func 보정을_끄면_원본_그대로_빈_결과() async throws {
        let service = try makeService()
        _ = try await 저장(service: service, term: "데이터베이스")

        let result = try await service.lookup("데이터배이스", typoCorrection: false)
        #expect(result.entries.isEmpty)
        #expect(result.correction == nil)
    }

    @Test func 가까운_저장_표현이_없으면_보정하지_않는다() async throws {
        let service = try makeService()
        _ = try await 저장(service: service, term: "데이터베이스")

        let result = try await service.lookup("머신러닝")
        #expect(result.entries.isEmpty)
        #expect(result.correction == nil)
    }

    private func makeService() throws -> LookupService {
        let db = try AppDatabase.makeInMemory()
        try db.migrate()
        return LookupService(database: db)
    }

    private func 저장(
        service: LookupService,
        term: String,
        aliases: [String] = []
    ) async throws -> Int64 {
        try await service.saveConcept(
            preferredTerm: term,
            aliases: aliases,
            field: nil,
            oneLine: "한 줄 설명",
            easyExplanation: "쉬운 설명",
            author: "user",
            provider: nil
        )
    }
}

import Foundation
import Testing
@testable import LexiCore

private actor RecordingEmbeddingProvider: TextEmbeddingProvider {
    enum Mode: Sendable, Equatable {
        case normal
        case invalidDocumentCount
    }

    nonisolated let identifier = "test:semantic"
    private let mode: Mode
    private var queryInputs: [String] = []
    private var documentInputs: [String] = []

    init(mode: Mode = .normal) {
        self.mode = mode
    }

    func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> [[Float]] {
        switch purpose {
        case .query:
            queryInputs.append(contentsOf: texts)
            return texts.map { _ in [1, 0] }
        case .document:
            documentInputs.append(contentsOf: texts)
            if mode == .invalidDocumentCount { return [] }
            return texts.map { text in
                if text.contains("외부 지식") || text.contains("벡터 유사도") {
                    return text.contains("외부 지식") ? [1, 0] : [0.8, 0.2]
                }
                return [0, 1]
            }
        }
    }

    func recordedInputs() -> (queries: [String], documents: [String]) {
        (queryInputs, documentInputs)
    }
}

@Suite struct SemanticSearchTests {
    private func makeService() throws -> LookupService {
        let database = try AppDatabase.makeInMemory()
        try database.migrate()
        return LookupService(database: database)
    }

    @Test func 의미검색은_일반검색과_별도로_유사도순_결과를_돌려준다() async throws {
        let service = try makeService()
        let rag = try await service.saveConcept(
            preferredTerm: "RAG",
            aliases: ["검색 증강 생성"],
            field: "AI",
            oneLine: "외부 지식을 찾아 답변에 활용한다",
            easyExplanation: "필요한 자료를 먼저 검색한다.",
            author: "user",
            provider: nil
        )
        let vectorDB = try await service.saveConcept(
            preferredTerm: "벡터 데이터베이스",
            aliases: ["vector database"],
            field: "DB",
            oneLine: "벡터 유사도로 가까운 자료를 찾는다",
            easyExplanation: "뜻이 가까운 항목을 검색한다.",
            author: "user",
            provider: nil
        )
        _ = try await service.saveConcept(
            preferredTerm: "사워도우",
            aliases: [],
            field: "요리",
            oneLine: "천연 발효종으로 만든 빵",
            easyExplanation: "오래 발효하는 빵이다.",
            author: "user",
            provider: nil
        )

        let search = SemanticLibrarySearch(
            service: service,
            provider: RecordingEmbeddingProvider()
        )
        let matches = try await search.matches(
            query: "필요한 자료를 찾아 답하는 방법",
            minimumSimilarity: 0.7
        )

        #expect(matches.map(\.item.conceptId) == [rag, vectorDB])
        #expect(matches[0].similarity > matches[1].similarity)
    }

    @Test func 의미검색은_텍스트일치_항목을_중복해서_보여주지_않는다() async throws {
        let service = try makeService()
        let rag = try await service.saveConcept(
            preferredTerm: "RAG", aliases: [], field: nil,
            oneLine: "외부 지식을 찾아 답한다", easyExplanation: "검색 뒤 생성한다.",
            author: "user", provider: nil
        )
        let vectorDB = try await service.saveConcept(
            preferredTerm: "벡터 DB", aliases: [], field: nil,
            oneLine: "벡터 유사도로 검색한다", easyExplanation: "가까운 자료를 찾는다.",
            author: "user", provider: nil
        )
        let search = SemanticLibrarySearch(
            service: service,
            provider: RecordingEmbeddingProvider()
        )

        let matches = try await search.matches(
            query: "검색",
            excludingConceptIDs: [rag],
            minimumSimilarity: 0.7
        )

        #expect(matches.map(\.item.conceptId) == [vectorDB])
    }

    @Test func 임베딩입력은_별칭과_최신설명을_포함하고_변경된_항목만_다시_계산한다() async throws {
        let service = try makeService()
        let rag = try await service.saveConcept(
            preferredTerm: "RAG", aliases: ["검색 증강 생성"], field: "AI",
            oneLine: "외부 지식을 찾아 답한다", easyExplanation: "처음 설명",
            author: "user", provider: nil
        )
        _ = try await service.saveConcept(
            preferredTerm: "사워도우", aliases: [], field: "요리",
            oneLine: "발효 빵", easyExplanation: "반죽을 오래 발효한다.",
            author: "user", provider: nil
        )
        let provider = RecordingEmbeddingProvider()
        let search = SemanticLibrarySearch(service: service, provider: provider)

        _ = try await search.matches(query: "검색", minimumSimilarity: -1)
        _ = try await search.matches(query: "자료", minimumSimilarity: -1)
        var recorded = await provider.recordedInputs()
        #expect(recorded.queries == ["검색", "자료"])
        #expect(recorded.documents.count == 2)
        #expect(recorded.documents.contains { $0.contains("별칭: 검색 증강 생성") })
        #expect(recorded.documents.contains { $0.contains("쉬운 설명: 처음 설명") })

        try await service.saveUserRevision(
            conceptId: rag,
            oneLine: "외부 지식을 찾아 답한다",
            easyExplanation: "바뀐 최신 설명"
        )
        _ = try await search.matches(query: "검색", minimumSimilarity: -1)
        recorded = await provider.recordedInputs()
        #expect(recorded.documents.count == 3)
        #expect(recorded.documents.last?.contains("쉬운 설명: 바뀐 최신 설명") == true)
    }

    @Test func 제공자의_배치결과수가_다르면_진단한다() async throws {
        let service = try makeService()
        _ = try await service.saveConcept(
            preferredTerm: "RAG", aliases: [], field: nil,
            oneLine: "외부 지식을 찾아 답한다", easyExplanation: "검색한다.",
            author: "user", provider: nil
        )
        let search = SemanticLibrarySearch(
            service: service,
            provider: RecordingEmbeddingProvider(mode: .invalidDocumentCount)
        )

        do {
            _ = try await search.matches(query: "검색")
            Issue.record("잘못된 배치 결과는 오류여야 한다")
        } catch SemanticSearchError.invalidEmbeddingResult {
            // expected
        } catch {
            Issue.record("예상하지 못한 오류: \(error)")
        }
    }
}

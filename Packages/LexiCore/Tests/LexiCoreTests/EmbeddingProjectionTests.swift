import Testing
import Foundation
@testable import LexiCore

@Suite struct EmbeddingProjectionTests {
    private func point(_ conceptId: Int64, _ vector: [Float], term: String? = nil, field: String? = nil) -> ConceptEmbedding {
        ConceptEmbedding(
            conceptId: conceptId,
            term: term ?? "t\(conceptId)",
            field: field,
            vector: vector
        )
    }

    @Test func 점이_세_개_미만이면_투영하지_않는다() {
        #expect(EmbeddingProjection.project([]) == nil)
        #expect(EmbeddingProjection.project([point(1, [1, 0]), point(2, [0, 1])]) == nil)
    }

    @Test func 차원이_두_개_미만이거나_서로_다르면_투영하지_않는다() {
        #expect(EmbeddingProjection.project([
            point(1, [1]), point(2, [2]), point(3, [3]),
        ]) == nil)
        #expect(EmbeddingProjection.project([
            point(1, [1, 0]), point(2, [0, 1, 2]), point(3, [1, 1]),
        ]) == nil)
    }

    @Test func 모든_벡터가_같으면_투영하지_않는다() {
        let same = [Float(1), 2, 3, 4]
        #expect(EmbeddingProjection.project([
            point(1, same), point(2, same), point(3, same), point(4, same),
        ]) == nil)
    }

    @Test func 두_군집을_서로_갈라놓는다() {
        // 군집 A는 첫 축, 군집 B는 두 번째 축 방향. 잡음은 군집 간 거리보다 훨씬 작다.
        var points: [ConceptEmbedding] = []
        for index in 0..<4 {
            points.append(point(Int64(100 + index), [10, Float(index) * 0.1, 0, 0], field: "A"))
            points.append(point(Int64(200 + index), [Float(index) * 0.1, 10, 0, 0], field: "B"))
        }

        let projected = EmbeddingProjection.project(points)!

        let aCluster = projected.filter { $0.field == "A" }
        let bCluster = projected.filter { $0.field == "B" }
        func centroidX(_ cluster: [ProjectedConcept]) -> Double {
            cluster.map(\.x).reduce(0, +) / Double(cluster.count)
        }
        // 군집 중심 사이 거리는 군집 내 퍼짐보다 크다.
        let spread = aCluster.map(\.x).map { abs($0 - centroidX(aCluster)) }.max()!
        let separation = abs(centroidX(aCluster) - centroidX(bCluster))
        #expect(separation > 1.0)
        #expect(spread < 0.2)
        // 결정적이다: 같은 입력이면 같은 결과.
        #expect(EmbeddingProjection.project(points) == projected)
    }

    @Test func 좌표는_단위_상자로_정규화된다() {
        let points = [
            point(1, [0, 0, 0]),
            point(2, [12, 0, 0]),
            point(3, [0, 5, 0]),
            point(4, [3, 1, 1]),
        ]

        let projected = EmbeddingProjection.project(points)!

        let maxAbs = projected.reduce(0.0) { max($0, abs($1.x), abs($1.y)) }
        #expect(abs(maxAbs - 1.0) < 1e-9)
    }

    @Test func 한_직선위_데이터도_유한한_지도를_돌려준다() {
        let points = [
            point(1, [1, 2, 3]),
            point(2, [2, 4, 6]),
            point(3, [3, 6, 9]),
            point(4, [5, 10, 15]),
        ]

        let projected = EmbeddingProjection.project(points)!

        #expect(projected.count == 4)
        #expect(projected.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        // 두 번째 성분의 분산이 없으므로 y는 0에 가깝다.
        #expect(projected.allSatisfy { abs($0.y) < 1e-6 })
    }
}

/// 캐시 동작을 관찰하기 위한 문서 임베딩 횟수 기록 제공자.
private actor CountingEmbeddingProvider: TextEmbeddingProvider {
    nonisolated let identifier = "counting:test"
    private(set) var documentEmbedCount = 0

    func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> [[Float]] {
        if purpose == .document { documentEmbedCount += texts.count }
        // 원문별로 구분되는 3차원 벡터. 원문이 바뀌면 벡터도 바뀐다.
        return texts.map { text in [Float(abs(text.hashValue % 997)), 1, 2] }
    }

    func recordedDocumentEmbedCount() -> Int {
        documentEmbedCount
    }
}

@Suite struct SemanticLibraryEmbeddingsTests {
    private func makeSearch() throws -> (LookupService, SemanticLibrarySearch, CountingEmbeddingProvider) {
        let db = try AppDatabase.makeInMemory()
        try db.migrate()
        let service = LookupService(database: db)
        let provider = CountingEmbeddingProvider()
        return (service, SemanticLibrarySearch(service: service, provider: provider), provider)
    }

    @Test func libraryEmbeddings는_캐시를_재사용하고_변경된_문서만_다시_계산한다() async throws {
        let (service, search, provider) = try makeSearch()
        let rag = try await service.saveConcept(
            preferredTerm: "RAG", aliases: [], field: nil,
            oneLine: "검색 증강 생성", easyExplanation: "찾아서 답한다.",
            author: "ai", provider: "test"
        )
        try await service.saveConcept(
            preferredTerm: "FTS5", aliases: [], field: nil,
            oneLine: "전문 검색", easyExplanation: "빠르게 찾는다.",
            author: "ai", provider: "test"
        )

        let first = try await search.libraryEmbeddings()
        #expect(first.count == 2)
        #expect(await provider.documentEmbedCount == 2)

        // 같은 입력이면 임베딩을 다시 계산하지 않는다.
        let second = try await search.libraryEmbeddings()
        #expect(second.count == 2)
        #expect(await provider.documentEmbedCount == 2)

        // 수정되면 그 문서만 다시 계산한다.
        try await service.saveUserRevision(conceptId: rag, oneLine: "검색해 답을 만든다", easyExplanation: "바뀐 설명.")
        let third = try await search.libraryEmbeddings()
        #expect(third.count == 2)
        #expect(await provider.documentEmbedCount == 3)
        #expect(third.first { $0.conceptId == rag }?.vector != first.first { $0.conceptId == rag }?.vector)
    }
}

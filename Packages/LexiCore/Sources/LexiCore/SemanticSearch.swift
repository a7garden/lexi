import Foundation
import MLX
import MLXEmbedders

/// 같은 임베딩 모델에서도 검색어와 문서에 서로 다른 접두어가 필요할 수 있다.
public enum EmbeddingPurpose: Sendable {
    case query
    case document
}

/// 의미 검색이 사용하는 배치 임베딩 추상화. 테스트에서는 모델 다운로드 없이 대역을 주입한다.
public protocol TextEmbeddingProvider: Sendable {
    var identifier: String { get }
    func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> [[Float]]
}

public enum SemanticSearchError: LocalizedError {
    case modelUnavailable(String)
    case invalidEmbeddingResult

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let detail):
            "의미 임베딩 모델을 준비할 수 없습니다: \(detail)"
        case .invalidEmbeddingResult:
            "의미 임베딩 모델이 올바르지 않은 결과를 돌려줬습니다."
        }
    }
}

/// 한국어와 영어를 함께 다루는 로컬 MLX 임베딩 제공자.
///
/// 모델 파일은 사용자가 의미 검색을 처음 실행할 때 Hugging Face에서 내려받고,
/// 이후 벡터 계산은 Mac 안에서만 수행한다.
public struct MLXTextEmbeddingProvider: TextEmbeddingProvider {
    public struct Config: Sendable {
        public var modelID: String
        public var maxTokens: Int
        public var batchSize: Int

        public init(
            modelID: String = MLXTextEmbeddingProvider.defaultModelID,
            maxTokens: Int = 256,
            batchSize: Int = 32
        ) {
            precondition(maxTokens > 0)
            precondition(batchSize > 0)
            self.modelID = modelID
            self.maxTokens = maxTokens
            self.batchSize = batchSize
        }
    }

    public static let defaultModelID = "intfloat/multilingual-e5-small"

    public let config: Config

    public init(config: Config = Config()) {
        self.config = config
    }

    public var identifier: String { "mlx-embedding:\(config.modelID)" }

    private actor ContainerCache {
        private var containers: [String: MLXEmbedders.ModelContainer] = [:]
        private var inflight: [String: Task<MLXEmbedders.ModelContainer, Error>] = [:]

        func container(for modelID: String) async throws -> MLXEmbedders.ModelContainer {
            if let container = containers[modelID] { return container }
            if let task = inflight[modelID] { return try await task.value }

            let task = Task.detached(priority: .userInitiated) {
                try await MLXEmbedders.loadModelContainer(
                    configuration: MLXEmbedders.ModelConfiguration(id: modelID)
                )
            }
            inflight[modelID] = task
            do {
                let container = try await task.value
                containers[modelID] = container
                inflight[modelID] = nil
                return container
            } catch {
                inflight[modelID] = nil
                throw error
            }
        }
    }

    private static let containerCache = ContainerCache()

    public func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        let container: MLXEmbedders.ModelContainer
        do {
            container = try await Self.containerCache.container(for: config.modelID)
        } catch {
            throw SemanticSearchError.modelUnavailable(error.localizedDescription)
        }

        let prepared = texts.map { text in
            switch purpose {
            case .query: "query: \(text)"
            case .document: "passage: \(text)"
            }
        }

        var result: [[Float]] = []
        result.reserveCapacity(prepared.count)

        for start in stride(from: 0, to: prepared.count, by: config.batchSize) {
            try Task.checkCancellation()
            let end = min(start + config.batchSize, prepared.count)
            let batch = Array(prepared[start ..< end])
            let maxTokens = config.maxTokens

            let vectors = try await container.perform { model, tokenizer, _ -> [[Float]] in
                let encoded = batch.map {
                    Array(tokenizer.encode(text: $0, addSpecialTokens: true).prefix(maxTokens))
                }
                guard encoded.allSatisfy({ !$0.isEmpty }) else {
                    throw SemanticSearchError.invalidEmbeddingResult
                }

                let paddingID = tokenizer.convertTokenToId("<pad>")
                    ?? tokenizer.convertTokenToId("[PAD]")
                    ?? 0
                let longest = encoded.map(\.count).max() ?? 1
                let tokenIDs = stacked(encoded.map { tokens in
                    MLXArray(tokens + Array(repeating: paddingID, count: longest - tokens.count))
                })
                let attentionMask = tokenIDs .!= paddingID
                let tokenTypes = MLXArray.zeros(like: tokenIDs)
                let pooler = Pooling(strategy: .mean)
                let embeddings = pooler(
                    model(
                        tokenIDs,
                        positionIds: nil,
                        tokenTypeIds: tokenTypes,
                        attentionMask: attentionMask
                    ),
                    mask: attentionMask,
                    normalize: true
                )
                eval(embeddings)
                return embeddings.map { $0.asArray(Float.self) }
            }
            result.append(contentsOf: vectors)
        }

        guard result.count == texts.count else {
            throw SemanticSearchError.invalidEmbeddingResult
        }
        return result
    }
}

/// 일반 텍스트 검색과 중복되지 않는 의미상 유사한 라이브러리 항목.
public struct SemanticLibraryMatch: Sendable, Equatable, Identifiable {
    public var id: Int64 { item.id }
    public var item: LibraryItem
    public var similarity: Float

    public init(item: LibraryItem, similarity: Float) {
        self.item = item
        self.similarity = similarity
    }
}

/// SQLite 원문에서 만든 파생 벡터를 메모리에 캐시하고 코사인 유사도로 순위를 매긴다.
/// 캐시는 원문이나 제공자 ID가 달라지면 자동으로 다시 계산되며 DB 정본에는 쓰지 않는다.
public actor SemanticLibrarySearch {
    private struct CachedEmbedding {
        var sourceText: String
        var vector: [Float]
    }

    private let service: LookupService
    private let provider: any TextEmbeddingProvider
    private var cachedProviderID: String?
    private var documentCache: [Int64: CachedEmbedding] = [:]

    public init(service: LookupService, provider: any TextEmbeddingProvider) {
        self.service = service
        self.provider = provider
    }

    public func matches(
        query rawQuery: String,
        filter: LibraryFilter = .all,
        excludingConceptIDs: Set<Int64> = [],
        limit: Int = 8,
        minimumSimilarity: Float = 0.72
    ) async throws -> [SemanticLibraryMatch] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }

        let documents = try await service.semanticLibraryDocuments(filter: filter, limit: 500)
            .filter { !excludingConceptIDs.contains($0.item.conceptId) }
        guard !documents.isEmpty else { return [] }

        if cachedProviderID != provider.identifier {
            documentCache.removeAll(keepingCapacity: true)
            cachedProviderID = provider.identifier
        }

        let queryResults = try await provider.embed([query], purpose: .query)
        guard let queryVector = queryResults.first,
              queryResults.count == 1,
              Self.isUsable(queryVector)
        else {
            throw SemanticSearchError.invalidEmbeddingResult
        }

        let staleDocuments = documents.filter { document in
            documentCache[document.item.conceptId]?.sourceText != document.sourceText
        }
        if !staleDocuments.isEmpty {
            let vectors = try await provider.embed(
                staleDocuments.map(\.sourceText),
                purpose: .document
            )
            guard vectors.count == staleDocuments.count else {
                throw SemanticSearchError.invalidEmbeddingResult
            }
            for (document, vector) in zip(staleDocuments, vectors) {
                guard Self.isUsable(vector) else { continue }
                documentCache[document.item.conceptId] = CachedEmbedding(
                    sourceText: document.sourceText,
                    vector: vector
                )
            }
        }

        try Task.checkCancellation()
        return documents.compactMap { document -> SemanticLibraryMatch? in
            guard let vector = documentCache[document.item.conceptId]?.vector,
                  let similarity = Self.cosineSimilarity(queryVector, vector),
                  similarity >= minimumSimilarity
            else { return nil }
            return SemanticLibraryMatch(item: document.item, similarity: similarity)
        }
        .sorted {
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            return $0.item.conceptId < $1.item.conceptId
        }
        .prefix(limit)
        .map { $0 }
    }

    private static func isUsable(_ vector: [Float]) -> Bool {
        !vector.isEmpty && vector.allSatisfy(\.isFinite)
    }

    private static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float? {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }
        var dot: Double = 0
        var lhsSquared: Double = 0
        var rhsSquared: Double = 0
        for (left, right) in zip(lhs, rhs) {
            let left = Double(left)
            let right = Double(right)
            dot += left * right
            lhsSquared += left * left
            rhsSquared += right * right
        }
        guard lhsSquared > 0, rhsSquared > 0 else { return nil }
        let similarity = dot / (sqrt(lhsSquared) * sqrt(rhsSquared))
        guard similarity.isFinite else { return nil }
        return Float(max(-1, min(1, similarity)))
    }
}

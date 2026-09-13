import Foundation
import MLXLLM
import MLXLMCommon

/// MLX Swift 기반 로컬 생성 엔진 (Apple Silicon 네이티브).
///
/// 모델 가중치는 첫 로드 시 ``LLMModelFactory``/`HubApi`가 Hugging Face에서
/// 내려받고(코드에서 다운로드를 구현하지 않는다), 컨테이너는 프로세스 수명 동안
/// 모델 ID별로 캐시되어 `complete` 호출마다 재로딩되지 않는다.
public struct MLXProvider: LLMProvider {
    public struct Config: Sendable {
        /// Hugging Face 모델 ID (예: `mlx-community/Qwen3-4B-4bit`)
        public var modelID: String

        public init(modelID: String) {
            self.modelID = modelID
        }
    }

    /// 생성 최대 토큰 수
    static let maxTokens = 1024
    /// 샘플링 온도
    static let temperature: Float = 0.6

    public let config: Config

    public init(config: Config) {
        self.config = config
    }

    public var identifier: String { "mlx:\(config.modelID)" }

    /// 모델 ID별 컨테이너 캐시. 첫 로드를 단일 작업으로 합쳐 중복 다운로드/로딩을 막는다.
    private actor ContainerCache {
        private var containers: [String: ModelContainer] = [:]
        private var inflight: [String: Task<ModelContainer, Error>] = [:]

        func container(for modelID: String) async throws -> ModelContainer {
            if let container = containers[modelID] { return container }
            if let existing = inflight[modelID] { return try await existing.value }

            let task = Task.detached(priority: .userInitiated) {
                try await LLMModelFactory.shared.loadContainer(
                    configuration: ModelConfiguration(id: modelID))
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

    public func complete(system: String?, user: String) async throws -> String {
        let container: ModelContainer
        do {
            container = try await Self.containerCache.container(for: config.modelID)
        } catch {
            throw LLMProviderError.unreachable(
                "MLX 모델 로드 실패 (\(config.modelID)): \(error.localizedDescription)")
        }

        var messages: [Chat.Message] = []
        if let system { messages.append(.system(system)) }
        messages.append(.user(user))

        // Chat.Message는 Sendable이 아니므로 컨테이너 클로저 진입 전에
        // Sendable인 UserInput으로 변환해 캡처한다.
        let input = UserInput(chat: messages)

        let parameters = GenerateParameters(
            maxTokens: Self.maxTokens, temperature: Self.temperature)

        let output = try await container.perform { context -> String in
            let lmInput = try await context.processor.prepare(input: input)
            let stream = try generate(
                input: lmInput, parameters: parameters, context: context)
            var text = ""
            for await generation in stream {
                if let chunk = generation.chunk { text += chunk }
            }
            return text
        }

        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LLMProviderError.badResponse("MLX 생성 결과가 비어 있음 (\(config.modelID))")
        }
        return output
    }
}

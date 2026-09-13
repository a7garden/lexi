import Foundation

/// Ollama 로컬 서버 어댑터 (기본 http://localhost:11434).
///
/// 주의(설계 문서): 로컬 주소에 연결된다고 계산이 로컬인 것은 아니다.
/// Ollama는 클라우드 기능을 함께 제공하므로, 실행 위치 표시는 이 어댑터만으로 단정하지 않고
/// 설정의 "실행 위치" 정보와 함께 다뤄야 한다.
public struct OllamaProvider: LLMProvider {
    public struct Config: Sendable {
        public var baseURL: URL
        public var model: String
        /// 생성 요청 타임아웃. 로컬 모델 로딩이 첫 요청에 수십 초 걸릴 수 있다.
        public var timeout: TimeInterval

        public init(baseURL: URL = URL(string: "http://localhost:11434")!, model: String, timeout: TimeInterval = 300) {
            self.baseURL = baseURL
            self.model = model
            self.timeout = timeout
        }
    }

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let stream: Bool
    }

    private struct ChatResponse: Decodable {
        struct Message: Decodable {
            let content: String
        }
        let message: Message
    }

    public let config: Config
    public var identifier: String { "ollama:\(config.model)" }

    private let session: URLSession

    public init(config: Config) {
        self.config = config
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = config.timeout
        self.session = URLSession(configuration: configuration)
    }

    public func complete(system: String?, user: String) async throws -> String {
        var messages: [ChatRequest.Message] = []
        if let system { messages.append(.init(role: "system", content: system)) }
        messages.append(.init(role: "user", content: user))

        var request = URLRequest(url: config.baseURL.appending(path: "api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatRequest(model: config.model, messages: messages, stream: false))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMProviderError.unreachable("HTTP 응답이 아닙니다")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw LLMProviderError.unreachable("Ollama가 \(http.statusCode)를 반환했습니다: \(String(data: data, encoding: .utf8) ?? "")")
        }
        do {
            return try JSONDecoder().decode(ChatResponse.self, from: data).message.content
        } catch {
            throw LLMProviderError.badResponse(String(describing: error))
        }
    }
}

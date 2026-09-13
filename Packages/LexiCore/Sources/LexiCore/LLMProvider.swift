import Foundation

/// 생성 엔진 추상화. 사전 데이터와 조회 동작은 제공자가 바뀌어도 그대로 유지된다.
/// - Ollama (외부 로컬 서버)
/// - MLX Swift (앱 내장, 후행 마일스톤)
/// - 외부 API (OpenAI 호환, 사용자가 명시적으로 선택한 경우에만)
public protocol LLMProvider: Sendable {
    /// 설정 화면에 표시할 식별자 (예: "ollama:llama3.1:8b")
    var identifier: String { get }

    /// 단일 프롬프트 완성. 구조화 출력(JSON)은 상위 계층에서 스키마로 요청한다.
    func complete(system: String?, user: String) async throws -> String
}

public enum LLMProviderError: LocalizedError {
    case unreachable(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let detail): "생성 엔진에 연결할 수 없습니다: \(detail)"
        case .badResponse(let detail): "생성 엔진 응답을 해석할 수 없습니다: \(detail)"
        }
    }
}

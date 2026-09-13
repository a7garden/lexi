import XCTest
@testable import LexiCore

/// 컴파일 수준 검증. 모델 다운로드/생성은 실행하지 않는다.
final class MLXProviderTests: XCTestCase {
    func testIdentifierEmbedsModelID() {
        let provider = MLXProvider(config: .init(modelID: "mlx-community/Qwen3-4B-4bit"))
        XCTAssertEqual(provider.identifier, "mlx:mlx-community/Qwen3-4B-4bit")
    }
}

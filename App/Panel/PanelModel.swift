import Foundation
import LexiCore

/// 즉시 보기 패널의 상태와 액션 콜백.
/// 상태는 루트 파이프라인이 `update(_:)`로 주입하고, UI는 콜백으로 되묻는다.
@MainActor
public final class PanelModel: ObservableObject {
    public enum PanelState: Equatable, Sendable {
        /// 사전에 저장된 항목을 바로 보여줌. correction = 오타를 보정해 찾은 경우.
        case hit(DictionaryEntry, correction: LookupCorrection?)
        /// 사전에 없어 AI 조사 진행 중.
        case researching(query: String)
        /// AI 조사 완료. saved = 사전 저장 여부.
        case result(DictionaryEntry, sources: [PanelSource], saved: Bool)
        /// 빈 질의 등 빈 상태.
        case empty(query: String)
        /// 조사 실패.
        case failed(query: String, message: String)
    }

    public struct PanelSource: Equatable, Identifiable, Sendable {
        public var id: UUID = UUID()
        public var title: String
        public var url: URL?
        public var excerpt: String?

        public init(id: UUID = UUID(), title: String, url: URL? = nil, excerpt: String? = nil) {
            self.id = id
            self.title = title
            self.url = url
            self.excerpt = excerpt
        }
    }

    @Published public private(set) var state: PanelState

    public var onRetry: (() -> Void)?
    public var onCancel: (() -> Void)?
    public var onEdit: (() -> Void)?
    public var onSettings: (() -> Void)?
    /// 패널 닫기 — InstantPanelController가 주입.
    public var onClose: (() -> Void)?

    public init(state: PanelState = .empty(query: "")) {
        self.state = state
    }

    public func update(_ state: PanelState) {
        self.state = state
    }
}

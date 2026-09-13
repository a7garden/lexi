import AppKit
import SwiftUI

/// Esc 닫기를 지원하는 nonactivating 패널.
/// `becomesKeyOnlyIfNeeded = true`라서 편집 뷰 클릭 시에만 key가 되고,
/// key인 동안 Esc는 `cancelOperation:` → `onEscape`로 닫힌다.
@MainActor
final class LexiInstantPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            cancelOperation(self)
        } else {
            super.keyDown(with: event)
        }
    }
}

/// 즉시 보기 패널 윈도우 래퍼. 호스트 앱을 활성화하지 않고 띄우는 게 계약.
@MainActor
public final class InstantPanelController {
    private static let panelSize = CGSize(width: 380, height: 460)

    private let model: PanelModel
    private var panel: LexiInstantPanel?

    public init(model: PanelModel) {
        self.model = model
        model.onClose = { [weak self] in self?.close() }
    }

    /// 패널 표시. point는 AppKit 스크린 좌표(좌하단 원점).
    /// point가 nil이거나 어떤 화면에도 속하지 않으면 마우스 커서가 있는 화면 중앙 상단 근처에 띄운다.
    /// NSApp.activate를 호출하지 않는다 — orderFrontRegardless로 활성화 없이 앞으로 가져온다.
    public func show(near point: CGPoint?) {
        guard let screen = targetScreen(for: point) else { return }
        let panel = makePanelIfNeeded()
        panel.setFrame(Self.panelFrame(near: point, on: screen), display: false)
        panel.orderFrontRegardless()
    }

    public func close() {
        panel?.orderOut(nil)
    }

    public var isVisible: Bool {
        panel?.isVisible ?? false
    }

    // MARK: - Internals

    private func makePanelIfNeeded() -> LexiInstantPanel {
        if let panel { return panel }
        let panel = LexiInstantPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView], // .resizable 의도적 제외
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .windowBackgroundColor
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.onEscape = { [weak self] in self?.close() }
        panel.contentView = NSHostingView(rootView: PanelContentView(model: model))
        self.panel = panel
        return panel
    }

    /// 표시 기준 화면: point가 속한 화면 → 마우스 커서가 있는 화면 → 메인 화면.
    private func targetScreen(for point: CGPoint?) -> NSScreen? {
        if let point, let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            return screen
        }
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return screen
        }
        return NSScreen.main
    }

    /// point 근처(우측 아래, 공간 부족 시 위) 배치. 화면 visibleFrame 안으로 클램프.
    private static func panelFrame(near point: CGPoint?, on screen: NSScreen) -> CGRect {
        let size = panelSize
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        guard let point, screen.frame.insetBy(dx: -1, dy: -1).contains(point) else {
            let origin = CGPoint(
                x: visible.midX - size.width / 2,
                y: visible.maxY - size.height - 48
            )
            return CGRect(origin: origin, size: size)
        }
        var origin = CGPoint(x: point.x + 14, y: point.y - size.height - 14)
        if origin.y < visible.minY { // 아래 공간 부족 → 포인트 위로
            origin.y = point.y + 14
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }
}

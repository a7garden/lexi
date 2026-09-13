import AppKit
import KeyboardShortcuts
import LexiCore
import SwiftUI
@preconcurrency import UserNotifications

/// 목업 #2의 글로벌 단축키. 기본값 ⌘D (클립보드 텍스트로 검색).
extension KeyboardShortcuts.Name {
    static let lookupSelection = Self("lookupSelection", default: .init(.d, modifiers: [.command]))
}

/// 검색 없이 로컬 모델 지식만으로 초안을 만드는 경로(웹 조사 비허용 시).
/// 이 경우 출처가 없으므로 결과는 "AI 초안 · 외부 출처 없음" 상태로 표시된다.
struct NoSearch: SearchProvider {
    func search(_ query: String, limit: Int) async throws -> [SearchHit] { [] }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panelController: InstantPanelController?
    private var panelModel: PanelModel?
    private var pipeline: LookupPipeline?
    private var researchTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpEngine()
        setUpStatusItem()
        setUpPanel()
        setUpShortcuts()
        NSApp.servicesProvider = self

        if let demo = ProcessInfo.processInfo.environment["LEXI_DEMO_QUERY"], !demo.isEmpty {
            Task { await runLookup(demo) }
        }
    }

    // MARK: - 생성 엔진 (설정 연동)

    private func setUpEngine() {
        guard let db = try? AppDatabase.makeDefault() else { return }
        try? db.migrate()
        let service = LookupService(database: db)

        let defaults = UserDefaults.standard
        let modelID = defaults.string(forKey: "mlxModelID") ?? "mlx-community/Qwen3-4B-4bit"
        let webAllowed = defaults.bool(forKey: "webResearchAllowed")

        // 내장 MLX(Apple Silicon)가 기본 생성 엔진. 모델 파일은 첫 생성 시 내려받는다.
        let provider = MLXProvider(config: .init(modelID: modelID))
        let research = WebResearchService(
            search: webAllowed ? DuckDuckGoSearch() : NoSearch(),
            llm: provider,
            fetcher: PageFetcher()
        )
        pipeline = LookupPipeline(service: service, research: research, llmIdentifier: provider.identifier)
    }

    // MARK: - 패널

    private func setUpPanel() {
        let model = PanelModel()
        panelModel = model
        panelController = InstantPanelController(model: model)
        wirePanelActions()
    }

    private func wirePanelActions() {
        guard let model = panelModel else { return }
        model.onRetry = { [weak self] in
            guard let self, let query = self.pipeline?.lastQuery, !query.isEmpty else { return }
            self.researchTask?.cancel()
            self.researchTask = Task { await self.runLookup(query) }
        }
        model.onCancel = { [weak self] in
            self?.researchTask?.cancel()
            self?.panelController?.close()
        }
        model.onEdit = { [weak self] in self?.openLibrary() }
        model.onFollowUp = nil  // 추가 질문(패널 확장)은 후속 마일스톤
    }

    private func setUpShortcuts() {
        KeyboardShortcuts.onKeyUp(for: .lookupSelection) { [weak self] in
            self?.lookupFromSelection()
        }
    }

    // MARK: - 조회 흐름

    private func lookupFromSelection() {
        guard SelectedTextReader.isAccessibilityGranted(promptIfNeeded: true) else { return }
        do {
            let text = try SelectedTextReader.readSelectedText()
            Task { await runLookup(text) }
        } catch {
            // 설계 규칙: 읽기 실패 시 클립보드로 대체 조회하지 않는다. 사전 창을 연다.
            openLibrary()
        }
    }

    private func runLookup(_ query: String) async {
        guard let pipeline, let model = panelModel else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 1차: 사전 정확 검색 — AI 실행 없음.
        let entries = await pipeline.lookup(trimmed)
        if let hit = entries.first {
            model.update(.hit(hit))
            panelController?.show(near: NSEvent.mouseLocation)
            return
        }

        // 2차: 조사·생성. 엔진이 없으면 억지로 정의를 만들지 않는다(미완료 기록은 이미 남김).
        guard pipeline.research != nil else {
            model.update(.failed(query: trimmed, message: "생성 엔진이 설정되지 않았어요."))
            panelController?.show(near: NSEvent.mouseLocation)
            return
        }

        model.update(.researching(query: trimmed))
        panelController?.show(near: NSEvent.mouseLocation)

        let result = await pipeline.researchAndSave(trimmed)
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let (entry, sources)):
            let panelSources = sources.map {
                PanelModel.PanelSource(title: $0.title, url: $0.url, excerpt: $0.excerpt)
            }
            model.update(.result(entry, sources: panelSources, saved: true))
            notifySaved(term: entry.preferredTerm)
        case .failure(let error):
            model.update(.failed(query: trimmed, message: error.localizedDescription))
        }
    }

    // MARK: - 저장 알림 (목업 #10)

    private func notifySaved(term: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "새 항목이 저장되었습니다"
            content.body = "'\(term)'가 사전에 추가되었어요."
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }

    // MARK: - 메뉴바 (목업 #9)

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menuBarImage = NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: "Lexi")
        menuBarImage?.isTemplate = true
        menuBarImage?.size = NSSize(width: 18, height: 18)
        item.button?.image = menuBarImage
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.setAccessibilityLabel("Lexi")
        let menu = NSMenu()
        let searchItem = menu.addItem(withTitle: "클립보드 텍스트로 검색", action: #selector(searchClipboard), keyEquivalent: "d")
        searchItem.target = self
        let openItem = menu.addItem(withTitle: "사전 열기", action: #selector(openLibraryAction), keyEquivalent: "n")
        openItem.target = self
        menu.addItem(.separator())
        let settingsItem = menu.addItem(withTitle: "설정…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Lexi 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func searchClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        Task { await runLookup(text) }
    }

    @objc private func openLibraryAction() {
        openLibrary()
    }

    func openLibrary() {
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.first { $0.canBecomeMain && $0.title == "Lexi" }
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    // MARK: - Services 메뉴 (목업 #1)

    /// 우클릭 → 서비스 → "Lexi에서 찾아보기". NSSendTypes로 선택 텍스트를 받는다.
    @objc func lookupSelectedText(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let text = pboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        Task { await runLookup(text) }
    }
}

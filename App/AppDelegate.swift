import AppKit
import CoreServices
import KeyboardShortcuts
import LexiCore
import SwiftUI

extension KeyboardShortcuts.Name {
    static let lookupSelection = Self("lookupSelection", default: .init(.d, modifiers: [.command]))
}

struct NoSearch: SearchProvider {
    func search(_ query: String, limit: Int) async throws -> [SearchHit] { [] }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    struct LibraryRequest: Identifiable {
        let id = UUID()
        var conceptID: Int64?
        var newEntry = false
    }

    @Published var libraryRequest: LibraryRequest?
    @Published var lookupNotice: String?
    @Published private(set) var iconPlacement: AppIconPlacement
    var showLibraryWindow: (() -> Void)?
    var showSettingsWindow: (() -> Void)?
    /// 서비스 콜드 런치처럼 LibraryView(WindowActions)가 아직 안 떠서 위 클로저가 nil인 경우의
    /// 시스템 폴백. Dock 재클릭(rapp)과 같은 위임 경로로 주 윈도우 씬을 생성한다. 테스트에서 대체한다.
    var reopenPrimaryScene: () -> Void = {
        // Dock 재클릭과 동일한 'rapp' Apple 이벤트를 자신에게 보낸다. SwiftUI는 이 이벤트로
        // 주 윈도우 씬을 생성·앞으로 가져온다. 델리게이트 셀렉터를 직접 수행하면 어댑터
        // 프록시가 종료로 처리하므로 반드시 실제 이벤트로 보내야 한다.
        let target = NSAppleEventDescriptor(
            processIdentifier: Int32(ProcessInfo.processInfo.processIdentifier))
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        try? event.sendEvent(options: .noReply, timeout: 1)
    }
    var openSettingsScene: () -> Void = {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    private let defaults: UserDefaults
    private var panelController: InstantPanelController?
    var panelModel: PanelModel?
    private var pipeline: LookupPipeline?
    private var engineSettings: EngineSettings?
    private var researchTask: Task<Void, Never>?
    private var lastQuery = ""
    /// iCloud 동기화. 켜져 있으면 기동 직후 시작하고 설정 화면이 상태를 관찰한다.
    let syncService = CloudSyncService()

    override init() {
        defaults = .standard
        iconPlacement = AppIconPlacement(
            stored: UserDefaults.standard.string(forKey: AppIconPlacement.storageKey))
        super.init()
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        iconPlacement = AppIconPlacement(stored: defaults.string(forKey: AppIconPlacement.storageKey))
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        applyActivationPolicy()
        NSApp.servicesProvider = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpPanel()
        KeyboardShortcuts.onKeyUp(for: .lookupSelection) { [weak self] in
            self?.lookupFromSelection()
        }
        Self.refreshServices()
        if defaults.bool(forKey: CloudSyncService.storageKey) {
            Task { await syncService.start() }
        }
        if let query = ProcessInfo.processInfo.environment["LEXI_DEMO_QUERY"], !query.isEmpty {
            startLookup(query)
        }
    }

    static func refreshServices() {
        LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        NSUpdateDynamicServices()
    }

    func updateIconPlacement(_ placement: AppIconPlacement) {
        guard iconPlacement != placement else { return }
        iconPlacement = placement
        defaults.set(placement.rawValue, forKey: AppIconPlacement.storageKey)
        applyActivationPolicy()
    }

    func setMenuBarIconVisible(_ isVisible: Bool) {
        updateIconPlacement(iconPlacement.settingMenuBarIconVisible(isVisible))
    }

    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(iconPlacement.activationPolicy)
    }

    private func prepareEngine() async throws {
        let settings = EngineSettings()
        guard pipeline == nil || engineSettings != settings else { return }
        // DB 열기·마이그레이션(v2 되메우기 포함)은 라이브러리가 클수록 오래 걸린다.
        // MainActor 밖에서 수행해 첫 조회가 패널을 멈추지 않게 한다.
        let db = try await Task.detached(priority: .userInitiated) {
            let db = try AppDatabase.makeDefault()
            try db.migrate()
            return db
        }.value
        let provider = MLXProvider(config: .init(modelID: settings.modelID))
        let research = WebResearchService(
            search: settings.webResearchAllowed ? DuckDuckGoSearch() : NoSearch(),
            llm: provider,
            fetcher: PageFetcher()
        )
        pipeline = LookupPipeline(
            service: LookupService(database: db),
            research: research,
            llmIdentifier: provider.identifier,
            explanationLanguage: settings.explanationLanguage,
            allowsTypoCorrection: settings.typoCorrectionEnabled
        )
        engineSettings = settings
    }

    func setUpPanel() {
        // 서비스 Apple 이벤트가 didFinishLaunching보다 먼저 패널을 만들 수 있다(콜드 런치).
        // 여기서 갈아끼우면 조회 결과는 버려진 모델로 가고, 화면의 패널은 빈 상태로 남는다.
        guard panelModel == nil, panelController == nil else { return }
        let model = PanelModel()
        panelModel = model
        panelController = InstantPanelController(model: model)
        model.onRetry = { [weak self] in
            guard let self else { return }
            self.startLookup(self.lastQuery)
        }
        model.onCancel = { [weak self] in
            self?.researchTask?.cancel()
            self?.panelController?.close()
        }
        model.onClose = model.onCancel
        model.onEdit = { [weak self] in
            guard let self else { return }
            let conceptID: Int64?
            switch self.panelModel?.state {
            case .hit(let entry, _), .result(let entry, _, _): conceptID = entry.conceptId
            default: conceptID = nil
            }
            self.panelController?.close()
            self.openLibrary(conceptID: conceptID)
        }
        model.onSettings = { [weak self] in self?.openSettings() }
    }

    private func lookupFromSelection() {
        do {
            let text = try SelectedTextReader.readSelectedText()
            startLookup(text)
        } catch {
            if (error as? SelectedTextError) == .notTrusted {
                _ = SelectedTextReader.isAccessibilityGranted(promptIfNeeded: true)
            }
            lookupNotice = error.localizedDescription
            openLibrary()
        }
    }

    /// Every entry point owns one cancellable lookup. A late result cannot replace a newer query.
    func startLookup(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        researchTask?.cancel()
        lastQuery = trimmed
        setUpPanel()
        researchTask = Task { await runLookup(trimmed) }
    }

    private func runLookup(_ query: String) async {
        guard let model = panelModel else { return }
        do {
            try await prepareEngine()
        } catch {
            model.update(.failed(query: query, message: error.localizedDescription))
            panelController?.show(near: NSEvent.mouseLocation)
            return
        }
        guard let pipeline else { return }
        let result = await pipeline.lookup(query)
        guard !Task.isCancelled else { return }
        NotificationCenter.default.post(name: .lexiLibraryChanged, object: nil)
        if let hit = result.entries.first {
            model.update(.hit(hit, correction: result.correction))
            panelController?.show(near: NSEvent.mouseLocation)
            return
        }
        model.update(.researching(query: query))
        panelController?.show(near: NSEvent.mouseLocation)
        let outcome = await pipeline.researchAndSave(query)
        guard !Task.isCancelled else { return }
        switch outcome {
        case .success(let (entry, sources)):
            model.update(.result(entry, sources: sources.map {
                PanelModel.PanelSource(title: $0.title, url: $0.url, excerpt: $0.excerpt)
            }, saved: true))
            NotificationCenter.default.post(name: .lexiLibraryChanged, object: nil)
        case .failure(let error):
            model.update(.failed(query: query, message: error.localizedDescription))
        }
    }

    func searchClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lookupNotice = String(localized: "클립보드에 텍스트가 없어요. 복사한 뒤 다시 시도하거나 개념을 직접 추가하세요.")
            openLibrary()
            return
        }
        startLookup(text)
    }

    func openLibrary(conceptID: Int64? = nil) {
        if let conceptID { libraryRequest = LibraryRequest(conceptID: conceptID) }
        if showLibraryWindow != nil {
            showLibraryWindow?()
        } else {
            reopenPrimaryScene()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func openNewEntry() {
        libraryRequest = LibraryRequest(newEntry: true)
        openLibrary()
    }

    func openSettings() {
        if showSettingsWindow != nil {
            showSettingsWindow?()
        } else {
            openSettingsScene()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called with the service pasteboard, independently of Accessibility permission or the clipboard.
    @objc func lookupSelectedText(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let text = (pboard.string(forType: .string)
            ?? pboard.string(forType: NSPasteboard.PasteboardType("NSStringPboardType")))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else {
            error.pointee = String(localized: "먼저 조회할 텍스트를 선택해 주세요.") as NSString
            return
        }
        startLookup(text)
    }
}

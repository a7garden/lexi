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

    private let defaults: UserDefaults
    private var panelController: InstantPanelController?
    private var panelModel: PanelModel?
    private var pipeline: LookupPipeline?
    private var engineSettings: EngineSettings?
    private var researchTask: Task<Void, Never>?
    private var lastQuery = ""

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
            explanationLanguage: settings.explanationLanguage
        )
        engineSettings = settings
    }

    private func setUpPanel() {
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
            case .hit(let entry), .result(let entry, _, _): conceptID = entry.conceptId
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
        if panelModel == nil { setUpPanel() }
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
        let entries = await pipeline.lookup(query)
        guard !Task.isCancelled else { return }
        NotificationCenter.default.post(name: .lexiLibraryChanged, object: nil)
        if let hit = entries.first {
            model.update(.hit(hit))
            panelController?.show(near: NSEvent.mouseLocation)
            return
        }
        model.update(.researching(query: query))
        panelController?.show(near: NSEvent.mouseLocation)
        let result = await pipeline.researchAndSave(query)
        guard !Task.isCancelled else { return }
        switch result {
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
            lookupNotice = "클립보드에 텍스트가 없어요. 복사한 뒤 다시 시도하거나 개념을 직접 추가하세요."
            openLibrary()
            return
        }
        startLookup(text)
    }

    func openLibrary(conceptID: Int64? = nil) {
        if let conceptID { libraryRequest = LibraryRequest(conceptID: conceptID) }
        showLibraryWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func openNewEntry() {
        libraryRequest = LibraryRequest(newEntry: true)
        openLibrary()
    }

    func openSettings() {
        showSettingsWindow?()
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
            error.pointee = "먼저 조회할 텍스트를 선택해 주세요." as NSString
            return
        }
        startLookup(text)
    }
}

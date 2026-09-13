import AppKit
import ApplicationServices
import XCTest
import LexiCore
@testable import Lexi

private actor AppSemanticEmbeddingProvider: TextEmbeddingProvider {
    nonisolated let identifier = "test:app-semantic"

    func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> [[Float]] {
        switch purpose {
        case .query:
            texts.map { _ in [1, 0] }
        case .document:
            texts.map { $0.contains("외부 지식") ? [1, 0] : [0, 1] }
        }
    }
}

final class MenuBarPresentationTests: XCTestCase {
    func testMenuBarIconUsesSystemTemplateTint() throws {
        let icon = try XCTUnwrap(NSImage(named: "MenuBarIcon"))
        XCTAssertTrue(icon.isTemplate)
    }

    func testIconPlacementAlwaysLeavesAVisibleEntryPoint() {
        XCTAssertEqual(AppIconPlacement(stored: nil), .menuBarAndDock)
        XCTAssertEqual(AppIconPlacement(stored: "invalid"), .menuBarAndDock)

        for placement in AppIconPlacement.allCases {
            XCTAssertTrue(placement.showsMenuBarIcon || placement.showsDockIcon)
            XCTAssertEqual(
                placement.activationPolicy,
                placement.showsDockIcon ? .regular : .accessory
            )
        }
    }

    func testRemovingMenuBarIconFallsBackToDock() {
        for placement in AppIconPlacement.allCases {
            let updated = placement.settingMenuBarIconVisible(false)
            XCTAssertEqual(updated, .dockOnly)
            XCTAssertFalse(updated.showsMenuBarIcon)
            XCTAssertTrue(updated.showsDockIcon)
        }
    }
}

final class EngineSettingsTests: XCTestCase {
    func testModelValidationAndFallback() {
        XCTAssertTrue(EngineSettings.isValidModelID("mlx-community/Qwen3-4B-4bit"))
        for value in ["", "Qwen3", "org/model/extra", "org/a b", "https://huggingface.co/org/model", "/model"] {
            XCTAssertFalse(EngineSettings.isValidModelID(value), value)
        }
        let name = "LexiSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("  ", forKey: "mlxModelID")
        XCTAssertEqual(EngineSettings(defaults: defaults).modelID, EngineSettings.defaultModelID)
        defaults.set(" org/model ", forKey: "mlxModelID")
        XCTAssertEqual(EngineSettings(defaults: defaults).modelID, "org/model")
    }

    func testSettingsSnapshotReflectsChangesWithoutRestart() {
        let name = "LexiSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let before = EngineSettings(defaults: defaults)
        defaults.set(true, forKey: "webResearchAllowed")
        defaults.set("local/new-model", forKey: "mlxModelID")
        let after = EngineSettings(defaults: defaults)
        XCTAssertNotEqual(before, after)
        XCTAssertTrue(after.webResearchAllowed)
        XCTAssertEqual(after.modelID, "local/new-model")
    }

    func testExplanationLanguagePreferenceParsingAndResolution() {
        // 기본값은 한국어 고정(기존 동작 유지), 잘못된 값도 한국어로 떨어진다.
        XCTAssertEqual(ExplanationLanguagePreference(stored: nil), .fixed(.korean))
        XCTAssertEqual(ExplanationLanguagePreference(stored: "zz"), .fixed(.korean))
        XCTAssertEqual(ExplanationLanguagePreference(stored: "auto"), .auto)
        XCTAssertEqual(ExplanationLanguagePreference(stored: "en"), .fixed(.english))

        // auto는 조회 언어를 따르고 추정 실패 시 한국어다.
        XCTAssertEqual(ExplanationLanguagePreference.auto.resolve(termLanguage: .japanese), .japanese)
        XCTAssertEqual(ExplanationLanguagePreference.auto.resolve(termLanguage: nil), .korean)
        XCTAssertEqual(ExplanationLanguagePreference.fixed(.german).resolve(termLanguage: .japanese), .german)

        // 설정 변경이 EngineSettings 스냅숏에 반영돼 파이프라인이 재구성된다.
        let name = "LexiSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("auto", forKey: ExplanationLanguagePreference.storageKey)
        XCTAssertEqual(EngineSettings(defaults: defaults).explanationLanguage, .auto)
        defaults.set("fr", forKey: ExplanationLanguagePreference.storageKey)
        XCTAssertEqual(EngineSettings(defaults: defaults).explanationLanguage, .fixed(.french))
    }
}

final class ServiceRegistrationTests: XCTestCase {
    @MainActor
    func testShippedServiceIsDiscoverableAndSelectorExists() throws {
        let services = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSServices") as? [[String: Any]])
        let service = try XCTUnwrap(services.first)
        XCTAssertEqual(service["NSPortName"] as? String, "Lexi")
        XCTAssertNotNil(service["NSRequiredContext"] as? [String: Any])
        XCTAssertEqual((service["NSMenuItem"] as? [String: String])?["default"], "Lexi에게 물어보기")
        let sendTypes = try XCTUnwrap(service["NSSendTypes"] as? [String])
        XCTAssertTrue(sendTypes.contains(NSPasteboard.PasteboardType.string.rawValue))
        let message = try XCTUnwrap(service["NSMessage"] as? String)
        XCTAssertTrue(AppDelegate().responds(to: NSSelectorFromString(message + ":userData:error:")))
    }

    func testAccessibilityStatusMatchesSystemTrust() {
        XCTAssertEqual(
            SelectedTextReader.isAccessibilityGranted(promptIfNeeded: false),
            AXIsProcessTrusted()
        )
        XCTAssertEqual(
            SelectedTextError.notTrusted.errorDescription,
            "선택한 텍스트를 읽으려면 손쉬운 사용 권한이 필요합니다. Lexi 설정 > 일반 > 접근 권한에서 Lexi를 허용해 주세요."
        )
    }

    @MainActor
    func testEmptyServiceSelectionReportsError() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(" \n ", forType: .string)
        var error: NSString?
        AppDelegate().lookupSelectedText(pasteboard, userData: nil, error: &error)
        XCTAssertEqual(error.map { $0 as String }, "먼저 조회할 텍스트를 선택해 주세요.")
    }

    @MainActor
    func testLibraryRouteCanReopenAndSelectRequestedConcept() {
        let delegate = AppDelegate()
        var opens = 0
        delegate.showLibraryWindow = { opens += 1 }
        delegate.openLibrary(conceptID: 42)
        XCTAssertEqual(delegate.libraryRequest?.conceptID, 42)
        delegate.openNewEntry()
        XCTAssertEqual(opens, 2)
        XCTAssertEqual(delegate.libraryRequest?.newEntry, true)
        XCTAssertNil(delegate.libraryRequest?.conceptID)
    }
}

@MainActor
final class LibraryEditingTests: XCTestCase {
    func testCreateSelectsEntryAndKeepsOptionalFieldsEmpty() async throws {
        let database = try LexiCore.AppDatabase.makeInMemory()
        try database.migrate()
        let model = LibraryViewModel(database: database)
        await model.refresh()
        let error = await model.createEntry(term: "  새 개념  ", oneLine: "", easy: "")
        XCTAssertNil(error)
        XCTAssertEqual(model.items.first?.preferredTerm, "새 개념")
        XCTAssertEqual(model.items.first?.oneLine, "")
        XCTAssertEqual(model.selectedConceptId, model.items.first?.conceptId)
    }

    func testSaveFailureReturnsErrorToEditorWithoutClearingSelection() async throws {
        let database = try LexiCore.AppDatabase.makeInMemory()
        try database.migrate()
        let model = LibraryViewModel(database: database)
        await model.refresh()
        let initialError = await model.createEntry(term: "원본", oneLine: "원래 설명", easy: "")
        XCTAssertNil(initialError)
        let selected = try XCTUnwrap(model.selectedConceptId)
        try await database.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_revision BEFORE INSERT ON definitionRevision BEGIN SELECT RAISE(ABORT, 'test write failure'); END")
        }
        let error = await model.saveRevision(conceptId: selected, oneLine: "새 설명", easy: "")
        XCTAssertNotNil(error)
        XCTAssertNil(model.loadError)
        XCTAssertEqual(model.selectedConceptId, selected)
        let entries = try await LexiCore.LookupService(database: database).lookupExact("원본")
        XCTAssertEqual(entries.first?.oneLine, "원래 설명")
    }

    func testSemanticSearchUsesFreshLexicalMatchesEvenBeforeDebounceCompletes() async throws {
        let database = try LexiCore.AppDatabase.makeInMemory()
        try database.migrate()
        let service = LookupService(database: database)
        let rag = try await service.saveConcept(
            preferredTerm: "RAG", aliases: [], field: "AI",
            oneLine: "외부 지식을 찾아 답한다", easyExplanation: "자료를 검색한다.",
            author: "user", provider: nil
        )
        _ = try await service.saveConcept(
            preferredTerm: "사워도우", aliases: [], field: "요리",
            oneLine: "발효 빵", easyExplanation: "반죽을 발효한다.",
            author: "user", provider: nil
        )
        let model = LibraryViewModel(
            database: database,
            embeddingProvider: AppSemanticEmbeddingProvider()
        )
        await model.refresh()

        model.setSearch(text: "자료를 참고해 답하는 방식")
        model.findSimilar()
        for _ in 0 ..< 100 where model.isSemanticSearching {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(model.isSemanticSearching)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.semanticMatches.map(\.item.conceptId), [rag])
        XCTAssertNil(model.semanticMessage)
    }
}

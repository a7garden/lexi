import AppKit
import KeyboardShortcuts
import LexiCore
import SwiftUI
/// 목업 #2의 글로벌 단축키. 기본값 ⌘D (클립보드 텍스트로 검색).
extension KeyboardShortcuts.Name {
    static let lookupSelection = Self("lookupSelection", default: .init(.d, modifiers: [.command]))
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var appDatabase: AppDatabase?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let db = try AppDatabase.makeDefault()
            try db.migrate()
            appDatabase = db
        } catch {
            NSApp.presentError(error)
        }

        setUpStatusItem()

        KeyboardShortcuts.onKeyUp(for: .lookupSelection) { [weak self] in
            self?.openLookupForSelectedText()
        }

        NSApp.servicesProvider = self
    }

    // MARK: - 메뉴바 (목업 #9)

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: "Lexi")
        let menu = NSMenu()
        menu.addItem(withTitle: "사전 열기", action: #selector(openLibrary), keyEquivalent: "n").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "설정…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Lexi 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func openLibrary() {
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.first { $0.canBecomeMain && $0.title == "Lexi" }
        window?.makeKeyAndOrderFront(self)
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    // MARK: - Services 메뉴 (목업 #1)
    @objc func lookupSelectedText(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let text = pboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        openLookup(query: text)
    }

    /// 단축키 경로. 접근성으로 선택 텍스트를 읽는 것은 다음 마일스톤(AX 권한 포함).
    private func openLookupForSelectedText() {
        // TODO(milestone-2): AXUIElement 시스템와이드 선택 텍스트 읽기 → openLookup(query:)
        openLibrary()
    }

    /// 조회 파이프라인 진입점. 패널 UI(목업 #3~5)는 다음 마일스톤에서 연결.
    private func openLookup(query: String) {
        NSApp.activate(ignoringOtherApps: true)
        NSLog("Lexi lookup: \(query)")
    }
}

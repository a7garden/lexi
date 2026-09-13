import SwiftUI

@main
struct LexiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// MenuBarExtra 갱신은 이 뷰가 다시 평가될 때만 읽힌다. 델리게이트는 DynamicProperty가
    /// 아니므로 저장된 설정 키를 직접 관찰해 배치 변경이 곧 아이콘 반영되게 한다.
    @AppStorage(AppIconPlacement.storageKey) private var storedIconPlacement =
        AppIconPlacement.defaultValue.rawValue

    var body: some Scene {
        Window("Lexi", id: "library") {
            LibraryView()
                .environmentObject(appDelegate)
                .background(WindowActions(appDelegate: appDelegate))
                .frame(minWidth: 860, minHeight: 580)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("개념 추가…") { appDelegate.openNewEntry() }
                    .keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appDelegate)
                .frame(width: 660, height: 560)
        }

        MenuBarExtra(isInserted: menuBarIconInserted) {
            LexiMenu(appDelegate: appDelegate)
        } label: {
            Image("MenuBarIcon")
        }
    }

    private var menuBarIconInserted: Binding<Bool> {
        Binding(
            get: { AppIconPlacement(stored: storedIconPlacement).showsMenuBarIcon },
            set: { appDelegate.setMenuBarIconVisible($0) }
        )
    }
}

private struct WindowActions: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    let appDelegate: AppDelegate

    var body: some View {
        Color.clear.onAppear {
            appDelegate.showLibraryWindow = { openWindow(id: "library") }
            appDelegate.showSettingsWindow = { openSettings() }
        }
    }
}

private struct LexiMenu: View {
    @ObservedObject var appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("개념 추가…", systemImage: "plus") {
            openWindow(id: "library")
            appDelegate.openNewEntry()
        }
        Button("클립보드로 조회", systemImage: "doc.on.clipboard") {
            appDelegate.searchClipboard()
        }
        Divider()
        Button("내 사전 열기", systemImage: "books.vertical") {
            openWindow(id: "library")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("설정…", systemImage: "gearshape") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")
        Divider()
        Button("Lexi 종료") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

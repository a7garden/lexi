import SwiftUI

@main
struct LexiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Lexi") {
            LibraryView()
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 980, height: 640)

        Settings {
            SettingsView()
                .frame(width: 520, height: 320)
        }
    }
}

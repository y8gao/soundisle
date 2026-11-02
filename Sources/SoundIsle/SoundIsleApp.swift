import SoundIsleCore
import SwiftUI

@main
struct SoundIsleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(AppInfo.displayName) {
            MainWindowView(model: appDelegate.model)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .pasteboard) {
                Button("搜索") {
                    appDelegate.model.requestSearchFocus()
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    appDelegate.model.isSettingsPresented = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

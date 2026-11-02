import SoundIsleCore
import SwiftUI

@main
struct SoundIsleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.production()

    var body: some Scene {
        WindowGroup(AppInfo.displayName) {
            MainWindowView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .pasteboard) {
                Button("搜索") {
                    model.requestSearchFocus()
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    model.isSettingsPresented = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

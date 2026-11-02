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
            CommandMenu("歌词") {
                Button("更换歌词…") {
                    appDelegate.model.promptImportLyrics()
                }
                Button("恢复自动匹配") {
                    appDelegate.model.restoreAutomaticLyrics()
                }
                Button("重试匹配") {
                    appDelegate.model.retryLyrics()
                }
            }
        }
    }
}

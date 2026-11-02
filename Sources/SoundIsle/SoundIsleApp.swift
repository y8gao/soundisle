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
            LyricsCommands(model: appDelegate.model)
        }
    }
}

/// Mirrors the menu-bar enablement so 恢复自动匹配 and 重试匹配 are not offered
/// when they cannot do anything.
private struct LyricsCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandMenu("歌词") {
            Button("更换歌词…") {
                model.promptImportLyrics()
            }
            .disabled(model.currentTrack == nil)

            Button("恢复自动匹配") {
                model.restoreAutomaticLyrics()
            }
            .disabled(!model.hasLyricsOverride)

            Button("重试匹配") {
                model.retryLyrics()
            }
            .disabled(model.currentTrack == nil || model.isResolvingLyrics)
        }
    }
}

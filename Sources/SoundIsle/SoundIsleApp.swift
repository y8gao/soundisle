import SwiftUI
import SoundIsleCore

@main
struct SoundIsleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(AppInfo.displayName) {
            Text(AppInfo.displayName)
        }
    }
}

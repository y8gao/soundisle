import AppKit
import SoundIsleCore

/// The menu bar music note. The menu is rebuilt every time it opens so the
/// track title and play/pause label are never stale.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let miniPlayer: MiniPlayerWindowController
    private let showMainWindow: () -> Void
    private let menu = NSMenu()
    private let statusItem: NSStatusItem

    init(
        model: AppModel,
        miniPlayer: MiniPlayerWindowController,
        showMainWindow: @escaping () -> Void
    ) {
        self.model = model
        self.miniPlayer = miniPlayer
        self.showMainWindow = showMainWindow
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "声屿")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "声屿"

        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuild()
    }

    private func rebuild() {
        menu.removeAllItems()

        let trackItem = NSMenuItem(title: currentTrackTitle, action: nil, keyEquivalent: "")
        trackItem.isEnabled = false
        menu.addItem(trackItem)
        menu.addItem(.separator())

        addItem(model.isPlaying ? "暂停" : "播放", action: #selector(togglePlayPause))
        addItem("上一首", action: #selector(previous))
        addItem("下一首", action: #selector(next))
        menu.addItem(.separator())

        addItem(miniPlayer.isVisible ? "隐藏迷你窗" : "显示迷你窗", action: #selector(toggleMiniPlayer))
        menu.addItem(.separator())

        // Task 8 renders the lyric overlay. The actions already call the
        // AppModel hooks, so only the disabled state changes then.
        let showLyrics = addItem(
            model.isLyricsVisible ? "隐藏歌词（即将提供）" : "显示歌词（即将提供）",
            action: #selector(toggleLyrics)
        )
        showLyrics.isEnabled = false
        let lockLyrics = addItem(
            model.isLyricsLocked ? "解锁歌词（即将提供）" : "锁定歌词（即将提供）",
            action: #selector(toggleLyricsLock)
        )
        lockLyrics.isEnabled = false
        menu.addItem(.separator())

        addItem("显示主窗口", action: #selector(showMainWindowItem))
        addItem("退出声屿", action: #selector(quit), keyEquivalent: "q")
    }

    @discardableResult
    private func addItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        menu.addItem(item)
        return item
    }

    private var currentTrackTitle: String {
        guard let track = model.currentTrack else { return "未在播放" }
        let line = track.artist.isEmpty ? track.title : "\(track.title) — \(track.artist)"
        return track.isMissing ? "\(line)（文件缺失）" : line
    }

    // MARK: - Actions

    @objc private func togglePlayPause() {
        model.togglePlayPause()
    }

    @objc private func previous() {
        model.previous()
    }

    @objc private func next() {
        model.next()
    }

    @objc private func toggleMiniPlayer() {
        miniPlayer.toggle()
    }

    @objc private func toggleLyrics() {
        model.toggleLyricsVisibility()
    }

    @objc private func toggleLyricsLock() {
        model.toggleLyricsLock()
    }

    @objc private func showMainWindowItem() {
        showMainWindow()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

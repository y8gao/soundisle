import AppKit
import SoundIsleCore

/// The menu bar music note. The menu is rebuilt every time it opens so the
/// track title and play/pause label are never stale.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let miniPlayer: MiniPlayerWindowController
    private let showMainWindow: () -> Void
    private let showMiniPlayer: () -> Void
    private let menu = NSMenu()
    private let statusItem: NSStatusItem

    init(
        model: AppModel,
        miniPlayer: MiniPlayerWindowController,
        showMainWindow: @escaping () -> Void,
        showMiniPlayer: @escaping () -> Void
    ) {
        self.model = model
        self.miniPlayer = miniPlayer
        self.showMainWindow = showMainWindow
        self.showMiniPlayer = showMiniPlayer
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let image = NoteGlyph.templateImage(size: 16)
            ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: L("声屿"))
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = L("声屿")

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

        addItem(model.isPlaying ? L("暂停（空格）") : L("播放（空格）"), action: #selector(togglePlayPause))
        addItem(L("上一首（⌘←）"), action: #selector(previous))
        addItem(L("下一首（⌘→）"), action: #selector(next))
        menu.addItem(.separator())

        // One toggle instead of two items: the mini and the main window are
        // mutually exclusive, so the label names the destination.
        if miniPlayer.isVisible {
            addItem(L("返回主窗口"), action: #selector(showMainFromMenu))
        } else {
            addItem(L("迷你模式"), action: #selector(showMiniFromMenu))
        }
        menu.addItem(.separator())

        let lyricsItem = addItem(
            model.isLyricsVisible ? L("隐藏歌词") : L("显示歌词"),
            action: #selector(toggleLyrics)
        )
        lyricsItem.state = model.isLyricsVisible ? .on : .off
        addItem(model.isLyricsLocked ? L("解锁歌词") : L("锁定歌词"), action: #selector(toggleLyricsLock))
        let importItem = addItem(L("更换歌词…"), action: #selector(importLyrics))
        importItem.isEnabled = model.currentTrack != nil
        let restoreItem = addItem(L("恢复自动匹配"), action: #selector(restoreAutomaticLyrics))
        restoreItem.isEnabled = model.hasLyricsOverride
        if model.canRetryLyrics {
            addItem(L("重试匹配"), action: #selector(retryLyrics))
        }
        menu.addItem(.separator())

        addItem(L("退出声屿"), action: #selector(quit), keyEquivalent: "q")
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
        guard let track = model.currentTrack else { return L("未在播放") }
        let line = track.artist.isEmpty ? track.title : "\(track.title) — \(track.artist)"
        return track.isMissing ? Lf("%@（文件缺失）", line) : line
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

    @objc private func showMainFromMenu() {
        showMainWindow()
    }

    @objc private func showMiniFromMenu() {
        showMiniPlayer()
    }

    @objc private func toggleLyrics() {
        model.toggleLyricsVisibility()
    }

    @objc private func toggleLyricsLock() {
        model.toggleLyricsLock()
    }

    @objc private func importLyrics() {
        model.promptImportLyrics()
    }

    @objc private func restoreAutomaticLyrics() {
        model.restoreAutomaticLyrics()
    }

    @objc private func retryLyrics() {
        model.retryLyrics()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

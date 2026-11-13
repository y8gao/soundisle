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

        switch UpdatePresentation.menuBar(for: model.updates.state) {
        case .available(let version):
            addItem(Lf("发现新版本 %@…", version), action: #selector(openSettings))
            menu.addItem(.separator())
        case .downloading:
            let item = NSMenuItem(title: L("正在下载更新…"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        case .ready:
            addItem(L("重启以更新…"), action: #selector(restartToUpdate))
            menu.addItem(.separator())
        case nil:
            break
        }

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
            model.isLyricsVisible ? L("隐藏桌面歌词") : L("显示桌面歌词"),
            action: #selector(toggleLyrics)
        )
        lyricsItem.state = model.isLyricsVisible ? .on : .off
        menu.addItem(.separator())

        addItem(L("设置…"), action: #selector(openSettings), keyEquivalent: ",")
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

    /// Settings live in a sheet on the main window, so bring the window back
    /// before presenting them — the menu bar may be the only surface that is
    /// visible (mini player mode).
    @objc private func restartToUpdate() {
        model.updates.restartToApply()
    }

    @objc private func openSettings() {
        showMainWindow()
        DispatchQueue.main.async { [weak self] in
            self?.model.isSettingsPresented = true
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

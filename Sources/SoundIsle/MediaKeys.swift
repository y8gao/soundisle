import AppKit
import Combine
import MediaPlayer
import SoundIsleCore

/// Bridges the system media keys (F7/F8/F9 and the Now Playing widget) to
/// `AppModel`, and keeps the Now Playing panel in sync with the track.
@MainActor
final class MediaKeyController {
    private let model: AppModel
    private var cancellables = Set<AnyCancellable>()
    private var commandTargets: [(command: MPRemoteCommand, target: Any)] = []

    init(model: AppModel) {
        self.model = model
        registerCommands()
        observe()
        updateNowPlaying()
    }

    deinit {
        for entry in commandTargets {
            entry.command.removeTarget(entry.target)
        }
    }

    // MARK: - Remote commands

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand) { [weak self] in self?.model.play() }
        add(center.pauseCommand) { [weak self] in self?.model.pause() }
        add(center.togglePlayPauseCommand) { [weak self] in self?.model.togglePlayPause() }
        add(center.nextTrackCommand) { [weak self] in self?.model.next() }
        add(center.previousTrackCommand) { [weak self] in self?.model.previous() }
    }

    private func add(_ command: MPRemoteCommand, action: @escaping @MainActor () -> Void) {
        command.isEnabled = true
        let target = command.addTarget { _ in
            Task { @MainActor in action() }
            return .success
        }
        commandTargets.append((command, target))
    }

    // MARK: - Now Playing

    private func observe() {
        model.$currentTrack
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateNowPlaying() }
            }
            .store(in: &cancellables)

        model.$isPlaying
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateNowPlaying() }
            }
            .store(in: &cancellables)

        // The engine publishes position twice a second; the system panel only
        // needs one update a second.
        model.engine.$position
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateNowPlaying() }
            }
            .store(in: &cancellables)
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = model.currentTrack else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }

        let duration = model.displayDuration > 0 ? model.displayDuration : track.duration
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: model.displayPosition,
            MPNowPlayingInfoPropertyPlaybackRate: model.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if !track.artist.isEmpty {
            info[MPMediaItemPropertyArtist] = track.artist
        }
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        center.nowPlayingInfo = info
        center.playbackState = model.isPlaying ? .playing : .paused
    }
}

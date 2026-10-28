import Foundation
@preconcurrency import MediaPlayer

enum MobilePlaybackCommand: Equatable, Sendable {
    case play, pause, togglePlayPause, stop, nextSection, previousSection
    case changeRate(Double)
}

/// Only user-facing document/section labels are published. Text has no precise
/// audio duration, so the system receives no invented timeline or seek position.
struct MobileNowPlayingMetadata: Equatable, Sendable {
    let title: String
    let section: String?
    let rate: Double
    let isPlaying: Bool
}

@MainActor
protocol MobileNowPlayingPublishing: AnyObject {
    func beginOwnership(generation: UUID, handler: @escaping @MainActor (UUID, MobilePlaybackCommand) -> Bool)
    func update(_ metadata: MobileNowPlayingMetadata)
    func endOwnership()
}

@MainActor
final class MobileNowPlaying: MobileNowPlayingPublishing {
    private let center: MPRemoteCommandCenter
    private let info: MPNowPlayingInfoCenter
    private var targets: [(MPRemoteCommand, Any)] = []

    init(center: MPRemoteCommandCenter = .shared(), info: MPNowPlayingInfoCenter = .default()) {
        self.center = center
        self.info = info
    }
    func beginOwnership(generation: UUID, handler: @escaping @MainActor (UUID, MobilePlaybackCommand) -> Bool) {
        endOwnership()
        register(center.playCommand, generation: generation, handler: handler) { _ in .play }
        register(center.pauseCommand, generation: generation, handler: handler) { _ in .pause }
        register(center.togglePlayPauseCommand, generation: generation, handler: handler) { _ in .togglePlayPause }
        register(center.stopCommand, generation: generation, handler: handler) { _ in .stop }
        register(center.nextTrackCommand, generation: generation, handler: handler) { _ in .nextSection }
        register(center.previousTrackCommand, generation: generation, handler: handler) { _ in .previousSection }
        center.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
        register(center.changePlaybackRateCommand, generation: generation, handler: handler) { event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return nil }
            return .changeRate(Double(event.playbackRate))
        }
        center.changePlaybackPositionCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
    }
    func update(_ metadata: MobileNowPlayingMetadata) {
        var value: [String: Any] = [MPMediaItemPropertyTitle: metadata.title,
            MPNowPlayingInfoPropertyPlaybackRate: metadata.isPlaying ? metadata.rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: metadata.rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false]
        if let section = metadata.section { value[MPMediaItemPropertyAlbumTitle] = section }
        info.nowPlayingInfo = value
        info.playbackState = metadata.isPlaying ? .playing : .paused
    }
    func endOwnership() {
        for (command, target) in targets { command.removeTarget(target); command.isEnabled = false }
        targets.removeAll()
        info.nowPlayingInfo = nil
        info.playbackState = .stopped
    }
    private func register(_ command: MPRemoteCommand, generation: UUID,
                          handler: @escaping @MainActor (UUID, MobilePlaybackCommand) -> Bool,
                          makeCommand: @escaping @Sendable (MPRemoteCommandEvent) -> MobilePlaybackCommand?) {
        command.isEnabled = true
        let target = command.addTarget { event in
            guard let command = makeCommand(event) else { return .commandFailed }
            // MediaPlayer may call from its own queue. The generation is checked
            // again on MainActor after delivery, even after handler removal.
            Task { @MainActor in _ = handler(generation, command) }
            return .success
        }
        targets.append((command, target))
    }
}

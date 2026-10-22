import Foundation
import Observation
@preconcurrency import AVFAudio

@MainActor
protocol MobileAudioSessionManaging: AnyObject {
    func activate() throws
    func deactivate()
}

@MainActor
final class SystemMobileAudioSession: MobileAudioSessionManaging {
    private let session = AVAudioSession.sharedInstance()
    func activate() throws {
        try session.setCategory(.playback, mode: .spokenAudio, options: [])
        try session.setActive(true)
    }
    func deactivate() { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
}

/// Retained by the app, independently of reader views and scene activity.
/// A reader's stable identity prevents an old window from closing another
/// reader's playback. The shared session retains the immutable spoken version.
@MainActor @Observable
final class MobilePlaybackOwner {
    let session: SpeechSession
    let preferences: SpeechPreferences
    private(set) var spokenDocument: SpeechDocument?
    private(set) var title = ""
    private(set) var url: URL?
    private(set) var ownerID: UUID?
    private(set) var ownershipGeneration = UUID()
    private(set) var hasPendingVersion = false
    private var audioNotice: String?
    @ObservationIgnored private let audioSession: any MobileAudioSessionManaging
    @ObservationIgnored private let nowPlaying: any MobileNowPlayingPublishing
    @ObservationIgnored private let progressStore: SpeechProgressStore
    @ObservationIgnored private var ownsSystemPlayback = false
    @ObservationIgnored private var lastCheckpoint = Date.distantPast

    init(session: SpeechSession = SpeechSession(),
         audioSession: any MobileAudioSessionManaging = SystemMobileAudioSession(),
         nowPlaying: any MobileNowPlayingPublishing = MobileNowPlaying(),
         preferences: SpeechPreferences = .shared,
         progressStore: SpeechProgressStore = SpeechProgressStore()) {
        self.session = session
        self.audioSession = audioSession
        self.nowPlaying = nowPlaying
        self.preferences = preferences
        self.progressStore = progressStore
        session.onProgress = { [weak self] in self?.didProgress() }
        session.onStop = { [weak self] in
            guard let self else { return }
            checkpoint(force: true)
            endSystemOwnership()
        }
    }

    var notice: String? { audioNotice ?? session.notice }
    var playbackHolding: Bool { ownerID != nil && (session.isActive || hasPendingVersion) }

    func play(document: SpeechDocument, title: String, url: URL?, from: Int = 0, offset: Int = 0,
              ownerID: UUID? = nil) {
        let retainsPendingVersion = hasPendingVersion && self.ownerID == ownerID &&
            spokenDocument == document && self.url == url
        stop()
        self.ownerID = ownerID ?? UUID()
        self.spokenDocument = document
        self.title = title
        self.url = url
        hasPendingVersion = retainsPendingVersion
        audioNotice = nil
        lastCheckpoint = .distantPast
        session.useAssistiveTechnologySettings = preferences.useAssistiveTechnologySettings
        session.followReading = preferences.followReading
        session.setRate(preferences.rate)
        session.setVoice(preferences.voice(for: document.language))
        guard activateAudio() else { return }
        ownershipGeneration = UUID()
        ownsSystemPlayback = true
        nowPlaying.beginOwnership(generation: ownershipGeneration) { [weak self] generation, command in
            self?.handle(command, generation: generation) ?? false
        }
        session.play(document, from: from, offset: offset)
        if session.isActive { publishMetadata() }
        else { endSystemOwnership() }
    }

    func pause() { session.pause(); publishMetadata() }
    func resume() {
        guard session.status == .paused, ownsSystemPlayback, activateAudio() else { return }
        session.resume()
        didProgress()
    }
    func stop() {
        // Invalidate first: an already queued remote event cannot restart this
        // playback or operate on the next reader after the stop completes.
        ownershipGeneration = UUID()
        session.stop()
        endSystemOwnership()
    }
    func setRate(_ value: Double) {
        preferences.rate = value
        session.setRate(preferences.rate)
        publishMetadata()
    }
    func setVoice(_ id: String?) {
        preferences.setVoice(id, for: spokenDocument?.language)
        session.setVoice(id)
        publishMetadata()
    }
    func setFollowReading(_ value: Bool) { preferences.followReading = value; session.followReading = value }
    func refreshVoices() { session.refreshVoices(); publishMetadata() }
    func nextSection() { session.nextSection(); didProgress() }
    func previousSection() { session.previousSection(); didProgress() }
    func seek(_ index: Int, offset: Int = 0) { session.seek(index, offset: offset); didProgress() }

    func notePendingVersion(ownerID: UUID) {
        guard self.ownerID == ownerID, spokenDocument != nil else { return }
        hasPendingVersion = true
    }
    func clearPendingVersion(ownerID: UUID) {
        guard self.ownerID == ownerID else { return }
        hasPendingVersion = false
    }
    func releaseVersionHold(ownerID: UUID) {
        guard self.ownerID == ownerID else { return }
        clearDocument()
    }
    func documentWillChange(ownerID: UUID) {
        guard self.ownerID == ownerID else { return }
        clearDocument()
    }
    func savedPosition(document: SpeechDocument, url: URL?) -> SpeechBookmark? {
        _ = preferences.historyRevision
        guard let url else { return nil }
        return progressStore.resume(url: url, document: document)
    }
    func clearHistory() { progressStore.clear(); preferences.historyRevision += 1 }

    private func clearDocument() {
        stop()
        hasPendingVersion = false
        ownerID = nil
        spokenDocument = nil
        url = nil
        title = ""
        audioNotice = nil
    }
    private func activateAudio() -> Bool {
        do { try audioSession.activate(); audioNotice = nil; return true }
        catch { audioNotice = String(localized: "Unable to start audio playback."); return false }
    }
    private func endSystemOwnership() {
        ownershipGeneration = UUID()
        guard ownsSystemPlayback else { return }
        ownsSystemPlayback = false
        nowPlaying.endOwnership()
        audioSession.deactivate()
    }
    private func didProgress() {
        if session.isActive { checkpoint(force: session.status == .paused) }
        publishMetadata()
    }
    private func checkpoint(force: Bool) {
        guard force || Date().timeIntervalSince(lastCheckpoint) >= 2,
              let url, let document = spokenDocument, session.document == document else { return }
        progressStore.save(url: url, document: document, index: session.currentIndex, offset: session.offset)
        lastCheckpoint = Date()
    }
    private func publishMetadata() {
        guard ownsSystemPlayback else { return }
        nowPlaying.update(MobileNowPlayingMetadata(title: title,
            section: spokenDocument?.section(at: session.currentIndex)?.title,
            rate: session.rate, isPlaying: session.status == .playing))
    }
    private func handle(_ command: MobilePlaybackCommand, generation: UUID) -> Bool {
        guard ownsSystemPlayback, ownershipGeneration == generation, session.isActive else { return false }
        switch command {
        case .play: resume()
        case .pause: pause()
        case .togglePlayPause: session.status == .playing ? pause() : resume()
        case .stop: stop()
        case .nextSection: nextSection()
        case .previousSection: previousSection()
        case .changeRate(let rate): setRate(rate)
        }
        return true
    }
}

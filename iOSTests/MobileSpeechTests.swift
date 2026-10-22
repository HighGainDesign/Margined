import AVFAudio
import XCTest
@testable import MDViewiOS

@MainActor
final class MobileSpeechTests: XCTestCase {
    func testPendingVersionKeepsImmutableSpokenDocumentAfterStop() throws {
        let rig = makeRig()
        let reader = UUID()
        let original = document("Original", fingerprint: "old")
        rig.owner.play(document: original, title: "Original title", url: file, ownerID: reader)
        rig.owner.notePendingVersion(ownerID: reader)
        rig.owner.stop()
        XCTAssertEqual(rig.owner.session.status, .idle)
        XCTAssertEqual(rig.owner.spokenDocument, original)
        XCTAssertEqual(rig.owner.session.document, original)
        XCTAssertTrue(rig.owner.playbackHolding)
        XCTAssertTrue(rig.owner.hasPendingVersion)
        rig.owner.releaseVersionHold(ownerID: reader)
        XCTAssertFalse(rig.owner.playbackHolding)
    }

    func testRevertedPendingVersionKeepsPlayingThenReleasesOnStop() {
        let rig = makeRig()
        let reader = UUID()
        rig.owner.play(document: document("Original"), title: "Title", url: file, ownerID: reader)
        rig.owner.notePendingVersion(ownerID: reader)
        rig.owner.clearPendingVersion(ownerID: UUID())
        XCTAssertTrue(rig.owner.hasPendingVersion, "Another reader cannot discard this reader's pending choice")
        rig.owner.clearPendingVersion(ownerID: reader)
        XCTAssertFalse(rig.owner.hasPendingVersion)
        XCTAssertEqual(rig.owner.session.status, .playing)
        XCTAssertTrue(rig.owner.playbackHolding)
        rig.owner.stop()
        XCTAssertFalse(rig.owner.playbackHolding)
    }

    func testReplayingHeldVersionDoesNotDiscardPendingLatestChoice() {
        let rig = makeRig()
        let reader = UUID()
        let original = document("Original", fingerprint: "old")
        rig.owner.play(document: original, title: "Title", url: file, ownerID: reader)
        rig.owner.notePendingVersion(ownerID: reader)
        rig.owner.stop()
        rig.owner.play(document: original, title: "Title", url: file, ownerID: reader)
        rig.owner.stop()
        XCTAssertTrue(rig.owner.hasPendingVersion)
        XCTAssertTrue(rig.owner.playbackHolding)
        rig.owner.play(document: document("Latest", fingerprint: "new"), title: "Title", url: file, ownerID: reader)
        rig.owner.stop()
        XCTAssertFalse(rig.owner.hasPendingVersion)
        XCTAssertFalse(rig.owner.playbackHolding)
    }

    func testCompetingReadersShareOneSessionAndOldReaderCannotStopNewOwner() throws {
        let rig = makeRig()
        let firstReader = UUID(), secondReader = UUID()
        let session = rig.owner.session
        rig.owner.play(document: document("First"), title: "First file", url: file, ownerID: firstReader)
        let firstToken = try XCTUnwrap(rig.driver.requests.last).token
        rig.owner.play(document: document("Second"), title: "Second file", url: nil, ownerID: secondReader)
        rig.owner.documentWillChange(ownerID: firstReader)
        rig.driver.send(.finished(firstToken))
        XCTAssertTrue(rig.owner.session === session)
        XCTAssertEqual(rig.owner.session.status, .playing)
        XCTAssertEqual(rig.owner.session.currentSegment?.text, "Second")
        XCTAssertEqual(rig.owner.ownerID, secondReader)
        rig.owner.documentWillChange(ownerID: secondReader)
        XCTAssertEqual(rig.owner.session.status, .idle)
        XCTAssertNil(rig.owner.spokenDocument)
        XCTAssertFalse(rig.owner.playbackHolding)
    }

    func testStaleRemoteCommandCannotChangeNewPlaybackOwnership() throws {
        let rig = makeRig()
        rig.owner.play(document: document("First"), title: "First", url: file)
        let stale = try XCTUnwrap(rig.nowPlaying.handlers.last)
        rig.owner.play(document: document("Second"), title: "Second", url: nil)
        XCTAssertFalse(stale.handler(stale.generation, .pause))
        XCTAssertEqual(rig.owner.session.status, .playing)
        let current = try XCTUnwrap(rig.nowPlaying.handlers.last)
        XCTAssertTrue(current.handler(current.generation, .pause))
        XCTAssertEqual(rig.owner.session.status, .paused)
        rig.owner.stop()
        XCTAssertFalse(current.handler(current.generation, .play))
        XCTAssertEqual(rig.owner.session.status, .idle)
    }

    func testRemoteTransportAndPreferencesPreservePausedPosition() throws {
        let rig = makeRig()
        rig.owner.play(document: document("Beginning"), title: "Title", url: file, from: 1, offset: 3)
        let command = try XCTUnwrap(rig.nowPlaying.handlers.last)
        XCTAssertTrue(command.handler(command.generation, .pause))
        rig.owner.setRate(1.5)
        rig.owner.setVoice("french")
        XCTAssertEqual(rig.owner.session.status, .paused)
        XCTAssertEqual(rig.owner.session.offset, 3)
        XCTAssertEqual(rig.preferences.rate, 1.5)
        XCTAssertEqual(rig.preferences.voice(for: "en-US"), "french")
        XCTAssertTrue(command.handler(command.generation, .nextSection))
        XCTAssertEqual(rig.owner.session.currentIndex, 2)
        XCTAssertTrue(command.handler(command.generation, .play))
        XCTAssertEqual(rig.owner.session.status, .playing)
        XCTAssertEqual(rig.driver.requests.last?.text, "Next section")
        XCTAssertEqual(rig.driver.requests.last?.rate, 1.5)
        XCTAssertEqual(rig.driver.requests.last?.voice?.id, "french")
    }

    func testAudioSessionFailureDoesNotSpeakOrPublishOwnership() {
        let rig = makeRig()
        rig.audio.failure = NSError(domain: "Audio", code: 1)
        rig.owner.play(document: document("Private text"), title: "Title", url: file)
        XCTAssertEqual(rig.owner.session.status, .idle)
        XCTAssertNotNil(rig.owner.notice)
        XCTAssertTrue(rig.driver.requests.isEmpty)
        XCTAssertTrue(rig.nowPlaying.handlers.isEmpty)
    }

    func testStopCancelsSpeechBeforeDeactivatingAudioSession() {
        let rig = makeRig()
        var speakingWhenDeactivated = false
        rig.audio.onDeactivate = { speakingWhenDeactivated = rig.driver.isSpeaking }
        rig.owner.play(document: document("Text"), title: "Title", url: file)
        rig.owner.stop()
        XCTAssertFalse(speakingWhenDeactivated, "iOS can refuse to deactivate an audio session that is still speaking")
    }

    func testExplicitResumeFailureKeepsPausedPositionAndCannotAutoplay() {
        let rig = makeRig()
        rig.owner.play(document: document("Text"), title: "Title", url: file, from: 1, offset: 4)
        rig.owner.pause()
        rig.audio.failure = NSError(domain: "Audio", code: 1)
        rig.owner.resume()
        XCTAssertEqual(rig.owner.session.status, .paused)
        XCTAssertEqual(rig.owner.session.currentIndex, 1)
        XCTAssertEqual(rig.owner.session.offset, 4)
        XCTAssertNotNil(rig.owner.notice)
    }

    func testStopCheckpointsFilePositionButStreamHasNoBookmark() throws {
        let rig = makeRig()
        let spoken = document("Text", fingerprint: "fixed")
        rig.owner.play(document: spoken, title: "Title", url: file, from: 1, offset: 4)
        rig.owner.stop()
        let bookmark = try XCTUnwrap(rig.owner.savedPosition(document: spoken, url: file))
        XCTAssertEqual(bookmark.index, 1)
        XCTAssertEqual(bookmark.offset, 4)
        XCTAssertNil(rig.owner.savedPosition(document: spoken, url: nil))
        rig.owner.clearHistory()
        XCTAssertNil(rig.owner.savedPosition(document: spoken, url: file))
    }

    func testMetadataContainsOnlyTitleSectionAndRate() throws {
        let rig = makeRig()
        rig.owner.play(document: document("Private body text"), title: "Public file title", url: file)
        let metadata = try XCTUnwrap(rig.nowPlaying.metadata)
        XCTAssertEqual(metadata.title, "Public file title")
        XCTAssertEqual(metadata.section, "First section")
        XCTAssertEqual(metadata.rate, 1)
        XCTAssertTrue(metadata.isPlaying)
        rig.owner.pause()
        XCTAssertFalse(try XCTUnwrap(rig.nowPlaying.metadata).isPlaying)
    }

    func testInterruptionAndOldDeviceLossPauseWithoutAutomaticResume() async throws {
        let center = NotificationCenter()
        let rig = makeRig()
        let monitor = SpeechInterruptionMonitor(notificationCenter: center) { message in
            rig.driver.send(.interrupted(rig.driver.requests.last!.token, message))
        }
        rig.owner.play(document: document("Keep position"), title: "Title", url: file)
        monitor.start()
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        await drainNotifications()
        XCTAssertEqual(rig.owner.session.status, .paused)
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                               AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        await drainNotifications()
        XCTAssertEqual(rig.owner.session.status, .paused)
        rig.owner.resume()
        center.post(name: AVAudioSession.routeChangeNotification, object: nil,
                    userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
        await drainNotifications()
        XCTAssertEqual(rig.owner.session.status, .playing)
        center.post(name: AVAudioSession.routeChangeNotification, object: nil,
                    userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        await drainNotifications()
        XCTAssertEqual(rig.owner.session.status, .paused)
        monitor.stop()
    }

    func testRouteLossPausesBeforeTheNextSegmentCanStart() throws {
        let center = NotificationCenter()
        let rig = makeRig()
        let monitor = SpeechInterruptionMonitor(notificationCenter: center) { message in
            rig.driver.send(.interrupted(rig.driver.requests.last!.token, message))
        }
        rig.owner.play(document: document("Private text"), title: "Title", url: file)
        let token = try XCTUnwrap(rig.driver.requests.last).token
        monitor.start()
        center.post(name: AVAudioSession.routeChangeNotification, object: nil,
                    userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        rig.driver.send(.finished(token))
        XCTAssertEqual(rig.owner.session.status, .paused)
        XCTAssertEqual(rig.owner.session.currentIndex, 0, "A known route loss must pause before another utterance is queued")
        monitor.stop()
    }

    func testStoppedMonitorDoesNotReceiveLaterNotifications() async {
        let center = NotificationCenter()
        var count = 0
        let monitor = SpeechInterruptionMonitor(notificationCenter: center) { _ in count += 1 }
        monitor.start()
        monitor.stop()
        center.post(name: AVAudioSession.routeChangeNotification, object: nil,
                    userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        await drainNotifications()
        XCTAssertEqual(count, 0)
    }

    func testReaderViewDestructionAndSceneInactivityDoNotReleaseAppOwnedPlayback() {
        let rig = makeRig()
        weak var released: ReaderAttachment?
        do {
            let view = ReaderAttachment(owner: rig.owner)
            released = view
            view.owner.play(document: document("Retained"), title: "Title", url: file)
        }
        XCTAssertNil(released)
        XCTAssertEqual(rig.owner.session.status, .playing)
        XCTAssertEqual(rig.owner.session.currentSegment?.text, "Retained")
    }

    private let file = URL(fileURLWithPath: "/tmp/mobile-speech-private.md")
    private func document(_ text: String, fingerprint: String = UUID().uuidString) -> SpeechDocument {
        SpeechDocument(segments: [
            SpeechSegment(id: "a", elementID: "a", text: text, sectionID: "first", kind: .heading),
            SpeechSegment(id: "b", elementID: "b", text: "Paragraph body", sectionID: "first", kind: .paragraph),
            SpeechSegment(id: "c", elementID: "c", text: "Next section", sectionID: "next", kind: .heading)
        ], sections: [SpeechSection(id: "first", title: "First section", firstSegment: 0),
                      SpeechSection(id: "next", title: "Next section", firstSegment: 2)], language: "en-US", fingerprint: fingerprint)
    }
    private func makeRig() -> Rig {
        let defaults = UserDefaults(suiteName: "MobileSpeechTests-\(UUID().uuidString)")!
        let preferences = SpeechPreferences(defaults: defaults)
        let driver = MobileRecordingSpeechDriver(), audio = RecordingMobileAudioSession(), nowPlaying = RecordingMobileNowPlaying()
        let session = SpeechSession(driver: driver, voices: {
            [SpeechVoice(id: "english", name: "English", language: "en-US", quality: 1),
             SpeechVoice(id: "french", name: "French", language: "fr-FR", quality: 1)]
        }, coordinator: SpeechCoordinator())
        let owner = MobilePlaybackOwner(session: session, audioSession: audio, nowPlaying: nowPlaying,
                                        preferences: preferences, progressStore: SpeechProgressStore(defaults: defaults))
        return Rig(owner: owner, driver: driver, audio: audio, nowPlaying: nowPlaying, preferences: preferences)
    }
    private func drainNotifications() async { for _ in 0..<4 { await Task.yield() } }
    private struct Rig {
        let owner: MobilePlaybackOwner
        let driver: MobileRecordingSpeechDriver
        let audio: RecordingMobileAudioSession
        let nowPlaying: RecordingMobileNowPlaying
        let preferences: SpeechPreferences
    }
    private final class ReaderAttachment {
        let owner: MobilePlaybackOwner
        init(owner: MobilePlaybackOwner) { self.owner = owner }
    }
}

@MainActor
private final class MobileRecordingSpeechDriver: SpeechDriver {
    struct Request { let text: String; let voice: SpeechVoice?; let rate: Double; let token: UUID }
    var eventHandler: ((SpeechDriverEvent) -> Void)?
    var useAssistiveTechnologySettings = false
    var requests: [Request] = []
    var isSpeaking = false
    func speak(_ text: String, voice: SpeechVoice?, rate: Double, token: UUID) {
        requests.append(Request(text: text, voice: voice, rate: rate, token: token))
        isSpeaking = true
    }
    func pause() -> Bool { true }
    func resume() -> Bool { true }
    func stop() { isSpeaking = false }
    func send(_ event: SpeechDriverEvent) { eventHandler?(event) }
}

@MainActor
private final class RecordingMobileAudioSession: MobileAudioSessionManaging {
    var failure: Error?
    var onDeactivate: (() -> Void)?
    func activate() throws { if let failure { throw failure } }
    func deactivate() { onDeactivate?() }
}

@MainActor
private final class RecordingMobileNowPlaying: MobileNowPlayingPublishing {
    struct Registration { let generation: UUID; let handler: @MainActor (UUID, MobilePlaybackCommand) -> Bool }
    var handlers: [Registration] = []
    var metadata: MobileNowPlayingMetadata?
    func beginOwnership(generation: UUID, handler: @escaping @MainActor (UUID, MobilePlaybackCommand) -> Bool) {
        handlers.append(Registration(generation: generation, handler: handler))
    }
    func update(_ metadata: MobileNowPlayingMetadata) { self.metadata = metadata }
    func endOwnership() { metadata = nil }
}

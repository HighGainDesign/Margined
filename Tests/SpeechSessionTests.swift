import XCTest
@testable import Margined

@MainActor
final class SpeechSessionTests: XCTestCase {
    private let voices = [SpeechVoice(id: "english", name: "English", language: "en-US", quality: 1),
                          SpeechVoice(id: "french", name: "Français", language: "fr-FR", quality: 2)]

    func testPlaybackAdvancesOnlyForCurrentUtteranceAndFinishes() async throws {
        let document = try await fixture()
        let driver = RecordingSpeechDriver()
        let session = SpeechSession(driver: driver, voices: { self.voices }, coordinator: SpeechCoordinator())
        session.play(document)
        XCTAssertEqual(session.status, .playing)
        XCTAssertEqual(session.currentSegment?.text, "First")
        let old = try XCTUnwrap(driver.requests.last).token
        driver.send(.finished(old))
        XCTAssertEqual(session.currentSegment?.text, "First paragraph.")
        driver.send(.finished(old))
        XCTAssertEqual(session.currentSegment?.text, "First paragraph.", "Late callbacks cannot skip new speech")
        while session.status == .playing { driver.send(.finished(try XCTUnwrap(driver.requests.last).token)) }
        XCTAssertEqual(session.status, .finished)
    }

    func testPauseAndRateChangePreservePositionAndDoNotAutoplay() async throws {
        let driver = RecordingSpeechDriver()
        let session = SpeechSession(driver: driver, voices: { self.voices }, coordinator: SpeechCoordinator())
        session.play(try await fixture(), from: 1)
        driver.send(.range(try XCTUnwrap(driver.requests.last).token, NSRange(location: 6, length: 4)))
        session.pause()
        XCTAssertEqual(session.status, .paused)
        session.setRate(1.5)
        XCTAssertEqual(session.status, .paused)
        XCTAssertEqual(session.currentIndex, 1)
        session.resume()
        XCTAssertEqual(session.status, .playing)
        XCTAssertEqual(driver.requests.last?.rate, 1.5)
        session.stop()
        XCTAssertEqual(session.status, .idle)
        let last = try XCTUnwrap(driver.requests.last).token
        driver.send(.finished(last))
        XCTAssertEqual(session.status, .idle)
    }

    func testSectionNavigationAndOwnershipTransferStopPreviousWindow() async throws {
        let coordinator = SpeechCoordinator(), firstDriver = RecordingSpeechDriver(), secondDriver = RecordingSpeechDriver()
        let first = SpeechSession(driver: firstDriver, voices: { self.voices }, coordinator: coordinator)
        let second = SpeechSession(driver: secondDriver, voices: { self.voices }, coordinator: coordinator)
        let document = try await fixture()
        first.play(document)
        first.nextSection()
        XCTAssertEqual(first.currentSegment?.text, "Second")
        first.previousSection()
        XCTAssertEqual(first.currentSegment?.text, "First")
        second.play(document)
        XCTAssertEqual(first.status, .idle)
        XCTAssertEqual(second.status, .playing)
        XCTAssertFalse(firstDriver.requests.isEmpty)
        second.stop()
    }

    func testVoiceMatchesDocumentInsteadOfInterfaceAndReportsUnavailablePreference() async throws {
        let driver = RecordingSpeechDriver()
        let session = SpeechSession(driver: driver, voices: { self.voices }, coordinator: SpeechCoordinator())
        let output = try await MarkdownRenderer.shared.render("Texte français.", documentLanguage: "fr", prepareSpeech: true)
        session.setVoice("missing")
        session.play(try XCTUnwrap(output.speech))
        XCTAssertEqual(session.resolvedVoice?.id, "french")
        XCTAssertNotNil(session.notice)
        session.stop()
    }

    func testEmptyDocumentAndDriverFailureNeverPretendToBePlaying() {
        let driver = RecordingSpeechDriver()
        let session = SpeechSession(driver: driver, voices: { self.voices }, coordinator: SpeechCoordinator())
        let empty = SpeechDocument(segments: [], sections: [], language: nil, fingerprint: "empty")
        session.play(empty)
        XCTAssertEqual(session.status, .idle)
        XCTAssertNotNil(session.notice)
        XCTAssertTrue(driver.requests.isEmpty)
    }

    func testCancelledUtteranceDoesNotAdvanceOrRestart() async throws {
        let driver = RecordingSpeechDriver()
        let session = SpeechSession(driver: driver, voices: { self.voices }, coordinator: SpeechCoordinator())
        session.play(try await fixture())
        let request = try XCTUnwrap(driver.requests.last)
        driver.send(.cancelled(request.token))
        XCTAssertEqual(session.status, .paused)
        XCTAssertEqual(session.currentIndex, 0)
        XCTAssertEqual(driver.requests.count, 1)
        session.resume()
        XCTAssertEqual(session.status, .playing)
        session.stop()
    }

    func testInterruptionPausesAndStaleFailureCannotStopReplacementSpeech() async throws {
        let driver = RecordingSpeechDriver()
        let session = SpeechSession(driver: driver, voices: { self.voices }, coordinator: SpeechCoordinator())
        let document = try await fixture()
        session.play(document)
        let old = try XCTUnwrap(driver.requests.last).token
        driver.send(.interrupted(old, "Output changed"))
        XCTAssertEqual(session.status, .paused)
        XCTAssertEqual(session.notice, "Output changed")
        session.resume()
        XCTAssertEqual(session.status, .playing)
        let active = try XCTUnwrap(driver.requests.last).token
        driver.send(.failed(old, "Old failure"))
        XCTAssertEqual(session.status, .playing)
        driver.send(.failed(active, "Current failure"))
        XCTAssertEqual(session.status, .failed)
        XCTAssertEqual(session.notice, "Current failure")
    }

    func testUnknownLanguageUsesDefaultVoiceOrderInsteadOfUnrelatedPremiumVoice() async throws {
        let driver = RecordingSpeechDriver()
        let session = SpeechSession(driver: driver, voices: { self.voices }, coordinator: SpeechCoordinator())
        session.play(try await fixture())
        XCTAssertEqual(session.resolvedVoice?.id, "english")
        session.stop()
    }

    func testVoiceRemovalSelectsReplacementAndWarnsBeforeContinuing() async throws {
        let driver = RecordingSpeechDriver()
        var available = voices
        let session = SpeechSession(driver: driver, voices: { available }, coordinator: SpeechCoordinator())
        session.setVoice("french")
        session.play(try await fixture())
        available.removeAll { $0.id == "french" }
        session.refreshVoices()
        XCTAssertEqual(session.resolvedVoice?.id, "english")
        XCTAssertNotNil(session.notice)
        XCTAssertEqual(session.status, .playing)
        available = []
        session.refreshVoices()
        XCTAssertEqual(session.status, .failed)
    }

    func testEmptyReplacementStopsPlaybackAndReleasesReaderHold() async throws {
        let driver = RecordingSpeechDriver()
        let session = SpeechSession(driver: driver, voices: { self.voices }, coordinator: SpeechCoordinator())
        var released = false
        session.onStop = { released = true }
        session.play(try await fixture())
        session.play(SpeechDocument(segments: [], sections: [], language: nil, fingerprint: "empty"))
        XCTAssertEqual(session.status, .idle)
        XCTAssertTrue(released)
    }

    func testSectionCommandsCannotRestartStoppedOrCompletedPlayback() async throws {
        let driver = RecordingSpeechDriver()
        let session = SpeechSession(driver: driver, voices: { self.voices }, coordinator: SpeechCoordinator())
        let document = try await fixture()
        session.play(document); session.stop()
        let stoppedCount = driver.requests.count
        session.nextSection(); session.previousSection(); session.seek(1)
        XCTAssertEqual(session.status, .idle)
        XCTAssertEqual(driver.requests.count, stoppedCount)
        session.play(document)
        while session.status == .playing { driver.send(.finished(driver.requests.last!.token)) }
        let finishedCount = driver.requests.count
        session.previousSection(); session.nextSection()
        XCTAssertEqual(session.status, .finished)
        XCTAssertEqual(driver.requests.count, finishedCount)
    }

    func testPauseBeforeEngineStartsCannotLeaveQueuedSpeechPlaying() async throws {
        let driver = RecordingSpeechDriver(); driver.pauseAccepted = false
        let session = SpeechSession(driver: driver, voices: { self.voices }, coordinator: SpeechCoordinator())
        session.play(try await fixture())
        let original = driver.requests.last!.token
        session.pause()
        XCTAssertEqual(session.status, .paused)
        driver.send(.started(original)); driver.send(.finished(original))
        XCTAssertEqual(session.status, .paused)
        session.resume()
        XCTAssertEqual(session.status, .playing)
        XCTAssertEqual(driver.requests.count, 2, "Resume must explicitly restart the cancelled queued utterance")
    }

    private func fixture() async throws -> SpeechDocument {
        let rendered = try await MarkdownRenderer.shared.render("# First\n\nFirst paragraph.\n\n# Second\n\nSecond paragraph.\n", prepareSpeech: true)
        return try XCTUnwrap(rendered.speech)
    }
}

@MainActor
final class RecordingSpeechDriver: SpeechDriver {
    struct Request { let text: String; let voice: SpeechVoice?; let rate: Double; let token: UUID }
    var eventHandler: ((SpeechDriverEvent) -> Void)?
    var useAssistiveTechnologySettings = false
    var requests: [Request] = []
    var paused = false
    var pauseAccepted = true
    func speak(_ text: String, voice: SpeechVoice?, rate: Double, token: UUID) {
        requests.append(Request(text: text, voice: voice, rate: rate, token: token)); paused = false
    }
    func pause() -> Bool { paused = pauseAccepted; return pauseAccepted }
    func resume() -> Bool { paused = false; return true }
    func stop() { paused = false }
    func send(_ event: SpeechDriverEvent) { eventHandler?(event) }
}

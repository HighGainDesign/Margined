import Foundation
import XCTest
@testable import MarginediOS

/// Integration boundaries between displayed text, asynchronous document saves,
/// and playback ownership. Real coordinated files are used only where ordering
/// of an accepted save is the behavior under test.
@MainActor
final class MobileReaderRaceTests: XCTestCase {
    func testSelectedUTF16OffsetStartsInsideNormalizedSplitParagraphAndKeepsMathSource() async throws {
        let rig = makeRig()
        let text = "# Reader\n\n" + String(repeating: "A readable sentence.  ", count: 90) +
            "😀    TARGET $\\frac{1}{2}$ finishes this paragraph.\n"
        await rig.reader.openPreview(url: preview(text))
        await rig.reader.waitForRendering()
        let document = try XCTUnwrap(rig.reader.rendered?.speech)
        let element = try XCTUnwrap(document.elements.first { _, map in
            map.anchors.contains { $0.sourceText.contains("TARGET") }
        })
        let anchor = try XCTUnwrap(element.value.anchors.first { $0.sourceText.contains("TARGET") })
        let target = (anchor.sourceText as NSString).range(of: "TARGET")
        XCTAssertNotEqual(target.location, NSNotFound)
        let sourceOffset = anchor.sourceRange.location + target.location
        let position = try XCTUnwrap(document.position(elementID: element.key, sourceOffset: sourceOffset))
        XCTAssertGreaterThan(position.index, 1, "The selection is beyond the first 1,200 UTF-16 speech chunk")
        XCTAssertGreaterThan(sourceOffset, document.segments[position.index].elementOffset,
                             "Raw DOM offsets retain the emoji and repeated whitespace")

        rig.reader.startSpeech(mode: "selection")
        let request = try XCTUnwrap(rig.reader.speechStartRequest)
        rig.reader.completeSpeechStart(requestID: request, elementID: element.key, offset: sourceOffset)

        XCTAssertEqual(rig.owner.session.currentIndex, position.index)
        XCTAssertEqual(rig.owner.session.offset, position.offset)
        let spoken = try XCTUnwrap(rig.driver.requests.last)
        XCTAssertTrue(spoken.hasPrefix("TARGET "), spoken)
        XCTAssertTrue(spoken.contains("\\frac{1}{2}"), "Read Aloud uses semantic math source rather than generated artwork")
        XCTAssertEqual(rig.audio.activations, 1)
        XCTAssertEqual(rig.nowPlaying.metadata?.title, "Reader test")
        await rig.reader.close()
    }

    func testMissingSelectionDoesNotStartButBeginningIgnoresSelection() async throws {
        let rig = makeRig()
        await rig.reader.openPreview(url: preview("# Beginning\n\nA second paragraph.\n"))
        await rig.reader.waitForRendering()
        rig.reader.startSpeech(mode: "selection")
        let request = try XCTUnwrap(rig.reader.speechStartRequest)
        rig.reader.completeSpeechStart(requestID: request, elementID: nil, offset: 0)
        XCTAssertTrue(rig.driver.requests.isEmpty)
        XCTAssertEqual(rig.audio.activations, 0)
        XCTAssertEqual(rig.owner.session.status, .idle)
        XCTAssertNotNil(rig.reader.errorMessage)

        rig.reader.startSpeech(mode: "beginning")
        XCTAssertNil(rig.reader.speechStartRequest, "Beginning must not wait for a JavaScript selection callback")
        XCTAssertEqual(rig.driver.requests, ["Beginning"])
        XCTAssertEqual(rig.owner.session.currentIndex, 0)
        XCTAssertEqual(rig.owner.session.offset, 0)
        await rig.reader.close()
    }

    func testDelayedLocateCannotStartSpeechAfterAnExternalVersionRenders() async throws {
        let file = try fixture("# Original\n\nOld paragraph.\n")
        let rig = makeRig()
        await rig.reader.open(url: file)
        await rig.reader.waitForRendering()
        let element = try XCTUnwrap(rig.reader.rendered?.speech?.segments.first?.elementID)
        rig.reader.startSpeech(mode: "selection")
        let request = try XCTUnwrap(rig.reader.speechStartRequest)

        try Data("# Replacement\n\nAn agent replaced the file.\n".utf8).write(to: file, options: .atomic)
        await rig.reader.refresh()
        await rig.reader.waitForRendering()
        XCTAssertTrue(rig.reader.source.contains("Replacement"))
        rig.reader.completeSpeechStart(requestID: request, elementID: element, offset: 0)

        XCTAssertTrue(rig.driver.requests.isEmpty, "The old DOM's locate callback cannot authorize another rendered version")
        XCTAssertEqual(rig.audio.activations, 0)
        XCTAssertEqual(rig.owner.session.status, .idle)
        await rig.reader.close()
    }

    func testDelayedLocateCannotStartSpeechWhileARenderIsInFlight() async throws {
        let rig = makeRig()
        await rig.reader.openPreview(url: preview("# Stable\n\nA paragraph.\n"))
        await rig.reader.waitForRendering()
        let element = try XCTUnwrap(rig.reader.rendered?.speech?.segments.first?.elementID)
        rig.reader.startSpeech(mode: "selection")
        let request = try XCTUnwrap(rig.reader.speechStartRequest)
        rig.reader.render()
        XCTAssertTrue(rig.reader.isRendering)
        rig.reader.completeSpeechStart(requestID: request, elementID: element, offset: 0)
        XCTAssertTrue(rig.driver.requests.isEmpty)
        await rig.reader.waitForRendering()
        rig.reader.completeSpeechStart(requestID: request, elementID: element, offset: 0)
        XCTAssertTrue(rig.driver.requests.isEmpty, "A rejected request cannot revive after rendering completes")
        await rig.reader.close()
    }

    func testConsentSaveAcceptedImmediatelyBeforeCloseCompletesOnOriginalFile() async throws {
        let file = try fixture("- [ ] Accepted tick\n")
        let rig = makeRig()
        await rig.reader.open(url: file)
        await rig.reader.waitForRendering()
        let task = try XCTUnwrap(rig.reader.rendered?.tasks.first)
        XCTAssertTrue(rig.reader.requestTaskChecked(task.id, checked: true))
        rig.reader.confirmChecklistSaving()
        // No actor yield between consent and close: the save Task has not had
        // an opportunity to enqueue its document operation yet.
        await rig.reader.close()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "- [x] Accepted tick\n")
        XCTAssertFalse(rig.reader.hasDocument)
        XCTAssertNil(rig.reader.fileURL)
        XCTAssertTrue(rig.driver.requests.isEmpty)
    }

    func testSupersedingClosesAndOpenCannotBypassAnAcceptedSaveDrain() async throws {
        let first = try fixture("- [ ] Same task\n")
        let second = try fixture("- [ ] Same task\n")
        let gate = ReaderSaveGate()
        defer { gate.release() }
        let rig = makeRig(access: MobileDocumentAccess(environment: gate.environment))
        await rig.reader.open(url: first)
        await rig.reader.waitForRendering()
        let task = try XCTUnwrap(rig.reader.rendered?.tasks.first)
        XCTAssertTrue(rig.reader.requestTaskChecked(task.id, checked: true))
        rig.reader.confirmChecklistSaving()
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered)

        let firstCloseStarted = expectation(description: "First close starts")
        let firstClose = Task { firstCloseStarted.fulfill(); await rig.reader.close() }
        await fulfillment(of: [firstCloseStarted], timeout: 2)
        XCTAssertFalse(rig.reader.hasDocument)
        let secondCloseStarted = expectation(description: "Superseding close starts")
        let secondClose = Task { secondCloseStarted.fulfill(); await rig.reader.close() }
        await fulfillment(of: [secondCloseStarted], timeout: 2)
        let openStarted = expectation(description: "Replacement open starts")
        let opening = Task { openStarted.fulfill(); await rig.reader.open(url: second) }
        await fulfillment(of: [openStarted], timeout: 2)

        XCTAssertFalse(gate.started(second), "Every superseding transition must await the still-accepted save")
        XCTAssertFalse(gate.stopped(first), "The accepted write must retain its original file scope")
        XCTAssertNil(rig.reader.fileURL)
        gate.release()
        await firstClose.value
        await secondClose.value
        await opening.value
        await rig.reader.waitForRendering()
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "- [x] Same task\n")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "- [ ] Same task\n")
        XCTAssertEqual(rig.reader.fileURL, second)
        XCTAssertFalse(rig.reader.checklistMode)
        XCTAssertFalse(rig.reader.canUndoChecklist, "The old document's accepted save cannot create new-document Undo history")
        await rig.reader.close()
    }

    func testConsentAndSavingBlockPlaybackAndStoppingAutosavePreservesExplicitUndo() async throws {
        let file = try fixture("# Tasks\n\n- [ ] Review the scope\n")
        let gate = ReaderSaveGate()
        defer { gate.release() }
        let rig = makeRig(access: MobileDocumentAccess(environment: gate.environment))
        await rig.reader.open(url: file)
        await rig.reader.waitForRendering()
        let task = try XCTUnwrap(rig.reader.rendered?.tasks.first)
        let element = try XCTUnwrap(rig.reader.rendered?.speech?.segments.first?.elementID)
        rig.reader.startSpeech(mode: "selection")
        let staleSelection = try XCTUnwrap(rig.reader.speechStartRequest)
        XCTAssertTrue(rig.reader.requestTaskChecked(task.id, checked: true))
        rig.reader.startSpeech(mode: "beginning")
        rig.reader.resumeSpeechPosition()
        rig.reader.completeSpeechStart(requestID: staleSelection, elementID: element, offset: 0)
        XCTAssertTrue(rig.driver.requests.isEmpty)
        XCTAssertEqual(rig.audio.activations, 0)

        rig.reader.confirmChecklistSaving()
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered)
        XCTAssertTrue(rig.reader.checklistSaving)
        rig.reader.startSpeech(mode: "beginning")
        rig.reader.resumeSpeechPosition()
        XCTAssertTrue(rig.driver.requests.isEmpty)
        XCTAssertNil(rig.reader.speechStartRequest)

        rig.reader.stopSavingCheckmarks()
        gate.release()
        await rig.reader.waitForSaving()
        await rig.reader.waitForRendering()
        XCTAssertFalse(rig.reader.checklistMode)
        XCTAssertTrue(rig.reader.canUndoChecklist)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Tasks\n\n- [x] Review the scope\n")
        rig.reader.undoChecklist()
        await rig.reader.waitForSaving()
        await rig.reader.waitForRendering()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Tasks\n\n- [ ] Review the scope\n")
        XCTAssertFalse(rig.reader.checklistMode, "Explicit Undo does not re-enable future click autosaves")
        XCTAssertTrue(rig.reader.canRedoChecklist)
        await rig.reader.close()
    }

    private func fixture(_ source: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data(source.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func preview(_ source: String) -> URL {
        var parts = URLComponents(string: "margined://preview")!
        parts.queryItems = [.init(name: "text", value: source), .init(name: "title", value: "Reader test")]
        return parts.url!
    }

    private func makeRig(access: MobileDocumentAccess = MobileDocumentAccess()) -> Rig {
        let suite = "MobileReaderRaceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let driver = ReaderRecordingSpeechDriver()
        let audio = ReaderRecordingAudioSession()
        let nowPlaying = ReaderRecordingNowPlaying()
        let session = SpeechSession(driver: driver, voices: {
            [SpeechVoice(id: "test", name: "Test", language: "en-US", quality: 1)]
        }, coordinator: SpeechCoordinator())
        let owner = MobilePlaybackOwner(session: session, audioSession: audio, nowPlaying: nowPlaying,
            preferences: SpeechPreferences(defaults: defaults), progressStore: SpeechProgressStore(defaults: defaults))
        return Rig(reader: MobileReaderState(access: access, playback: owner, defaults: defaults),
                   owner: owner, driver: driver, audio: audio, nowPlaying: nowPlaying)
    }

    private struct Rig {
        let reader: MobileReaderState
        let owner: MobilePlaybackOwner
        let driver: ReaderRecordingSpeechDriver
        let audio: ReaderRecordingAudioSession
        let nowPlaying: ReaderRecordingNowPlaying
    }
}

@MainActor
private final class ReaderRecordingSpeechDriver: SpeechDriver {
    var eventHandler: ((SpeechDriverEvent) -> Void)?
    var useAssistiveTechnologySettings = false
    var requests: [String] = []
    func speak(_ text: String, voice: SpeechVoice?, rate: Double, token: UUID) { requests.append(text) }
    func pause() -> Bool { true }
    func resume() -> Bool { true }
    func stop() { }
}

@MainActor
private final class ReaderRecordingAudioSession: MobileAudioSessionManaging {
    var activations = 0
    func activate() throws { activations += 1 }
    func deactivate() { }
}

@MainActor
private final class ReaderRecordingNowPlaying: MobileNowPlayingPublishing {
    var metadata: MobileNowPlayingMetadata?
    func beginOwnership(generation: UUID, handler: @escaping @MainActor (UUID, MobilePlaybackCommand) -> Bool) { }
    func update(_ metadata: MobileNowPlayingMetadata) { self.metadata = metadata }
    func endOwnership() { metadata = nil }
}

/// A bounded, one-shot gate before real file coordination. No sleeps or mock
/// filesystem are needed to hold the accepted save across reader transitions.
private final class ReaderSaveGate: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)
    private var blocksWrite = true
    private var starts: Set<URL> = []
    private var stops: Set<URL> = []
    var environment: MobileDocumentEnvironment {
        MobileDocumentEnvironment(startAccessing: { [self] url in
            lock.withLock { _ = starts.insert(url) }
            return true
        }, stopAccessing: { [self] url in
            lock.withLock { _ = stops.insert(url) }
        }, willCoordinate: { [self] operation, _ in
            let shouldBlock = lock.withLock {
                guard operation == .write, blocksWrite else { return false }
                blocksWrite = false
                return true
            }
            if shouldBlock {
                entered.signal()
                _ = resume.wait(timeout: .now() + 10)
            }
        })
    }
    func started(_ url: URL) -> Bool { lock.withLock { starts.contains(url) } }
    func stopped(_ url: URL) -> Bool { lock.withLock { stops.contains(url) } }
    func release() { resume.signal() }
    func waitUntilEntered() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                continuation.resume(returning: entered.wait(timeout: .now() + 5) == .success)
            }
        }
    }
}

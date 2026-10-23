import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Margined

@MainActor
final class ReaderSpeechTests: XCTestCase {
    func testPlaybackHoldsLatestFileUntilExplicitShowLatestEvenAfterStop() async throws {
        let reader = makeReader(); defer { reader.stop() }
        reader.fileURL = URL(fileURLWithPath: "/tmp/speech-held.md")
        reader.source = "# Original\n\nReading text.\n"; reader.render(); try await settle(reader)
        reader.speech.start()
        XCTAssertTrue(reader.playbackHolding)
        XCTAssertEqual(reader.speech.session.status, .playing)
        reader.receiveFileUpdate("# Latest\n\nAgent text.\n")
        XCTAssertEqual(reader.source, "# Original\n\nReading text.\n")
        XCTAssertTrue(reader.hasPendingFileUpdate)
        reader.speech.stop()
        XCTAssertTrue(reader.playbackHolding)
        XCTAssertEqual(reader.source, "# Original\n\nReading text.\n")
        reader.speech.showLatest(); try await settle(reader)
        XCTAssertFalse(reader.playbackHolding)
        XCTAssertEqual(reader.source, "# Latest\n\nAgent text.\n")
        XCTAssertFalse(reader.hasPendingFileUpdate)
    }

    func testDiscussionOnlyRefreshKeepsSpeechPlayingAndUpdatesNotes() async throws {
        let source = """
        # Title

        A readable passage.

        <!-- margined:thread v1
        id: t1
        state: open
        target: {type: TextQuoteSelector, exact: A readable passage., prefix: Title, suffix: ''}
        messages:
          - id: m1
            author: Reviewer
            created: "2026-10-23T09:00:00Z"
            body: First note.
        -->
        """
        let reader = makeReader(); defer { reader.stop() }
        reader.fileURL = URL(fileURLWithPath: "/tmp/note-only-speech.md")
        reader.source = source; reader.render(); try await settle(reader)
        reader.speech.start()
        XCTAssertEqual(reader.speech.session.status, .playing)
        let fingerprint = reader.rendered?.speech?.fingerprint
        let message = DiscussionMessage(id: "m2", author: "Another reviewer", created: "2026-10-23T10:00:00Z", body: "An external reply.", inReplyTo: "m1")
        let parsed = try DiscussionCodec.parse(source)
        let data = try MarkdownSourceEdits.apply(DiscussionEdits.splices(for: .reply(threadID: "t1", message: message, reopenResolved: false), in: parsed), to: Data(source.utf8), expectedSource: source)
        reader.receiveFileUpdate(try MarkdownSource.decode(data))
        for _ in 0..<300 {
            if reader.rendered?.discussions?.threads.first?.messages.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(reader.rendered?.discussions?.threads.first?.messages.count, 2)
        XCTAssertFalse(reader.hasPendingFileUpdate)
        XCTAssertEqual(reader.rendered?.speech?.fingerprint, fingerprint)
        XCTAssertEqual(reader.speech.session.status, .playing)
    }

    func testClosingPlayerKeepsPendingVersionVisibleUntilExplicitShowLatest() async throws {
        let reader = makeReader(); defer { reader.stop() }
        reader.fileURL = URL(fileURLWithPath: "/tmp/player-close-held.md")
        reader.source = "Original text."; reader.render(); try await settle(reader)
        reader.speech.start(); reader.receiveFileUpdate("New text.")
        reader.speech.close()
        XCTAssertFalse(reader.speech.showPlayer)
        XCTAssertTrue(reader.playbackHolding, "The Show Latest choice must remain visible when the player closes")
        reader.receiveFileUpdate("Newest text.")
        XCTAssertEqual(reader.source, "Original text.")
        reader.speech.showLatest(); try await settle(reader)
        XCTAssertEqual(reader.source, "Newest text.")
        reader.speech.start(); reader.receiveFileUpdate("Another edit."); reader.stop()
        XCTAssertFalse(reader.playbackHolding, "Closing the document releases its hold")
    }

    func testManualPauseRemainsIndependentFromPlaybackHold() async throws {
        let reader = makeReader(); defer { reader.stop() }
        reader.fileURL = URL(fileURLWithPath: "/tmp/manual-pause-speech.md")
        reader.source = "Old text."; reader.render(); try await settle(reader)
        reader.setFileUpdatesPaused(true)
        reader.speech.start(); reader.speech.stop()
        XCTAssertTrue(reader.fileUpdatesPaused)
        XCTAssertFalse(reader.playbackHolding)
        reader.speech.start()
        reader.receiveFileUpdate("New text.")
        reader.setFileUpdatesPaused(false)
        XCTAssertEqual(reader.source, "Old text.", "Resuming file updates cannot replace the spoken version")
        reader.speech.showLatest(); try await settle(reader)
        XCTAssertEqual(reader.source, "New text.")
        XCTAssertFalse(reader.fileUpdatesPaused)
    }

    func testStreamSwitchHoldsTextAndSourceNameTogether() async throws {
        let reader = makeReader(); defer { reader.stop() }
        reader.isStreamingPreview = true
        reader.receiveStreamUpdate("# First draft", sourceName: "Drafts")
        try await settle(reader)
        reader.speech.start()
        reader.receiveStreamUpdate("# Second draft", sourceName: "Other Editor")
        XCTAssertEqual(reader.source, "# First draft")
        XCTAssertEqual(reader.streamSourceName, "Drafts")
        XCTAssertTrue(reader.hasPendingFileUpdate)
        reader.speech.showLatest(); try await settle(reader)
        XCTAssertEqual(reader.source, "# Second draft")
        XCTAssertEqual(reader.streamSourceName, "Other Editor")
    }

    func testChecklistCannotWriteWhilePlayingEvenWithoutPendingExternalChange() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: file) }
        let reader = makeReader(); defer { reader.stop() }
        reader.fileURL = file; reader.source = "- [ ] Task\n"
        try reader.source.write(to: file, atomically: true, encoding: .utf8)
        reader.render(); try await settle(reader); reader.checklistMode = true
        reader.speech.start()
        XCTAssertFalse(reader.requestTaskChecked(0, checked: true))
        reader.setTaskChecked(0, checked: true)
        XCTAssertFalse(reader.checklistSaving)
        XCTAssertEqual(try MarkdownSource.read(file), "- [ ] Task\n")
        reader.speech.stop()
        XCTAssertTrue(reader.requestTaskChecked(0, checked: true))
        try await settle(reader)
        XCTAssertEqual(try MarkdownSource.read(file), "- [x] Task\n")
    }

    func testClosingReaderStopsSpeechAndClearsItsHold() async throws {
        let reader = makeReader()
        reader.source = "Text to read."; reader.render(); try await settle(reader)
        reader.speech.start()
        reader.stop()
        XCTAssertEqual(reader.speech.session.status, .idle)
        XCTAssertFalse(reader.playbackHolding)
    }

    func testNativeCheckboxDisablesDuringPlaybackAndExplainsHowToSave() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let reader = makeReader(); reader.fileURL = file; reader.source = "- [ ] Task\n"
        try reader.source.write(to: file, atomically: true, encoding: .utf8)
        let controller = NSHostingController(rootView: ReaderView(reader: reader))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false; window.setContentSize(NSSize(width: 650, height: 500)); window.orderFront(nil)
        defer { window.close(); reader.stop(); try? FileManager.default.removeItem(at: file) }
        var web: WKWebView?
        for _ in 0..<150 {
            web = findWeb(controller.view)
            if !reader.isRendering, let web,
               (try? await web.evaluateJavaScript("document.querySelector('input')?.disabled")) as? Bool == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let browser = try XCTUnwrap(web)
        reader.speech.start()
        var disabled = false
        for _ in 0..<100 {
            disabled = (try? await browser.evaluateJavaScript("document.querySelector('input')?.disabled")) as? Bool == true
            if disabled { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(disabled)
        let title = try await browser.evaluateJavaScript("document.querySelector('input').title") as? String
        XCTAssertTrue(title?.contains("Read Aloud") == true)
        reader.speech.stop()
    }

    func testSpeechControllerDoesNotRetainAClosedReader() async throws {
        weak var released: ReaderState?
        do {
            let reader = makeReader(); released = reader
            reader.source = "Reading text."; reader.render(); try await settle(reader)
            reader.speech.start(); reader.stop()
        }
        XCTAssertNil(released)
    }

    func testPendingChecklistConsentMustFinishBeforeSpeechStarts() async throws {
        let reader = makeReader(); defer { reader.stop() }
        reader.fileURL = URL(fileURLWithPath: "/tmp/consent-before-speech.md")
        reader.source = "- [ ] Task\n"; reader.render(); try await settle(reader)
        XCTAssertTrue(reader.requestTaskChecked(0, checked: true))
        reader.speech.start()
        XCTAssertFalse(reader.playbackHolding)
        XCTAssertFalse(reader.speech.session.isActive)
        XCTAssertTrue(reader.showChecklistConfirmation)
    }

    func testChangedSpeechOptionsApplyWhenRestartingAnOpenDocument() async throws {
        let reader = makeReader(); defer { reader.stop() }
        reader.source = "[Project](https://example.org)\n\n```swift\nlet answer = 42\n```\n"
        reader.render(); try await settle(reader)
        reader.speech.start(); reader.speech.session.pause()
        let original = reader.speech.session.document
        reader.speech.preferences.options = SpeechOptions(includeCode: true, includeLinkDestinations: true)
        XCTAssertEqual(reader.speech.session.document, original, "Settings must not replace paused speech")
        reader.speech.requestStart(.beginning)
        for _ in 0..<300 {
            if reader.speech.session.document?.segments.contains(where: { $0.text.contains("let answer") }) == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let spoken = reader.speech.session.document?.segments.map(\.text).joined(separator: " ") ?? ""
        XCTAssertTrue(spoken.contains("let answer = 42"))
        XCTAssertTrue(spoken.contains("https://example.org"))
        XCTAssertEqual(reader.speech.session.status, .playing)
    }

    func testStopCancelsPlaybackWaitingForChangedContentOptions() async throws {
        let reader = makeReader(); defer { reader.stop() }
        reader.source = "Text.\n\n```\ncode\n```\n"; reader.render(); try await settle(reader)
        reader.speech.preferences.options = SpeechOptions(includeCode: true)
        reader.speech.start(); reader.speech.stop()
        try await settle(reader)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(reader.speech.session.status, .idle)
        XCTAssertFalse(reader.playbackHolding)
    }

    private func findWeb(_ view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.findWeb($0) }.first
    }

    private func makeReader() -> ReaderState {
        let name = "MarginedTests.ReaderSpeech.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        let preferences = SpeechPreferences(defaults: defaults)
        return ReaderState(speechFactory: { reader in
            ReaderSpeech(reader: reader, session: SpeechSession(driver: RecordingSpeechDriver(),
                voices: { [SpeechVoice(id: "test", name: "Test", language: "en-US", quality: 1)] },
                coordinator: SpeechCoordinator()), preferences: preferences, progress: SpeechProgressStore(defaults: defaults))
        })
    }
    private func settle(_ reader: ReaderState) async throws {
        for _ in 0..<300 {
            if !reader.isRendering && !reader.checklistSaving { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Reader operation did not settle")
    }
}

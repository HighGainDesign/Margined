import Foundation
import XCTest
import SwiftUI
import WebKit
#if os(iOS)
import UIKit
private typealias ConversationNativeView = UIView
#else
import AppKit
private typealias ConversationNativeView = NSView
#endif
#if os(iOS)
@testable import MarginediOS
private typealias ConversationReader = MobileReaderState
#else
@testable import Margined
private typealias ConversationReader = ReaderState
#endif

@MainActor
final class ConversationPlaybackTests: XCTestCase {
    func testExplicitConversationReplacesProseWithOnlySavedAuthorsAndMessages() async throws {
        let f = try await fixture()
        f.startProse()
        f.reader.discussions.setDraft("Private unposted reply.", for: .thread(f.thread.id))
        let history = try await transcript(f.thread)
        f.reader.readConversation(thread: f.thread, document: history, context: f.context)
        XCTAssertEqual(f.session.document?.fingerprint, history.fingerprint)
        XCTAssertEqual(f.driver.requests.last?.text, "Alex")
        let text = f.session.document?.segments.map(\.text).joined(separator: " ") ?? ""
        XCTAssertTrue(text.contains("Saved first reply."))
        XCTAssertTrue(text.contains("Saved second reply."))
        XCTAssertTrue(text.contains("Sam"))
        XCTAssertFalse(text.contains("Private unposted reply."))
        XCTAssertFalse(text.contains("A later paragraph."))
        XCTAssertEqual(try Data(contentsOf: f.file), f.bytes)
    }

    func testConversationFinishNeverAutoplaysProseAndExplicitResumeKeepsItsPosition() async throws {
        let f = try await fixture()
        f.startProse()
        f.session.seek(1, offset: 2)
        let prose = try XCTUnwrap(f.session.document)
        let history = try await transcript(f.thread)
        f.reader.readConversation(thread: f.thread, document: history, context: f.context)
        XCTAssertEqual(f.session.document?.fingerprint, history.fingerprint)
        guard f.session.document?.fingerprint == history.fingerprint else { return }
        for _ in history.segments {
            let token = try XCTUnwrap(f.driver.requests.last?.token)
            f.driver.send(.finished(token))
        }
        XCTAssertEqual(f.session.status, .finished)
        let requests = f.driver.requests.count
        await Task.yield()
        XCTAssertEqual(f.driver.requests.count, requests, "Finishing a conversation must never restart document playback")
        XCTAssertEqual(f.session.document?.fingerprint, history.fingerprint)
        f.resumeProse()
        XCTAssertEqual(f.session.document?.fingerprint, prose.fingerprint)
        XCTAssertEqual(f.session.currentIndex, 1)
        XCTAssertEqual(f.session.offset, 2)
        XCTAssertEqual(f.driver.requests.last?.text, "document paragraph.")
        XCTAssertEqual(try Data(contentsOf: f.file), f.bytes)
    }

    func testAnOldDocumentCallbackCannotSpeakInAnotherFileWithIdenticalThreadIDs() async throws {
        let f = try await fixture()
        let oldContext = f.context
        let history = try await transcript(f.thread)
        let second = f.file.deletingLastPathComponent().appendingPathComponent("Second.md")
        try f.bytes.write(to: second)
        await f.show(second, source: String(decoding: f.bytes, as: UTF8.self))
        XCTAssertNotEqual(f.context, oldContext)
        f.startProse()
        let requests = f.driver.requests.count
        f.reader.readConversation(thread: f.thread, document: history, context: oldContext)
        XCTAssertEqual(f.driver.requests.count, requests)
        XCTAssertFalse(f.session.document?.fingerprint == history.fingerprint)
        f.reader.readConversation(thread: f.thread, document: history, context: f.context)
        XCTAssertEqual(f.session.document?.fingerprint, history.fingerprint, "The current document's explicit action must work")
        XCTAssertEqual(try Data(contentsOf: second), f.bytes)
    }

    func testAStalePreparedHistoryCannotReplaceTheUpdatedConversation() async throws {
        let f = try await fixture()
        let old = try await transcript(f.thread)
        let updated = String(decoding: f.bytes, as: UTF8.self)
            .replacingOccurrences(of: "Saved first reply.", with: "New saved first reply.")
        try Data(updated.utf8).write(to: f.file, options: .atomic)
        await f.show(f.file, source: updated)
        let thread = try XCTUnwrap(f.reader.rendered?.discussions?.threads.first)
        let current = try await transcript(thread)
        f.startProse()
        let requests = f.driver.requests.count
        f.reader.readConversation(thread: f.thread, document: old, context: f.context)
        XCTAssertEqual(f.driver.requests.count, requests)
        f.reader.readConversation(thread: thread, document: current, context: f.context)
        XCTAssertEqual(f.session.document?.fingerprint, current.fingerprint)
        XCTAssertTrue(f.session.document?.segments.contains { $0.text.contains("New saved first reply.") } == true)
        XCTAssertEqual(try Data(contentsOf: f.file), Data(updated.utf8))
    }

    func testAnOldVisibleProseStartCannotReplaceExplicitConversationPlayback() async throws {
        let f = try await fixture()
        let prose = try XCTUnwrap(f.reader.rendered?.speech)
        let passage = try XCTUnwrap(prose.segments.dropFirst().first)
        #if os(iOS)
        f.reader.startSpeech(mode: "visible")
        let request = try XCTUnwrap(f.reader.speechStartRequest)
        #else
        f.reader.speech.requestStart(.visible)
        let request = try XCTUnwrap(f.reader.speech.startRequest)
        #endif
        let history = try await transcript(f.thread)
        f.reader.readConversation(thread: f.thread, document: history, context: f.context)
        XCTAssertEqual(f.session.document?.fingerprint, history.fingerprint)
        #if os(iOS)
        XCTAssertNil(f.reader.speechStartRequest)
        f.reader.completeSpeechStart(requestID: request, elementID: passage.elementID, offset: 0)
        #else
        XCTAssertNil(f.reader.speech.startRequest)
        f.reader.speech.completeStart(request, elementID: passage.elementID, offset: 0)
        #endif
        XCTAssertEqual(f.session.document?.fingerprint, history.fingerprint,
                       "A delayed visible-passage lookup must not restart prose after Read Conversation")
        XCTAssertEqual(try Data(contentsOf: f.file), f.bytes)
    }

    func testSnapshotConversationPreservesTheInMemoryProsePosition() async throws {
        let f = try await fixture()
        await f.showSnapshot()
        XCTAssertNil(f.reader.fileURL)
        f.startProse(); f.session.seek(1, offset: 2)
        let prose = try XCTUnwrap(f.session.document)
        let history = try await transcript(f.thread)
        f.reader.readConversation(thread: f.thread, document: history, context: f.context)
        XCTAssertEqual(f.session.document?.fingerprint, history.fingerprint)
        f.resumeProse()
        XCTAssertEqual(f.session.document?.fingerprint, prose.fingerprint)
        XCTAssertEqual(f.session.currentIndex, 1)
        XCTAssertEqual(f.session.offset, 2)
        XCTAssertEqual(f.driver.requests.last?.text, "document paragraph.")
    }

    func testConversationTransportPausesResumesAndReplaysWithoutStartingProse() async throws {
        let f = try await fixture(), history = try await transcript(fixtureThread())
        f.startProse()
        f.reader.readConversation(thread: f.thread, document: history, context: f.context)
        f.togglePlayback(); XCTAssertEqual(f.session.status, .paused)
        f.togglePlayback(); XCTAssertEqual(f.session.status, .playing)
        XCTAssertEqual(f.session.document?.fingerprint, history.fingerprint)
        f.stopPlayback(); XCTAssertEqual(f.session.status, .idle)
        let previous = try XCTUnwrap(f.driver.requests.last?.token)
        f.togglePlayback(); await f.waitForPreparation()
        XCTAssertEqual(f.session.document?.fingerprint, history.fingerprint)
        XCTAssertEqual(f.driver.requests.last?.text, "Alex")
        f.driver.send(.finished(previous))
        XCTAssertEqual(f.session.currentIndex, 0, "A stopped utterance cannot advance the replay")
        guard f.session.document?.fingerprint == history.fingerprint else { return }
        for _ in history.segments { f.driver.send(.finished(try XCTUnwrap(f.driver.requests.last?.token))) }
        XCTAssertEqual(f.session.status, .finished)
        f.togglePlayback(); await f.waitForPreparation()
        XCTAssertEqual(f.session.document?.fingerprint, history.fingerprint)
        XCTAssertEqual(f.session.currentIndex, 0)
    }

    func testAChangeToTheSpokenConversationWaitsForShowLatest() async throws {
        let f = try await fixture(), history = try await transcript(fixtureThread())
        f.reader.readConversation(thread: f.thread, document: history, context: f.context)
        let changed = String(decoding: f.bytes, as: UTF8.self)
            .replacingOccurrences(of: "Saved first reply.", with: "A newly saved reply.")
        await f.externalUpdate(changed)
        XCTAssertTrue(f.reader.hasPendingFileUpdate)
        XCTAssertEqual(f.reader.source, String(decoding: f.bytes, as: UTF8.self))
        XCTAssertEqual(f.session.document?.fingerprint, history.fingerprint)
        XCTAssertEqual(f.session.status, .playing)
        await f.showLatest()
        XCTAssertEqual(f.reader.source, changed)
        XCTAssertFalse(f.reader.hasPendingFileUpdate)
        XCTAssertEqual(f.session.status, .idle, "Show Latest must not implicitly read prose")
        XCTAssertEqual(try Data(contentsOf: f.file), Data(changed.utf8))
    }

    func testProseChangesApplyWhileAnUnchangedConversationKeepsPlaying() async throws {
        let f = try await fixture(), history = try await transcript(fixtureThread())
        f.reader.readConversation(thread: f.thread, document: history, context: f.context)
        let requests = f.driver.requests.count
        let changed = String(decoding: f.bytes, as: UTF8.self)
            .replacingOccurrences(of: "A later paragraph.", with: "An agent changed this prose paragraph.")
        await f.externalUpdate(changed)
        XCTAssertEqual(f.reader.source, changed)
        XCTAssertFalse(f.reader.hasPendingFileUpdate)
        XCTAssertEqual(f.session.document?.fingerprint, history.fingerprint)
        XCTAssertEqual(f.session.status, .playing)
        XCTAssertEqual(f.driver.requests.count, requests, "An unrelated prose edit must not restart the conversation")
        XCTAssertEqual(try Data(contentsOf: f.file), Data(changed.utf8))
    }

    func testConversationPreparationUsesTheReadersCodeAndLinkOptions() async throws {
        let original = fixtureThread()
        let thread = DiscussionThread(id: original.id, state: original.state, target: original.target,
            messages: [.init(id: "m-options", author: "Alex", created: "2026-10-24T10:00:00Z",
                body: "[Reference](https://example.com/saved-note)\n\n```swift\nlet spokenCode = 42\n```", inReplyTo: nil)],
            resolvedBy: nil, resolved: nil, attachmentHistory: [])
        let ordinary = try await transcript(thread)
        let options = SpeechOptions(includeCode: true, includeLinkDestinations: true)
        let expanded = try await transcript(thread, options: options)
        XCTAssertEqual(expanded.options, options)
        XCTAssertFalse(ordinary.segments.contains { $0.text.contains("spokenCode") })
        XCTAssertTrue(expanded.segments.contains { $0.text.contains("spokenCode") })
        XCTAssertTrue(expanded.segments.contains { $0.text.contains("https://example.com/saved-note") })
        XCTAssertNotEqual(expanded.segments, ordinary.segments)
    }

    func testAnOldProseLocationCallbackCannotReplaceANewerPlaybackOwner() async throws {
        let f = try await fixture()
        let passage = try XCTUnwrap(f.reader.rendered?.speech?.segments.first)
        let other = try await MarkdownRenderer.shared.render("# Another reader\n", prepareSpeech: true)
        let speech = try XCTUnwrap(other.speech)
        #if os(iOS)
        f.reader.startSpeech(mode: "selection")
        let request = try XCTUnwrap(f.reader.speechStartRequest)
        let newOwner = UUID()
        f.reader.playback.play(document: speech, title: "Another reader", url: nil, ownerID: newOwner)
        f.reader.completeSpeechStart(requestID: request, elementID: passage.elementID, offset: 0)
        XCTAssertEqual(f.reader.playback.ownerID, newOwner)
        XCTAssertEqual(f.session.document?.fingerprint, speech.fingerprint)
        #else
        f.reader.speech.requestStart(.selection)
        let request = try XCTUnwrap(f.reader.speech.startRequest)
        let otherDriver = ConversationSpeechDriver()
        let otherSession = SpeechSession(driver: otherDriver,
            voices: { [SpeechVoice(id: "test", name: "Test", language: "en-US", quality: 1)] }, coordinator: f.coordinator)
        defer { otherSession.stop() }
        otherSession.play(speech)
        f.reader.speech.completeStart(request, elementID: passage.elementID, offset: 0)
        XCTAssertEqual(otherSession.status, .playing)
        XCTAssertEqual(f.session.status, .idle)
        #endif
    }

    func testANewerPlaybackOwnerSupersedesDelayedProsePreparation() async throws {
        let f = try await fixture(); f.startProse()
        f.preferences.options.includeCode = true
        let other = try await MarkdownRenderer.shared.render("# Another reader\n\nOther document text.\n",
            prepareSpeech: true, speechOptions: f.preferences.options)
        let speech = try XCTUnwrap(other.speech)
        f.resumeProse()
        XCTAssertTrue(f.reader.isRendering)
        #if os(iOS)
        let newOwner = UUID()
        f.reader.playback.play(document: speech, title: "Another reader", url: nil, ownerID: newOwner)
        await f.waitForPreparation(); await f.settle()
        XCTAssertEqual(f.reader.playback.ownerID, newOwner)
        XCTAssertEqual(f.session.document?.fingerprint, speech.fingerprint)
        #else
        let otherDriver = ConversationSpeechDriver()
        let otherSession = SpeechSession(driver: otherDriver,
            voices: { [SpeechVoice(id: "test", name: "Test", language: "en-US", quality: 1)] }, coordinator: f.coordinator)
        defer { otherSession.stop() }
        otherSession.play(speech)
        await f.waitForPreparation(); await f.settle()
        XCTAssertEqual(otherSession.status, .playing)
        XCTAssertEqual(f.session.status, .idle)
        #endif
    }

    func testStopCancelsProsePreparationAfterContentOptionsChange() async throws {
        let f = try await fixture()
        f.startProse()
        f.preferences.options.includeCode = true
        f.resumeProse()
        XCTAssertTrue(f.reader.isRendering, "Changing speech content must prepare a fresh document")
        f.stopPlayback()
        let requests = f.driver.requests.count
        await f.waitForPreparation(); await f.settle()
        XCTAssertEqual(f.reader.rendered?.speech?.options.includeCode, true,
                       "The document preparation must complete even though the speech intent was cancelled")
        XCTAssertEqual(f.session.status, .idle)
        XCTAssertEqual(f.driver.requests.count, requests, "Stop must not be followed by a delayed prose start")
        XCTAssertEqual(try Data(contentsOf: f.file), f.bytes)
    }

    func testLocalRepliesAndUndoRespectTheSpokenConversationVersion() async throws {
        let f = try await fixture()
        #if os(macOS)
        f.reader.installLoadedSnapshot(try SourceFileEdit.read(f.file))
        #endif
        f.reader.discussions.displayName = "Taylor"
        f.reader.openDiscussion(f.thread.id)
        f.reader.discussions.setDraft("A locally posted reply.", for: .thread(f.thread.id))
        let history = try await transcript(f.thread)
        f.reader.readConversation(thread: f.thread, document: history, context: f.context)
        f.reader.postDiscussion()
        await f.waitForSave(); await f.reader.waitForFileUpdateClassification(); await f.settle()
        let posted = try Data(contentsOf: f.file), postedSource = try MarkdownSource.decode(posted)
        XCTAssertTrue(postedSource.contains("A locally posted reply."), "The actual conditional file write must succeed")
        guard postedSource.contains("A locally posted reply.") else { return }
        XCTAssertNil(f.reader.discussionError)
        XCTAssertTrue(f.reader.hasPendingFileUpdate)
        XCTAssertEqual(f.reader.source, String(decoding: f.bytes, as: UTF8.self))
        XCTAssertEqual(f.session.document?.fingerprint, history.fingerprint)
        XCTAssertEqual(f.session.status, .playing)
        f.stopPlayback(); await f.showLatest()
        XCTAssertEqual(f.reader.source, postedSource)
        XCTAssertTrue(f.reader.canUndoDiscussion, "Showing the saved snapshot must preserve its conditional Undo")
        guard f.reader.canUndoDiscussion, let updatedThread = f.reader.rendered?.discussions?.threads.first else { return }
        let updatedSpeech = try await transcript(updatedThread)
        f.reader.readConversation(thread: updatedThread, document: updatedSpeech, context: f.context)
        f.reader.undoDiscussion()
        await f.waitForSave(); await f.reader.waitForFileUpdateClassification(); await f.settle()
        XCTAssertEqual(try Data(contentsOf: f.file), f.bytes, "Undo must restore the exact original file")
        XCTAssertTrue(f.reader.hasPendingFileUpdate)
        XCTAssertEqual(f.reader.source, postedSource, "Undo must not replace the displayed spoken history mid-sentence")
        XCTAssertEqual(f.session.document?.fingerprint, updatedSpeech.fingerprint)
        await f.showLatest()
        XCTAssertEqual(f.reader.source, String(decoding: f.bytes, as: UTF8.self))
    }

    func testRootReplayUsesCurrentOptionsAndSavedThreadAndRefusesDeletedConversation() async throws {
        let f = try await fixture(), history = try await transcript(fixtureThread())
        f.reader.readConversation(thread: f.thread, document: history, context: f.context)
        f.stopPlayback()
        let changed = String(decoding: f.bytes, as: UTF8.self)
            .replacingOccurrences(of: "Saved first reply.", with: "The saved reply has changed.")
        await f.externalUpdate(changed)
        XCTAssertEqual(f.reader.source, changed)
        f.preferences.options.includeLinkDestinations = true
        f.togglePlayback(); await f.waitForPreparation(); await f.settle()
        XCTAssertEqual(f.session.document?.options, f.preferences.options)
        XCTAssertTrue(f.session.document?.segments.contains { $0.text.contains("The saved reply has changed.") } == true)
        XCTAssertFalse(f.session.document?.segments.contains { $0.text == "Saved first reply." } == true)
        XCTAssertEqual(f.session.status, .playing)
        f.stopPlayback()
        await f.externalUpdate("# Plan\n\nNo conversations remain.\n")
        XCTAssertTrue(f.reader.rendered?.discussions?.threads.isEmpty == true)
        let requests = f.driver.requests.count
        f.togglePlayback(); await f.waitForPreparation(); await f.settle()
        XCTAssertEqual(f.driver.requests.count, requests, "A deleted conversation must never replay or turn into prose")
        XCTAssertFalse(f.session.isActive)
    }

    func testFailedSelectionKeepsThePreviewProseResumePosition() async throws {
        let f = try await fixture(); await f.showSnapshot()
        f.startProse(); f.session.seek(1, offset: 2)
        let history = try await transcript(f.thread)
        f.reader.readConversation(thread: f.thread, document: history, context: f.context)
        #if os(iOS)
        f.reader.startSpeech(mode: "selection")
        let request = try XCTUnwrap(f.reader.speechStartRequest)
        f.reader.completeSpeechStart(requestID: request, elementID: nil, offset: 0)
        #else
        f.reader.speech.requestStart(.selection)
        let request = try XCTUnwrap(f.reader.speech.startRequest)
        f.reader.speech.completeStart(request, elementID: nil, offset: 0)
        #endif
        XCTAssertEqual(f.session.document?.fingerprint, history.fingerprint)
        XCTAssertEqual(f.session.status, .playing)
        f.resumeProse()
        XCTAssertEqual(f.session.currentIndex, 1)
        XCTAssertEqual(f.session.offset, 2)
        XCTAssertEqual(f.driver.requests.last?.text, "document paragraph.")
    }

    func testConversationSpeechHighlightsOnlyItsMountedHistory() async throws {
        let f = try await fixture()
        #if os(iOS)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: MobileDocumentWorkspace(reader: f.reader, openFolder: {}, closeFile: {}))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1_200, height: 900)
        window.rootViewController = host; window.makeKeyAndVisible(); host.loadViewIfNeeded(); host.view.layoutIfNeeded()
        addTeardownBlock { @MainActor in window.isHidden = true; window.rootViewController = nil }
        let marginReady = await poll { f.reader.discussionUsesMargin }
        XCTAssertTrue(marginReady, "The wide hosted reader must be mounted before testing two visible speech surfaces")
        guard marginReady else { return }
        #else
        let host = NSHostingController(rootView: ReaderView(reader: f.reader))
        let window = ConversationTestWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 1_200, height: 900)); window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil); window.contentViewController = nil; window.close() }
        #endif
        let mounted = await poll { self.webViews(in: host.view).first?.estimatedProgress == 1 }
        XCTAssertTrue(mounted, "A real committed prose page is the positive control")
        guard mounted, let prose = webViews(in: host.view).first else { return }
        let proseReady = await pollScript(prose, "document.querySelector('main')?.textContent.includes('A document paragraph.')===true")
        XCTAssertTrue(proseReady); guard proseReady else { return }
        f.startProse()
        let proseHighlight = await pollScript(prose, "document.querySelector('.margined-speaking')?.textContent.includes('Plan')===true")
        XCTAssertTrue(proseHighlight, "Document playback must visibly highlight before testing conversation isolation")
        guard proseHighlight else { return }
        f.reader.openDiscussion(f.thread.id)
        let historyMounted = await poll { self.webViews(in: host.view).contains { $0 !== prose && $0.estimatedProgress == 1 } }
        XCTAssertTrue(historyMounted, "The existing native history must be mounted")
        guard historyMounted, let history = webViews(in: host.view).first(where: { $0 !== prose }) else { return }
        let historyReady = await pollScript(history, "document.querySelector('article')?.textContent.includes('Saved first reply.')===true")
        XCTAssertTrue(historyReady); guard historyReady else { return }
        let speech = try await transcript(f.thread)
        f.reader.readConversation(thread: f.thread, document: speech, context: f.context)
        let marked = await pollScript(history, "document.querySelector('.margined-speaking')?.textContent==='Alex'")
        XCTAssertTrue(marked, "Conversation speech must highlight the saved author in its own native history")
        let proseMarks = try await prose.evaluateJavaScript("document.querySelectorAll('.margined-speaking').length") as? Int
        XCTAssertEqual(proseMarks, 0, "Conversation element IDs must never highlight or scroll document prose")
        XCTAssertEqual(f.session.document?.fingerprint, speech.fingerprint)
        XCTAssertEqual(try Data(contentsOf: f.file), f.bytes)
    }

    private func webViews(in view: ConversationNativeView) -> [WKWebView] {
        if let web = view as? WKWebView { return [web] }
        return view.subviews.flatMap { webViews(in: $0) }
    }
    private func poll(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<250 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
    private func pollScript(_ web: WKWebView, _ script: String) async -> Bool {
        for _ in 0..<250 {
            if (try? await web.evaluateJavaScript(script) as? Bool) == true { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func transcript(_ thread: DiscussionThread, options: SpeechOptions = SpeechOptions()) async throws -> SpeechDocument {
        let output = try await MarkdownRenderer.shared.renderDiscussion(thread,
            documentLanguage: "en", prepareSpeech: true, speechOptions: options, includeContext: false)
        return try XCTUnwrap(output.speech)
    }

    private func fixtureThread() -> DiscussionThread {
        return DiscussionThread(id: "t-speech", state: .open,
            target: .init(type: "TextQuoteSelector", exact: "A document paragraph.", prefix: "Plan", suffix: "Next", section: "Plan"),
            messages: [
                .init(id: "m-first", author: "Alex", created: "2026-10-24T10:00:00Z", body: "Saved first reply.", inReplyTo: nil),
                .init(id: "m-second", author: "Sam", created: "2026-10-24T10:10:00Z", body: "Saved second reply.", inReplyTo: "m-first")
            ], resolvedBy: nil, resolved: nil, attachmentHistory: [])
    }

    private func fixture() async throws -> Rig {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Conversation.md")
        let prose = "# Plan\n\nA document paragraph.\n\n## Next\n\nA later paragraph.\n"
        let thread = fixtureThread()
        let bytes = try MarkdownSourceEdits.apply(DiscussionEdits.splices(for: .newThread(thread), in: DiscussionCodec.parse(prose)),
            to: Data(prose.utf8), expectedSource: prose)
        try bytes.write(to: file)
        let domain = "Margined.ConversationSpeechTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let preferences = SpeechPreferences(defaults: defaults), progress = SpeechProgressStore(defaults: defaults)
        let driver = ConversationSpeechDriver()
        let coordinator = SpeechCoordinator()
        let session = SpeechSession(driver: driver,
            voices: { [SpeechVoice(id: "test", name: "Test", language: "en-US", quality: 1)] },
            coordinator: coordinator)
        #if os(iOS)
        let owner = MobilePlaybackOwner(session: session, audioSession: ConversationAudioSession(),
            nowPlaying: ConversationNowPlaying(), preferences: preferences, progressStore: progress)
        let reader = MobileReaderState(playback: owner, defaults: defaults)
        #else
        let reader = ReaderState(speechFactory: { reader in
            ReaderSpeech(reader: reader, session: session, preferences: preferences, progress: progress)
        })
        _ = reader.speech
        #endif
        let rig = Rig(reader: reader, driver: driver, session: session, coordinator: coordinator, file: file, bytes: bytes, thread: thread)
        await rig.show(file, source: String(decoding: bytes, as: UTF8.self))
        XCTAssertNotNil(reader.rendered?.speech)
        addTeardownBlock { @MainActor in
            reader.discussions.discardDrafts()
            #if os(iOS)
            await reader.close()
            #else
            reader.stop()
            #endif
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: folder)
        }
        return rig
    }

    @MainActor
    private struct Rig {
        let reader: ConversationReader
        let driver: ConversationSpeechDriver
        let session: SpeechSession
        let coordinator: SpeechCoordinator
        let file: URL
        let bytes: Data
        let thread: DiscussionThread
        var context: UUID {
            #if os(iOS)
            reader.documentGeneration
            #else
            reader.currentDiscussionVersion.context
            #endif
        }
        func show(_ url: URL, source: String) async {
            #if os(iOS)
            if reader.fileURL == url { await reader.refresh() }
            else { await reader.open(url: url) }
            await reader.waitForRendering()
            #else
            reader.fileURL = url; reader.source = source; reader.render()
            for _ in 0..<500 {
                if !reader.isRendering { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            #endif
        }
        func showSnapshot() async {
            #if os(iOS)
            var url = URLComponents(); url.scheme = "margined"; url.host = "preview"
            url.queryItems = [.init(name: "text", value: String(decoding: bytes, as: UTF8.self)), .init(name: "title", value: "Conversation")]
            await reader.openPreview(url: url.url!)
            await reader.waitForRendering()
            #else
            reader.fileURL = nil; reader.source = String(decoding: bytes, as: UTF8.self); reader.render()
            await settle()
            #endif
        }
        func externalUpdate(_ text: String) async {
            do { try Data(text.utf8).write(to: file, options: .atomic) }
            catch { XCTFail("Could not prepare external update: \(error)"); return }
            #if os(iOS)
            await reader.refresh()
            #else
            reader.receiveFileUpdate(text)
            #endif
            await reader.waitForFileUpdateClassification()
            await settle()
        }
        func settle() async {
            #if os(iOS)
            await reader.waitForRendering()
            #else
            for _ in 0..<500 {
                if !reader.isRendering { return }
                try? await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Reader render did not settle")
            #endif
        }
        func showLatest() async {
            #if os(iOS)
            reader.showLatest()
            #else
            reader.speech.showLatest()
            #endif
            await settle()
        }
        func togglePlayback() {
            #if os(iOS)
            reader.toggleSpeechPlayback()
            #else
            reader.speech.togglePlayback()
            #endif
        }
        func stopPlayback() {
            #if os(iOS)
            reader.stopSpeech()
            #else
            reader.speech.stop()
            #endif
        }
        var preferences: SpeechPreferences {
            #if os(iOS)
            reader.playback.preferences
            #else
            reader.speech.preferences
            #endif
        }
        func waitForPreparation() async {
            #if os(iOS)
            await reader.waitForSpeechPreparation()
            #else
            await reader.speech.waitForPreparation()
            #endif
        }
        func waitForSave() async {
            #if os(iOS)
            await reader.waitForSaving()
            #else
            for _ in 0..<500 {
                if !reader.discussionSaving { return }
                try? await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("The discussion save did not finish")
            #endif
        }
        func startProse() {
            #if os(iOS)
            reader.startSpeech(mode: "beginning")
            #else
            reader.speech.start()
            #endif
        }
        func resumeProse() {
            #if os(iOS)
            reader.resumeSpeechPosition()
            #else
            reader.speech.resumeSaved()
            #endif
        }
    }
}

@MainActor
private final class ConversationSpeechDriver: SpeechDriver {
    struct Request { let text: String; let token: UUID }
    var eventHandler: ((SpeechDriverEvent) -> Void)?
    var useAssistiveTechnologySettings = false
    var requests: [Request] = []
    func speak(_ text: String, voice: SpeechVoice?, rate: Double, token: UUID) { requests.append(.init(text: text, token: token)) }
    func pause() -> Bool { true }
    func resume() -> Bool { true }
    func stop() {}
    func send(_ event: SpeechDriverEvent) { eventHandler?(event) }
}

#if os(iOS)
@MainActor
private final class ConversationAudioSession: MobileAudioSessionManaging {
    func activate() throws {}
    func deactivate() {}
}
@MainActor
private final class ConversationNowPlaying: MobileNowPlayingPublishing {
    func beginOwnership(generation: UUID, handler: @escaping @MainActor (UUID, MobilePlaybackCommand) -> Bool) {}
    func update(_ metadata: MobileNowPlayingMetadata) {}
    func endOwnership() {}
}
#endif

#if os(macOS)
@MainActor
private final class ConversationTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
#endif

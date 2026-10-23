import Foundation
import AppKit
import XCTest
@testable import Margined

@MainActor final class DiscussionStateTests: XCTestCase {
    func testSnapshotsAndStreamsOfferACopyWithoutPostingOrDroppingDrafts() async throws {
        for streaming in [false, true] {
            let reader = ReaderState()
            defer { reader.discussions.discardDrafts(); reader.stop() }
            reader.source = "Passage."; reader.isStreamingPreview = streaming
            reader.render(); try await settle(reader)
            let key = DiscussionSession.DraftKey.new(UUID())
            reader.discussions.displayName = "Reviewer"; reader.discussions.selection = key
            reader.discussions.setDraft("Keep this note.", for: key, target: .init(type: "TextQuoteSelector", exact: "Passage.", prefix: "", suffix: "", section: nil))
            reader.postDiscussion()
            XCTAssertTrue(reader.discussionCopyOffered)
            XCTAssertEqual(reader.discussionError, DiscussionSession.Failure.savedCopyRequired.localizedDescription)
            XCTAssertEqual(reader.source, "Passage.")
            XCTAssertEqual(reader.discussions.drafts[key]?.body, "Keep this note.")
            XCTAssertNil(reader.discussions.pending)
        }
    }

    func testPermissionLossOffersACopyAndKeepsTheUnpostedDraft() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let data = Data("Passage.".utf8); try data.write(to: file)
        let reader = ReaderState()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            reader.discussions.discardDrafts(); reader.stop(); try? FileManager.default.removeItem(at: file)
        }
        reader.fileURL = file; reader.source = "Passage."; reader.render(); try await settle(reader)
        let key = DiscussionSession.DraftKey.new(UUID())
        reader.discussions.displayName = "Reviewer"; reader.discussions.selection = key
        reader.discussions.setDraft("Keep after permission loss.", for: key, target: .init(type: "TextQuoteSelector", exact: "Passage.", prefix: "", suffix: "", section: nil))
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        reader.postDiscussion(); try await settle(reader)
        XCTAssertTrue(reader.discussionCopyOffered)
        XCTAssertEqual(reader.discussions.drafts[key]?.body, "Keep after permission loss.")
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testNoteOnlyRefreshKeepsReviewSelectionAndDoesNotAnnounceProseChanges() async throws {
        let initial = "# Plan\n\nFirst.\n\nSecond.\n"
        let changed = "# Plan\n\nFirst changed.\n\nSecond changed.\n"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data(initial.utf8).write(to: file)
        var messages: [String] = []
        let announcements = ReaderAnnouncements(delay: .milliseconds(5)) { messages.append($0) }
        announcements.isEligible = { true }
        let reader = ReaderState(announcements: announcements)
        defer { reader.stop(); try? FileManager.default.removeItem(at: file) }
        reader.fileURL = file; reader.source = initial; reader.render(); try await settle(reader)
        reader.markReviewed(); try await settle(reader)
        try Data(changed.utf8).write(to: file, options: .atomic)
        reader.acceptFileUpdate(changed); try await settle(reader)
        XCTAssertEqual(reader.changes.count, 2)
        reader.currentChangeIndex = 1
        let selected = try XCTUnwrap(reader.selectedChange)
        try await Task.sleep(for: .milliseconds(20)); messages.removeAll()
        let message = DiscussionMessage(id: "m-note", author: "Reviewer", created: "2026-10-23T10:00:00Z", body: "Note only.", inReplyTo: nil)
        let thread = DiscussionThread(id: "t-note", state: .open,
            target: .init(type: "TextQuoteSelector", exact: "Second changed.", prefix: "First changed.", suffix: "", section: "Plan"),
            messages: [message], resolvedBy: nil, resolved: nil, attachmentHistory: [])
        let parsed = try DiscussionCodec.parse(changed)
        let data = try MarkdownSourceEdits.apply(DiscussionEdits.splices(for: .newThread(thread), in: parsed), to: Data(changed.utf8), expectedSource: changed)
        try data.write(to: file, options: .atomic)
        reader.acceptFileUpdate(try MarkdownSource.decode(data)); try await settle(reader)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(reader.selectedChange?.id, selected.id)
        XCTAssertEqual(reader.selectedChange?.after, selected.after)
        XCTAssertTrue(messages.isEmpty, "Discussion-only activity must not announce new prose changes")
    }

    func testQuitConfirmationKeepsTheSafeDefaultAndDestructiveAlternative() throws {
        let alert = DiscussionDraftAlert.make(quitting: true)
        let keep = try XCTUnwrap(alert.buttons.first)
        XCTAssertEqual(keep.title, String(localized: "Keep Open"))
        XCTAssertEqual(keep.keyEquivalent, "\r")
        XCTAssertTrue(alert.window.defaultButtonCell?.controlView === keep)
        XCTAssertTrue(try XCTUnwrap(alert.buttons.last).hasDestructiveAction)
    }

    func testCloseSheetSafeDefaultKeepsDraftsUntilExplicitDiscard() async throws {
        let document = MarkdownDocument(), delegate = DiscussionCloseDelegate()
        document.makeWindowControllers()
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
            document.reader.discussions.discardDrafts(); document.close()
        }
        window.makeKeyAndOrderFront(nil)
        let key = DiscussionSession.DraftKey.new(UUID())
        document.reader.discussions.setDraft("Keep me until explicit discard.", for: key)
        let selector = #selector(DiscussionCloseDelegate.document(_:shouldClose:contextInfo:))
        let cookie = UnsafeMutableRawPointer(bitPattern: 0x4321)
        document.canClose(withDelegate: delegate, shouldClose: selector, contextInfo: cookie)
        for _ in 0..<100 { if window.attachedSheet != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertEqual((sheet.defaultButtonCell?.controlView as? NSButton)?.title, String(localized: "Keep Open"))
        XCTAssertTrue(sheet.isVisible)
        try XCTUnwrap(sheet.defaultButtonCell?.controlView as? NSButton).performClick(nil)
        for _ in 0..<100 { if delegate.allowed != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(delegate.allowed, false)
        XCTAssertEqual(delegate.context, cookie)
        XCTAssertTrue(document.reader.discussions.hasUnpostedDrafts)
        if let remaining = window.attachedSheet { window.endSheet(remaining, returnCode: .alertFirstButtonReturn) }
        for _ in 0..<100 { if window.attachedSheet == nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        delegate.allowed = nil
        document.canClose(withDelegate: delegate, shouldClose: selector, contextInfo: cookie)
        for _ in 0..<100 { if window.attachedSheet != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        func button(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == String(localized: "Discard Drafts") { return button }
            return view.subviews.lazy.compactMap { button(in: $0) }.first
        }
        let content = try XCTUnwrap(window.attachedSheet?.contentView)
        try XCTUnwrap(button(in: content)).performClick(nil)
        for _ in 0..<100 { if delegate.allowed != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(delegate.allowed, true)
        XCTAssertFalse(document.reader.discussions.hasUnpostedDrafts)
    }

    func testPostThenTickAndUndoKeepBothFeaturesOnOneDisplayedFile() async throws {
        let source = "- [ ] Task\n\nPassage.\n", file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data(source.utf8).write(to: file)
        let reader = ReaderState()
        defer { reader.discussions.discardDrafts(); reader.stop(); try? FileManager.default.removeItem(at: file) }
        reader.fileURL = file; reader.source = source; reader.render(); try await settle(reader)
        let key = DiscussionSession.DraftKey.new(UUID())
        reader.discussions.displayName = "Anand"; reader.discussions.selection = key
        reader.discussions.setDraft("A note.", for: key, target: DiscussionTarget(type: "TextQuoteSelector", exact: "Passage.", prefix: "Task ", suffix: "", section: nil))
        reader.postDiscussion(); try await settle(reader)
        let posted = try MarkdownSource.read(file)
        XCTAssertEqual(try DiscussionCodec.parse(posted).threads.count, 1)
        XCTAssertFalse(reader.discussions.hasUnpostedDrafts)
        reader.checklistMode = true; reader.setTaskChecked(0, checked: true); try await settle(reader)
        XCTAssertTrue(try MarkdownSource.read(file).hasPrefix("- [x] Task"))
        reader.undoChecklist(); try await settle(reader)
        XCTAssertEqual(try MarkdownSource.read(file), posted)
        reader.undoDiscussion(); try await settle(reader)
        XCTAssertEqual(try Data(contentsOf: file), Data(source.utf8))
    }

    func testStalePostRetainsDraftAndDoesNotOverwriteAgentProse() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data("Passage.\n".utf8).write(to: file)
        let reader = ReaderState()
        defer { reader.discussions.discardDrafts(); reader.stop(); try? FileManager.default.removeItem(at: file) }
        reader.fileURL = file; reader.source = "Passage.\n"; reader.render(); try await settle(reader)
        let key = DiscussionSession.DraftKey.new(UUID())
        reader.discussions.displayName = "Anand"; reader.discussions.selection = key
        reader.discussions.setDraft("Keep this draft.", for: key, target: DiscussionTarget(type: "TextQuoteSelector", exact: "Passage.", prefix: "", suffix: "", section: nil))
        try Data("Agent replacement.\n".utf8).write(to: file, options: .atomic)
        reader.postDiscussion(); try await settle(reader)
        XCTAssertEqual(try Data(contentsOf: file), Data("Agent replacement.\n".utf8))
        XCTAssertEqual(reader.discussions.drafts[key]?.body, "Keep this draft.")
        XCTAssertNotNil(reader.discussionError)
    }

    func testCloseValidationKeepsUnpostedDraftsAndRepliesToAppKit() {
        let document = MarkdownDocument(), delegate = DiscussionCloseDelegate()
        let key = DiscussionSession.DraftKey.new(UUID())
        document.reader.discussions.setDraft("Do not lose this reply.", for: key)
        let cookie = UnsafeMutableRawPointer(bitPattern: 0x1234)
        document.canClose(withDelegate: delegate, shouldClose: #selector(DiscussionCloseDelegate.document(_:shouldClose:contextInfo:)), contextInfo: cookie)
        XCTAssertEqual(delegate.allowed, false)
        XCTAssertEqual(delegate.context, cookie)
        XCTAssertTrue(document.reader.discussions.hasUnpostedDrafts)
        document.reader.discussions.discardDrafts()
        delegate.allowed = nil
        document.canClose(withDelegate: delegate, shouldClose: #selector(DiscussionCloseDelegate.document(_:shouldClose:contextInfo:)), contextInfo: cookie)
        XCTAssertEqual(delegate.allowed, true)
        document.close()
    }

    private func settle(_ reader: ReaderState) async throws {
        for _ in 0..<300 {
            if !reader.fileSaving && !reader.isRendering { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Document save/render did not settle")
    }
}

@MainActor private final class DiscussionCloseDelegate: NSObject {
    var allowed: Bool?
    var context: UnsafeMutableRawPointer?
    @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        allowed = shouldClose; context = contextInfo
    }
}

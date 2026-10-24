import Foundation
import XCTest
@testable import Margined

@MainActor final class DiscussionActionsTests: XCTestCase {
    func testAuthorConfirmationAfterRefreshRetainsDraftAndRefusesAutomaticPost() async throws {
        let f = try await fixture()
        defer { cleanup(f) }
        let reader = f.reader, key = DiscussionSession.DraftKey.thread("t1")
        reader.discussions.displayName = ""; reader.discussions.selection = key
        reader.discussions.setDraft("Keep this unposted reply.", for: key)
        reader.postDiscussion()
        XCTAssertTrue(reader.showDiscussionAuthorPrompt)
        let replacement = f.source + "\nAgent update.\n"
        try Data(replacement.utf8).write(to: f.file, options: .atomic)
        let before = reader.lastRefreshed
        reader.reload()
        for _ in 0..<200 { if reader.lastRefreshed != before { break }; try await Task.sleep(for: .milliseconds(10)) }
        try await settle(reader)
        XCTAssertNotEqual(reader.lastRefreshed, before)
        reader.confirmDiscussionAuthor("Reviewer")
        try await settle(reader)
        XCTAssertEqual(try Data(contentsOf: f.file), Data(replacement.utf8))
        XCTAssertEqual(reader.discussions.drafts[key]?.body, "Keep this unposted reply.")
        XCTAssertNotNil(reader.discussionError)
    }
    func testSuccessfulPostSelectsItsSavedThread() async throws {
        let f = try await fixture()
        defer { cleanup(f) }
        let reader = f.reader, key = DiscussionSession.DraftKey.new(UUID())
        reader.discussions.displayName = "Reviewer"; reader.discussions.selection = key
        reader.discussions.setDraft("New discussion.", for: key,
            target: .init(type: "TextQuoteSelector", exact: "Replacement.", prefix: "Passage.", suffix: "After.", section: nil))
        reader.postDiscussion(); try await settle(reader)
        let thread = try XCTUnwrap(reader.rendered?.discussions?.threads.last)
        XCTAssertEqual(thread.messages.first?.body, "New discussion.")
        XCTAssertEqual(reader.discussions.selection, .thread(thread.id))
        XCTAssertNil(reader.discussions.drafts[key])
    }
    func testTypingDuringAcceptedPostKeepsItsDraftSelected() async throws {
        let f = try await fixture()
        defer { cleanup(f) }
        let reader = f.reader, key = DiscussionSession.DraftKey.new(UUID())
        reader.discussions.displayName = "Reviewer"; reader.discussions.selection = key
        reader.discussions.setDraft("Posted text.", for: key,
            target: .init(type: "TextQuoteSelector", exact: "Replacement.", prefix: "Passage.", suffix: "After.", section: nil))
        reader.postDiscussion()
        reader.discussions.setDraft("More typing while saving.", for: key)
        try await settle(reader)
        XCTAssertEqual(reader.discussions.selection, key)
        XCTAssertEqual(reader.discussions.drafts[key]?.body, "More typing while saving.")
        XCTAssertEqual(reader.rendered?.discussions?.threads.last?.messages.first?.body, "Posted text.")
    }
    func testResolveChoicesRequestAuthorAndReopenKeepsANewerDraft() async throws {
        let f = try await fixture()
        defer { cleanup(f) }
        let reader = f.reader, key = DiscussionSession.DraftKey.thread("t1")
        reader.discussions.displayName = ""; reader.discussions.selection = key
        reader.discussions.setDraft("Reply before resolving.", for: key)
        reader.requestResolveDiscussion("t1")
        XCTAssertNotNil(reader.discussionResolution)
        XCTAssertEqual(try Data(contentsOf: f.file), Data(f.source.utf8))
        reader.confirmDiscussionResolution(.keepOpen)
        XCTAssertEqual(reader.discussions.drafts[key]?.body, "Reply before resolving.")
        XCTAssertNil(reader.discussionResolution)
        reader.requestResolveDiscussion("t1")
        reader.confirmDiscussionResolution(.postDraft)
        XCTAssertTrue(reader.showDiscussionAuthorPrompt)
        reader.confirmDiscussionAuthor("Reviewer"); try await settle(reader)
        let thread = try XCTUnwrap(reader.rendered?.discussions?.threads.first)
        XCTAssertEqual(thread.state, .resolved)
        XCTAssertEqual(thread.messages.map(\.author), ["Original", "Reviewer"])
        XCTAssertEqual(thread.messages.last?.body, "Reply before resolving.")
        XCTAssertNil(reader.discussions.drafts[key])
        reader.discussions.setDraft("Keep after reopen.", for: key)
        reader.reopenDiscussion("t1"); try await settle(reader)
        XCTAssertEqual(reader.rendered?.discussions?.threads.first?.state, .open)
        XCTAssertNil(reader.rendered?.discussions?.threads.first?.resolvedBy)
        XCTAssertEqual(reader.discussions.drafts[key]?.body, "Keep after reopen.")
    }
    func testReattachmentComparesQuotesAndWritesOnlyAfterConfirmation() async throws {
        let f = try await fixture()
        defer { cleanup(f) }
        let reader = f.reader, key = DiscussionSession.DraftKey.thread("t1")
        reader.discussions.displayName = "Reviewer"; reader.discussions.selection = key
        reader.discussions.setDraft("Keep this reply.", for: key)
        let projection = try XCTUnwrap(reader.rendered?.discussionText)
        let selected = try XCTUnwrap(projection.selection((projection.text as NSString).range(of: "Replacement."), renderID: "native"))
        reader.proposeDiscussionReattachment("t1", selection: selected)
        XCTAssertEqual(reader.discussionReattachment?.originalTarget.exact, "Passage.")
        XCTAssertEqual(reader.discussionReattachment?.selection.target.exact, "Replacement.")
        XCTAssertEqual(try Data(contentsOf: f.file), Data(f.source.utf8))
        reader.cancelDiscussionReattachment()
        XCTAssertNil(reader.discussionReattachment)
        reader.proposeDiscussionReattachment("t1", selection: selected)
        reader.confirmDiscussionReattachment(); try await settle(reader)
        let thread = try XCTUnwrap(reader.rendered?.discussions?.threads.first)
        XCTAssertEqual(thread.target.exact, "Replacement.")
        XCTAssertEqual(thread.attachmentHistory.first?.target.exact, "Passage.")
        XCTAssertEqual(thread.attachmentHistory.first?.author, "Reviewer")
        XCTAssertEqual(reader.discussions.drafts[key]?.body, "Keep this reply.")
        XCTAssertNil(reader.discussionReattachment)
        reader.undoDiscussion(); try await settle(reader)
        XCTAssertEqual(try Data(contentsOf: f.file), Data(f.source.utf8))
    }
    func testOpeningAFilteredThreadMakesItsConversationVisible() async throws {
        let f = try await fixture(resolved: true)
        defer { cleanup(f) }
        f.reader.discussions.filter = .open
        f.reader.openDiscussion("t1")
        XCTAssertEqual(f.reader.discussions.filter, .all)
        XCTAssertEqual(f.reader.discussions.selection, .thread("t1"))
        XCTAssertTrue(f.reader.showDiscussions)
        XCTAssertEqual(try Data(contentsOf: f.file), Data(f.source.utf8))
    }
    func testResolvedReplyRequiresConfirmationAndCancellationKeepsDraft() async throws {
        let f = try await fixture(resolved: true)
        defer { cleanup(f) }
        let reader = f.reader, key = DiscussionSession.DraftKey.thread("t1")
        reader.discussions.displayName = "Reviewer"; reader.openDiscussion("t1")
        reader.discussions.setDraft("Reply after resolution.", for: key)
        reader.postDiscussion()
        XCTAssertEqual(reader.discussionReopenReply?.key, key)
        XCTAssertEqual(try Data(contentsOf: f.file), Data(f.source.utf8))
        reader.cancelDiscussionReopenReply()
        XCTAssertNil(reader.discussionReopenReply)
        XCTAssertEqual(reader.discussions.drafts[key]?.body, "Reply after resolution.")
        reader.postDiscussion(); reader.confirmDiscussionReopenReply(); try await settle(reader)
        XCTAssertEqual(reader.rendered?.discussions?.threads.first?.state, .open)
        XCTAssertEqual(reader.rendered?.discussions?.threads.first?.messages.map(\.author), ["Original", "Reviewer"])
        XCTAssertEqual(reader.rendered?.discussions?.threads.first?.messages.last?.body, "Reply after resolution.")
        XCTAssertNil(reader.discussions.drafts[key])
        XCTAssertNil(reader.discussionReopenReply)
    }
    func testResolvedReplyConfirmationRefusesNewerTyping() async throws {
        let f = try await fixture(resolved: true)
        defer { cleanup(f) }
        let reader = f.reader, key = DiscussionSession.DraftKey.thread("t1")
        reader.discussions.displayName = "Reviewer"; reader.openDiscussion("t1")
        reader.discussions.setDraft("Initial reply.", for: key); reader.postDiscussion()
        XCTAssertNotNil(reader.discussionReopenReply)
        reader.discussions.setDraft("Newer unconfirmed reply.", for: key)
        reader.confirmDiscussionReopenReply(); try await settle(reader)
        XCTAssertEqual(try Data(contentsOf: f.file), Data(f.source.utf8))
        XCTAssertEqual(reader.discussions.drafts[key]?.body, "Newer unconfirmed reply.")
        XCTAssertEqual(reader.rendered?.discussions?.threads.first?.state, .resolved)
        XCTAssertNotNil(reader.discussionError)
    }
    func testChangingFutureAuthorDoesNotPostOrRewriteRecordedMessages() async throws {
        let f = try await fixture()
        defer { cleanup(f) }
        let reader = f.reader, key = DiscussionSession.DraftKey.thread("t1")
        reader.discussions.displayName = "Prior name"; reader.openDiscussion("t1")
        reader.discussions.setDraft("Unposted reply.", for: key)
        reader.requestChangeDiscussionAuthor()
        XCTAssertTrue(reader.showDiscussionAuthorPrompt)
        reader.confirmDiscussionAuthor("Future name"); try await settle(reader)
        XCTAssertFalse(reader.showDiscussionAuthorPrompt)
        XCTAssertEqual(reader.discussions.displayName, "Future name")
        XCTAssertEqual(try Data(contentsOf: f.file), Data(f.source.utf8))
        XCTAssertEqual(reader.discussions.drafts[key]?.body, "Unposted reply.")
        reader.postDiscussion(); try await settle(reader)
        XCTAssertEqual(reader.rendered?.discussions?.threads.first?.messages.map(\.author), ["Original", "Future name"])
    }

    private struct Fixture { let reader: ReaderState; let file: URL; let source: String }
    private func fixture(resolved: Bool = false) async throws -> Fixture {
        var source = "# Plan\n\nBefore.\n\nPassage.\n\nReplacement.\n\nAfter.\n"
        let thread = DiscussionThread(id: "t1", state: resolved ? .resolved : .open,
            target: .init(type: "TextQuoteSelector", exact: "Passage.", prefix: "Before.", suffix: "Replacement.", section: "Plan"),
            messages: [.init(id: "m1", author: "Original", created: "2026-10-23T10:00:00Z", body: "First note.", inReplyTo: nil)],
            resolvedBy: resolved ? "Original" : nil, resolved: resolved ? "2026-10-23T11:00:00Z" : nil, attachmentHistory: [])
        let document = try DiscussionCodec.parse(source)
        source = try MarkdownSource.decode(MarkdownSourceEdits.apply(DiscussionEdits.splices(for: .newThread(thread), in: document), to: Data(source.utf8), expectedSource: source))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data(source.utf8).write(to: file)
        let reader = ReaderState(); reader.fileURL = file; reader.source = source; reader.render(); try await settle(reader)
        return .init(reader: reader, file: file, source: source)
    }
    private func settle(_ reader: ReaderState) async throws {
        for _ in 0..<300 {
            if !reader.fileSaving && !reader.isRendering { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Discussion action did not settle")
    }
    private func cleanup(_ fixture: Fixture) {
        fixture.reader.discussions.discardDrafts(); fixture.reader.stop()
        try? FileManager.default.removeItem(at: fixture.file)
    }
}

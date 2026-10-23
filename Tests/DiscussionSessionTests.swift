import Foundation
import XCTest
#if MARGINED_DISCUSSION_PROBE
#elseif os(iOS)
@testable import MarginediOS
#else
@testable import Margined
#endif

final class DiscussionSessionTests: XCTestCase {
    @MainActor func testNewDraftCannotMoveToAnEqualPassageAfterItsOriginWasDeleted() throws {
        let old = "Intro\n\nTarget.\n\nMiddle\n\nTarget.\n\nEnd\n"
        let deleted = "Intro\n\nMiddle\n\nTarget.\n\nEnd\n"
        let changed = old + "\nDifferent version.\n"
        func project(_ source: String) throws -> DiscussionTextProjection {
            let html = source.split(separator: "\n").map { "<p>" + $0 + "</p>" }.joined()
            return try DiscussionText.project(html: html, source: source)
        }
        func snapshot(_ source: String) -> SourceFileEdit.Snapshot {
            .init(url: URL(fileURLWithPath: "/Document.md"), data: Data(source.utf8), identity: .init(device: 1, inode: 1))
        }
        let projection = try project(old), session = DiscussionSession()
        session.displayName = "Anand"
        let selected = try XCTUnwrap(projection.selection((projection.text as NSString).range(of: "Target."), renderID: "r1"))
        let key = try session.beginDraft(selected, in: projection)
        session.setDraft("Keep this original quote.", for: key)
        session.acceptProjection(try project(deleted))
        XCTAssertThrowsError(try session.preparePost(in: DiscussionCodec.parse(deleted), snapshot: snapshot(deleted))) {
            XCTAssertEqual($0 as? DiscussionSession.Failure, .passageChanged)
        }
        XCTAssertEqual(session.drafts[key]?.target, selected.target)
        XCTAssertEqual(session.drafts[key]?.body, "Keep this original quote.")
        session.acceptProjection(try project(changed))
        XCTAssertThrowsError(try session.preparePost(in: DiscussionCodec.parse(changed), snapshot: snapshot(changed)))
        session.acceptProjection(projection)
        _ = try session.preparePost(in: DiscussionCodec.parse(old), snapshot: snapshot(old))
    }

    @MainActor func testNewDraftTracksAUniqueMovedPassageAndWritesItsCurrentContexts() throws {
        let old = "Before\n\nTarget.\n\nAfter\n", moved = "Changed intro\n\nTarget.\n\nNew end\n"
        let original = try DiscussionText.project(html: "<p>Before</p><p>Target.</p><p>After</p>", source: old)
        let current = try DiscussionText.project(html: "<p>Changed intro</p><p>Target.</p><p>New end</p>", source: moved)
        let selected = try XCTUnwrap(original.selection((original.text as NSString).range(of: "Target."), renderID: "r"))
        let session = DiscussionSession(); session.displayName = "Anand"
        let key = try session.beginDraft(selected, in: original)
        session.setDraft("This follows the same passage.", for: key)
        session.acceptProjection(current)
        let snapshot = SourceFileEdit.Snapshot(url: URL(fileURLWithPath: "/Document.md"), data: Data(moved.utf8), identity: .init(device: 1, inode: 1))
        let post = try session.preparePost(in: DiscussionCodec.parse(moved), snapshot: snapshot)
        let target = try XCTUnwrap(DiscussionCodec.parse(try MarkdownSource.decode(post.replacement)).threads.first?.target)
        XCTAssertEqual(target.exact, "Target.")
        XCTAssertTrue(target.prefix.contains("Changed intro"))
        XCTAssertTrue(target.suffix.contains("New end"))
    }

    // Switching inspector/thread must not discard unsent text; only a verified save acknowledges it.
    @MainActor func testDraftSurvivesSwitchAndFailureAndRequiresExplicitRetry() throws {
        let session = DiscussionSession(), key = DiscussionSession.DraftKey.new(UUID())
        let target = DiscussionTarget(type: "TextQuoteSelector", exact: "Passage.", prefix: "", suffix: "", section: nil)
        session.displayName = "Anand"
        session.selection = key
        session.setDraft("My reply.", for: key, target: target)
        let data = Data("Passage.\n".utf8)
        let snapshot = SourceFileEdit.Snapshot(url: URL(fileURLWithPath: "/Document.md"), data: data, identity: .init(device: 1, inode: 1))
        let document = try DiscussionCodec.parse("Passage.\n")
        let pending = try session.preparePost(in: document, snapshot: snapshot)
        session.selection = .thread("other"); session.visible = false
        session.failed(pending, error: CocoaError(.fileWriteNoPermission))
        XCTAssertNil(session.pending)
        XCTAssertEqual(session.drafts[key]?.body, "My reply.")
        XCTAssertEqual(session.drafts[key]?.target, target)
        XCTAssertNotNil(session.saveError)
        session.selection = key
        let retry = try session.preparePost(in: document, snapshot: snapshot)
        XCTAssertNotEqual(retry.id, pending.id)
        XCTAssertEqual(try DiscussionCodec.parse(try MarkdownSource.decode(retry.replacement)).threads.first?.messages.first?.author, "Anand")
        let saved = SourceFileEdit.Snapshot(url: snapshot.url, data: retry.replacement, identity: .init(device: 1, inode: 2))
        try session.saved(retry, as: saved)
        XCTAssertFalse(session.hasUnpostedDrafts)
    }

    @MainActor func testFirstPostNeedsNameAndSnapshotAndCannotClearNewerTyping() throws {
        let session = DiscussionSession(), key = DiscussionSession.DraftKey.new(UUID())
        session.selection = key
        session.setDraft("First.", for: key, target: DiscussionTarget(type: "TextQuoteSelector", exact: "body", prefix: "", suffix: "", section: nil))
        let document = try DiscussionCodec.parse("body")
        let snapshot = SourceFileEdit.Snapshot(url: URL(fileURLWithPath: "/Document.md"), data: Data("body".utf8), identity: .init(device: 1, inode: 1))
        XCTAssertThrowsError(try session.preparePost(in: document, snapshot: snapshot)) { XCTAssertEqual($0 as? DiscussionSession.Failure, .displayNameRequired) }
        session.displayName = "  Zoë 日本  "
        XCTAssertThrowsError(try session.preparePost(in: document, snapshot: nil)) { XCTAssertEqual($0 as? DiscussionSession.Failure, .savedCopyRequired) }
        let pending = try session.preparePost(in: document, snapshot: snapshot)
        let posted = try DiscussionCodec.parse(try MarkdownSource.decode(pending.replacement))
        XCTAssertEqual(posted.threads.first?.messages.first?.author, "Zoë 日本")
        session.setDraft("Another thought typed during save.", for: key)
        let saved = SourceFileEdit.Snapshot(url: snapshot.url, data: pending.replacement, identity: .init(device: 1, inode: 2))
        try session.saved(pending, as: saved)
        XCTAssertEqual(session.drafts[key]?.body, "Another thought typed during save.")
        XCTAssertTrue(session.hasUnpostedDrafts)
    }
    @MainActor func testUndoIsConditionalAndKeepsDraftsWhileRestoringOnlyTheSavedVersion() throws {
        let session = DiscussionSession(), key = DiscussionSession.DraftKey.new(UUID())
        session.displayName = "Anand"; session.selection = key
        session.setDraft("A saved note.", for: key, target: DiscussionTarget(type: "TextQuoteSelector", exact: "body", prefix: "", suffix: "", section: nil))
        let baseline = SourceFileEdit.Snapshot(url: URL(fileURLWithPath: "/Document.md"), data: Data("body".utf8), identity: .init(device: 1, inode: 1))
        let post = try session.preparePost(in: DiscussionCodec.parse("body"), snapshot: baseline)
        let saved = SourceFileEdit.Snapshot(url: baseline.url, data: post.replacement, identity: .init(device: 1, inode: 2))
        try session.saved(post, as: saved)
        session.setDraft("Unposted reply.", for: .thread(post.threadID))
        let replaced = SourceFileEdit.Snapshot(url: saved.url, data: saved.data, identity: .init(device: 1, inode: 3))
        XCTAssertThrowsError(try session.prepareUndo(snapshot: replaced))
        let undo = try session.prepareUndo(snapshot: saved)
        XCTAssertEqual(undo.replacement, baseline.data)
        let restored = SourceFileEdit.Snapshot(url: saved.url, data: baseline.data, identity: .init(device: 1, inode: 4))
        try session.saved(undo, as: restored)
        XCTAssertEqual(session.drafts[.thread(post.threadID)]?.body, "Unposted reply.")
    }

    @MainActor func testReplyToResolvedThreadRequiresConfirmationAndKeepsRecordedAuthors() throws {
        let source = """
        body

        <!-- margined:thread v1
        id: t1
        state: resolved
        resolved-by: Original
        resolved: "2026-10-23T10:00:00Z"
        target: {type: TextQuoteSelector, exact: body, prefix: '', suffix: ''}
        messages:
          - id: m1
            author: Original
            created: "2026-10-23T09:00:00Z"
            body: First note.
        -->
        """
        let session = DiscussionSession(), key = DiscussionSession.DraftKey.thread("t1")
        session.displayName = "Zoë"; session.selection = key
        session.setDraft("A response.", for: key, inReplyTo: "m1")
        let snapshot = SourceFileEdit.Snapshot(url: URL(fileURLWithPath: "/Document.md"), data: Data(source.utf8), identity: .init(device: 1, inode: 1))
        let document = try DiscussionCodec.parse(source)
        XCTAssertThrowsError(try session.preparePost(in: document, snapshot: snapshot)) { XCTAssertEqual($0 as? DiscussionSession.Failure, .reopenRequired) }
        XCTAssertEqual(session.drafts[key]?.body, "A response.")
        let post = try session.preparePost(in: document, snapshot: snapshot, reopenResolved: true)
        let result = try DiscussionCodec.parse(try MarkdownSource.decode(post.replacement))
        XCTAssertEqual(result.threads.first?.state, .open)
        XCTAssertEqual(result.threads.first?.messages.map(\.author), ["Original", "Zoë"])
        XCTAssertEqual(result.threads.first?.messages.last?.inReplyTo, "m1")
        XCTAssertNil(result.threads.first?.resolvedBy)
    }

    @MainActor func testResolveWithDraftRequiresExplicitChoiceAndDiscardsOnlyAfterSave() throws {
        let session = DiscussionSession(), key = DiscussionSession.DraftKey.new(UUID())
        session.displayName = "Anand"; session.selection = key
        session.setDraft("First note.", for: key, target: DiscussionTarget(type: "TextQuoteSelector", exact: "body", prefix: "", suffix: "", section: nil))
        let baseline = SourceFileEdit.Snapshot(url: URL(fileURLWithPath: "/Document.md"), data: Data("body".utf8), identity: .init(device: 1, inode: 1))
        let first = try session.preparePost(in: DiscussionCodec.parse("body"), snapshot: baseline)
        let snapshot = SourceFileEdit.Snapshot(url: baseline.url, data: first.replacement, identity: .init(device: 1, inode: 2))
        try session.saved(first, as: snapshot)
        let replyKey = DiscussionSession.DraftKey.thread(first.threadID)
        session.setDraft("Unposted reply.", for: replyKey)
        let document = try DiscussionCodec.parse(try snapshot.source)
        XCTAssertNil(try session.prepareResolve(threadID: first.threadID, in: document, snapshot: snapshot, choice: .keepOpen))
        XCTAssertEqual(session.drafts[replyKey]?.body, "Unposted reply.")
        let discard = try XCTUnwrap(session.prepareResolve(threadID: first.threadID, in: document, snapshot: snapshot, choice: .discardDraft))
        XCTAssertEqual(session.drafts[replyKey]?.body, "Unposted reply.", "Preparation cannot discard text before a verified save")
        XCTAssertEqual(try DiscussionCodec.parse(try MarkdownSource.decode(discard.replacement)).threads.first?.messages.count, 1)
        session.failed(discard, error: CocoaError(.fileWriteNoPermission))
        let post = try XCTUnwrap(session.prepareResolve(threadID: first.threadID, in: document, snapshot: snapshot, choice: .postDraft))
        let posted = try DiscussionCodec.parse(try MarkdownSource.decode(post.replacement))
        XCTAssertEqual(posted.threads.first?.state, .resolved)
        XCTAssertEqual(posted.threads.first?.messages.last?.body, "Unposted reply.")
        let saved = SourceFileEdit.Snapshot(url: baseline.url, data: post.replacement, identity: .init(device: 1, inode: 3))
        try session.saved(post, as: saved)
        XCTAssertFalse(session.hasUnpostedDrafts)
    }

    @MainActor func testRetryAfterUncertainSaveCannotDuplicateTheAlreadyPostedMessage() throws {
        let session = DiscussionSession(), key = DiscussionSession.DraftKey.new(UUID())
        session.displayName = "Anand"; session.selection = key
        session.setDraft("One note only.", for: key, target: DiscussionTarget(type: "TextQuoteSelector", exact: "body", prefix: "", suffix: "", section: nil))
        let baseline = SourceFileEdit.Snapshot(url: URL(fileURLWithPath: "/Document.md"), data: Data("body".utf8), identity: .init(device: 1, inode: 1))
        let post = try session.preparePost(in: DiscussionCodec.parse("body"), snapshot: baseline)
        session.failed(post, error: SourceFileEdit.Failure.uncertain(recovery: URL(fileURLWithPath: "/Recovery.md"), underlying: CocoaError(.fileReadUnknown)))
        let reloaded = SourceFileEdit.Snapshot(url: baseline.url, data: post.replacement, identity: .init(device: 1, inode: 2))
        let document = try DiscussionCodec.parse(try reloaded.source)
        XCTAssertThrowsError(try session.preparePost(in: document, snapshot: reloaded)) { XCTAssertEqual($0 as? DiscussionSession.Failure, .alreadySaved) }
        XCTAssertEqual(session.drafts[key]?.body, "One note only.", "An uncertain save never silently drops the draft")
    }

}

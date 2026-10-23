import Foundation
import AppKit
import XCTest
@testable import Margined

@MainActor final class DiscussionStateTests: XCTestCase {
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

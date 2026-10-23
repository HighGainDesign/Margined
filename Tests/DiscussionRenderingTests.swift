import Foundation
import SwiftSoup
import XCTest
#if os(iOS)
@testable import MarginediOS
#else
@testable import Margined
#endif

final class DiscussionRenderingTests: XCTestCase {
    func testNotesAreSeparateFromProseSpeechCountAndReview() async throws {
        let source = "# Plan\n\nRead this paragraph.\n\n- [ ] Complete the task.\n"
        let target = DiscussionTarget(type: "TextQuoteSelector", exact: "Read this paragraph.", prefix: "Plan", suffix: "Complete the task.", section: "Plan")
        let message = DiscussionMessage(id: "m1", author: "Reviewer", created: "2026-10-23T10:00:00Z", body: "First hidden conversation.", inReplyTo: nil)
        let thread = DiscussionThread(id: "t1", state: .open, target: target, messages: [message], resolvedBy: nil, resolved: nil, attachmentHistory: [])
        let edits = try DiscussionEdits.splices(for: .newThread(thread), in: DiscussionCodec.parse(source))
        var bytes = Array(source.utf8)
        for edit in edits.reversed() { bytes.replaceSubrange(edit.range, with: edit.replacement.utf8) }
        let annotated = String(decoding: bytes, as: UTF8.self)
        let plain = try await MarkdownRenderer.shared.render(source, mapTasks: true, prepareSpeech: true)
        let before = try await MarkdownRenderer.shared.render(annotated, mapTasks: true, prepareSpeech: true)
        let updated = annotated.replacingOccurrences(of: "First hidden conversation.", with: "New reply content with more words and a [link](https://example.com).")
        let after = try await MarkdownRenderer.shared.render(updated, baseline: annotated, mapTasks: true, prepareSpeech: true, previousDiscussions: before.discussions)
        XCTAssertEqual(before.wordCount, plain.wordCount)
        XCTAssertEqual(after.wordCount, before.wordCount)
        XCTAssertEqual(after.html, before.html)
        XCTAssertEqual(before.html, plain.html)
        XCTAssertEqual(after.speech?.fingerprint, before.speech?.fingerprint)
        XCTAssertEqual(before.speech?.fingerprint, plain.speech?.fingerprint)
        XCTAssertEqual(after.speech?.segments, before.speech?.segments)
        XCTAssertEqual(after.changes.count, 0)
        XCTAssertEqual(after.discussionActivity.updatedThreads, 1)
        XCTAssertEqual(DiscussionActivity.compare(current: try XCTUnwrap(after.discussions), previous: before.discussions).updatedThreads, 1)
        XCTAssertFalse(DiscussionActivity.compare(current: try XCTUnwrap(before.discussions), previous: nil).hasChanges)
        XCTAssertEqual(after.tasks, before.tasks)
        XCTAssertEqual(after.taskSource, updated)
        let notes = try XCTUnwrap(after.discussions)
        XCTAssertEqual(notes.threads.first?.messages.first?.body, "New reply content with more words and a [link](https://example.com).")
        XCTAssertEqual(after.discussionText?.text, "Plan Read this paragraph. Complete the task.")
        XCTAssertFalse(after.html.contains("margined:thread"))
    }

    func testCodeExamplesRemainVisibleAndMalformedNotesKeepLocatedWarnings() async throws {
        let code = "```md\n<!-- margined:thread v1\nexample only\n-->\n```"
        let source = code + "\n\n<!-- margined:thread v9\nfuture data\n-->\n\nAfter."
        let rendered = try await MarkdownRenderer.shared.render(source)
        XCTAssertEqual(rendered.discussions?.blocks.count, 1)
        XCTAssertFalse(rendered.discussions?.diagnostics.isEmpty ?? true)
        XCTAssertTrue(try SwiftSoup.parse(rendered.html).select("pre code").text().contains("margined:thread v1"))
        XCTAssertFalse(rendered.discussionText?.text.contains("future data") ?? true)
        XCTAssertTrue(rendered.discussionText?.text.contains("example only") == true)
    }
    func testUncertainInlineWrapperDoesNotReinterpretFollowingTextAsCode() async throws {
        let source = "Before.\n\n<!-- margined:thread v1 -->After."
        let rendered = try await MarkdownRenderer.shared.render(source)
        let document = try SwiftSoup.parse(rendered.html)
        XCTAssertEqual(try document.select("pre").size(), 0)
        XCTAssertTrue(try document.body()?.text().contains("After.") == true)
        XCTAssertEqual(rendered.discussions?.blocks.first?.hasCertainExtent, false)
    }

}

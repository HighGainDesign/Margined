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

    func testOptionalAppendixDoesNotChangeProseSpeechWordCountReviewOrEditableTasks() async throws {
        let prose = "# Plan\n\nRead this paragraph.\n\n- [ ] Complete the task.\n\n## appendix-discussion-title-t-appendix\n"
        let thread = DiscussionThread(id: "t-appendix", state: .open,
            target: .init(type: "TextQuoteSelector", exact: "Read this paragraph.", prefix: "Plan", suffix: "Complete the task.", section: "Plan"),
            messages: [.init(id: "m-appendix", author: "Reviewer", created: "2026-10-24T10:00:00Z",
                             body: "A saved **comment**.\n\n- [ ] Read-only comment task\n\n## Note details\n\n[Back to note details](#note-details)", inReplyTo: nil)],
            resolvedBy: nil, resolved: nil, attachmentHistory: [])
        let bytes = try MarkdownSourceEdits.apply(DiscussionEdits.splices(for: .newThread(thread), in: DiscussionCodec.parse(prose)),
                                                 to: Data(prose.utf8), expectedSource: prose)
        let source = try MarkdownSource.decode(bytes)
        let ordinary = try await MarkdownRenderer.shared.render(source, mapTasks: true, prepareSpeech: true)
        let included = try await MarkdownRenderer.shared.render(source, baseline: source, mapTasks: true, prepareSpeech: true,
                                                               includeDiscussionAppendix: true)
        let doc = try SwiftSoup.parse(included.html)
        XCTAssertEqual(try doc.select("section.discussion-appendix").size(), 1)
        guard try doc.select("section.discussion-appendix").size() == 1 else { return }
        XCTAssertEqual(try SwiftSoup.parse(ordinary.html).select("section.discussion-appendix").size(), 0)
        XCTAssertEqual(included.wordCount, ordinary.wordCount)
        XCTAssertEqual(included.headings, ordinary.headings)
        XCTAssertEqual(included.speech?.fingerprint, ordinary.speech?.fingerprint)
        XCTAssertEqual(included.speech?.segments, ordinary.speech?.segments)
        XCTAssertEqual(included.discussionText?.text, ordinary.discussionText?.text)
        XCTAssertEqual(included.tasks, ordinary.tasks)
        XCTAssertEqual(included.tasks.count, 1)
        XCTAssertEqual(included.checkboxCount, ordinary.checkboxCount)
        XCTAssertEqual(included.taskSource, source)
        XCTAssertEqual(included.changes.count, 0)
        XCTAssertEqual(try doc.select("section.discussion-appendix [data-margined-task],section.discussion-appendix [data-margined-speech]").size(), 0)
        XCTAssertEqual(try doc.select("section.discussion-appendix input[type=checkbox][disabled]").size(), 1)
        let ids = try doc.select("[id]").array().map { try $0.attr("id") }
        XCTAssertEqual(Set(ids).count, ids.count, "Appended metadata and message headings must not collide with prose IDs")
        let appendix = try XCTUnwrap(doc.select("section.discussion-appendix").first())
        let localIDs = Set(try appendix.select("[id]").array().map { try $0.attr("id") })
        let link = try appendix.select(".discussion-message-body a").attr("href")
        XCTAssertTrue(link.hasPrefix("#"))
        XCTAssertTrue(localIDs.contains(String(link.dropFirst())), "A local note link must still target its own message")
        for element in try appendix.select("[aria-labelledby]").array() {
            for id in try element.attr("aria-labelledby").split(separator: " ") {
                XCTAssertTrue(localIDs.contains(String(id)), "Metadata accessibility labels must target the appended history")
            }
        }
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


    func testConversationRendersRichBodiesWithTheDocumentsReadOnlyResourcePolicy() async throws {
        let body = """
        | Task | State |
        | --- | --- |
        | Review | Ready |

        Inline math: $x^2$.

        ```mermaid
        flowchart LR
          A[Read] --> B[Reply]
        ```

        ![Local](images/chart.png)

        ![Remote](https://example.com/tracker.png)

        - [ ] A task inside a comment.
        """
        let rendered = try await MarkdownRenderer.shared.renderDiscussion(conversation(body))
        let document = try SwiftSoup.parse(rendered.html)
        let available = try document.select("article[data-message-id=m-first]").size() == 1
        XCTAssertTrue(available, "A conversation must render its saved message bodies, not an empty placeholder")
        guard available else { return }
        XCTAssertEqual(try document.select("table tbody td").text(), "Review Ready")
        XCTAssertEqual(try document.select("span.margined-math math").size(), 1)
        XCTAssertEqual(try document.select("figure.margined-diagram img[src^='data:image/svg+xml;base64,']").size(), 1)
        XCTAssertEqual(try document.select("img[alt=Local]").attr("src"), "margined-resource://local/images%2Fchart%2Epng")
        XCTAssertFalse(try document.select("img[alt=Remote]").hasAttr("src"))
        XCTAssertEqual(try document.select("input[type=checkbox]:not([disabled])").size(), 0)
        XCTAssertTrue(rendered.tasks.isEmpty)
        XCTAssertNil(rendered.discussions)
        XCTAssertNil(rendered.discussionText)
        let allowed = try await MarkdownRenderer.shared.renderDiscussion(conversation(body), loadRemoteImages: true)
        let remote = try SwiftSoup.parse(allowed.html).select("img[alt=Remote]")
        XCTAssertEqual(try remote.attr("src"), "https://example.com/tracker.png")
        XCTAssertEqual(try remote.attr("referrerpolicy"), "no-referrer")
    }

    func testConversationEscapesMetadataAndSeparatesEachMessagesMarkdownBoundary() async throws {
        let author = #"<img src=x onerror="alert(1)"> **Alex**"#
        let thread = conversation("```swift\nAn unfinished code fence.", second: "**A formatted reply.**", firstAuthor: author)
        let rendered = try await MarkdownRenderer.shared.renderDiscussion(thread,
            locale: Locale(identifier: "en_US"), timeZone: TimeZone(secondsFromGMT: 0)!)
        let document = try SwiftSoup.parse(rendered.html)
        let available = try document.select("article").size() == 2
        XCTAssertTrue(available, "Each saved message must retain an independent body and literal metadata")
        guard available else { return }
        let first = try document.select("article[data-message-id=m-first]")
        let second = try document.select("article[data-message-id=m-second]")
        XCTAssertTrue(try first.select("header").text().contains(author))
        XCTAssertEqual(try document.select("header img, script, [onerror], iframe").size(), 0)
        XCTAssertEqual(try first.select("pre code").text(), "An unfinished code fence.")
        XCTAssertEqual(try second.select("strong").text(), "A formatted reply.")
        XCTAssertEqual(try first.select("time").attr("datetime"), "2026-10-23T10:00:00Z")
        XCTAssertTrue(try first.select("time").text().contains("2026"))
        XCTAssertNotEqual(try first.select("time").text(), "2026-10-23T10:00:00Z")
        XCTAssertTrue(try second.select("header a").text().contains(author))
        let replyTarget = try second.select("header a").attr("href")
        XCTAssertTrue(replyTarget.hasPrefix("#"))
        XCTAssertEqual(try first.attr("id"), String(replyTarget.dropFirst()))
    }

    func testConversationDoesNotRecursivelyParseExamplesAndKeepsBodyLinksLocal() async throws {
        let example = """
        ## Same heading

        [Within this message](#same-heading)

        ```md
        <!-- margined:thread v1
        id: t-example
        state: open
        target:
          type: TextQuoteSelector
          exact: "Example only."
          prefix: ""
          suffix: ""
        messages:
          - id: m-example
            author: "Example Author"
            created: "2026-10-23T10:00:00Z"
            body: |
              A code example, not another conversation.
        -->
        ```
        """
        let rendered = try await MarkdownRenderer.shared.renderDiscussion(conversation(example, second: "## Same heading\n\n[Another local link](#same-heading)"))
        let document = try SwiftSoup.parse(rendered.html)
        let available = try document.select("article").size() == 2
        XCTAssertTrue(available, "Discussion example syntax must remain inside its original message")
        guard available else { return }
        XCTAssertNil(rendered.discussions)
        XCTAssertNil(rendered.discussionText)
        XCTAssertTrue(try document.select("pre code").text().contains("margined:thread v1"))
        var headingIDs = Set<String>()
        for article in try document.select("article").array() {
            let heading = try article.select("h2").attr("id")
            XCTAssertFalse(heading.isEmpty)
            XCTAssertTrue(headingIDs.insert(heading).inserted, "Equal headings in separate messages must not duplicate DOM destinations")
            let links = try article.select("a").array()
            XCTAssertEqual(try links.last?.attr("href"), "#" + heading)
        }
    }

    func testExplicitConversationSpeechIncludesAuthorsRepliesAndFormattedBody() async throws {
        let thread = conversation("Read this comment.", second: "**Only this reply.**")
        let rendered = try await MarkdownRenderer.shared.renderDiscussion(thread,
            documentLanguage: "en", prepareSpeech: true)
        let available = rendered.speech?.segments.isEmpty == false
        XCTAssertTrue(available, "Explicit conversation playback must have its own semantic speech content")
        guard available, let speech = rendered.speech else { return }
        let text = speech.segments.map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains("Alex"))
        XCTAssertTrue(text.contains("Sam"))
        XCTAssertTrue(text.contains("Read this comment."))
        XCTAssertTrue(text.contains("Only this reply."))
        XCTAssertFalse(text.contains("m-first"))
        XCTAssertFalse(text.contains("m-second"))
        XCTAssertFalse(text.contains("**"))
        XCTAssertNil(rendered.discussions)
        XCTAssertTrue(rendered.tasks.isEmpty)
    }

    func testNativeHistoryCanOmitContextWhileFullTranscriptsKeepIt() async throws {
        let thread = conversation("**A saved message.**")
        let history = try await MarkdownRenderer.shared.renderDiscussion(thread, includeContext: false)
        let document = try SwiftSoup.parse(history.html)
        let quoteCount = try document.select("main > blockquote").size()
        XCTAssertEqual(quoteCount, 0, "The native thread already displays its quote and state outside the history")
        guard quoteCount == 0 else { return }
        XCTAssertEqual(try document.select("main > h1").size(), 0)
        XCTAssertEqual(try document.select("article header h3").text(), "Alex")
        XCTAssertEqual(try document.select("article strong").text(), "A saved message.")
        let full = try await MarkdownRenderer.shared.renderDiscussion(thread)
        XCTAssertEqual(try SwiftSoup.parse(full.html).select("main > blockquote").text(), "Review this sentence.")
    }

    private func conversation(_ body: String, second: String? = nil, firstAuthor: String = "Alex") -> DiscussionThread {
        var messages = [DiscussionMessage(id: "m-first", author: firstAuthor, created: "2026-10-23T10:00:00Z", body: body, inReplyTo: nil)]
        if let second {
            messages.append(.init(id: "m-second", author: "Sam", created: "2026-10-23T10:30:00Z", body: second, inReplyTo: "m-first"))
        }
        return DiscussionThread(id: "t-conversation", state: .open,
            target: .init(type: "TextQuoteSelector", exact: "Review this sentence.", prefix: "", suffix: "", section: nil),
            messages: messages, resolvedBy: nil, resolved: nil, attachmentHistory: [])
    }

}

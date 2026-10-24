import Foundation
import XCTest
#if MARGINED_DISCUSSION_PROBE
#elseif os(iOS)
@testable import MarginediOS
#else
@testable import Margined
#endif

final class DiscussionCodecTests: XCTestCase {
    // Dropping blocks, authors or reply order must fail this approved-format fixture.
    func testApprovedSamplePreservesIndependentThreadsAndReplies() throws {
        let parsed = try DiscussionCodec.parse(Self.sample)
        XCTAssertEqual(parsed.threads.count, 4)
        XCTAssertTrue(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
        XCTAssertEqual(parsed.threads.flatMap(\.messages).count, 8)
        XCTAssertEqual(Set(parsed.threads.flatMap(\.messages).map(\.author)), ["Craig", "Codex", "Anand"])
        guard parsed.threads.count == 4 else { return }
        XCTAssertEqual(parsed.threads[0].target, parsed.threads[1].target)
        XCTAssertEqual(parsed.threads[0].messages[2].inReplyTo, "reading-codex-1")
        XCTAssertEqual(parsed.threads[2].state, .resolved)
        XCTAssertEqual(parsed.threads[2].resolvedBy, "Anand")
        XCTAssertEqual(parsed.threads[3].target.exact, "Automatically send every note to a server.")
        XCTAssertTrue(parsed.blocks.allSatisfy(\.hasCertainExtent))
        XCTAssertEqual(parsed.source, Self.sample)
    }

    private static let note = """
    <!-- margined:thread v1
    id: t1
    state: open
    target:
      type: TextQuoteSelector
      exact: "A passage."
      prefix: ""
      suffix: ""
    messages:
      - id: m1
        author: "Zoë 日本"
        created: "2026-10-23T10:00:00Z"
        body: |
          A **reply**.
    -->
    """

    func testOnlyActualTopLevelCommentsBecomeThreads() throws {
        let note = Self.note
        let examples = [
            "```md\n\(note)\n```", "~~~\n\(note)\n~~~",
            note.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n"),
            note.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n"),
            "`<!-- margined:thread v1 -->`", "Text <!-- margined:thread v1 -->",
            "$$\n\(note)\n$$", "$`<!-- margined:thread v1 -->`$",
            "---\nexample: |\n" + note.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n") + "\n---\n# Prose",
            "<div>\n\(note)\n</div>"
        ]
        for example in examples {
            let parsed = try DiscussionCodec.parse(example)
            XCTAssertTrue(parsed.blocks.isEmpty, "Example became editable: \(example)")
        }
        let real = try DiscussionCodec.parse("# Read\n\n<!-- ordinary -->\n\n" + note + "\n\nAfter.\n")
        XCTAssertEqual(real.threads.map(\.id), ["t1"])
    }

    func testBlockRangesPreserveUnicodeAndCRLFSource() throws {
        let note = Self.note.replacingOccurrences(of: "\n", with: "\r\n")
        let source = "# 🐈 café\r\n\r\n" + note + "\r\n\r\nUnrelated."
        let parsed = try DiscussionCodec.parse(source)
        let block = try XCTUnwrap(parsed.blocks.first)
        XCTAssertEqual(block.line, 3)
        XCTAssertEqual(String(decoding: Array(source.utf8)[block.range], as: UTF8.self), note)
        XCTAssertEqual(block.thread?.messages.first?.author, "Zoë 日本")
        XCTAssertEqual(block.thread?.messages.first?.body, "A **reply**.\n")
        XCTAssertEqual(parsed.source, source)
    }

    func testInvalidAndFutureBlocksRetainIndependentWrapperCertainty() throws {
        for note in [Self.note.replacingOccurrences(of: "v1\n", with: "v9\n"), Self.note.replacingOccurrences(of: "state: open", with: "state: [unterminated")] {
            let parsed = try DiscussionCodec.parse(note)
            XCTAssertTrue(parsed.threads.isEmpty)
            XCTAssertEqual(parsed.blocks.count, 1)
            XCTAssertEqual(parsed.blocks.first?.hasCertainExtent, true)
            XCTAssertFalse(parsed.diagnostics.isEmpty)
            XCTAssertTrue(parsed.diagnostics.allSatisfy { $0.line > 0 && $0.column > 0 })
        }
        let unterminated = String(Self.note.dropLast(3))
        let parsed = try DiscussionCodec.parse(unterminated)
        XCTAssertEqual(parsed.blocks.first?.hasCertainExtent, false)
        XCTAssertTrue(parsed.threads.isEmpty)
        XCTAssertFalse(parsed.diagnostics.isEmpty)
    }

    func testRestrictedYAMLRejectsReferencesDuplicateKeysAndExtraDocuments() throws {
        let changes = [
            ("id: t1", "id: t1\nid: other"),
            ("author: \"Zoë 日本\"", "author: &name Person"),
            ("author: \"Zoë 日本\"", "author: *name"),
            ("author: \"Zoë 日本\"", "author: !application Person"),
            ("author: \"Zoë 日本\"", "author: !!int 42"),
            ("state: open", "state: yes"),
            ("id: t1", "id: 'has space'"),
            ("created: \"2026-10-23T10:00:00Z\"", "created: 2026-10-23T10:00:00Z"),
            ("created: \"2026-10-23T10:00:00Z\"", "created: \"2026-99-99T10:00:00Z\""),
            ("body: |", "in-reply-to: later\n    body: |"),
            ("-->" , "---\nextra: document\n-->")
        ]
        for (old, new) in changes {
            let note = Self.note.replacingOccurrences(of: old, with: new)
            let parsed = try DiscussionCodec.parse(note)
            XCTAssertTrue(parsed.threads.isEmpty, "Accepted invalid \(new)")
            XCTAssertFalse(parsed.diagnostics.isEmpty, "Missing warning for \(new)")
            XCTAssertEqual(parsed.source, note)
        }
    }

    func testFileWideDuplicateIDsDisableAffectedThreadsOnly() throws {
        let second = Self.note.replacingOccurrences(of: "id: t1", with: "id: t2")
        let third = second.replacingOccurrences(of: "id: t2", with: "id: t3").replacingOccurrences(of: "id: m1", with: "id: m3")
        let parsed = try DiscussionCodec.parse(Self.note + "\n\n" + second + "\n\n" + third)
        XCTAssertEqual(parsed.threads.map(\.id), ["t3"])
        XCTAssertGreaterThanOrEqual(parsed.diagnostics.count, 2)
        XCTAssertEqual(parsed.blocks.count, 3)
        let duplicateThread = try DiscussionCodec.parse(Self.note + "\n\n" + Self.note.replacingOccurrences(of: "id: m1", with: "id: m2"))
        XCTAssertTrue(duplicateThread.threads.isEmpty)
    }

    func testHistoryAndLongImportedContextRemainReadable() throws {
        let history = """
        attachment-history:
          - target: {type: TextQuoteSelector, exact: Before, prefix: '', suffix: ''}
            author: Reviewer
            created: '2026-10-22T01:02:03.123+05:30'
        """
        let note = Self.note.replacingOccurrences(of: "prefix: \"\"", with: "prefix: '" + String(repeating: "a", count: 100) + "'")
            .replacingOccurrences(of: "messages:", with: history + "\nmessages:")
        let parsed = try DiscussionCodec.parse(note)
        let thread = try XCTUnwrap(parsed.threads.first)
        XCTAssertEqual(thread.target.prefix.count, 100)
        XCTAssertEqual(thread.attachmentHistory.first?.target.exact, "Before")
        XCTAssertEqual(thread.attachmentHistory.first?.created, "2026-10-22T01:02:03.123+05:30")
    }

    func testParserBoundsNestedAndEventHeavyInputWithoutDroppingRawSource() throws {
        for extra in ["extra: " + String(repeating: "[", count: 70) + "value" + String(repeating: "]", count: 70),
                      "extra: [" + Array(repeating: "a", count: 200_001).joined(separator: ",") + "]"] {
            let note = Self.note.replacingOccurrences(of: "messages:", with: extra + "\nmessages:")
            let parsed = try DiscussionCodec.parse(note)
            XCTAssertTrue(parsed.threads.isEmpty)
            XCTAssertFalse(parsed.diagnostics.isEmpty)
            XCTAssertEqual(parsed.source, note)
        }
    }

    private func applying(_ operation: DiscussionOperation, to source: String) throws -> String {
        let document = try DiscussionCodec.parse(source)
        let splices = try DiscussionEdits.splices(for: operation, in: document)
        var bytes = Array(source.utf8)
        for splice in splices.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            bytes.replaceSubrange(splice.range, with: splice.replacement.utf8)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private let newReply = DiscussionMessage(id: "m2", author: "Anand", created: "2026-10-23T11:00:00Z", body: "New **reply**.\n", inReplyTo: "m1")

    func testReplyAppendsWithoutRewritingExistingFieldsOrProse() throws {
        let note = Self.note.replacingOccurrences(of: "messages:", with: "future: {keep: 'exact spacing'}\nmessages:")
        let source = "# Prose 🐈\n\n" + note + "\n\n<!-- ordinary -->\nAfter."
        let changed = try applying(.reply(threadID: "t1", message: newReply, reopenResolved: false), to: source)
        let parsed = try DiscussionCodec.parse(changed)
        XCTAssertEqual(parsed.threads.first?.messages.map(\.id), ["m1", "m2"])
        XCTAssertEqual(parsed.threads.first?.messages.last, newReply)
        XCTAssertTrue(changed.hasPrefix(String(source.prefix(upTo: source.range(of: "\n-->")!.lowerBound))))
        XCTAssertTrue(changed.hasSuffix("\n-->\n\n<!-- ordinary -->\nAfter."))
        XCTAssertTrue(changed.contains("future: {keep: 'exact spacing'}"))
    }

    func testResolveAndReopenKeepMessagesAndUnknownFields() throws {
        let source = Self.note.replacingOccurrences(of: "state: open", with: "future: keep\nstate: open")
        let resolved = try applying(.resolve(threadID: "t1", author: "Anand", created: "2026-10-23T11:00:00Z"), to: source)
        let thread = try XCTUnwrap(DiscussionCodec.parse(resolved).threads.first)
        XCTAssertEqual(thread.state, .resolved)
        XCTAssertEqual(thread.resolvedBy, "Anand")
        XCTAssertEqual(thread.resolved, "2026-10-23T11:00:00Z")
        let reopened = try applying(.reopen(threadID: "t1"), to: resolved)
        let reopenedThread = try XCTUnwrap(DiscussionCodec.parse(reopened).threads.first)
        XCTAssertEqual(reopenedThread.state, .open)
        XCTAssertNil(reopenedThread.resolvedBy)
        XCTAssertNil(reopenedThread.resolved)
        XCTAssertEqual(reopenedThread.messages, thread.messages)
        XCTAssertTrue(reopened.contains("future: keep\nstate: open"))
    }

    func testReplyToResolvedThreadRequiresExplicitReopenAndOneEditSet() throws {
        let source = try applying(.resolve(threadID: "t1", author: "A", created: "2026-10-23T11:00:00Z"), to: Self.note)
        XCTAssertThrowsError(try applying(.reply(threadID: "t1", message: newReply, reopenResolved: false), to: source))
        let changed = try applying(.reply(threadID: "t1", message: newReply, reopenResolved: true), to: source)
        let thread = try XCTUnwrap(DiscussionCodec.parse(changed).threads.first)
        XCTAssertEqual(thread.state, .open)
        XCTAssertEqual(thread.messages.count, 2)
        XCTAssertNil(thread.resolved)
    }

    func testReattachmentRetainsOldQuoteAndPriorHistory() throws {
        let target = DiscussionTarget(type: "TextQuoteSelector", exact: "New passage", prefix: "Before", suffix: "After", section: "Chapter")
        let changed = try applying(.reattach(threadID: "t1", target: target, author: "A", created: "2026-10-23T11:00:00Z"), to: Self.note)
        let thread = try XCTUnwrap(DiscussionCodec.parse(changed).threads.first)
        XCTAssertEqual(thread.target, target)
        XCTAssertEqual(thread.attachmentHistory.first?.target.exact, "A passage.")
        XCTAssertEqual(thread.attachmentHistory.first?.author, "A")
        let twice = try applying(.reattach(threadID: "t1", target: target, author: "B", created: "2026-10-23T12:00:00Z"), to: changed)
        XCTAssertEqual(try DiscussionCodec.parse(twice).threads.first?.attachmentHistory.map(\.author), ["A", "B"])
    }

    func testReattachmentHistoryPreservesUnknownTargetScalarTypes() throws {
        let source = """
        Original. Replacement.

        <!-- margined:thread v1
        id: t1
        state: open
        target: {type: TextQuoteSelector, exact: Original., prefix: "", suffix: Replacement., opaque: {flag: true, quoted: "true", empty: }}
        messages:
          - id: m1
            author: Original
            created: "2026-10-23T10:00:00Z"
            body: Note.
        -->
        """
        let document = try DiscussionCodec.parse(source)
        let target = DiscussionTarget(type: "TextQuoteSelector", exact: "Replacement.", prefix: "Original.", suffix: "", section: nil)
        let edits = try DiscussionEdits.splices(for: .reattach(threadID: "t1", target: target, author: "Reviewer", created: "2026-10-23T11:00:00Z"), in: document)
        let data = try MarkdownSourceEdits.apply(edits, to: Data(source.utf8), expectedSource: source)
        let updated = try DiscussionCodec.parse(MarkdownSource.decode(data))
        let history = try XCTUnwrap(updated.blocks.first?.syntax?["attachment-history"]?.items?.first?["target"]?["opaque"])
        if case .scalar(_, .plain)? = history["flag"]?.value {} else { XCTFail("History changed a boolean into a string") }
        if case .scalar(_, .doubleQuoted)? = history["quoted"]?.value {} else { XCTFail("History lost a quoted string's type") }
        if case .scalar(_, .plain)? = history["empty"]?.value {} else { XCTFail("History changed null into an empty string") }
        XCTAssertEqual(updated.threads.first?.attachmentHistory.first?.target.exact, "Original.")
        XCTAssertEqual(updated.threads.first?.target.exact, "Replacement.")
        XCTAssertEqual(updated.threads.first?.messages.first?.body, "Note.")
    }

    func testNewBlockRoundTripsLiteralDelimitersUnicodeAndTrailingNewlines() throws {
        for body in ["Plain **Markdown**.\n", "No trailing newline", "Two\n\n", "<!-- literal -->\n--!>\n🐈\n", "Tabs\tand \"quotes\"\n\\escape\n"] {
            let message = DiscussionMessage(id: "m-new", author: "A --> B", created: "2026-10-23T11:00:00Z", body: body, inReplyTo: nil)
            let target = DiscussionTarget(type: "TextQuoteSelector", exact: "<!-- text -->", prefix: "--!>", suffix: "", section: nil)
            let thread = DiscussionThread(id: "t-new", state: .open, target: target, messages: [message], resolvedBy: nil, resolved: nil, attachmentHistory: [])
            let source = "# Original\r\n\r\nEnd.\r\n"
            let changed = try applying(.newThread(thread), to: source)
            let parsed = try DiscussionCodec.parse(changed)
            XCTAssertEqual(parsed.threads, [thread])
            XCTAssertTrue(parsed.blocks.allSatisfy(\.hasCertainExtent))
            XCTAssertTrue(parsed.diagnostics.isEmpty)
            XCTAssertTrue(changed.hasPrefix(source))
        }
    }

    func testEmptyWrapperAndSizeLimitFailWithoutLosingSource() throws {
        let source = "<!-- margined:thread v1\n-->"
        let parsed = try DiscussionCodec.parse(source)
        XCTAssertEqual(parsed.blocks.count, 1)
        XCTAssertEqual(parsed.blocks.first?.hasCertainExtent, true)
        XCTAssertFalse(parsed.diagnostics.isEmpty)
        XCTAssertEqual(parsed.source, source)
        XCTAssertThrowsError(try DiscussionCodec.parse(String(repeating: "a", count: 8 * 1_024 * 1_024 + 1)))
    }

    func testFlowMappingEditsRetainUnknownDataAndExistingMessageBytes() throws {
        let source = """
        <!-- margined:thread v1
        {id: t1, state: resolved, resolved-by: A, resolved: '2026-10-23T10:00:00Z', target: {type: TextQuoteSelector, exact: Before, prefix: '', suffix: '', extra: 'keep'}, messages: [{id: m1, author: A, created: '2026-10-23T10:00:00Z', body: 'Original body', custom: 'message data'}], future: ['one', {two: 'three'}]}
        -->
        """
        let reply = try applying(.reply(threadID: "t1", message: newReply, reopenResolved: true), to: source)
        let parsed = try DiscussionCodec.parse(reply)
        XCTAssertEqual(parsed.threads.first?.messages.map(\.id), ["m1", "m2"])
        XCTAssertEqual(parsed.threads.first?.state, .open)
        XCTAssertTrue(reply.contains("{id: m1, author: A, created: '2026-10-23T10:00:00Z', body: 'Original body', custom: 'message data'}"))
        XCTAssertTrue(reply.contains("future: ['one', {two: 'three'}]"))
        let target = DiscussionTarget(type: "TextQuoteSelector", exact: "After", prefix: "", suffix: "", section: "Chapter")
        let attached = try applying(.reattach(threadID: "t1", target: target, author: "A", created: "2026-10-23T11:00:00Z"), to: reply)
        let block = try XCTUnwrap(DiscussionCodec.parse(attached).blocks.first)
        XCTAssertEqual(block.thread?.target, target)
        XCTAssertEqual(block.syntax?["target"]?["extra"]?.string, "keep")
        XCTAssertEqual(block.syntax?["attachment-history"]?.items?.first?["target"]?["extra"]?.string, "keep")
    }

    func testBlockScalarMetadataCanBeChangedWithoutJoiningTheFollowingKey() throws {
        let source = Self.note.replacingOccurrences(of: "state: open", with: "state: |-\n  open")
        let resolved = try applying(.resolve(threadID: "t1", author: "A", created: "2026-10-23T11:00:00Z"), to: source)
        let parsed = try DiscussionCodec.parse(resolved)
        XCTAssertEqual(parsed.threads.first?.state, .resolved)
        XCTAssertEqual(parsed.threads.first?.target.exact, "A passage.")
    }

    func testInvalidCalendarDatesAreRejected() throws {
        for date in ["2026-02-30T10:00:00Z", "2026-02-29T10:00:00Z", "2026-10-23T25:00:00Z", "2026-10-23T10:00:00+25:00"] {
            let parsed = try DiscussionCodec.parse(Self.note.replacingOccurrences(of: "2026-10-23T10:00:00Z", with: date))
            XCTAssertTrue(parsed.threads.isEmpty, "Accepted invalid date \(date)")
            XCTAssertFalse(parsed.diagnostics.isEmpty)
        }
        XCTAssertEqual(try DiscussionCodec.parse(Self.note.replacingOccurrences(of: "2026-10-23T10:00:00Z", with: "2024-02-29T10:00:00Z")).threads.count, 1)
    }

    func testEventBudgetAppliesAcrossAllBlocksInOneFile() throws {
        let extra = "extra: [" + Array(repeating: "a", count: 500).joined(separator: ",") + "]\nmessages:"
        let source = (0..<500).map { index in
            Self.note.replacingOccurrences(of: "id: t1", with: "id: t\(index)")
                .replacingOccurrences(of: "id: m1", with: "id: m\(index)")
                .replacingOccurrences(of: "messages:", with: extra)
        }.joined(separator: "\n\n")
        let parsed = try DiscussionCodec.parse(source)
        XCTAssertLessThan(parsed.threads.count, 500)
        XCTAssertFalse(parsed.diagnostics.isEmpty)
        XCTAssertEqual(parsed.blocks.count, 500)
        XCTAssertEqual(parsed.source, source)
    }

    func testBodyIndentationAndWhitespaceRoundTripExactly() throws {
        for body in ["  first\n    indented\n", "\nStarts later\n", "\n", "\n\n", "x\r\ny\r\n", "x\u{0085}y\u{2028}z\u{2029}", "a\u{0000}b\n"] {
            let message = DiscussionMessage(id: "m2", author: "A", created: "2026-10-23T11:00:00Z", body: body, inReplyTo: "m1")
            let changed = try applying(.reply(threadID: "t1", message: message, reopenResolved: false), to: Self.note)
            XCTAssertEqual(try DiscussionCodec.parse(changed).threads.first?.messages.last?.body, body)
        }
    }

    func testImportedTrailingCommasAndCommentsRemainEditable() throws {
        let source = """
        <!-- margined:thread v1
        {id: t1, state: open, target: {type: TextQuoteSelector, exact: Before, prefix: '', suffix: '',}, messages: [{id: m1, author: A, created: '2026-10-23T10:00:00Z', body: First}, # keep this, comma in comment
        ], # keep root comment
        }
        -->
        """
        let changed = try applying(.reply(threadID: "t1", message: newReply, reopenResolved: false), to: source)
        let resolved = try applying(.resolve(threadID: "t1", author: "A", created: "2026-10-23T11:00:00Z"), to: changed)
        XCTAssertEqual(try DiscussionCodec.parse(resolved).threads.first?.messages.count, 2)
        XCTAssertEqual(try DiscussionCodec.parse(resolved).threads.first?.state, .resolved)
        XCTAssertTrue(resolved.contains("# keep this, comma in comment"))
        XCTAssertTrue(resolved.contains("# keep root comment"))
    }

    static let sample = #"""
# A small reading plan

This file demonstrates a proposed portable comment format for Margined.
It is a design sample, not an implemented collaboration feature.

## What to compare

- In a rendered preview, read the plan below. The discussions should be hidden.
- In a source editor, look at the end of the file. Read or edit the discussions.
- Save a copy from each app, then reopen its source to check that the notes survived.

The comment bodies are readable Markdown inside HTML comments. Thread IDs,
authors, dates, reply links and quoted passage anchors are included as YAML.
The anchors use W3C Web Annotation concepts; this embedding is a proposal,
not an existing W3C Markdown syntax.

## Speech controls

Pause should feel predictable.

Keep the reading position when playback pauses.

Resume should start at the current sentence.

## File sharing

Local files remain usable without a Margined installation.

A reviewer can open the same document in their preferred editor, add a reply,
and return the `.md` file. There is no separate comment database to send.

## Before sharing

| Check | Expected result |
| --- | --- |
| Read the document | The plan is readable without annotations |
| Inspect the source | Named messages and reply relationships remain available |
| Save and reopen | The discussion blocks remain intact |

- [ ] Compare a Markdown preview
- [ ] Compare an ordinary source editor
- [ ] Save a copy and check its source

**End of the visible plan.** Everything after this paragraph is a hidden
annotation block. A clean preview should not display its contents.

<!-- margined:thread v1
id: thread-reading-position
state: open
target:
  type: TextQuoteSelector
  exact: "Keep the reading position when playback pauses."
  prefix: "Pause should feel predictable."
  suffix: "Resume should start at the current sentence."
messages:
  - id: reading-craig-1
    author: Craig
    created: "2026-10-22T10:11:00-07:00"
    body: |
      Can playback resume at the start of the sentence?

      **Suggestion:** keep the paragraph visible while it is paused.
  - id: reading-codex-1
    author: Codex
    created: "2026-10-22T10:18:00-07:00"
    in-reply-to: reading-craig-1
    body: |
      Yes. Resume at that sentence and preserve the reader’s position.
  - id: reading-anand-1
    author: Anand
    created: "2026-10-22T10:24:00-07:00"
    in-reply-to: reading-codex-1
    body: |
      Keep manual scrolling free. Please do not pull me back automatically.
  - id: reading-craig-2
    author: Craig
    created: "2026-10-22T10:31:00-07:00"
    in-reply-to: reading-anand-1
    body: |
      That sounds right. I will try it with a longer document.

      COMMENT_CANARY_OPEN — this line belongs only in the source or note UI.
-->

<!-- margined:thread v1
id: thread-independent-scrolling
state: open
target:
  type: TextQuoteSelector
  exact: "Keep the reading position when playback pauses."
  prefix: "Pause should feel predictable."
  suffix: "Resume should start at the current sentence."
messages:
  - id: scrolling-anand-1
    author: Anand
    created: "2026-10-22T11:00:00-07:00"
    body: |
      A separate question on this same passage: should Follow Reading stay off
      after I manually scroll?

      COMMENT_CANARY_SECOND_THREAD — separate thread, identical target.
-->

<!-- margined:thread v1
id: thread-portable-file
state: resolved
resolved-by: Anand
resolved: "2026-10-22T11:20:00-07:00"
target:
  type: TextQuoteSelector
  exact: "Local files remain usable without a Margined installation."
  prefix: "File sharing"
  suffix: "A reviewer can open the same document in their preferred editor"
messages:
  - id: portable-anand-1
    author: Anand
    created: "2026-10-22T11:05:00-07:00"
    body: |
      Can a reviewer reply using a plain text editor?
  - id: portable-codex-1
    author: Codex
    created: "2026-10-22T11:10:00-07:00"
    in-reply-to: portable-anand-1
    body: |
      Yes. Copy a message entry, choose a new ID, add your name and reply text,
      and point in-reply-to at the message you are answering.

      This resolved conversation is retained rather than deleted.
      COMMENT_CANARY_RESOLVED — this line must remain in the saved source.
-->

<!-- margined:thread v1
id: thread-original-text-removed
state: open
target:
  type: TextQuoteSelector
  exact: "Automatically send every note to a server."
  prefix: ""
  suffix: ""
messages:
  - id: removed-craig-1
    author: Craig
    created: "2026-10-22T11:30:00-07:00"
    body: |
      This sentence was removed from the plan. Preserve this discussion and
      its original quotation; do not attach it to an unrelated passage.

      COMMENT_CANARY_UNATTACHED — a missing target must not lose its thread.
-->

"""#
}

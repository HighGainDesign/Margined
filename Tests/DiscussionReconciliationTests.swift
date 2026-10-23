import Foundation
import XCTest
import CcmarkGFM
import SwiftSoup
import Darwin
#if MARGINED_DISCUSSION_PROBE
#elseif os(iOS)
@testable import MarginediOS
#else
@testable import Margined
#endif

final class DiscussionReconciliationTests: XCTestCase {
    private func message(_ id: String, body: String = "Note.", reply: String? = nil, extra: String = "") -> String {
        "  - id: \(id)\n    author: Reviewer\n    created: \"2026-10-23T10:00:00Z\"\n    body: \(DiscussionEdits.quote(body))\n" + (reply.map { "    in-reply-to: \($0)\n" } ?? "") + extra
    }
    private func block(_ id: String = "t1", messages: [String], extra: String = "") -> String {
        "<!-- margined:thread v1\nid: \(id)\nstate: open\ntarget: {type: TextQuoteSelector, exact: Passage., prefix: \"\", suffix: \"\"}\n" + extra + "messages:\n" + messages.joined() + "-->"
    }
    private func document(_ blocks: [String], prose: String = "# Current\n\nPassage.") throws -> DiscussionDocument {
        try DiscussionCodec.parse(prose + "\n\n" + blocks.joined(separator: "\n\n") + "\n\nTail.\n")
    }
    private func apply(_ preview: DiscussionImportPreview, choices: [String: DiscussionReconciliation.Choice] = [:], ids: [String] = []) throws -> DiscussionDocument {
        var ids = ids
        let edits = try DiscussionReconciliation.splices(for: preview, in: preview.current, choices: choices, newID: { ids.isEmpty ? UUID().uuidString : ids.removeFirst() })
        let data = try MarkdownSourceEdits.apply(edits, to: Data(preview.current.source.utf8), expectedSource: preview.current.source)
        return try DiscussionCodec.parse(MarkdownSource.decode(data))
    }
    func testDeduplicationNeverDeletesAbsentMessagesOrCurrentProse() throws {
        let current = try document([block(messages: [message("m1"), message("m2", reply: "m1")])])
        let incoming = try document([block(messages: [message("m1")])], prose: "Incoming prose must not replace current prose.")
        let preview = DiscussionReconciliation.preview(current: current, incoming: incoming)
        XCTAssertEqual(preview.items.first?.kind, .duplicate)
        let result = try apply(preview)
        XCTAssertTrue(result.source.utf8.elementsEqual(current.source.utf8))
        XCTAssertEqual(result.threads.first?.messages.map(\.id), ["m1", "m2"])
    }
    func testNewRepliesKeepCurrentOrderAndUnknownTypedMetadata() throws {
        let extra = "opaque: {enabled: true, quoted: \"true\", empty: , nested: [one, two]}\n"
        let current = try document([block(messages: [message("m1"), message("m3", reply: "m1")], extra: extra)])
        let incoming = try document([block(messages: [message("m1"), message("m2", reply: "m1", extra: "    custom: {enabled: false, quoted: \"false\"}\n")], extra: extra)])
        let preview = DiscussionReconciliation.preview(current: current, incoming: incoming)
        XCTAssertEqual(preview.items.first?.kind, .replies)
        XCTAssertEqual(preview.items.first?.addedMessageIDs, ["m2"])
        let result = try apply(preview)
        XCTAssertEqual(result.threads.first?.messages.map(\.id), ["m1", "m3", "m2"])
        XCTAssertEqual(result.blocks.first?.syntax?["opaque"]?["enabled"]?.string, "true")
        XCTAssertEqual(result.blocks.first?.syntax?["opaque"]?["quoted"]?.string, "true")
        if case .scalar(_, .plain)? = result.blocks.first?.syntax?["opaque"]?["enabled"]?.value {} else { XCTFail("Unknown boolean became a string") }
        if case .scalar(_, .doubleQuoted)? = result.blocks.first?.syntax?["opaque"]?["quoted"]?.value {} else { XCTFail("Unknown string became a boolean") }
        XCTAssertEqual(result.blocks.first?.syntax?["messages"]?.items?.last?["custom"]?["enabled"]?.string, "false")
        XCTAssertTrue(result.source.hasPrefix("# Current\n\nPassage.\n\n"))
        XCTAssertTrue(result.source.hasSuffix("\n\nTail.\n"))
        XCTAssertTrue(result.diagnostics.isEmpty)
    }
    func testRootChangesRequireAnExplicitChoice() throws {
        let original = block(messages: [message("m1"), message("m-current", reply: "m1")])
        let current = try document([original])
        for replacement in [original.replacingOccurrences(of: "exact: Passage.", with: "exact: Different."), original.replacingOccurrences(of: "state: open", with: "state: resolved\nresolved-by: Reviewer\nresolved: \"2026-10-23T11:00:00Z\""), original.replacingOccurrences(of: "messages:", with: "opaque: extra\nmessages:"), original.replacingOccurrences(of: "messages:", with: "attachment-history:\n  - target: {type: TextQuoteSelector, exact: Before., prefix: \"\", suffix: \"\"}\n    author: Reviewer\n    created: \"2026-10-23T09:00:00Z\"\nmessages:")] {
            let preview = DiscussionReconciliation.preview(current: current, incoming: try document([replacement]))
            XCTAssertEqual(preview.items.first?.kind, .conflict)
            XCTAssertThrowsError(try apply(preview))
            XCTAssertEqual(try apply(preview, choices: ["t1": .keepCurrent]).source, current.source)
            let selected = try apply(preview, choices: ["t1": .useIncoming])
            XCTAssertEqual(selected.threads.first?.messages.map(\.id), ["m1", "m-current"])
        }
    }
    func testChangedSharedMessageNeedsChoiceAndIncomingChoiceRetainsAbsentReplies() throws {
        let current = try document([block(messages: [message("m1", body: "Old."), message("m-local", reply: "m1")])])
        let incoming = try document([block(messages: [message("m1", body: "New."), message("m-remote", reply: "m1")])])
        let preview = DiscussionReconciliation.preview(current: current, incoming: incoming)
        XCTAssertEqual(preview.items.first?.kind, .conflict)
        let result = try apply(preview, choices: ["t1": .useIncoming])
        XCTAssertEqual(result.threads.first?.messages.map(\.id), ["m1", "m-local", "m-remote"])
        XCTAssertEqual(result.threads.first?.messages.first?.body, "New.")
    }
    func testSharedAuthorDateReplyAndUnknownFieldsArePartOfConflictDetection() throws {
        let base = block(messages: [message("m1"), message("m2", reply: "m1", extra: "    opaque: true\n")])
        let current = try document([base])
        for changed in [base.replacingOccurrences(of: "author: Reviewer", with: "author: Another"),
                        base.replacingOccurrences(of: "10:00:00Z", with: "11:00:00Z"),
                        base.replacingOccurrences(of: "    in-reply-to: m1\n", with: ""),
                        base.replacingOccurrences(of: "    opaque: true", with: "    opaque: false")] {
            let incoming = try document([changed]); XCTAssertTrue(incoming.diagnostics.isEmpty)
            XCTAssertEqual(DiscussionReconciliation.preview(current: current, incoming: incoming).items.first?.kind, .conflict)
        }
    }
    func testKnownStringFormattingChangesDeduplicateWithoutRewritingCurrentSource() throws {
        let current = try document([block(messages: [message("m1")])])
        let flow = "<!-- margined:thread v1\n{id: \"t1\", state: \"open\", target: {type: \"TextQuoteSelector\", exact: \"Passage.\", prefix: \"\", suffix: \"\"}, messages: [{id: \"m1\", author: \"Reviewer\", created: \"2026-10-23T10:00:00Z\", body: \"Note.\"}]}\n-->"
        let incoming = try document([flow]); XCTAssertTrue(incoming.diagnostics.isEmpty)
        let preview = DiscussionReconciliation.preview(current: current, incoming: incoming)
        XCTAssertEqual(preview.items.first?.kind, .duplicate)
        XCTAssertTrue(try apply(preview).source.utf8.elementsEqual(current.source.utf8))
    }
    func testKeepSeparateRemapsEveryInternalReplyIDAndLeavesOriginalUntouched() throws {
        let current = try document([block(messages: [message("m1")])])
        let incoming = try document([block(messages: [message("m1", body: "Changed."), message("m2", reply: "m1")])])
        let preview = DiscussionReconciliation.preview(current: current, incoming: incoming)
        let result = try apply(preview, choices: ["t1": .keepSeparate], ids: ["t-new", "m-new1", "m-new2"])
        XCTAssertTrue(result.source.hasPrefix(current.source))
        XCTAssertEqual(result.threads.map(\.id), ["t1", "t-new"])
        XCTAssertEqual(result.threads.last?.messages.map(\.id), ["m-new1", "m-new2"])
        XCTAssertEqual(result.threads.last?.messages.last?.inReplyTo, "m-new1")
        XCTAssertTrue(result.diagnostics.isEmpty)
    }
    func testNewThreadWithGloballyCollidingMessageIDsCannotOverwriteAnotherThread() throws {
        let current = try document([block(messages: [message("m1")])])
        let incoming = try document([block("t2", messages: [message("m1", body: "Other thread.")])])
        let preview = DiscussionReconciliation.preview(current: current, incoming: incoming)
        XCTAssertEqual(preview.items.first?.kind, .conflict)
        XCTAssertThrowsError(try apply(preview, choices: ["t2": .useIncoming]))
        let result = try apply(preview, choices: ["t2": .keepSeparate], ids: ["t3", "m3"])
        XCTAssertEqual(result.threads.map(\.id), ["t1", "t3"])
        XCTAssertEqual(result.threads.last?.messages.first?.id, "m3")
    }
    func testUnknownScalarTypeAndByteDifferentUnicodeAreConflicts() throws {
        let base = block(messages: [message("m1", body: "café")], extra: "opaque: true\n")
        let current = try document([base])
        for other in [base.replacingOccurrences(of: "opaque: true", with: "opaque: \"true\""), base.replacingOccurrences(of: "café", with: "cafe\u{301}")] {
            XCTAssertEqual(DiscussionReconciliation.preview(current: current, incoming: try document([other])).items.first?.kind, .conflict)
        }
    }
    func testIndependentThreadAddsWithoutMergingProseAndLeavesIncomingFileUnchanged() throws {
        let current = try document([block(messages: [message("m1")])])
        let incoming = try document([block("t2", messages: [message("m2")])], prose: "Different prose.")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let data = Data(incoming.source.utf8); try data.write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let result = try apply(DiscussionReconciliation.preview(current: current, incoming: incoming))
        XCTAssertTrue(result.source.hasPrefix(current.source))
        XCTAssertFalse(result.source.contains("Different prose."))
        XCTAssertEqual(result.threads.map(\.id), ["t1", "t2"])
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
    func testKeepSeparateAvoidsIdentifiersInLaterIncomingThreads() throws {
        let current = try document([block(messages: [message("m1")])])
        let incoming = try document([block(messages: [message("m1", body: "Changed.")]), block("t-later", messages: [message("m-later")])])
        let preview = DiscussionReconciliation.preview(current: current, incoming: incoming)
        let result = try apply(preview, choices: ["t1": .keepSeparate], ids: ["t-later", "t-separate", "m-separate"])
        XCTAssertEqual(result.threads.map(\.id), ["t1", "t-separate", "t-later"])
        XCTAssertTrue(result.diagnostics.isEmpty)
    }
    func testMergedUnknownNullsAndExplicitStringsKeepTheirMeaning() throws {
        let extra = "opaque:\n  empty:\n  items:\n    -\n    - ~\n    - !!str true\n  multiline: |\n    A value.\n"
        let current = try document([block(messages: [message("m1")], extra: extra)])
        let incoming = try document([block(messages: [message("m1"), message("m2", reply: "m1")], extra: extra)])
        XCTAssertTrue(current.diagnostics.isEmpty); XCTAssertTrue(incoming.diagnostics.isEmpty)
        let result = try apply(DiscussionReconciliation.preview(current: current, incoming: incoming))
        let opaque = try XCTUnwrap(result.blocks.first?.syntax?["opaque"])
        XCTAssertEqual(opaque["empty"]?.string, "")
        XCTAssertEqual(opaque["items"]?.items?.map(\.string), ["", "~", "true"])
        if case .scalar(_, .doubleQuoted)? = opaque["items"]?.items?.last?.value {} else { XCTFail("Explicit string lost its type") }
        XCTAssertEqual(opaque["multiline"]?.string, "A value.\n")
    }
    func testImportedLiteralCommentDelimitersCannotTerminateTheWrapper() throws {
        let current = try document([block(messages: [message("m1")])])
        let body = "Literal <!-- comment --> and --!> 日本"
        let incoming = try document([block(messages: [message("m1"), message("m2", body: body, reply: "m1")])])
        XCTAssertTrue(incoming.diagnostics.isEmpty)
        let result = try apply(DiscussionReconciliation.preview(current: current, incoming: incoming))
        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertEqual(result.blocks.count, 1)
        XCTAssertEqual(result.threads.first?.messages.last?.body, body)
        XCTAssertTrue(result.source.hasSuffix("\n\nTail.\n"))
    }
    func testStalePreviewAndExhaustedIDAllocatorRefuseEdits() throws {
        let current = try document([block(messages: [message("m1")])], prose: "café")
        let incoming = try document([block(messages: [message("m1", body: "Changed.")])])
        let preview = DiscussionReconciliation.preview(current: current, incoming: incoming)
        let stale = try DiscussionCodec.parse(current.source.replacingOccurrences(of: "café", with: "cafe\u{301}"))
        XCTAssertThrowsError(try DiscussionReconciliation.splices(for: preview, in: stale, choices: ["t1": .keepSeparate]))
        XCTAssertThrowsError(try DiscussionReconciliation.splices(for: preview, in: current, choices: ["t1": .keepSeparate], newID: { "t1" }))
    }
    @MainActor func testImportUsesConditionalFileUndoAndRetainsUnpostedReplies() throws {
        let current = try document([block(messages: [message("m1")])])
        let incoming = try document([block(messages: [message("m1"), message("m2", reply: "m1")])])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let data = Data(current.source.utf8); try data.write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let session = DiscussionSession(), key = DiscussionSession.DraftKey.thread("t1")
        session.setDraft("My unposted reply.", for: key)
        let preview = DiscussionReconciliation.preview(current: current, incoming: incoming), snapshot = try SourceFileEdit.read(file)
        let operation = try XCTUnwrap(session.prepareImport(preview, snapshot: snapshot))
        let saved = try SourceFileEdit.commit(operation.replacement, expected: operation.expected)
        try session.saved(operation, as: saved)
        XCTAssertEqual(try DiscussionCodec.parse(saved.source).threads.first?.messages.map(\.id), ["m1", "m2"])
        XCTAssertEqual(session.drafts[key]?.body, "My unposted reply.")
        XCTAssertEqual(session.displayName, "", "Import must keep the original recorded authors")
        let undo = try session.prepareUndo(snapshot: saved), undone = try SourceFileEdit.commit(undo.replacement, expected: undo.expected)
        try session.saved(undo, as: undone)
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertEqual(session.drafts[key]?.body, "My unposted reply.")
        XCTAssertTrue(session.canRedo(snapshot: undone))
    }
    @MainActor func testImportNoOpStaleAndReadOnlyKeepDraftsAndDoNotAcceptASave() throws {
        let current = try document([block(messages: [message("m1")])])
        let session = DiscussionSession(), key = DiscussionSession.DraftKey.thread("t1")
        session.setDraft("Keep this draft.", for: key)
        let url = URL(fileURLWithPath: "/Document.md")
        let snapshot = SourceFileEdit.Snapshot(url: url, data: Data(current.source.utf8), identity: .init(device: 1, inode: 1))
        let duplicate = DiscussionReconciliation.preview(current: current, incoming: current)
        XCTAssertNil(try session.prepareImport(duplicate, snapshot: snapshot))
        XCTAssertNil(session.pending)
        let incoming = try document([block(messages: [message("m1"), message("m2", reply: "m1")])])
        let preview = DiscussionReconciliation.preview(current: current, incoming: incoming)
        let stale = SourceFileEdit.Snapshot(url: url, data: Data((current.source + "Agent edit.").utf8), identity: snapshot.identity)
        XCTAssertThrowsError(try session.prepareImport(preview, snapshot: stale))
        XCTAssertThrowsError(try session.prepareImport(preview, snapshot: nil))
        XCTAssertNil(session.pending)
        XCTAssertEqual(session.drafts[key]?.body, "Keep this draft.")
    }
    func testCleanCopyPreservesExactEncodingAndAllUnrelatedBytes() throws {
        let note = block(messages: [message("m1")]).replacingOccurrences(of: "\n", with: "\r\n")
        let before = "# 🐈 café\r\n<!-- ordinary -->\r\n\r\n", after = "\r\n\r\nTail.\r\n"
        let source = before + note + after
        let forms = [Data(source.utf8), Data([0xef,0xbb,0xbf]) + Data(source.utf8), Data([0xff,0xfe]) + source.data(using: .utf16LittleEndian)!, Data([0xfe,0xff]) + source.data(using: .utf16BigEndian)!]
        let expected = before + after
        let targets = [Data(expected.utf8), Data([0xef,0xbb,0xbf]) + Data(expected.utf8), Data([0xff,0xfe]) + expected.data(using: .utf16LittleEndian)!, Data([0xfe,0xff]) + expected.data(using: .utf16BigEndian)!]
        for (data, target) in zip(forms, targets) {
            let export = try DiscussionExports.cleanCopy(data)
            XCTAssertEqual(export.removedBlocks, 1); XCTAssertEqual(export.data, target)
        }
    }
    func testCleanCopyRemovesCertainInvalidAndFutureBlocksButRefusesUncertainExtent() throws {
        let valid = block(messages: [message("m1")])
        let future = valid.replacingOccurrences(of: "v1\n", with: "v9\n")
        let bad = valid.replacingOccurrences(of: "state: open", with: "state: [broken")
        let source = "```md\n" + valid + "\n```\n\n" + future + "\n\n" + bad
        let result = try DiscussionExports.cleanCopy(Data(source.utf8))
        XCTAssertEqual(result.removedBlocks, 2)
        XCTAssertTrue(try MarkdownSource.decode(result.data).hasPrefix("```md\n" + valid + "\n```"))
        XCTAssertThrowsError(try DiscussionExports.cleanCopy(Data(valid.dropLast(3).utf8)))
    }
    func testConversationExportsLiteralDelimitersAuthorsQuotesAndReplyRelationships() throws {
        let raw = "<!-- literal --> **not formatting** `code`\n<script>evil</script> 日本"
        let source = try document([block(messages: [message("m1", body: raw), message("m2", reply: "m1")])])
        let exported = DiscussionExports.conversation(source)
        XCTAssertTrue(exported.contains("Reviewer")); XCTAssertTrue(exported.contains("Passage."))
        XCTAssertTrue(exported.contains("m1")); XCTAssertTrue(exported.contains("m2"))
        let html = try XCTUnwrap(exported.withCString { cmark_markdown_to_html($0, exported.utf8.count, CMARK_OPT_DEFAULT) })
        defer { free(html) }
        let dom = try SwiftSoup.parse(String(cString: html)), visible = try dom.text()
        XCTAssertTrue(visible.contains("<!-- literal --> **not formatting** `code`"))
        XCTAssertTrue(visible.contains("<script>evil</script> 日本"))
        XCTAssertTrue(try dom.select("script").array().isEmpty)
        XCTAssertFalse(exported.contains("<!--")); XCTAssertFalse(exported.contains("<script>"))
    }
}

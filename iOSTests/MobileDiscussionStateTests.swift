import Foundation
import XCTest
@testable import MarginediOS

@MainActor final class MobileDiscussionStateTests: XCTestCase {
    func testPreviewOffersACopyWithoutChangingTheSnapshotOrLosingDrafts() async throws {
        let reader = MobileReaderState()
        var components = URLComponents(string: "margined://preview")!
        components.queryItems = [URLQueryItem(name: "text", value: "Passage.")]
        await reader.openPreview(url: try XCTUnwrap(components.url)); try await settle(reader)
        let key = DiscussionSession.DraftKey.new(UUID())
        reader.discussions.displayName = "Reviewer"; reader.discussions.selection = key
        reader.discussions.setDraft("Keep my snapshot note.", for: key, target: .init(type: "TextQuoteSelector", exact: "Passage.", prefix: "", suffix: "", section: nil))
        reader.postDiscussion()
        XCTAssertTrue(reader.discussionCopyOffered)
        XCTAssertEqual(reader.discussionError, DiscussionSession.Failure.savedCopyRequired.localizedDescription)
        XCTAssertEqual(reader.source, "Passage.")
        XCTAssertNil(reader.fileURL)
        XCTAssertEqual(reader.discussions.drafts[key]?.body, "Keep my snapshot note.")
        XCTAssertNil(reader.discussions.pending)
        reader.discussions.discardDrafts(); await reader.close()
    }

    func testNoteOnlyRefreshKeepsTheSelectedProseChange() async throws {
        let initial = "# Plan\n\nFirst.\n\nSecond.\n"
        let changed = "# Plan\n\nFirst changed.\n\nSecond changed.\n"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data(initial.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let reader = MobileReaderState()
        await reader.open(url: file); try await settle(reader)
        try Data(changed.utf8).write(to: file, options: .atomic)
        await reader.refresh(); try await settle(reader)
        XCTAssertEqual(reader.changes.count, 2)
        reader.selectChange(1)
        let selected = try XCTUnwrap(reader.selectedChange)
        let message = DiscussionMessage(id: "m-note", author: "Reviewer", created: "2026-10-23T10:00:00Z", body: "Note only.", inReplyTo: nil)
        let thread = DiscussionThread(id: "t-note", state: .open,
            target: .init(type: "TextQuoteSelector", exact: "Second changed.", prefix: "First changed.", suffix: "", section: "Plan"),
            messages: [message], resolvedBy: nil, resolved: nil, attachmentHistory: [])
        let parsed = try DiscussionCodec.parse(changed)
        let data = try MarkdownSourceEdits.apply(DiscussionEdits.splices(for: .newThread(thread), in: parsed), to: Data(changed.utf8), expectedSource: changed)
        try data.write(to: file, options: .atomic)
        await reader.refresh(); try await settle(reader)
        XCTAssertEqual(reader.selectedChange?.id, selected.id)
        XCTAssertEqual(reader.selectedChange?.after, selected.after)
        await reader.close()
    }

    func testPostAndConditionalUndoUseTheActiveDocumentLease() async throws {
        let data = Data("Passage.\n".utf8), file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try data.write(to: file)
        let reader = MobileReaderState()
        defer { try? FileManager.default.removeItem(at: file) }
        await reader.open(url: file); try await settle(reader)
        let key = DiscussionSession.DraftKey.new(UUID())
        reader.discussions.displayName = "Anand"; reader.discussions.selection = key
        reader.discussions.setDraft("A note.", for: key, target: DiscussionTarget(type: "TextQuoteSelector", exact: "Passage.", prefix: "", suffix: "", section: nil))
        reader.postDiscussion(); try await settle(reader)
        XCTAssertEqual(try DiscussionCodec.parse(try MarkdownSource.read(file)).threads.count, 1)
        XCTAssertFalse(reader.discussions.hasUnpostedDrafts)
        reader.undoDiscussion(); try await settle(reader)
        XCTAssertEqual(try Data(contentsOf: file), data)
        reader.discussions.discardDrafts(); await reader.close()
    }

    func testCloseOrReplacementRequiresExplicitDiscardOfUnpostedDraft() async throws {
        let first = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let second = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data("First.".utf8).write(to: first); try Data("Second.".utf8).write(to: second)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let reader = MobileReaderState()
        await reader.open(url: first); try await settle(reader)
        let key = DiscussionSession.DraftKey.new(UUID())
        reader.discussions.setDraft("Keep this unsent reply.", for: key)
        await reader.open(url: second)
        XCTAssertEqual(reader.fileURL, first)
        XCTAssertTrue(reader.showDraftDiscardConfirmation)
        reader.cancelDocumentTransition()
        XCTAssertTrue(reader.discussions.hasUnpostedDrafts)
        await reader.close()
        XCTAssertTrue(reader.hasDocument)
        XCTAssertTrue(reader.showDraftDiscardConfirmation)
        await reader.confirmDiscardDrafts()
        XCTAssertFalse(reader.hasDocument)
        XCTAssertFalse(reader.discussions.hasUnpostedDrafts)
        reader.discussions.discardDrafts(); await reader.close()
    }

    func testIdenticalExternalReplacementInvalidatesUndoAndAdoptsItsNewIdentity() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data("- [ ] Task\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let reader = MobileReaderState()
        await reader.open(url: file); try await settle(reader)
        reader.checklistMode = true
        XCTAssertTrue(reader.requestTaskChecked(0, checked: true)); try await settle(reader)
        XCTAssertTrue(reader.canUndoChecklist)
        let data = try Data(contentsOf: file)
        try data.write(to: file, options: .atomic)
        await reader.refresh(); try await settle(reader)
        XCTAssertFalse(reader.canUndoChecklist, "An identical replacement is still an external file version")
        XCTAssertTrue(reader.requestTaskChecked(0, checked: false)); try await settle(reader)
        XCTAssertEqual(try Data(contentsOf: file), Data("- [ ] Task\n".utf8))
        await reader.close()
    }

    func testCanonicallyEquivalentRefreshRebuildsSourceMappings() async throws {
        let before = "# cafe\u{301}\n\n- [ ] Task\n", after = "# café\n\n- [ ] Task\n"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data(before.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let reader = MobileReaderState()
        await reader.open(url: file); try await settle(reader)
        try Data(after.utf8).write(to: file, options: .atomic)
        await reader.refresh(); try await settle(reader)
        XCTAssertEqual(Array(reader.source.utf8), Array(after.utf8))
        XCTAssertEqual(Array(try XCTUnwrap(reader.rendered).taskSource.utf8), Array(after.utf8))
        await reader.close()
    }

    func testOtherCopyIsReadOnlyAndImportUndoRetainsDraftAndCurrentDocument() async throws {
        let source = "# Current\n\nBefore.\n\nPassage.\n\nAfter.\n"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Current.md"), other = directory.appendingPathComponent("Other.md")
        let data = Data(source.utf8), incoming = try makeImportCopy(withContext: true)
        try data.write(to: file); try incoming.write(to: other)
        let reader = MobileReaderState()
        await reader.open(url: file); try await settle(reader)
        let key = DiscussionSession.DraftKey.new(UUID())
        reader.discussions.setDraft("Keep my unposted text.", for: key, target: .init(type: "TextQuoteSelector", exact: "Passage.", prefix: "", suffix: "", section: nil))
        await reader.reviewDiscussionCopy(other)
        XCTAssertEqual(reader.discussionImportPreview?.items.first?.kind, .newThread)
        XCTAssertEqual(reader.source, source); XCTAssertEqual(reader.fileURL, file)
        XCTAssertEqual(try Data(contentsOf: file), data)
        reader.importDiscussions(); try await settle(reader)
        XCTAssertEqual(try DiscussionCodec.parse(reader.source).threads.map(\.id), ["t-import"])
        XCTAssertEqual(try Data(contentsOf: other), incoming)
        XCTAssertFalse(reader.source.contains("Other copy prose."))
        XCTAssertEqual(reader.discussions.drafts[key]?.body, "Keep my unposted text.")
        XCTAssertEqual(reader.rendered?.discussionText?.anchorResults["t-import"]?.status, .attached)
        XCTAssertNil(reader.discussionImportPreview)
        reader.undoDiscussion(); try await settle(reader)
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertEqual(reader.discussions.drafts[key]?.body, "Keep my unposted text.")
        reader.discussions.discardDrafts(); await reader.close()
    }
    func testIdenticalReplacementAfterReviewRefusesImportAgainstAnotherFileIdentity() async throws {
        let source = "# Current\n\nPassage.\n"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Current.md"), other = directory.appendingPathComponent("Other.md")
        let data = Data(source.utf8); try data.write(to: file); try makeImportCopy().write(to: other)
        let reader = MobileReaderState()
        await reader.open(url: file); try await settle(reader)
        await reader.reviewDiscussionCopy(other)
        XCTAssertNotNil(reader.discussionImportPreview)
        try data.write(to: file, options: .atomic)
        await reader.refresh(); try await settle(reader)
        reader.importDiscussions(); try await settle(reader)
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertNotNil(reader.discussionError)
        reader.discussions.discardDrafts(); await reader.close()
    }
    func testFailedOtherCopyReadKeepsCurrentDocumentAndAllowsAnotherReview() async throws {
        let source = "Passage.\n"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Current.md"), other = directory.appendingPathComponent("Other.md")
        let data = Data(source.utf8); try data.write(to: file); try makeImportCopy().write(to: other)
        let reader = MobileReaderState()
        await reader.open(url: file); try await settle(reader)
        let key = DiscussionSession.DraftKey.new(UUID())
        reader.discussions.setDraft("Keep the draft after a read error.", for: key)
        await reader.reviewDiscussionCopy(directory.appendingPathComponent("Missing.md"))
        XCTAssertNotNil(reader.discussionError)
        XCTAssertFalse(reader.discussionImportLoading)
        XCTAssertNil(reader.discussionImportPreview)
        XCTAssertEqual(reader.source, source); XCTAssertEqual(reader.fileURL, file)
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertEqual(reader.discussions.drafts[key]?.body, "Keep the draft after a read error.")
        await reader.reviewDiscussionCopy(other)
        XCTAssertNil(reader.discussionError)
        XCTAssertEqual(reader.discussionImportPreview?.items.first?.kind, .newThread)
        reader.discussions.discardDrafts(); await reader.close()
        XCTAssertNil(reader.discussionImportPreview)
    }
    func testImportedQuotesRemainMissingOrAmbiguousRatherThanRetargeting() async throws {
        for (source, expected) in [("# Current\n\nDifferent.\n", DiscussionAnchorResult.Status.missing),
                                    ("# Current\n\nPassage.\n\nPassage.\n", .ambiguous),
                                    ("# Current\n\nPassage.\n", .needsConfirmation)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("Current.md"), other = directory.appendingPathComponent("Other.md")
            try Data(source.utf8).write(to: file); try makeImportCopy().write(to: other)
            let reader = MobileReaderState()
            await reader.open(url: file); try await settle(reader)
            await reader.reviewDiscussionCopy(other)
            reader.importDiscussions(); try await settle(reader)
            XCTAssertEqual(reader.rendered?.discussionText?.anchorResults["t-import"]?.status, expected)
            XCTAssertEqual(try DiscussionCodec.parse(reader.source).threads.first?.target.exact, "Passage.")
            XCTAssertTrue(reader.source.hasPrefix(source))
            await reader.close()
        }
    }

    private func makeImportCopy(withContext: Bool = false) throws -> Data {
        let source = withContext ? "# Other copy prose.\n\nBefore.\n\nPassage.\n\nAfter.\n" : "# Other copy prose.\n\nPassage.\n"
        let thread = DiscussionThread(id: "t-import", state: .open,
            target: .init(type: "TextQuoteSelector", exact: "Passage.", prefix: withContext ? "Before." : "", suffix: withContext ? "After." : "", section: nil),
            messages: [.init(id: "m-import", author: "Original Author", created: "2026-10-23T10:00:00Z", body: "A reply from the other copy.", inReplyTo: nil)],
            resolvedBy: nil, resolved: nil, attachmentHistory: [])
        let parsed = try DiscussionCodec.parse(source)
        return try MarkdownSourceEdits.apply(DiscussionEdits.splices(for: .newThread(thread), in: parsed), to: Data(source.utf8), expectedSource: source)
    }

    private func settle(_ reader: MobileReaderState) async throws {
        for _ in 0..<300 {
            if !reader.fileSaving && !reader.isRendering && !reader.isOpening { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Document save/render did not settle")
    }
}

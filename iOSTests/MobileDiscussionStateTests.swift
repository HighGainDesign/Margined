import Foundation
import XCTest
@testable import MarginediOS

@MainActor final class MobileDiscussionStateTests: XCTestCase {
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

    private func settle(_ reader: MobileReaderState) async throws {
        for _ in 0..<300 {
            if !reader.fileSaving && !reader.isRendering && !reader.isOpening { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Document save/render did not settle")
    }
}

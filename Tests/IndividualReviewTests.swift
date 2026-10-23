import Foundation
import XCTest
import SwiftSoup
@testable import Margined

@MainActor
final class IndividualReviewTests: XCTestCase {
    func testIndividualEditsAdvanceBaselineAndLeaveOtherChanges() async throws {
        let reader = makeReader("# Notes\n\nOld first.\n\n## Second\n\nOld second.")
        reader.acceptFileUpdate("# Notes\n\nNew first.\n\n## Second\n\nNew second.")
        try await settle(reader)
        XCTAssertEqual(reader.changes.count, 2)
        reader.markCurrentChangeReviewed()
        try await settle(reader)
        XCTAssertEqual(reader.changes.count, 1)
        XCTAssertEqual(reader.selectedChange?.after, "New second.")
        XCTAssertEqual(try SwiftSoup.parse(reader.rendered!.html).select(".margined-change").size(), 1)
        reader.wide.toggle()
        reader.render()
        try await settle(reader)
        XCTAssertEqual(reader.changes.count, 1)
        reader.acceptFileUpdate("# Notes\n\nNewest first.\n\n## Second\n\nNew second.")
        try await settle(reader)
        XCTAssertEqual(reader.changes.count, 2)
        XCTAssertEqual(reader.changes.entries.first?.before, "New first.")
        reader.markReviewed()
        try await settle(reader)
        XCTAssertEqual(reader.changes.count, 0)
        reader.stop()
    }

    func testAdditionsDeletionsAndDuplicateTextCanBeReviewedSeparately() async throws {
        let reader = makeReader("# One\n\nOld.\n\nDelete me.\n\n# Two\n\nOld.")
        reader.acceptFileUpdate("# One\n\nNew.\n\n# Two\n\nNew.\n\nAdded.")
        try await settle(reader)
        XCTAssertEqual(reader.changes.count, 4)
        reader.currentChangeIndex = 1
        XCTAssertEqual(reader.selectedChange?.kind, .removed)
        reader.markCurrentChangeReviewed()
        try await settle(reader)
        XCTAssertEqual(reader.changes.count, 3)
        XCTAssertEqual(reader.selectedChange?.after, "New.")
        reader.currentChangeIndex = 0
        reader.markCurrentChangeReviewed()
        try await settle(reader)
        XCTAssertEqual(reader.changes.count, 2, "Reviewing one duplicate must not clear the other")
        reader.currentChangeIndex = 1
        XCTAssertEqual(reader.selectedChange?.kind, .added)
        reader.markCurrentChangeReviewed()
        try await settle(reader)
        XCTAssertEqual(reader.changes.count, 1)
        reader.markCurrentChangeReviewed()
        try await settle(reader)
        XCTAssertEqual(reader.changes.count, 0)
        reader.acceptFileUpdate("# One\n\nNew.\n\n# Two\n\nNew.\n\nAdded again.")
        try await settle(reader)
        XCTAssertEqual(reader.changes.entries.first?.before, "Added.")
        reader.stop()
    }

    func testFormattingTablesAndImagePreferenceSurviveIndividualReview() async throws {
        let reader = makeReader("[Same](https://example.com/old)\n\n| A | B |\n|---|---|\n| One | Old |\n\n![Image](https://example.com/image.png)")
        reader.acceptFileUpdate("[Same](https://example.com/new)\n\n| A | B |\n|---|---|\n| One | New |\n\n![Image](https://example.com/image.png)")
        try await settle(reader)
        XCTAssertEqual(reader.changes.count, 2)
        reader.markCurrentChangeReviewed()
        try await settle(reader)
        reader.loadRemoteImages = true
        reader.documentAppearance = .dark
        reader.render()
        try await settle(reader)
        XCTAssertEqual(reader.changes.count, 1, "Image policy must not resurrect reviewed changes or add false ones")
        XCTAssertTrue(reader.selectedChange?.before.contains("Old") == true)
        reader.markCurrentChangeReviewed()
        try await settle(reader)
        let document = try SwiftSoup.parse(reader.rendered!.html)
        XCTAssertEqual(reader.changes.count, 0)
        XCTAssertEqual(try document.select("td").size(), 2)
        XCTAssertEqual(try document.select("a").attr("href"), "https://example.com/new")
        reader.stop()
    }

    func testDeletionOnlyNavigationAndReviewNeverWriteFile() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let text = "# Deleted\n\nOld paragraph."
        try text.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let reader = makeReader(text)
        reader.fileURL = file
        reader.acceptFileUpdate("")
        try await settle(reader)
        reader.jumpToChange()
        XCTAssertEqual(reader.selectedChange?.before, "Old paragraph.")
        XCTAssertNil(reader.selectedChange?.targetID)
        reader.markCurrentChangeReviewed()
        try await settle(reader)
        reader.markCurrentChangeReviewed()
        try await settle(reader)
        XCTAssertEqual(reader.changes.count, 0)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text)
        reader.stop()
    }

    func testRapidReviewClickCannotAcknowledgeAnotherChange() async throws {
        let reader = makeReader("# One\n\nOld one.\n\n# Two\n\nOld two.")
        reader.acceptFileUpdate("# One\n\nNew one.\n\n# Two\n\nNew two.")
        try await settle(reader)
        reader.markCurrentChangeReviewed()
        reader.markCurrentChangeReviewed()
        try await settle(reader)
        XCTAssertEqual(reader.changes.count, 1)
        reader.stop()
    }

    func testAdjacentChangesReviewedOutOfOrderAndSaveDuringReview() async throws {
        let reader = makeReader("Old block.\n\n# End\n\nDelete this.")
        reader.acceptFileUpdate("Edited block.\n\nAdded A.\n\nAdded B.\n\n# End")
        try await settle(reader)
        XCTAssertEqual(reader.changes.count, 4)
        for text in ["Added B.", "Added A.", "Edited block."] {
            reader.currentChangeIndex = try XCTUnwrap(reader.changes.entries.firstIndex { $0.after == text })
            reader.markCurrentChangeReviewed()
            try await settle(reader)
        }
        XCTAssertEqual(reader.changes.count, 1)
        XCTAssertEqual(reader.selectedChange?.kind, .removed)
        reader.markCurrentChangeReviewed()
        // A fresh save may arrive before the acknowledgement render finishes.
        reader.acceptFileUpdate("Newest block.\n\nAdded A.\n\nAdded B.\n\n# End")
        try await settle(reader)
        XCTAssertEqual(reader.changes.count, 1)
        XCTAssertEqual(reader.selectedChange?.before, "Edited block.")
        XCTAssertEqual(reader.selectedChange?.after, "Newest block.")
        reader.stop()
    }

    func testChangeShortcutOpensReviewForADeletionWithoutMovingSource() async throws {
        let reader = makeReader("# Notes\n\nDeleted paragraph.\n\nKeep.")
        reader.acceptFileUpdate("# Notes\n\nKeep.")
        try await settle(reader)
        reader.jumpToChange(focus:true)
        XCTAssertEqual(reader.selectedChange?.kind,.removed)
        XCTAssertTrue(reader.showChanges,"A removed change has no document target; its review must become reachable")
        XCTAssertEqual(reader.source,"# Notes\n\nKeep.")
        reader.stop()
    }

    private func makeReader(_ text: String) -> ReaderState {
        let reader = ReaderState()
        reader.fileURL = URL(fileURLWithPath: "/tmp/review-\(UUID().uuidString).md")
        reader.source = text
        return reader
    }

    private func settle(_ reader: ReaderState) async throws {
        for _ in 0..<200 {
            if !reader.isRendering {
                XCTAssertNil(reader.errorMessage)
                XCTAssertNotNil(reader.rendered)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Render did not finish")
    }
}

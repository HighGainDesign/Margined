import XCTest
@testable import MarginediOS

@MainActor
final class MobileReaderTests: XCTestCase {
    private func file(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data(text.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testFirstClickCancelDoesNotWriteAndConsentSupportsUndoRedo() async throws {
        let url = try file("# Tasks\n\n- [ ] Review the scope\n")
        let reader = MobileReaderState()
        await reader.open(url: url); await reader.waitForRendering()
        let task = try XCTUnwrap(reader.rendered?.tasks.first)
        XCTAssertTrue(reader.requestTaskChecked(task.id, checked: true))
        XCTAssertTrue(reader.showChecklistConfirmation)
        reader.cancelChecklistConfirmation()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), reader.source)
        XCTAssertTrue(reader.requestTaskChecked(task.id, checked: true))
        reader.confirmChecklistSaving(); await reader.waitForSaving(); await reader.waitForRendering()
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("[x]"))
        XCTAssertTrue(reader.canUndoChecklist)
        reader.undoChecklist(); await reader.waitForSaving(); await reader.waitForRendering()
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("[ ]"))
        reader.redoChecklist(); await reader.waitForSaving(); await reader.waitForRendering()
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("[x]"))
        await reader.close()
    }

    func testPausedUpdateRetainsSourceThenReviewsIndividualChanges() async throws {
        let url = try file("# Original\n\nOld text.\n")
        let reader = MobileReaderState()
        await reader.open(url: url); await reader.waitForRendering()
        reader.setFileUpdatesPaused(true)
        try Data("# Original\n\nNew text.\n\nAdded paragraph.\n".utf8).write(to: url, options: .atomic)
        await reader.refresh()
        XCTAssertTrue(reader.source.contains("Old text"))
        XCTAssertTrue(reader.hasPendingFileUpdate)
        reader.setFileUpdatesPaused(false); await reader.waitForRendering()
        XCTAssertTrue(reader.source.contains("New text"))
        let count = reader.changes.count
        XCTAssertGreaterThan(count, 1)
        reader.markCurrentChangeReviewed(); await reader.waitForRendering()
        XCTAssertEqual(reader.changes.count, count - 1)
        reader.markAllReviewed(); await reader.waitForRendering()
        XCTAssertEqual(reader.changes.count, 0)
        await reader.close()
    }

    func testSnapshotCannotSaveAndExplicitOpenResetsConsent() async throws {
        let reader = MobileReaderState()
        var parts = URLComponents(string: "margined://preview")!
        parts.queryItems = [.init(name: "text", value: "- [ ] Snapshot"), .init(name: "title", value: "Draft")]
        await reader.openPreview(url: parts.url!); await reader.waitForRendering()
        XCTAssertNil(reader.fileURL)
        XCTAssertFalse(reader.requestTaskChecked(0, checked: true))
        let url = try file("- [ ] A")
        await reader.open(url: url); await reader.waitForRendering()
        XCTAssertFalse(reader.checklistMode)
        XCTAssertEqual(reader.title, url.lastPathComponent)
        await reader.close()
    }
    func testConsentedTickCompletesWhenDocumentClosesImmediately() async throws {
        let url = try file("- [ ] Accepted change\n")
        let reader = MobileReaderState()
        await reader.open(url: url); await reader.waitForRendering()
        let task = try XCTUnwrap(reader.rendered?.tasks.first)
        XCTAssertTrue(reader.requestTaskChecked(task.id, checked: true))
        reader.confirmChecklistSaving()
        await reader.close()
        await reader.waitForSaving()
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("[x]"))
        XCTAssertFalse(reader.hasDocument)
    }

    func testOpeningAnotherDocumentClearsNavigationAndSearchIntent() async throws {
        let reader = MobileReaderState()
        var parts = URLComponents(string: "margined://preview")!
        parts.queryItems = [.init(name: "text", value: "# Top\n\n## Later\n")]
        await reader.openPreview(url: parts.url!); await reader.waitForRendering()
        reader.navigate(to: "later")
        reader.searchText = "old search"
        let oldGeneration = reader.documentGeneration
        await reader.openPreview(url: parts.url!); await reader.waitForRendering()
        XCTAssertNotEqual(reader.documentGeneration, oldGeneration)
        XCTAssertNil(reader.navigationTarget)
        XCTAssertEqual(reader.searchText, "")
        await reader.close()
    }

}

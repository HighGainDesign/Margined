import Foundation
import XCTest
@testable import Margined

@MainActor
final class ChecklistStateTests: XCTestCase {
    func testExplicitModeRequiredAndUndoRedoPreserveUppercaseMarker() async throws {
        let source = "- [X] First\n- [ ] Second\n"
        let (reader, file) = try makeReader(source)
        defer { reader.stop(); try? FileManager.default.removeItem(at: file) }
        reader.render(); try await settle(reader)
        reader.setTaskChecked(0, checked: false)
        try await settle(reader)
        XCTAssertEqual(try MarkdownSource.read(file), source)
        reader.checklistMode = true
        reader.setTaskChecked(0, checked: false)
        try await settle(reader)
        XCTAssertEqual(try MarkdownSource.read(file), "- [ ] First\n- [ ] Second\n")
        XCTAssertTrue(reader.canUndoChecklist)
        reader.undoChecklist(); try await settle(reader)
        XCTAssertEqual(try MarkdownSource.read(file), source)
        XCTAssertTrue(reader.canRedoChecklist)
        reader.redoChecklist(); try await settle(reader)
        XCTAssertEqual(try MarkdownSource.read(file), "- [ ] First\n- [ ] Second\n")
        reader.setTaskChecked(1, checked: true); try await settle(reader)
        reader.undoChecklist(); try await settle(reader)
        reader.undoChecklist(); try await settle(reader)
        XCTAssertEqual(try MarkdownSource.read(file), source)
    }

    func testAgentEditRejectsClickWithoutLosingItsText() async throws {
        let source = "- [ ] Agent task\n"
        let (reader, file) = try makeReader(source)
        defer { reader.stop(); try? FileManager.default.removeItem(at: file) }
        reader.render(); try await settle(reader); reader.checklistMode = true
        let agent = "- [ ] Agent renamed task\n"
        try agent.write(to: file, atomically: true, encoding: .utf8)
        reader.setTaskChecked(0, checked: true)
        try await settle(reader)
        XCTAssertEqual(try MarkdownSource.read(file), agent)
        XCTAssertNotNil(reader.checklistError)
        for _ in 0..<100 where reader.source != agent { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(reader.source, agent)
        XCTAssertFalse(reader.canUndoChecklist)
        reader.checklistMode = false
        XCTAssertNil(reader.checklistError)
    }

    func testExternalRefreshClearsHistoryAndSnapshotsCannotWrite() async throws {
        let source = "- [ ] First\n"
        let (reader, file) = try makeReader(source)
        defer { reader.stop(); try? FileManager.default.removeItem(at: file) }
        reader.render(); try await settle(reader); reader.checklistMode = true
        reader.setTaskChecked(0, checked: true); try await settle(reader)
        XCTAssertTrue(reader.canUndoChecklist)
        reader.acceptFileUpdate("- [x] First\n\nAgent addition."); try await settle(reader)
        XCTAssertFalse(reader.canUndoChecklist)
        let snapshot = ReaderState(); snapshot.source = source; snapshot.checklistMode = true
        snapshot.render(); try await settle(snapshot)
        XCTAssertTrue(snapshot.rendered?.tasks.isEmpty == true)
        snapshot.setTaskChecked(0, checked: true)
        XCTAssertFalse(snapshot.checklistSaving)
        snapshot.stop()
    }

    func testClosingWaitsForCommittedCheckboxWrite() async throws {
        let source = "- [ ] Save before closing\n"
        let (_, file) = try makeReader(source)
        defer { try? FileManager.default.removeItem(at: file) }
        let document = MarkdownDocument()
        document.reader.fileURL = file; document.reader.source = source
        document.reader.render(); try await settle(document.reader)
        document.reader.checklistMode = true
        document.reader.setTaskChecked(0, checked: true)
        XCTAssertTrue(document.reader.checklistSaving)
        document.close()
        document.close()
        XCTAssertTrue(document.reader.checklistMode)
        try await settle(document.reader)
        for _ in 0..<100 where document.reader.checklistMode { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(document.reader.checklistMode)
        XCTAssertEqual(try MarkdownSource.read(file), "- [x] Save before closing\n")
    }

    func testFirstClickCancelAndConfirmApplyOnlyThePendingGesture() async throws {
        let source = "- [ ] First\n- [ ] Second\n"
        let (reader, file) = try makeReader(source)
        defer { reader.stop(); try? FileManager.default.removeItem(at: file) }
        reader.render(); try await settle(reader)
        reader.requestTaskChecked(0, checked: true)
        XCTAssertTrue(reader.showChecklistConfirmation)
        XCTAssertFalse(reader.checklistMode)
        XCTAssertEqual(try MarkdownSource.read(file), source)
        reader.cancelChecklistConfirmation()
        XCTAssertNil(reader.pendingChecklistConfirmation)
        XCTAssertEqual(try MarkdownSource.read(file), source)
        reader.requestTaskChecked(0, checked: true)
        reader.confirmChecklistSaving(); try await settle(reader)
        XCTAssertTrue(reader.checklistMode)
        XCTAssertFalse(reader.showChecklistConfirmation)
        XCTAssertEqual(try MarkdownSource.read(file), "- [x] First\n- [ ] Second\n")
        reader.requestTaskChecked(1, checked: true); try await settle(reader)
        XCTAssertFalse(reader.showChecklistConfirmation)
        XCTAssertEqual(try MarkdownSource.read(file), "- [x] First\n- [x] Second\n")
        reader.undoChecklist(); try await settle(reader)
        XCTAssertEqual(try MarkdownSource.read(file), "- [x] First\n- [ ] Second\n")
    }

    func testAgentEditDuringConsentCannotCheckADifferentTask() async throws {
        let source = "- [ ] Original\n"
        let (reader, file) = try makeReader(source)
        defer { reader.stop(); try? FileManager.default.removeItem(at: file) }
        reader.render(); try await settle(reader)
        reader.requestTaskChecked(0, checked: true)
        let updated = "- [ ] A different task from the agent\n"
        try updated.write(to: file, atomically: true, encoding: .utf8)
        reader.acceptFileUpdate(updated); try await settle(reader)
        reader.confirmChecklistSaving(); try await settle(reader)
        XCTAssertEqual(try MarkdownSource.read(file), updated)
        XCTAssertNotNil(reader.checklistError)
        XCTAssertFalse(reader.canUndoChecklist)
    }

    func testSnapshotsAndStoppedReadersCannotRequestWriteConsent() async throws {
        let reader = ReaderState(); reader.source = "- [ ] Snapshot\n"
        reader.render(); try await settle(reader)
        reader.requestTaskChecked(0, checked: true)
        XCTAssertFalse(reader.showChecklistConfirmation)
        let (fileReader, file) = try makeReader(reader.source)
        defer { try? FileManager.default.removeItem(at: file) }
        fileReader.render(); try await settle(fileReader)
        fileReader.requestTaskChecked(0, checked: true)
        XCTAssertTrue(fileReader.showChecklistConfirmation)
        fileReader.stop()
        XCTAssertFalse(fileReader.showChecklistConfirmation)
        XCTAssertNil(fileReader.pendingChecklistConfirmation)
        fileReader.confirmChecklistSaving()
        XCTAssertEqual(try MarkdownSource.read(file), reader.source)
        reader.stop()
    }

    func testStoppingAnInFlightRenderClearsTheBusyState() {
        let reader = ReaderState(); reader.source = "A document being rendered."
        reader.render()
        XCTAssertTrue(reader.isRendering)
        reader.stop()
        XCTAssertFalse(reader.isRendering, "A cancelled render must not leave a closed reader busy forever")
    }

    private func makeReader(_ source: String) throws -> (ReaderState, URL) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let reader = ReaderState(); reader.fileURL = file; reader.source = source
        return (reader, file)
    }

    private func settle(_ reader: ReaderState) async throws {
        for _ in 0..<300 {
            if !reader.checklistSaving && !reader.isRendering { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Checklist operation did not settle")
    }
}

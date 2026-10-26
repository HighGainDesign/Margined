import XCTest
@testable import Margined

@MainActor
final class ReaderUpdatesTests: XCTestCase {
    func testPauseKeepsDisplayedDocumentAndReviewBaselineUntilLatestResume() async throws {
        let reader = ReaderState()
        reader.fileURL = URL(fileURLWithPath: "/tmp/update-state.md")
        reader.source = "# Notes\n\nOriginal.\n"
        reader.render(); try await settle(reader)
        reader.setFileUpdatesPaused(true)
        reader.receiveFileUpdate("# Notes\n\nIntermediate.\n")
        reader.receiveFileUpdate("# Notes\n\nLatest.\n")
        XCTAssertEqual(reader.source, "# Notes\n\nOriginal.\n")
        XCTAssertEqual(reader.changes.count, 0)
        XCTAssertTrue(reader.hasPendingFileUpdate)
        reader.setFileUpdatesPaused(false); try await settle(reader)
        XCTAssertEqual(reader.source, "# Notes\n\nLatest.\n")
        XCTAssertEqual(reader.changes.count, 1)
        XCTAssertEqual(reader.selectedChange?.before, "Original.")
        XCTAssertEqual(reader.selectedChange?.after, "Latest.")
        XCTAssertFalse(reader.hasPendingFileUpdate)
        reader.stop()
    }

    func testRevertingWhilePausedClearsPendingWithoutChangingDisplay() async throws {
        let reader = ReaderState(); reader.fileURL = URL(fileURLWithPath: "/tmp/revert-state.md")
        reader.source = "Original\n"; reader.render(); try await settle(reader)
        reader.setFileUpdatesPaused(true)
        reader.receiveFileUpdate("New\n")
        XCTAssertTrue(reader.hasPendingFileUpdate)
        reader.receiveFileUpdate("Original\n")
        XCTAssertFalse(reader.hasPendingFileUpdate)
        reader.setFileUpdatesPaused(false); try await settle(reader)
        XCTAssertEqual(reader.source, "Original\n")
        XCTAssertEqual(reader.changes.count, 0)
        reader.stop()
    }

    func testPendingExternalUpdateInvalidatesUndoAndCannotSaveStaleCheckbox() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: file) }
        try "- [ ] First\n".write(to: file, atomically: true, encoding: .utf8)
        let reader = ReaderState(); reader.fileURL = file; reader.source = "- [ ] First\n"
        reader.render(); try await settle(reader); reader.checklistMode = true
        reader.setTaskChecked(0, checked: true); try await settle(reader)
        XCTAssertTrue(reader.canUndoChecklist)
        reader.setFileUpdatesPaused(true)
        let updated = "- [ ] Agent renamed task\n"
        try updated.write(to: file, atomically: true, encoding: .utf8)
        reader.receiveFileUpdate(updated)
        XCTAssertFalse(reader.canUndoChecklist)
        XCTAssertTrue(reader.hasPendingFileUpdate)
        XCTAssertFalse(reader.requestTaskChecked(0, checked: false))
        reader.setTaskChecked(0, checked: false); try await settle(reader)
        XCTAssertEqual(try MarkdownSource.read(file), updated)
        XCTAssertEqual(reader.source, "- [x] First\n")
        reader.setFileUpdatesPaused(false); try await settle(reader)
        XCTAssertEqual(reader.source, updated)
        reader.stop()
    }

    func testOwnChecklistSaveAppliesWhilePausedWithoutUnpausing() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: file) }
        try "- [ ] First\n".write(to: file, atomically: true, encoding: .utf8)
        let reader = ReaderState(); reader.fileURL = file; reader.source = "- [ ] First\n"
        reader.render(); try await settle(reader); reader.checklistMode = true
        reader.setFileUpdatesPaused(true)
        reader.setTaskChecked(0, checked: true); try await settle(reader)
        XCTAssertEqual(reader.source, "- [x] First\n")
        XCTAssertTrue(reader.fileUpdatesPaused)
        reader.receiveFileUpdate(reader.source)
        XCTAssertFalse(reader.hasPendingFileUpdate)
        reader.stop()
    }

    func testPauseIsFileOnlyAndFileSwitchDropsOldPendingText() {
        let reader = ReaderState(); reader.source = "Snapshot"
        reader.setFileUpdatesPaused(true)
        XCTAssertFalse(reader.fileUpdatesPaused)
        reader.receiveFileUpdate("Unrelated")
        XCTAssertEqual(reader.source, "Snapshot")
        reader.fileURL = URL(fileURLWithPath: "/tmp/first.md")
        reader.setFileUpdatesPaused(true); reader.receiveFileUpdate("Old pending")
        reader.fileURL = URL(fileURLWithPath: "/tmp/second.md")
        XCTAssertFalse(reader.fileUpdatesPaused)
        XCTAssertFalse(reader.hasPendingFileUpdate)
        reader.isStreamingPreview = true
        reader.setFileUpdatesPaused(true)
        XCTAssertFalse(reader.fileUpdatesPaused)
        reader.stop()
    }

    func testExternalUpdateDuringConsentWhilePausedReportsConflictWithoutWriting() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: file) }
        let reader = ReaderState(); reader.fileURL = file; reader.source = "- [ ] Original\n"
        try reader.source.write(to: file, atomically: true, encoding: .utf8)
        reader.render(); try await settle(reader)
        reader.requestTaskChecked(0, checked: true)
        reader.setFileUpdatesPaused(true)
        try "- [ ] Renamed\n".write(to: file, atomically: true, encoding: .utf8)
        reader.receiveFileUpdate("- [ ] Renamed\n")
        reader.confirmChecklistSaving(); try await settle(reader)
        XCTAssertNotNil(reader.checklistError)
        XCTAssertEqual(reader.source, "- [ ] Original\n")
        XCTAssertEqual(try MarkdownSource.read(file), "- [ ] Renamed\n")
        reader.stop()
    }

    func testWatcherAndReloadRespectPauseAcrossAtomicReplacement() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: file) }
        let reader = ReaderState(); reader.fileURL = file; reader.source = "Original\n"
        try reader.source.write(to: file, atomically: true, encoding: .utf8)
        let watcher = Task { await reader.watchFile() }
        defer { watcher.cancel(); reader.stop() }
        for _ in 0..<100 where reader.rendered == nil { try await Task.sleep(for: .milliseconds(20)) }
        reader.setFileUpdatesPaused(true)
        try "Agent replacement\n".write(to: file, atomically: true, encoding: .utf8)
        for _ in 0..<150 where !reader.hasPendingFileUpdate { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(reader.hasPendingFileUpdate)
        XCTAssertEqual(reader.source, "Original\n")
        try "Latest replacement\n".write(to: file, atomically: true, encoding: .utf8)
        reader.reload()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(reader.source, "Original\n")
        reader.setFileUpdatesPaused(false)
        for _ in 0..<150 where reader.source != "Latest replacement\n" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(reader.source, "Latest replacement\n")
        XCTAssertFalse(reader.hasPendingFileUpdate)
        XCTAssertNil(reader.errorMessage)
    }

    func testLateSaveCompletionCannotReplaceNewerAgentTextOrRestoreStaleUndo() async throws {
        for scenario in 0..<4 {
            let pauseThenResume = scenario % 2 == 1
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
            defer { try? FileManager.default.removeItem(at:file) }
            let gate = SaveResultGate()
            let reader = ReaderState(checklistWriter: { url,source,task,marker in
                let result = try await ChecklistFileStore.setMarker(at:url,source:source,task:task,marker:marker)
                await gate.holdResult()
                return result
            })
            defer { gate.release(); reader.stop() }
            reader.fileURL = file; reader.source = "- [ ] Original\n"
            try reader.source.write(to:file,atomically:true,encoding:.utf8)
            reader.render(); try await settle(reader); reader.checklistMode = true
            reader.setFileUpdatesPaused(pauseThenResume)
            reader.setTaskChecked(0,checked:true)
            for _ in 0..<200 where !gate.waiting { try await Task.sleep(for:.milliseconds(10)) }
            XCTAssertTrue(gate.waiting)
            XCTAssertEqual(try MarkdownSource.read(file),"- [x] Original\n")
            let agent = scenario < 2 ? "- [ ] New task from agent\n" : "- [ ] Original\n"
            try agent.write(to:file,atomically:true,encoding:.utf8)
            reader.receiveFileUpdate(agent)
            if pauseThenResume { reader.setFileUpdatesPaused(false) }
            gate.release(); try await settle(reader)
            XCTAssertEqual(reader.source,agent,"A completed old write must not replace a newer displayed update")
            XCTAssertEqual(try MarkdownSource.read(file),agent)
            XCTAssertFalse(reader.canUndoChecklist,"Late completion must not revive obsolete history")
        }
    }

    @MainActor private final class SaveResultGate {
        var waiting = false
        private var continuation: CheckedContinuation<Void,Never>?
        func holdResult() async {
            waiting = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    func testStoppingTheReaderEndsObservationWithoutPublishingLaterSaves() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let source = "# Closed document\n"
        try source.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let reader = ReaderState(); reader.fileURL = file; reader.source = source
        reader.installLoadedSnapshot(try SourceFileEdit.read(file))
        var finished = false
        let watcher = Task { await reader.watchFile(); finished = true }
        defer { watcher.cancel(); reader.stop() }
        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while (reader.rendered == nil || reader.isRendering) && ContinuousClock.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let ready = reader.rendered != nil && !reader.isRendering
        XCTAssertTrue(ready, "Start the actual observation before testing its close fence")
        guard ready else { watcher.cancel(); await watcher.value; return }
        reader.stop()
        try "# Saved after close\n".write(to: file, atomically: true, encoding: .utf8)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !finished && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(finished, "A closed reader must release its file observation even when the URL is unchanged")
        XCTAssertEqual(reader.source, source)
        XCTAssertNil(reader.errorMessage)
        watcher.cancel(); await watcher.value
    }

    private func settle(_ reader: ReaderState) async throws {
        for _ in 0..<300 {
            if !reader.isRendering && !reader.checklistSaving { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Reader operation did not settle")
    }
}

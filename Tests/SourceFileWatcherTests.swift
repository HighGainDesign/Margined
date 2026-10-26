import XCTest
@testable import Margined

@MainActor
final class SourceFileWatcherTests: XCTestCase {
    func testWatcherRefreshesAtomicSaveWithinHalfASecond() async throws {
        try await assertFastRefresh(atomic: true)
    }

    func testWatcherRefreshesInPlaceSaveWithinHalfASecond() async throws {
        try await assertFastRefresh(atomic: false)
    }

    func testWatcherFollowsRepeatedAtomicSavesAndThenInPlaceWrites() async throws {
        let f = try await liveReader()
        defer { dispose(f) }
        for index in 1...3 {
            let source = "# Refresh\n\nAtomic \(index).\n"
            try source.write(to: f.file, atomically: true, encoding: .utf8)
            let updated = try await wait(timeout: .milliseconds(500)) { f.reader.source == source }
            XCTAssertTrue(updated, "Every replacement must rearm observation of this pathname")
        }
        let source = "# Refresh\n\nAn in-place save after the replacements.\n"
        try writeInPlace(source, to: f.file)
        let updated = try await wait(timeout: .milliseconds(500)) { f.reader.source == source }
        XCTAssertTrue(updated, "The replacement inode must receive subsequent in-place changes")
        XCTAssertNil(f.reader.errorMessage)
    }

    func testWatcherFollowsASymlinkIntoAnotherDirectory() async throws {
        let f = try await liveReader(symlink: true)
        defer { dispose(f) }
        let target = f.folder.appendingPathComponent("assets/target.md")
        for atomic in [true, false] {
            let source = atomic ? "# Replaced target\n" : "# Updated target in place\n"
            if atomic { try source.write(to: target, atomically: true, encoding: .utf8) }
            else { try writeInPlace(source, to: target) }
            let updated = try await wait(timeout: .milliseconds(500)) { f.reader.source == source }
            XCTAssertTrue(updated, "A linked document must follow its target across replacement and later writes")
        }
        XCTAssertEqual(f.reader.fileURL, f.file)
        XCTAssertNil(f.reader.errorMessage)
    }

    func testWatcherRecoversAfterDeletionAndRecreation() async throws {
        let f = try await liveReader()
        defer { dispose(f) }
        try FileManager.default.removeItem(at: f.file)
        let missing = try await wait { f.reader.errorMessage != nil }
        XCTAssertTrue(missing)
        let source = "# Recovered\n\nThe same path exists again.\n"
        try source.write(to: f.file, atomically: true, encoding: .utf8)
        let recovered = try await wait(timeout: .milliseconds(500)) { f.reader.source == source && f.reader.errorMessage == nil }
        XCTAssertTrue(recovered)
    }

    func testWatcherKeepsLatestPausedSourceAndRecognizesAReversion() async throws {
        let f = try await liveReader()
        defer { dispose(f) }
        let original = f.reader.source
        f.reader.setFileUpdatesPaused(true)
        try "# Intermediate\n".write(to: f.file, atomically: true, encoding: .utf8)
        let pending = try await wait(timeout: .milliseconds(500)) { f.reader.hasPendingFileUpdate }
        XCTAssertTrue(pending)
        XCTAssertEqual(f.reader.source, original)
        let latest = "# Latest saved version\n"
        try latest.write(to: f.file, atomically: true, encoding: .utf8)
        f.reader.setFileUpdatesPaused(false)
        let resumed = try await wait(timeout: .milliseconds(500)) { f.reader.source == latest }
        XCTAssertTrue(resumed)
        f.reader.setFileUpdatesPaused(true)
        try "# A pending edit\n".write(to: f.file, atomically: true, encoding: .utf8)
        let waiting = try await wait(timeout: .milliseconds(500)) { f.reader.hasPendingFileUpdate }
        XCTAssertTrue(waiting)
        try latest.write(to: f.file, atomically: true, encoding: .utf8)
        let reverted = try await wait(timeout: .milliseconds(500)) { !f.reader.hasPendingFileUpdate }
        XCTAssertTrue(reverted)
        f.reader.setFileUpdatesPaused(false)
        XCTAssertEqual(f.reader.source, latest)
    }

    func testOwnChecklistWritesAndUndoSurviveWatcherEchoes() async throws {
        let source = "- [ ] Review this task\n"
        let f = try await liveReader(source: source)
        defer { dispose(f) }
        f.reader.checklistMode = true
        f.reader.setTaskChecked(0, checked: true)
        let saved = try await wait { !f.reader.checklistSaving && !f.reader.isRendering && f.reader.canUndoChecklist }
        XCTAssertTrue(saved)
        // Consume an idle backstop as well as the immediate in-place event.
        try await Task.sleep(for: .milliseconds(1_150))
        XCTAssertTrue(f.reader.canUndoChecklist)
        f.reader.undoChecklist()
        let undone = try await wait { !f.reader.checklistSaving && !f.reader.isRendering && f.reader.canRedoChecklist }
        XCTAssertTrue(undone)
        XCTAssertEqual(try MarkdownSource.read(f.file), source)
        f.reader.redoChecklist()
        let redone = try await wait { !f.reader.checklistSaving && !f.reader.isRendering && f.reader.canUndoChecklist }
        XCTAssertTrue(redone)
        XCTAssertEqual(try MarkdownSource.read(f.file), "- [x] Review this task\n")
        XCTAssertNil(f.reader.checklistError)
    }

    func testWatcherReconcilesASaveBetweenLoadingAndSubscription() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("late-save.md")
        let original = "# Loaded version\n", saved = "# Saved before observation\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        let reader = ReaderState(); reader.fileURL = file; reader.source = original
        reader.installLoadedSnapshot(try SourceFileEdit.read(file))
        try saved.write(to: file, atomically: true, encoding: .utf8)
        let task = Task { await reader.watchFile() }
        defer { task.cancel(); reader.stop() }
        let updated = try await wait(timeout: .milliseconds(500)) { reader.source == saved }
        XCTAssertTrue(updated, "A save before kernel registration must not disappear into the initial stamp")
    }

    func testSlowConsumerRetainsAForcedReadAcrossTheBackstop() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("buffered.md")
        try "# Original\n".write(to: file, atomically: true, encoding: .utf8)
        let watcher = SourceFileWatcher(url: file)
        defer { watcher.cancel() }
        try "# Changed\n".write(to: file, atomically: true, encoding: .utf8)
        // Deliberate backpressure: do not consume until the 1-second idle timer.
        try await Task.sleep(for: .milliseconds(1_300))
        var iterator = watcher.events.makeAsyncIterator()
        let hint = await iterator.next()
        XCTAssertTrue(hint == .initial || hint == .change,
                      "An unread change must not be replaced by an idle backstop")
    }

    func testUnrelatedParentActivityDoesNotEmitDocumentChanges() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("document.md")
        try "# Unchanged\n".write(to: file, atomically: true, encoding: .utf8)
        let watcher = SourceFileWatcher(url: file)
        var hints: [SourceFileWatcher.Hint] = []
        var ended = false
        let consumer = Task {
            for await hint in watcher.events { hints.append(hint) }
            ended = true
        }
        defer { watcher.cancel(); consumer.cancel() }
        let ready = try await wait { hints.contains(.backstop) }
        XCTAssertTrue(ready, "The real observation and recovery timer must be active")
        hints.removeAll()
        try "Unrelated sibling".write(to: folder.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(hints.contains(.change))
        watcher.cancel()
        let finished = try await wait { ended }
        XCTAssertTrue(finished, "Cancellation must finish the consumer")
        consumer.cancel(); await consumer.value
    }

    func testCancelledWatcherCannotPublishIntoASamePathReopen() async throws {
        let f = try await liveReader()
        defer { dispose(f) }
        f.task.cancel()
        f.reader.fileURL = nil
        let reopened = "# Reopened document\n"
        try reopened.write(to: f.file, atomically: true, encoding: .utf8)
        f.reader.fileURL = f.file; f.reader.source = reopened
        f.reader.installLoadedSnapshot(try SourceFileEdit.read(f.file))
        let next = Task { await f.reader.watchFile() }
        defer { next.cancel() }
        await f.task.value
        let newest = "# New save after reopening\n"
        try newest.write(to: f.file, atomically: true, encoding: .utf8)
        let updated = try await wait(timeout: .milliseconds(500)) { f.reader.source == newest }
        XCTAssertTrue(updated)
        XCTAssertNil(f.reader.errorMessage)
    }

    private struct LiveReader {
        let reader: ReaderState
        let folder: URL
        let file: URL
        let task: Task<Void, Never>
    }
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    private func liveReader(source: String = "# Original\n", symlink: Bool = false) async throws -> LiveReader {
        let folder = try makeFolder(), file = folder.appendingPathComponent("document.md")
        if symlink {
            let assets = folder.appendingPathComponent("assets", isDirectory: true)
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            let target = assets.appendingPathComponent("target.md")
            try source.write(to: target, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        } else { try source.write(to: file, atomically: true, encoding: .utf8) }
        let reader = ReaderState(); reader.fileURL = file; reader.source = source
        reader.installLoadedSnapshot(try SourceFileEdit.read(file))
        let task = Task { await reader.watchFile() }
        let rendered = try await wait { reader.rendered != nil && !reader.isRendering }
        XCTAssertTrue(rendered)
        try await Task.sleep(for: .milliseconds(60))
        return .init(reader: reader, folder: folder, file: file, task: task)
    }
    private func dispose(_ f: LiveReader) {
        f.task.cancel(); f.reader.stop()
        try? FileManager.default.removeItem(at: f.folder)
    }
    private func writeInPlace(_ source: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(source.utf8)); try handle.synchronize()
    }
    private func wait(timeout: Duration = .seconds(3), _ predicate: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !predicate() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return predicate()
    }

    private func assertFastRefresh(atomic: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("refresh.md")
        let original = "# Refresh test\n\nOriginal.\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        let reader = ReaderState(); reader.fileURL = file; reader.source = original
        reader.installLoadedSnapshot(try SourceFileEdit.read(file))
        let watcher = Task { await reader.watchFile() }
        defer { watcher.cancel(); reader.stop() }
        for _ in 0..<150 where reader.rendered == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(reader.rendered)
        try await Task.sleep(for: .milliseconds(60))
        let updated = "# Refresh test\n\nUpdated by agent.\n"
        let start = ContinuousClock.now
        if atomic {
            try updated.write(to: file, atomically: true, encoding: .utf8)
        } else {
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(updated.utf8))
            try handle.synchronize(); try handle.close()
        }
        let deadline = start.advanced(by: .milliseconds(500))
        while reader.source != updated && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(reader.source, updated, "Saved local Markdown must refresh within 500 ms")
        XCTAssertNil(reader.errorMessage)
    }
}

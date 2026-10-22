import Foundation
import XCTest
@testable import MDViewiOS

@MainActor
final class MobileDocumentTests: XCTestCase {
    func testUTF8AndBOMUTF16OpenAndMarkerWritePreserveExactBytes() async throws {
        let source = "# 日本語\r\n- [X] Completed\r\n"
        let fixtures = [
            Data(source.utf8),
            Data([239, 187, 191]) + Data(source.utf8),
            Data([255, 254]) + source.data(using: .utf16LittleEndian)!,
            Data([254, 255]) + source.data(using: .utf16BigEndian)!
        ]
        for bytes in fixtures {
            let file = try fixture(bytes)
            defer { try? FileManager.default.removeItem(at: file) }
            let access = MobileDocumentAccess()
            let opened = try await access.open(url: file)
            XCTAssertEqual(opened.source, source)
            XCTAssertEqual(opened.data, bytes)
            let task = MarkdownTask(id: 0, utf8Offset: Array(source.utf8).firstIndex(of: 88)!, marker: 88, label: "Completed")
            let saved = try await access.write(leaseID: opened.leaseID, task: task, marker: 32, expectedSource: source)
            XCTAssertEqual(saved.source, "# 日本語\r\n- [ ] Completed\r\n")
            let actual = try Data(contentsOf: file)
            XCTAssertEqual(actual, saved.data)
            XCTAssertEqual(actual.count, bytes.count)
            XCTAssertEqual(zip(bytes, actual).filter { $0 != $1 }.count, 1)
            await access.close()
        }
    }

    func testExternalReplacementRefusesStaleWriteAndRefreshesCurrentBytes() async throws {
        let file = try fixture(Data("- [ ] Original\n".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let access = MobileDocumentAccess()
        let opened = try await access.open(url: file)
        let external = Data("- [ ] Agent replacement\n".utf8)
        try external.write(to: file, options: .atomic)
        do {
            _ = try await access.write(leaseID: opened.leaseID, task: task(), marker: 120, expectedSource: opened.source)
            XCTFail("A click from the replaced version must not save")
        } catch { XCTAssertEqual(try Data(contentsOf: file), external) }
        let refreshed = try await access.refresh()
        XCTAssertEqual(refreshed.data, external)
        await access.close()
    }

    func testChangingEncodingWithIdenticalTextStillRefusesOldSnapshotWrite() async throws {
        let file = try fixture(Data("- [ ] Task\n".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let access = MobileDocumentAccess()
        let opened = try await access.open(url: file)
        let replacement = Data([255, 254]) + opened.source.data(using: .utf16LittleEndian)!
        try replacement.write(to: file, options: .atomic)
        do {
            _ = try await access.write(leaseID: opened.leaseID, task: task(), marker: 120, expectedSource: opened.source)
            XCTFail("Identical decoded text does not authorize changed bytes")
        } catch { XCTAssertEqual(try Data(contentsOf: file), replacement) }
        await access.close()
    }

    func testOversizedAndInvalidEncodingFilesAreRejected() async throws {
        for data in [Data(repeating: 65, count: MarkdownSource.maximumBytes + 1), Data([0xff, 0x80, 0x01])] {
            let file = try fixture(data)
            defer { try? FileManager.default.removeItem(at: file) }
            let access = MobileDocumentAccess()
            do {
                _ = try await access.open(url: file)
                XCTFail("Unreadable sources must be rejected before rendering")
            } catch { }
            await access.close()
        }
    }

    func testClosedLeaseCannotWriteReopenedIdenticalDocument() async throws {
        let file = try fixture(Data("- [ ] Task\n".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let access = MobileDocumentAccess()
        let original = try await access.open(url: file)
        await access.close()
        let reopened = try await access.open(url: file)
        XCTAssertNotEqual(original.leaseID, reopened.leaseID)
        do {
            _ = try await access.write(leaseID: original.leaseID, task: task(), marker: 120, expectedSource: original.source)
            XCTFail("A closed lease cannot acquire a replacement document")
        } catch { XCTAssertEqual(try Data(contentsOf: file), Data("- [ ] Task\n".utf8)) }
        await access.close()
    }

    func testAcceptedWriteKeepsOriginalLeaseWhenIdenticalDocumentOpens() async throws {
        let first = try fixture(Data("- [ ] Task\n".utf8))
        let second = try fixture(Data("- [ ] Task\n".utf8))
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let gate = DocumentOperationGate(block: .write)
        defer { gate.resume.signal() }
        let access = MobileDocumentAccess(environment: gate.environment)
        let original = try await access.open(url: first)
        let writing = Task { try await access.write(leaseID: original.leaseID, task: task(), marker: 120, expectedSource: original.source) }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered)
        let replacement = try await access.open(url: second)
        XCTAssertNotEqual(replacement.leaseID, original.leaseID)
        XCTAssertFalse(gate.stopped(first), "The original accepted write still owns its scope")
        gate.resume.signal()
        let saved = try await writing.value
        XCTAssertEqual(saved.leaseID, original.leaseID)
        XCTAssertEqual(try Data(contentsOf: first), Data("- [x] Task\n".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("- [ ] Task\n".utf8))
        XCTAssertEqual(access.snapshot?.leaseID, replacement.leaseID)
        await access.close()
        XCTAssertTrue(gate.stopped(first))
        XCTAssertTrue(gate.stopped(second))
    }

    func testCloseDrainsAcceptedWriteBeforeReleasingScopeAndPresenter() async throws {
        let file = try fixture(Data("- [ ] Task\n".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let gate = DocumentOperationGate(block: .write)
        defer { gate.resume.signal() }
        let access = MobileDocumentAccess(environment: gate.environment)
        let opened = try await access.open(url: file)
        let writing = Task { try await access.write(leaseID: opened.leaseID, task: task(), marker: 120, expectedSource: opened.source) }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered)
        let closing = Task { await access.close() }
        await Task.yield()
        XCTAssertFalse(gate.stopped(file))
        XCTAssertTrue(NSFileCoordinator.filePresenters.contains { $0.presentedItemURL == file })
        gate.resume.signal()
        _ = try await writing.value
        await closing.value
        XCTAssertEqual(try Data(contentsOf: file), Data("- [x] Task\n".utf8))
        XCTAssertTrue(gate.stopped(file))
        XCTAssertFalse(NSFileCoordinator.filePresenters.contains { $0.presentedItemURL == file })
    }

    func testOwnWriteEchoIsSuppressedAndExternalDifferingBytesNotify() async throws {
        let file = try fixture(Data("- [ ] Task\n".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let access = MobileDocumentAccess()
        let opened = try await access.open(url: file)
        var changes: [MobileDocumentSnapshot] = []
        access.onChange = { changes.append($0) }
        _ = try await access.write(leaseID: opened.leaseID, task: task(), marker: 120, expectedSource: opened.source)
        let presenter = try XCTUnwrap(NSFileCoordinator.filePresenters.first { $0.presentedItemURL == file })
        presenter.presentedItemDidChange?()
        _ = try await access.refresh()
        XCTAssertTrue(changes.isEmpty, "An own-save echo must preserve checklist Undo")
        try Data("- [x] Task\nAgent addition\n".utf8).write(to: file, options: .atomic)
        let external = try await access.refresh()
        XCTAssertEqual(changes.last?.data, external.data)
        XCTAssertEqual(changes.count, 1)
        await access.close()
    }

    func testMoveUpdatesLeaseURLAndDeletionKeepsLastReadableSnapshotAndCompletes() async throws {
        let file = try fixture(Data("- [ ] Task\n".utf8))
        let moved = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: moved)
        }
        let access = MobileDocumentAccess()
        let opened = try await access.open(url: file)
        let presenter = try XCTUnwrap(NSFileCoordinator.filePresenters.first { $0.presentedItemURL == file })
        try FileManager.default.moveItem(at: file, to: moved)
        presenter.presentedItemDidMove?(to: moved)
        let refreshed = try await access.refresh()
        XCTAssertEqual(refreshed.url, moved)
        XCTAssertEqual(refreshed.leaseID, opened.leaseID)
        let deletion = expectation(description: "Presenter deletion callback completes")
        let reported = expectation(description: "Deletion error remains visible")
        access.onError = { _ in reported.fulfill() }
        try FileManager.default.removeItem(at: moved)
        Self.notifyDeletion(presenter) { error in
            XCTAssertNil(error)
            deletion.fulfill()
        }
        await fulfillment(of: [deletion, reported], timeout: 3)
        XCTAssertEqual(access.snapshot, refreshed)
        do {
            _ = try await access.write(leaseID: opened.leaseID, task: task(), marker: 120, expectedSource: refreshed.source)
            XCTFail("A deleted presentation cannot accept writes")
        } catch { }
        await access.close()
    }

    func testCancellationDuringOpenReleasesScopeAndPresenter() async throws {
        let file = try fixture(Data("- [ ] Task\n".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let gate = DocumentOperationGate(block: .read)
        defer { gate.resume.signal() }
        let access = MobileDocumentAccess(environment: gate.environment)
        let opening = Task { try await access.open(url: file) }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered)
        opening.cancel()
        gate.resume.signal()
        do {
            _ = try await opening.value
            XCTFail("Canceled opening cannot install a live lease")
        } catch is CancellationError { }
        XCTAssertNil(access.snapshot)
        XCTAssertTrue(gate.stopped(file))
        XCTAssertFalse(NSFileCoordinator.filePresenters.contains { $0.presentedItemURL == file })
        await access.close()
    }

    func testOSReadableLocalFileDoesNotRequireSecurityScopeSuccess() async throws {
        let file = try fixture(Data("Readable without a sandbox extension\n".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let environment = MobileDocumentEnvironment(startAccessing: { _ in false }, stopAccessing: { _ in
            XCTFail("A scope that was not started must not be stopped")
        }, willCoordinate: { _, _ in })
        let access = MobileDocumentAccess(environment: environment)
        let opened = try await access.open(url: file)
        XCTAssertEqual(opened.source, "Readable without a sandbox extension\n")
        await access.close()
    }

    func testFolderGrantLivesWithDocumentAndMarkerWritePreservesInodeAndPermissions() async throws {
        let file = try fixture(Data("- [ ] Task\n".utf8))
        let folder = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        let gate = DocumentOperationGate()
        let access = MobileDocumentAccess(environment: gate.environment)
        let opened = try await access.open(url: file)
        try await access.addFolderAccess(folder)
        XCTAssertFalse(gate.stopped(folder))
        _ = try await access.write(leaseID: opened.leaseID, task: task(), marker: 120, expectedSource: opened.source)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(after[.posixPermissions] as? Int, 0o640)
        await access.close()
        XCTAssertTrue(gate.stopped(folder))
    }

    func testBackgroundPresentationSuspendsRegistrationWithoutReleasingReadableLease() async throws {
        let file = try fixture(Data("Background read\n".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let gate = DocumentOperationGate()
        let access = MobileDocumentAccess(environment: gate.environment)
        let opened = try await access.open(url: file)
        await access.setPresented(false)
        XCTAssertFalse(NSFileCoordinator.filePresenters.contains { $0.presentedItemURL == file })
        XCTAssertFalse(gate.stopped(file))
        XCTAssertEqual(access.snapshot, opened)
        await access.setPresented(true)
        XCTAssertTrue(NSFileCoordinator.filePresenters.contains { $0.presentedItemURL == file })
        await access.close()
    }

    func testCoordinatedReplacementDoesNotPermanentlyDeleteTheLease() async throws {
        let file = try fixture(Data("- [ ] Task\n".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let access = MobileDocumentAccess()
        let opened = try await access.open(url: file)
        let replacement = Data("- [ ] Replacement\n".utf8)
        try await Task.detached {
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var writeError: Error?
            coordinator.coordinate(writingItemAt: file, options: .forReplacing, error: &coordinationError) { url in
                do { try replacement.write(to: url, options: .atomic) }
                catch { writeError = error }
            }
            if let coordinationError { throw coordinationError }
            if let writeError { throw writeError }
        }.value
        let current = try await access.refresh()
        XCTAssertEqual(current.leaseID, opened.leaseID)
        XCTAssertEqual(current.data, replacement)
        let saved = try await access.write(leaseID: current.leaseID, task: task(), marker: 120, expectedSource: current.source)
        XCTAssertEqual(saved.source, "- [x] Replacement\n")
        await access.close()
    }

    func testCloseDuringSuspendedOpenDrainsAndNeverInstallsTheCanceledLease() async throws {
        let file = try fixture(Data("Opening\n".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let gate = DocumentOperationGate(block: .read)
        defer { gate.resume.signal() }
        let access = MobileDocumentAccess(environment: gate.environment)
        let opening = Task { try await access.open(url: file) }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered)
        let closing = Task { await access.close() }
        await Task.yield()
        XCTAssertFalse(gate.stopped(file))
        gate.resume.signal()
        do {
            _ = try await opening.value
            XCTFail("A close must invalidate an in-flight open")
        } catch is CancellationError { }
        await closing.value
        XCTAssertNil(access.snapshot)
        XCTAssertTrue(gate.stopped(file))
    }

    func testBackgroundUnregisterAndRelinquishCallbacksDoNotWaitForSuspendedWrite() async throws {
        let file = try fixture(Data("- [ ] Task\n".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let gate = DocumentOperationGate(block: .write)
        defer { gate.resume.signal() }
        let access = MobileDocumentAccess(environment: gate.environment)
        let opened = try await access.open(url: file)
        let presenter = try XCTUnwrap(NSFileCoordinator.filePresenters.first { $0.presentedItemURL == file })
        let writing = Task { try await access.write(leaseID: opened.leaseID, task: task(), marker: 120, expectedSource: opened.source) }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered)
        let reader = expectation(description: "Reader relinquishment completes while IO is blocked")
        let writer = expectation(description: "Writer relinquishment completes while IO is blocked")
        presenter.relinquishPresentedItem?(toReader: { _ in reader.fulfill() })
        presenter.relinquishPresentedItem?(toWriter: { reacquire in
            writer.fulfill()
            reacquire?()
        })
        await access.setPresented(false)
        XCTAssertFalse(NSFileCoordinator.filePresenters.contains { $0.presentedItemURL == file })
        XCTAssertFalse(gate.stopped(file))
        await fulfillment(of: [reader, writer], timeout: 1)
        gate.resume.signal()
        _ = try await writing.value
        await access.setPresented(true)
        XCTAssertTrue(NSFileCoordinator.filePresenters.contains { $0.presentedItemURL == file })
        await access.close()
        XCTAssertEqual(try Data(contentsOf: file), Data("- [x] Task\n".utf8))
    }

    func testRecentBookmarksPersistResolveAndRemoveWithoutClosingTheDocument() async throws {
        let suite = "MDView-mobile-library-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = try fixture(Data("Remembered document\n".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let gate = DocumentOperationGate()
        let access = MobileDocumentAccess(environment: gate.environment)
        _ = try await access.open(url: file)
        let library = MobileDocumentLibrary(defaults: defaults)
        try await library.remember(file)
        let recent = try XCTUnwrap(library.recents.first)
        XCTAssertEqual(recent.title, file.lastPathComponent)
        XCTAssertFalse(gate.stopped(file))
        let restored = MobileDocumentLibrary(defaults: defaults)
        XCTAssertEqual(restored.recents.first?.id, recent.id)
        let resolved = try await restored.resolve(recent.id)
        XCTAssertEqual(try Data(contentsOf: resolved), Data("Remembered document\n".utf8))
        restored.remove(id: recent.id)
        XCTAssertTrue(MobileDocumentLibrary(defaults: defaults).recents.isEmpty)
        await access.close()
    }

    func testRecentListIsBoundedAndReopeningKeepsStableIdentity() async throws {
        let suite = "MDView-mobile-library-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = MobileDocumentLibrary(defaults: defaults)
        var files: [URL] = []
        defer { for file in files { try? FileManager.default.removeItem(at: file) } }
        for index in 0..<21 {
            let file = try fixture(Data("Document \(index)\n".utf8))
            files.append(file)
            try await library.remember(file)
        }
        XCTAssertEqual(library.recents.count, 20)
        let recent = try XCTUnwrap(library.recents.first)
        try await library.remember(try XCTUnwrap(files.last))
        XCTAssertEqual(library.recents.first?.id, recent.id)
        XCTAssertEqual(library.recents.count, 20)
    }

    func testMoveDuringSuspendedSaveCannotWriteAnIdenticalReplacementAtTheOldPath() async throws {
        let file = try fixture(Data("- [ ] Task\n".utf8))
        let moved = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: moved)
        }
        let gate = DocumentOperationGate(block: .write)
        defer { gate.resume.signal() }
        let access = MobileDocumentAccess(environment: gate.environment)
        let opened = try await access.open(url: file)
        let presenter = try XCTUnwrap(NSFileCoordinator.filePresenters.first { $0.presentedItemURL == file })
        let writing = Task { try await access.write(leaseID: opened.leaseID, task: task(), marker: 120, expectedSource: opened.source) }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered)
        try FileManager.default.moveItem(at: file, to: moved)
        try Data("- [ ] Task\n".utf8).write(to: file)
        presenter.presentedItemDidMove?(to: moved)
        gate.resume.signal()
        do {
            _ = try await writing.value
            XCTFail("A moved lease must never modify an identical replacement at its old URL")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: file), Data("- [ ] Task\n".utf8))
        XCTAssertEqual(try Data(contentsOf: moved), Data("- [ ] Task\n".utf8))
        await access.close()
    }

    func testLatePresenterNotificationWhileBackgroundedWaitsForForegroundRefresh() async throws {
        let file = try fixture(Data("Original foreground version\n".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let access = MobileDocumentAccess()
        let opened = try await access.open(url: file)
        let presenter = try XCTUnwrap(NSFileCoordinator.filePresenters.first { $0.presentedItemURL == file })
        await access.setPresented(false)
        try Data("External background version\n".utf8).write(to: file, options: .atomic)
        let changedWhileInactive = expectation(description: "Inactive presentation does not read late notifications")
        changedWhileInactive.isInverted = true
        access.onChange = { _ in changedWhileInactive.fulfill() }
        presenter.presentedItemDidChange?()
        await fulfillment(of: [changedWhileInactive], timeout: 0.5)
        XCTAssertEqual(access.snapshot, opened)
        access.onChange = nil
        await access.setPresented(true)
        let refreshed = try await access.refresh()
        XCTAssertEqual(refreshed.source, "External background version\n")
        await access.close()
    }

    func testSuspendedRefreshCannotPublishIntoAnIdenticalNewDocument() async throws {
        let first = try fixture(Data("Same text\n".utf8))
        let second = try fixture(Data("Same text\n".utf8))
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let gate = DocumentOperationGate()
        defer { gate.resume.signal() }
        let access = MobileDocumentAccess(environment: gate.environment)
        _ = try await access.open(url: first)
        gate.blockNext(.read)
        let refreshing = Task { try await access.refresh() }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered)
        try Data("First file external update\n".utf8).write(to: first, options: .atomic)
        let replacement = try await access.open(url: second)
        gate.resume.signal()
        do {
            _ = try await refreshing.value
            XCTFail("An old refresh cannot be published into a replacement lease")
        } catch is CancellationError { }
        XCTAssertEqual(access.snapshot, replacement)
        await access.close()
    }

    func testOverlappingOpenInstallsOnlyTheLatestLeaseAndBalancesBothScopes() async throws {
        let first = try fixture(Data("First\n".utf8))
        let second = try fixture(Data("Second\n".utf8))
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let gate = DocumentOperationGate(block: .read)
        defer { gate.resume.signal() }
        let access = MobileDocumentAccess(environment: gate.environment)
        let opening = Task { try await access.open(url: first) }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered)
        let replacement = try await access.open(url: second)
        gate.resume.signal()
        do {
            _ = try await opening.value
            XCTFail("An older open result must not displace the latest document")
        } catch is CancellationError { }
        XCTAssertEqual(access.snapshot, replacement)
        XCTAssertEqual(access.snapshot?.source, "Second\n")
        XCTAssertTrue(gate.stopped(first))
        await access.close()
        XCTAssertTrue(gate.stopped(second))
    }

    private nonisolated static func notifyDeletion(_ presenter: any NSFilePresenter, completion: @escaping @Sendable (Error?) -> Void) {
        presenter.accommodatePresentedItemDeletion?(completionHandler: completion)
    }

    private func fixture(_ data: Data) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("MDView-mobile-\(UUID()).md")
        try data.write(to: file)
        return file
    }

    private func task() -> MarkdownTask {
        MarkdownTask(id: 0, utf8Offset: 3, marker: 32, label: "Task")
    }
}

private final class DocumentOperationGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var starts: [URL] = []
    private var stops: [URL] = []
    private var blockOperation: MobileDocumentOperation?

    init(block: MobileDocumentOperation? = nil) { blockOperation = block }

    var environment: MobileDocumentEnvironment {
        MobileDocumentEnvironment(startAccessing: { [self] url in
            lock.withLock { starts.append(url) }
            return true
        }, stopAccessing: { [self] url in
            lock.withLock { stops.append(url) }
        }, willCoordinate: { [self] operation, _ in
            let shouldBlock = lock.withLock {
                guard blockOperation == operation else { return false }
                blockOperation = nil
                return true
            }
            if shouldBlock {
                entered.signal()
                _ = resume.wait(timeout: .now() + 10)
            }
        })
    }

    func blockNext(_ operation: MobileDocumentOperation) { lock.withLock { blockOperation = operation } }

    func stopped(_ url: URL) -> Bool { lock.withLock { stops.contains(url) } }

    func waitUntilEntered() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                continuation.resume(returning: entered.wait(timeout: .now() + 5) == .success)
            }
        }
    }
}

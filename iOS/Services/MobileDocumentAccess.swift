import Foundation
import Darwin

struct MobileDocumentSnapshot: Sendable, Equatable {
    let leaseID: UUID
    let sourceSnapshot: SourceFileEdit.Snapshot
    let source: String
    var url: URL { sourceSnapshot.url }
    var data: Data { sourceSnapshot.data }
    var identity: SourceFileEdit.Identity { sourceSnapshot.identity }
    init(leaseID: UUID, snapshot: SourceFileEdit.Snapshot) throws {
        self.leaseID = leaseID; self.sourceSnapshot = snapshot; source = try snapshot.source
    }
}

/// Scope operations and a coordination observer allow lifecycle instrumentation
/// without replacing the real presenter, coordinator, or filesystem operations.
enum MobileDocumentOperation: Sendable, Equatable { case read, write }
struct MobileDocumentEnvironment: Sendable {
    let startAccessing: @Sendable (URL) -> Bool
    let stopAccessing: @Sendable (URL) -> Void
    let willCoordinate: @Sendable (MobileDocumentOperation, URL) -> Void

    static let live = MobileDocumentEnvironment(
        startAccessing: { $0.startAccessingSecurityScopedResource() },
        stopAccessing: { $0.stopAccessingSecurityScopedResource() },
        willCoordinate: { _, _ in }
    )
}

private struct MobileDocumentUpdate: Sendable {
    let snapshot: MobileDocumentSnapshot
    let sequence: UInt64
}

/// The facade never performs file IO. Every accepted operation synchronously
/// enters its immutable lease's queue before this actor is allowed to suspend.
@MainActor
final class MobileDocumentAccess {
    private(set) var snapshot: MobileDocumentSnapshot?
    var onChange: ((MobileDocumentSnapshot) -> Void)?
    var onError: ((Error) -> Void)?

    private let environment: MobileDocumentEnvironment
    private var active: MobileDocumentLease?
    private var leases: [UUID: MobileDocumentLease] = [:]
    private var openingGeneration = UUID()
    private var isPresented = true
    private var appliedSequence: UInt64 = 0
    private var openingLeaseID: UUID?
    private var pendingOpenUpdate: MobileDocumentUpdate?

    init(environment: MobileDocumentEnvironment = .live) {
        self.environment = environment
    }

    deinit {
        for lease in leases.values { lease.beginClosing() }
    }

    func open(url: URL) async throws -> MobileDocumentSnapshot {
        try Task.checkCancellation()
        let generation = UUID()
        openingGeneration = generation
        active = nil
        snapshot = nil
        appliedSequence = 0
        pendingOpenUpdate = nil
        for lease in Array(leases.values) { retire(lease) }
        let lease = MobileDocumentLease(url: url, environment: environment, isPresented: isPresented) { [weak self] event in
            Task { @MainActor [weak self] in self?.receive(event) }
        }
        leases[lease.id] = lease
        openingLeaseID = lease.id
        let operation = lease.open()
        do {
            let read = try await operation.value()
            try Task.checkCancellation()
            guard openingGeneration == generation else { throw CancellationError() }
            let opened = pendingOpenUpdate.flatMap { $0.sequence > read.sequence ? $0 : nil } ?? read
            active = lease
            openingLeaseID = nil
            pendingOpenUpdate = nil
            appliedSequence = opened.sequence
            snapshot = opened.snapshot
            return opened.snapshot
        } catch {
            await lease.close()
            leases[lease.id] = nil
            if openingLeaseID == lease.id {
                openingLeaseID = nil
                pendingOpenUpdate = nil
            }
            throw error
        }
    }

    func write(leaseID: UUID, task: MarkdownTask, marker: UInt8, expectedSource: String) async throws -> MobileDocumentSnapshot {
        guard let expected = snapshot, expected.leaseID == leaseID,
              expected.source.utf8.elementsEqual(expectedSource.utf8) else { throw ChecklistError.changed }
        return try await write(expected: expected, task: task, marker: marker)
    }

    func write(expected: MobileDocumentSnapshot, task: MarkdownTask, marker: UInt8) async throws -> MobileDocumentSnapshot {
        guard let lease = active, lease.id == expected.leaseID, snapshot == expected else { throw ChecklistError.changed }
        let leaseID = expected.leaseID
        let operation = lease.write(expected: expected, task: task, marker: marker)
        let saved = try await operation.value()
        // An old accepted save may finish after another file has opened, or
        // after a newer external read has already reached the actor.
        if active?.id == leaseID, saved.sequence >= appliedSequence {
            appliedSequence = saved.sequence
            snapshot = saved.snapshot
        }
        return saved.snapshot
    }

    func replace(expected: MobileDocumentSnapshot, with replacement: Data) async throws -> MobileDocumentSnapshot {
        guard let lease = active, lease.id == expected.leaseID, snapshot == expected else { throw SourceFileEdit.Failure.changed }
        let operation = lease.replace(expected: expected, with: replacement)
        let saved = try await operation.value()
        if active?.id == expected.leaseID, saved.sequence >= appliedSequence {
            appliedSequence = saved.sequence; snapshot = saved.snapshot
        }
        return saved.snapshot
    }

    func refresh() async throws -> MobileDocumentSnapshot {
        guard let lease = active else { throw CocoaError(.fileReadNoSuchFile) }
        let operation = lease.refresh()
        let refreshed = try await operation.value()
        guard active?.id == lease.id else { throw CancellationError() }
        publish(refreshed)
        return snapshot ?? refreshed.snapshot
    }

    func addFolderAccess(_ url: URL) async throws {
        guard let lease = active else { throw CocoaError(.fileReadNoSuchFile) }
        try await lease.addFolderAccess(url).value()
    }

    /// iOS must unregister presenters before suspension. This deliberately does
    /// not wait behind provider IO; security scopes and accepted writes survive.
    func setPresented(_ isPresented: Bool) async {
        self.isPresented = isPresented
        for lease in leases.values { lease.setPresented(isPresented) }
    }

    func close() async {
        openingGeneration = UUID()
        openingLeaseID = nil
        pendingOpenUpdate = nil
        active = nil
        snapshot = nil
        let closing = Array(leases.values)
        for lease in closing { lease.beginClosing() }
        for lease in closing {
            await lease.close()
            leases[lease.id] = nil
        }
    }

    private func retire(_ lease: MobileDocumentLease) {
        lease.beginClosing()
        Task { [weak self] in
            await lease.close()
            self?.leases[lease.id] = nil
        }
    }

    private func receive(_ event: MobileDocumentLease.Event) {
        switch event {
        case .changed(let updated):
            if active?.id == updated.snapshot.leaseID {
                publish(updated)
            } else if openingLeaseID == updated.snapshot.leaseID,
                      updated.sequence > (pendingOpenUpdate?.sequence ?? 0) {
                pendingOpenUpdate = updated
            }
        case .failed(let leaseID, let sequence, let error):
            guard active?.id == leaseID, sequence >= appliedSequence else { return }
            onError?(error)
        }
    }

    private func publish(_ updated: MobileDocumentUpdate) {
        guard updated.sequence >= appliedSequence else { return }
        appliedSequence = updated.sequence
        guard snapshot != updated.snapshot else { return }
        snapshot = updated.snapshot
        onChange?(updated.snapshot)
    }
}

/// A one-consumer result whose operation is queued synchronously. Creating a
/// Task around the enqueue would allow close/switch to overtake an accepted save.
private final class MobileDocumentResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    func resolve(_ result: Result<Value, Error>) {
        let waiting = lock.withLock {
            self.result = result
            let waiting = continuation
            continuation = nil
            return waiting
        }
        waiting?.resume(with: result)
    }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let completed: Result<Value, Error>? = lock.withLock {
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let completed { continuation.resume(with: completed) }
        }
    }
}

/// Mutable file state lives on ioQueue. URL and registration have separate locks
/// because Foundation can query a presenter from any thread during coordination.
private final class MobileDocumentLease: NSObject, NSFilePresenter, @unchecked Sendable {
    enum Event: Sendable {
        case changed(MobileDocumentUpdate)
        case failed(UUID, UInt64, Error)
    }

    let id = UUID()
    let presentedItemOperationQueue: OperationQueue
    private let ioQueue: DispatchQueue
    private let environment: MobileDocumentEnvironment
    private let event: @Sendable (Event) -> Void
    private let urlLock = NSLock()
    private var url: URL
    private let scopeURL: URL
    private let registrationLock = NSLock()
    private var wantsPresentation: Bool
    private var isRegistered = false
    private var isReady = false
    private var isRetiring = false
    private let closeLock = NSLock()
    private var closing = false
    private var closed = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    // Only ioQueue touches these values.
    private var latest: MobileDocumentSnapshot?
    private var sequence: UInt64 = 0
    private var scopeStarted = false
    private var folderScopes: [URL] = []

    init(url: URL, environment: MobileDocumentEnvironment, isPresented: Bool, event: @escaping @Sendable (Event) -> Void) {
        self.url = url
        scopeURL = url
        self.environment = environment
        self.event = event
        wantsPresentation = isPresented
        ioQueue = DispatchQueue(label: "design.highgain.margined.document.\(id)", qos: .userInitiated)
        presentedItemOperationQueue = OperationQueue()
        presentedItemOperationQueue.name = "design.highgain.margined.presenter.\(id)"
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
        super.init()
    }

    var presentedItemURL: URL? { urlLock.withLock { url } }

    func open() -> MobileDocumentResult<MobileDocumentUpdate> {
        perform { [self] in
            scopeStarted = environment.startAccessing(scopeURL)
            try registrationLock.withLock {
                guard !isRetiring else { throw CancellationError() }
                isReady = true
                if wantsPresentation {
                    NSFileCoordinator.addFilePresenter(self)
                    isRegistered = true
                }
            }
            return try read()
        }
    }

    func refresh() -> MobileDocumentResult<MobileDocumentUpdate> {
        perform { [self] in try read() }
    }

    func write(expected: MobileDocumentSnapshot, task: MarkdownTask, marker: UInt8) -> MobileDocumentResult<MobileDocumentUpdate> {
        perform { [self] in
            guard presentedItemURL == expected.url else { throw ChecklistError.changed }
            environment.willCoordinate(.write, expected.url)
            guard presentedItemURL == expected.url else { throw ChecklistError.changed }
            let committed = try SourceFileEdit.setMarker(marker, at: task.utf8Offset, was: task.marker, expected: expected.sourceSnapshot, presenter: self)
            let saved = try MobileDocumentSnapshot(leaseID: id, snapshot: committed)
            // Commit before any subsequent presenter read: exact own-write echoes
            // never become external-change events, even while MainActor is busy.
            latest = saved
            sequence &+= 1
            return MobileDocumentUpdate(snapshot: saved, sequence: sequence)
        }
    }

    func replace(expected: MobileDocumentSnapshot, with replacement: Data) -> MobileDocumentResult<MobileDocumentUpdate> {
        perform { [self] in
            guard presentedItemURL == expected.url else { throw SourceFileEdit.Failure.changed }
            environment.willCoordinate(.write, expected.url)
            guard presentedItemURL == expected.url else { throw SourceFileEdit.Failure.changed }
            let committed = try SourceFileEdit.commit(replacement, expected: expected.sourceSnapshot, presenter: self)
            let saved = try MobileDocumentSnapshot(leaseID: id, snapshot: committed)
            latest = saved
            sequence &+= 1
            return MobileDocumentUpdate(snapshot: saved, sequence: sequence)
        }
    }

    func addFolderAccess(_ folder: URL) -> MobileDocumentResult<Void> {
        perform { [self] in
            let started = environment.startAccessing(folder)
            do {
                guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CocoaError(.fileReadUnsupportedScheme) }
                if started { folderScopes.append(folder) }
            } catch {
                if started { environment.stopAccessing(folder) }
                throw error
            }
        }
    }

    func setPresented(_ enabled: Bool) {
        registrationLock.withLock {
            wantsPresentation = enabled
            if !enabled, isRegistered {
                NSFileCoordinator.removeFilePresenter(self)
                isRegistered = false
            } else if enabled, isReady, !isRetiring, !isRegistered {
                NSFileCoordinator.addFilePresenter(self)
                isRegistered = true
            }
        }
    }

    func beginClosing() {
        let shouldClose = closeLock.withLock {
            guard !closing else { return false }
            closing = true
            return true
        }
        guard shouldClose else { return }
        registrationLock.withLock { isRetiring = true }
        ioQueue.async { [self] in
            registrationLock.withLock {
                isReady = false
                if isRegistered {
                    NSFileCoordinator.removeFilePresenter(self)
                    isRegistered = false
                }
            }
            // Unregister first, then drain callbacks already delivered by Cocoa.
            presentedItemOperationQueue.addBarrierBlock { [self] in
                ioQueue.async { [self] in
                    for folder in folderScopes { environment.stopAccessing(folder) }
                    folderScopes.removeAll()
                    if scopeStarted {
                        environment.stopAccessing(scopeURL)
                        scopeStarted = false
                    }
                    let waiting = closeLock.withLock {
                        closed = true
                        let waiting = closeWaiters
                        closeWaiters.removeAll()
                        return waiting
                    }
                    for continuation in waiting { continuation.resume() }
                }
            }
        }
    }

    func close() async {
        beginClosing()
        await withCheckedContinuation { continuation in
            let finished = closeLock.withLock {
                guard !closed else { return true }
                closeWaiters.append(continuation)
                return false
            }
            if finished { continuation.resume() }
        }
    }

    func presentedItemDidChange() { enqueueRefresh() }

    func presentedItemDidMove(to newURL: URL) {
        urlLock.withLock { url = newURL }
        enqueueRefresh()
    }

    func relinquishPresentedItem(toReader reader: @escaping @Sendable ((@Sendable () -> Void)?) -> Void) {
        reader(nil)
    }

    func relinquishPresentedItem(toWriter writer: @escaping @Sendable ((@Sendable () -> Void)?) -> Void) {
        writer { [weak self] in self?.enqueueRefresh() }
    }

    func savePresentedItemChanges(completionHandler: @escaping @Sendable (Error?) -> Void) {
        // Accepted writes use coordinated synchronous commits. Waiting for ioQueue
        // here could deadlock a coordinator already waiting for this callback.
        completionHandler(nil)
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping @Sendable (Error?) -> Void) {
        // .forReplacing also invokes this method. Re-read after relinquishment
        // instead of permanently declaring the lease deleted before replacement.
        completionHandler(nil)
        enqueueRefresh()
    }

    private func perform<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) -> MobileDocumentResult<Value> {
        let result = MobileDocumentResult<Value>()
        ioQueue.async { result.resolve(Result { try work() }) }
        return result
    }

    private func enqueueRefresh() {
        let acceptsEvents = registrationLock.withLock { isReady && !isRetiring && wantsPresentation }
        guard acceptsEvents else { return }
        ioQueue.async { [self] in
            // Closing may have begun since Foundation delivered the callback.
            guard registrationLock.withLock({ isReady && !isRetiring && wantsPresentation }) else { return }
            do {
                let previous = latest
                let updated = try read()
                if previous != updated.snapshot,
                   registrationLock.withLock({ isReady && !isRetiring && wantsPresentation }) {
                    event(.changed(updated))
                }
            } catch {
                sequence &+= 1
                if registrationLock.withLock({ isReady && !isRetiring && wantsPresentation }) {
                    event(.failed(id, sequence, error))
                }
            }
        }
    }

    private func read() throws -> MobileDocumentUpdate {
        let readingURL = urlLock.withLock { url }
        environment.willCoordinate(.read, readingURL)
        let coordinator = NSFileCoordinator(filePresenter: self)
        var coordinationError: NSError?
        var outcome: Result<MobileDocumentSnapshot, Error>?
        coordinator.coordinate(readingItemAt: readingURL, options: [], error: &coordinationError) { coordinatedURL in
            outcome = Result {
                let captured = try SourceFileEdit.capture(coordinatedURL, logicalURL: readingURL)
                return try MobileDocumentSnapshot(leaseID: id, snapshot: captured)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw CocoaError(.fileReadUnknown) }
        let updated = try outcome.get()
        latest = updated
        sequence &+= 1
        return MobileDocumentUpdate(snapshot: updated, sequence: sequence)
    }
}

import Foundation
import Darwin
import Dispatch

/// File events are hints. The reader still owns coordinated, stable reads.
final class SourceFileWatcher: Sendable {
    enum Hint: Equatable, Sendable { case initial, change, backstop }
    let events: AsyncStream<Hint>
    private let state: State

    init(url: URL) {
        let pair = AsyncStream<Hint>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = pair.stream
        let state = State(url: url, continuation: pair.continuation)
        self.state = state
        pair.continuation.onTermination = { [weak state] _ in state?.cancel() }
        state.start()
    }
    func cancel() { state.cancel() }
    deinit { state.cancel() }

    /// All mutable state and Dispatch handlers belong to this serial queue.
    private final class State: @unchecked Sendable {
        private struct Subscription {
            let source: any DispatchSourceFileSystemObject
            let identity: SourceFileEdit.Identity
            let generation: UUID
            let isFile: Bool
        }
        private let url: URL
        private let continuation: AsyncStream<Hint>.Continuation
        private let queue = DispatchQueue(label: "design.highgain.margined.file-observation", qos: .utility)
        private var subscriptions: [String: Subscription] = [:]
        private var timer: (any DispatchSourceTimer)?
        private var delivery: DispatchWorkItem?
        private var stamp: FileStamp?
        private var closed = false

        init(url: URL, continuation: AsyncStream<Hint>.Continuation) {
            self.url = url; self.continuation = continuation
        }
        func start() {
            queue.async { [self] in
                guard !closed else { return }
                reconcile(force: false)
                emit(.initial)
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(100))
                timer.setEventHandler { [weak self] in
                    guard let self, !closed else { return }
                    reconcile(force: false)
                    emit(.backstop)
                }
                self.timer = timer
                timer.resume()
            }
        }
        func cancel() { queue.async { [self] in finish() } }

        private func reconcile(force: Bool) {
            guard !closed else { return }
            let current = FileStamp(url: url)
            var desired: [String: Bool] = [:]
            desired[url.deletingLastPathComponent().standardizedFileURL.path] = false
            desired[url.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.path] = false
            if current.isRegular { desired[url.path] = true }
            for path in Array(subscriptions.keys) where desired[path] == nil {
                subscriptions.removeValue(forKey: path)?.source.cancel()
            }
            for (path, isFile) in desired {
                let target = FileStamp(url: URL(fileURLWithPath: path))
                if let subscription = subscriptions[path], subscription.identity == target.identity,
                   subscription.isFile == isFile { continue }
                subscriptions.removeValue(forKey: path)?.source.cancel()
                subscribe(path: path, isFile: isFile)
            }
            let changed = stamp != current
            stamp = current
            if force || changed { scheduleChange() }
        }

        private func subscribe(path: String, isFile: Bool) {
            let descriptor = Darwin.open(path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else { return }
            var attributes = stat()
            guard fstat(descriptor, &attributes) == 0,
                  attributes.st_mode & mode_t(S_IFMT) == mode_t(isFile ? S_IFREG : S_IFDIR) else {
                Darwin.close(descriptor); return
            }
            let identity = SourceFileEdit.Identity(device: UInt64(truncatingIfNeeded: attributes.st_dev), inode: UInt64(attributes.st_ino))
            let generation = UUID()
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .link, .rename, .delete, .revoke], queue: queue)
            source.setCancelHandler { Darwin.close(descriptor) }
            source.setEventHandler { [weak self] in
                guard let self, !closed, let subscription = subscriptions[path],
                      subscription.generation == generation else { return }
                // A file event forces a read even when provider metadata is stale.
                // Parent activity is filtered against this document's path stamp.
                reconcile(force: subscription.isFile)
            }
            source.setRegistrationHandler { [weak self] in
                guard let self, !closed, subscriptions[path]?.generation == generation else { return }
                // Kernel registration is asynchronous. Reconcile once it is live.
                reconcile(force: true)
            }
            subscriptions[path] = .init(source: source, identity: identity, generation: generation, isFile: isFile)
            source.resume()
        }

        private func scheduleChange() {
            guard delivery == nil, !closed else { return }
            // A fixed window coalesces bursts without starving sustained saves.
            let item = DispatchWorkItem { [weak self] in
                guard let self, !closed else { return }
                delivery = nil
                emit(.change)
            }
            delivery = item
            queue.asyncAfter(deadline: .now() + .milliseconds(40), execute: item)
        }
        private func emit(_ hint: Hint) {
            guard !closed else { return }
            let result = continuation.yield(hint)
            switch result {
            case .dropped(let previous):
                // A slow reader must not lose a forced read to an idle backstop.
                if case .backstop = hint {
                    switch previous {
                    case .initial, .change: _ = continuation.yield(previous)
                    case .backstop: break
                    }
                }
            case .terminated: finish()
            case .enqueued: break
            @unknown default: break
            }
        }
        private func finish() {
            guard !closed else { return }
            closed = true
            delivery?.cancel(); delivery = nil
            timer?.cancel(); timer = nil
            let previous = subscriptions.values
            subscriptions.removeAll()
            for subscription in previous { subscription.source.cancel() }
            continuation.finish()
        }
    }
}

/// Follow the pathname (including symlinks); omit access time so reads stay idle.
struct FileStamp: Equatable, Sendable {
    let identity: SourceFileEdit.Identity?
    private let size: Int64?
    private let modifiedSeconds: Int64?
    private let modifiedNanoseconds: Int64?
    private let changedSeconds: Int64?
    private let changedNanoseconds: Int64?
    private let kind: mode_t?
    var isRegular: Bool { kind == mode_t(S_IFREG) }

    init(url: URL) {
        var value = stat()
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return stat(path, &value)
        }
        if status == 0 {
            identity = .init(device: UInt64(truncatingIfNeeded: value.st_dev), inode: UInt64(value.st_ino))
            size = Int64(value.st_size)
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
            kind = value.st_mode & mode_t(S_IFMT)
        } else {
            identity = nil; size = nil; modifiedSeconds = nil; modifiedNanoseconds = nil
            changedSeconds = nil; changedNanoseconds = nil; kind = nil
        }
    }
}

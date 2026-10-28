import Foundation
import Darwin

/// Encoded bytes and filesystem identity belonging to one displayed version.
enum SourceFileEdit {
    struct Identity: Equatable, Sendable { let device: UInt64; let inode: UInt64 }
    struct Snapshot: Equatable, Sendable {
        let url: URL
        let data: Data
        let identity: Identity
        private let decoded: Result<String, Error>
        init(url: URL, data: Data, identity: Identity) {
            self.url = url; self.data = data; self.identity = identity
            decoded = Result { try MarkdownSource.decode(data) }
        }
        var source: String { get throws { try decoded.get() } }
        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.url == rhs.url && lhs.data == rhs.data && lhs.identity == rhs.identity
        }
    }
    enum Failure: LocalizedError {
        case changed, notRegular
        case uncertain(recovery: URL, underlying: Error)
        var errorDescription: String? {
            switch self {
            case .changed: String(localized: "The file changed before the edit could be saved. Reload it and try again.")
            case .notRegular: String(localized: "This item is not a regular Markdown file.")
            case let .uncertain(url, error): String(localized: "The save could not be verified. The original was retained at \(url.path). \(error.localizedDescription)")
            }
        }
    }
    static func read(_ url: URL, presenter: (any NSFilePresenter)? = nil) throws -> Snapshot {
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var error: NSError?, result: Result<Snapshot, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &error) { location in
            result = Result { try capture(location, logicalURL: url) }
        }
        if let error { throw error }
        guard let result else { throw Failure.changed }
        return try result.get()
    }

    /// Call synchronously inside the owning document's serial I/O gate. File
    /// coordination protects cooperating editors; it is not a global filesystem CAS.
    static func commit(_ replacement: Data, expected: Snapshot, presenter: (any NSFilePresenter)? = nil,
                       fileManager: FileManager = .default) throws -> Snapshot {
        _ = try MarkdownSource.decode(replacement)
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var error: NSError?, result: Result<Snapshot, Error>?
        var recoveryDirectory: URL?, recoveryOriginal: URL?
        var replacementStarted = false
        defer {
            // After a replacement attempt, preserve recovery material until BOTH
            // Foundation coordination and our actual pathname readback succeed.
            if !replacementStarted, let recoveryDirectory { try? fileManager.removeItem(at: recoveryDirectory) }
        }
        coordinator.coordinate(writingItemAt: expected.url, options: .forReplacing, error: &error) { location in
            result = Result {
                let handle = try open(location, writing: true)
                defer { try? handle.close() }
                let current = try capture(location, logicalURL: expected.url, handle: handle)
                guard current == expected else { throw Failure.changed }
                if current.data == replacement { return current }
                // Replace the referent, never turn a Markdown symlink into a file.
                let destination = location.resolvingSymlinksInPath()
                let directory = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                    appropriateFor: destination, create: true)
                recoveryDirectory = directory
                let original = directory.appendingPathComponent("Original.md")
                let staged = directory.appendingPathComponent("Replacement.md")
                try fileManager.copyItem(at: destination, to: original)
                guard try capture(original, logicalURL: original).data == expected.data else { throw Failure.changed }
                recoveryOriginal = original
                try fileManager.copyItem(at: original, to: staged)
                let output = try open(staged, writing: true)
                do {
                    try output.truncate(atOffset: 0)
                    try output.write(contentsOf: replacement)
                    try output.synchronize()
                    try output.close()
                } catch { try? output.close(); throw error }
                guard try capture(staged, logicalURL: staged).data == replacement else { throw Failure.changed }
                // Revalidate immediately before replacement; staging may have
                // taken time or caused a provider to materialize a different item.
                guard try capture(location, logicalURL: expected.url, handle: handle) == expected,
                      location.resolvingSymlinksInPath() == destination else { throw Failure.changed }
                replacementStarted = true
                _ = try fileManager.replaceItemAt(destination, withItemAt: staged, backupItemName: nil, options: [])
                let saved = try capture(location, logicalURL: expected.url)
                guard saved.data == replacement else { throw Failure.changed }
                return saved
            }
        }
        do {
            if let error { throw error }
            guard let result else { throw Failure.changed }
            let saved = try result.get()
            if let recoveryDirectory { try? fileManager.removeItem(at: recoveryDirectory) }
            return saved
        } catch {
            if replacementStarted, let recoveryOriginal {
                // Never restore this over the pathname: a noncooperating writer
                // may already have installed another version there.
                throw Failure.uncertain(recovery: recoveryOriginal, underlying: error)
            }
            throw error
        }
    }

    static func setMarker(_ marker: UInt8, at offset: Int, was: UInt8, expected: Snapshot,
                          presenter: (any NSFilePresenter)? = nil) throws -> Snapshot {
        let source = try expected.source, bytes = Array(source.utf8)
        guard [32, 88, 120].contains(marker), [32, 88, 120].contains(was),
              offset > 0, offset < bytes.count - 1,
              bytes[offset - 1] == 91, bytes[offset + 1] == 93, bytes[offset] == was else { throw Failure.changed }
        let replacement = try MarkdownSourceEdits.apply([.init(range: offset..<(offset + 1), replacement: String(UnicodeScalar(UInt32(marker))!))], to: expected.data, expectedSource: source)
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var error: NSError?, result: Result<Snapshot, Error>?
        coordinator.coordinate(writingItemAt: expected.url, options: [], error: &error) { location in
            result = Result {
                let file = try open(location, writing: true)
                defer { try? file.close() }
                guard try capture(location, logicalURL: expected.url, handle: file) == expected else { throw Failure.changed }
                let differences = replacement.indices.filter { replacement[$0] != expected.data[$0] }
                if let first = differences.first, let last = differences.last {
                    guard last - first <= 1 else { throw Failure.changed }
                    // A marker is the sole in-place write. Variable-length edits
                    // use commit's staged replacement and recovery behavior.
                    try file.seek(toOffset: UInt64(first))
                    try file.write(contentsOf: replacement[first...last])
                    try file.synchronize()
                }
                let saved = try capture(location, logicalURL: expected.url, handle: file)
                guard saved.data == replacement, saved.identity == expected.identity else { throw Failure.changed }
                return saved
            }
        }
        if let error { throw error }
        guard let result else { throw Failure.changed }
        return try result.get()
    }

    /// The caller must already hold file coordination (e.g. a mobile lease).
    static func capture(_ url: URL, logicalURL: URL? = nil, handle supplied: FileHandle? = nil) throws -> Snapshot {
        let file = try supplied ?? open(url, writing: false)
        defer { if supplied == nil { try? file.close() } }
        let before = try attributes(file)
        try file.seek(toOffset: 0)
        let bytes = try file.read(upToCount: MarkdownSource.maximumBytes + 1) ?? Data()
        _ = try MarkdownSource.decode(bytes)
        let after = try attributes(file)
        var path = stat()
        guard url.path.withCString({ stat($0, &path) }) == 0 else { throw posixError() }
        guard sameIdentity(before, after), sameIdentity(after, path), bytes.count == after.st_size,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw Failure.changed }
        return Snapshot(url: logicalURL ?? url, data: bytes,
            identity: Identity(device: UInt64(bitPattern: Int64(after.st_dev)), inode: UInt64(after.st_ino)))
    }
    private static func open(_ url: URL, writing: Bool) throws -> FileHandle {
        let descriptor = url.path.withCString { Darwin.open($0, (writing ? O_RDWR : O_RDONLY) | O_CLOEXEC | O_NONBLOCK) }
        guard descriptor >= 0 else { throw posixError() }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do { _ = try attributes(file); return file }
        catch { try? file.close(); throw error }
    }
    private static func attributes(_ handle: FileHandle) throws -> stat {
        var value = stat()
        guard fstat(handle.fileDescriptor, &value) == 0 else { throw posixError() }
        guard value.st_mode & S_IFMT == S_IFREG else { throw Failure.notRegular }
        return value
    }
    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool { lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino }
    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

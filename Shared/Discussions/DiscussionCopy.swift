import Foundation

/// Coordinated user-selected copy I/O, without changing the active document or
/// retaining picker permissions beyond the operation.
enum DiscussionCopy {
    /// Explicit new-file creation. Never replace a pathname chosen by another
    /// writer, even if it appears between the picker and this coordinated write.
    @concurrent
    static func create(_ data: Data, at url: URL) async throws -> SourceFileEdit.Snapshot {
        try Task.checkCancellation()
        guard url.isFileURL else { throw SourceFileEdit.Failure.notRegular }
        _ = try MarkdownSource.decode(data)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var error: NSError?, result: Result<SourceFileEdit.Snapshot, Error>?
        coordinator.coordinate(writingItemAt: url, options: [], error: &error) { location in
            result = Result {
                try data.write(to: location, options: .withoutOverwriting)
                let saved = try SourceFileEdit.capture(location, logicalURL: url)
                guard saved.data == data else { throw SourceFileEdit.Failure.changed }
                return saved
            }
        }
        if let error { throw error }
        guard let result else { throw SourceFileEdit.Failure.changed }
        return try result.get()
    }

    @concurrent
    static func read(_ url: URL) async throws -> DiscussionDocument {
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let snapshot = try SourceFileEdit.read(url)
        try Task.checkCancellation()
        return try DiscussionCodec.parse(snapshot.source)
    }
}

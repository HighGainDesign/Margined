import Foundation

/// Read the user-selected other copy without replacing the active document or
/// retaining its permission beyond the coordinated read.
enum DiscussionCopy {
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

import Foundation
import Observation

struct RecentDocument: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    fileprivate let bookmark: Data
    fileprivate let location: String
}

/// Bookmarks preserve Files access across launches; no document body is stored.
@MainActor @Observable
final class MobileDocumentLibrary {
    private(set) var recents: [RecentDocument] = []
    private let defaults: UserDefaults
    private static let key = "mobileRecentDocuments.v1"
    private static let maximumEntries = 20

    init(defaults: UserDefaults = ReaderPreferences.defaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), data.count <= 8 * 1_024 * 1_024,
           let saved = try? JSONDecoder().decode([RecentDocument].self, from: data) {
            recents = Array(saved.prefix(Self.maximumEntries))
        }
    }

    func remember(_ url: URL) async throws {
        try Task.checkCancellation()
        let bookmark = try await Self.makeBookmark(url)
        try Task.checkCancellation()
        let location = url.standardizedFileURL.absoluteString
        let id = recents.first { $0.location == location }?.id ?? UUID()
        recents.removeAll { $0.location == location }
        recents.insert(RecentDocument(id: id, title: url.lastPathComponent, bookmark: bookmark, location: location), at: 0)
        recents = Array(recents.prefix(Self.maximumEntries))
        persist()
    }

    func resolve(_ id: UUID) async throws -> URL {
        guard let recent = recents.first(where: { $0.id == id }) else { throw CocoaError(.fileReadNoSuchFile) }
        let resolved = try await Self.resolveBookmark(recent.bookmark)
        try Task.checkCancellation()
        guard let index = recents.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
        if let refreshed = resolved.refreshed {
            recents[index] = RecentDocument(id: id, title: resolved.url.lastPathComponent, bookmark: refreshed, location: resolved.url.standardizedFileURL.absoluteString)
            persist()
        }
        return resolved.url
    }

    func remove(id: UUID) {
        recents.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(recents) { defaults.set(data, forKey: Self.key) }
    }

    @concurrent
    private static func makeBookmark(_ url: URL) async throws -> Data {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private struct ResolvedBookmark: Sendable {
        let url: URL
        let refreshed: Data?
    }

    @concurrent
    private static func resolveBookmark(_ bookmark: Data) async throws -> ResolvedBookmark {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        let refreshed = stale ? try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) : nil
        return ResolvedBookmark(url: url, refreshed: refreshed)
    }
}

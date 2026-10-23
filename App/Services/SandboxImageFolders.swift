#if MARGINED_APP_STORE
import Foundation

/// Persistent OS folder access for the sandboxed Mac distribution only.
/// These app-scoped bookmarks are not permission grants for another bundle.
@MainActor
final class SandboxImageFolders {
    static let bookmarksKey = "sandboxImageFolderBookmarks"
    static let shared = SandboxImageFolders(defaults: ReaderPreferences.defaults)

    private struct Grant: Sendable {
        let url: URL
        let index: Int
        let started: Bool
        let stale: Bool
        var identity: String { url.standardizedFileURL.resolvingSymlinksInPath().path }
    }

    private let defaults: UserDefaults
    private var bookmarks: [Data]
    private var grants: [Grant] = []
    var folderURLs: [URL] { grants.map(\.url) }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        bookmarks = defaults.array(forKey: Self.bookmarksKey) as? [Data] ?? []
        refresh()
    }

    deinit {
        for grant in grants where grant.started { grant.url.stopAccessingSecurityScopedResource() }
    }

    /// Retry unavailable bookmarks after a drive or file provider becomes available.
    func refresh() {
        var updated = false
        for index in bookmarks.indices where !grants.contains(where: { $0.index == index }) {
            guard let grant = try? open(bookmarks[index], index: index) else { continue }
            guard !grants.contains(where: { $0.identity == grant.identity }) else {
                if grant.started { grant.url.stopAccessingSecurityScopedResource() }
                continue
            }
            grants.append(grant)
            if grant.stale, let data = try? bookmark(for: grant.url) {
                bookmarks[index] = data
                updated = true
            }
        }
        if updated { defaults.set(bookmarks, forKey: Self.bookmarksKey) }
    }

    func allow(_ folder: URL) throws {
        guard folder.isFileURL, try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CocoaError(.fileReadUnknown)
        }
        let data = try bookmark(for: folder)
        // Resolve the persisted representation before changing remembered permissions.
        let candidate = try open(data, index: bookmarks.count)
        if let offset = grants.firstIndex(where: { $0.identity == candidate.identity }) {
            let previous = grants[offset]
            bookmarks[previous.index] = data
            grants[offset] = Grant(url: candidate.url, index: previous.index, started: candidate.started, stale: candidate.stale)
            if previous.started { previous.url.stopAccessingSecurityScopedResource() }
        } else {
            bookmarks.append(data)
            grants.append(candidate)
        }
        defaults.set(bookmarks, forKey: Self.bookmarksKey)
    }

    func close() {
        for grant in grants where grant.started { grant.url.stopAccessingSecurityScopedResource() }
        grants.removeAll()
    }

    private func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                             includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func open(_ data: Data, index: Int) throws -> Grant {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        let started = url.startAccessingSecurityScopedResource()
        do {
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw CocoaError(.fileReadUnknown)
            }
            // A URL already inside the sandbox can legitimately need no extension.
            return Grant(url: url, index: index, started: started, stale: stale)
        } catch {
            if started { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }
}
#endif

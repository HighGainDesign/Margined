import Foundation
import Observation

/// User-selected project roots, shared across open documents and scenes.
/// Bookmarks store access, never document or image contents.
@MainActor @Observable
final class MobileImageFolders {
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let title: String
        let bookmark: Data
        let location: String
    }
    private static let key = "mobileImageFolders.v1"
    private static let maximumFolders = 64
    private(set) var folders: [Entry] = []
    private(set) var errors: [UUID: String] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let environment: MobileDocumentEnvironment
    @ObservationIgnored private var scopes: [UUID: FolderScope] = [:]
    @ObservationIgnored private var restoring: Task<Void, Never>?
    private var restored = false
    private(set) var isRestoring = false

    init(defaults: UserDefaults = ReaderPreferences.defaults, environment: MobileDocumentEnvironment = .live) {
        self.defaults = defaults; self.environment = environment
        if let data = defaults.data(forKey: Self.key), data.count <= 4 * 1_024 * 1_024,
           let entries = try? JSONDecoder().decode([Entry].self, from: data),
           entries.count <= Self.maximumFolders, Set(entries.map(\.id)).count == entries.count {
            folders = entries
        }
    }

    func remember(_ url: URL) async throws {
        let opened = try await Self.open(url: url, bookmark: nil, environment: environment)
        var adopted = false
        defer { if !adopted { opened.scope.release() } }
        try Task.checkCancellation()
        let location = opened.url.standardizedFileURL.absoluteString
        let prior = folders.first { $0.location == location }
        guard prior != nil || folders.count < Self.maximumFolders else {
            throw CocoaError(.fileWriteOutOfSpace, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "Forget an image folder before adding another. Margined can remember up to 64 folders.")])
        }
        let id = prior?.id ?? UUID()
        let entry = Entry(id: id, title: opened.url.lastPathComponent, bookmark: opened.bookmark, location: location)
        if let index = folders.firstIndex(where: { $0.id == id }) { folders[index] = entry }
        else { folders.append(entry) }
        scopes.removeValue(forKey: id)?.release()
        scopes[id] = opened.scope; adopted = true
        errors[id] = nil; persist()
    }

    func restore() async {
        if let restoring { await restoring.value; return }
        guard !restored else { return }
        isRestoring = true
        let task = Task { await restoreEntries() }
        restoring = task
        await task.value
        restoring = nil; restored = true; isRestoring = false
    }

    func forget(_ id: UUID) {
        folders.removeAll { $0.id == id }
        scopes.removeValue(forKey: id)?.release()
        errors[id] = nil; persist()
    }

    private func restoreEntries() async {
        for entry in folders {
            guard scopes[entry.id] == nil else { continue }
            do {
                let opened = try await Self.open(url: nil, bookmark: entry.bookmark, environment: environment)
                guard let index = folders.firstIndex(of: entry), scopes[entry.id] == nil else {
                    opened.scope.release(); continue
                }
                scopes[entry.id] = opened.scope
                folders[index] = Entry(id: entry.id, title: opened.url.lastPathComponent,
                    bookmark: opened.bookmark, location: opened.url.standardizedFileURL.absoluteString)
                errors[entry.id] = nil
            } catch {
                if folders.contains(entry) { errors[entry.id] = error.localizedDescription }
            }
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(folders) { defaults.set(data, forKey: Self.key) }
    }

    private struct Opened: Sendable {
        let url: URL
        let bookmark: Data
        let scope: FolderScope
    }
    @concurrent
    private static func open(url selected: URL?, bookmark: Data?, environment: MobileDocumentEnvironment) async throws -> Opened {
        try Task.checkCancellation()
        var stale = false
        let url: URL
        if let selected { url = selected }
        else if let bookmark {
            url = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
        } else { throw CocoaError(.fileReadNoSuchFile) }
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let scope = FolderScope(url: url, environment: environment)
        do {
            environment.willCoordinate(.read, url)
            var coordinationError: NSError?, result: Result<Void, Error>?
            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { location in
                result = Result {
                    guard try location.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                        throw CocoaError(.fileReadUnsupportedScheme)
                    }
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw CocoaError(.fileReadUnknown) }
            try result.get(); try Task.checkCancellation()
            let saved: Data
            if let bookmark, !stale { saved = bookmark }
            else { saved = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) }
            return Opened(url: url, bookmark: saved, scope: scope)
        } catch { scope.release(); throw error }
    }
}

/// Can release on any executor; a forgotten/failed root is stopped exactly once.
private final class FolderScope: @unchecked Sendable {
    private let url: URL
    private let environment: MobileDocumentEnvironment
    private let lock = NSLock()
    private var started: Bool
    init(url: URL, environment: MobileDocumentEnvironment) {
        self.url = url; self.environment = environment
        started = environment.startAccessing(url)
    }
    func release() {
        let stop = lock.withLock { let value = started; started = false; return value }
        if stop { environment.stopAccessing(url) }
    }
    deinit { release() }
}

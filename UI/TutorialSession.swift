import Foundation
import Observation

@MainActor @Observable
final class TutorialSession {
    let platform: TutorialPlatform
    var selection: TutorialLesson?
    var error: String?
    private(set) var preparing = false
    private(set) var applying = false
    private let root: URL
    private var practices: [URL: TutorialPractice] = [:]
    private var updated: Set<URL> = []
    private var updateErrors: [URL: String] = [:]

    init(platform: TutorialPlatform = .current, root: URL? = nil) {
        self.platform = platform
        self.root = root ?? (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("design.highgain.margined/Tutorial", isDirectory: true)
    }

    func makePractice(_ lesson: TutorialLesson) async throws -> URL {
        guard !preparing else { throw CancellationError() }
        preparing = true; error = nil
        defer { preparing = false }
        let root = root, platform = platform
        let practice = try await Task.detached(priority: .userInitiated) {
            try TutorialPractice.make(lesson: lesson, under: root, platform: platform)
        }.value
        try Task.checkCancellation()
        practices[practice.url.standardizedFileURL] = practice
        return practice.url
    }

    func practice(for url: URL?) -> TutorialPractice? {
        guard let url else { return nil }
        return practices[url.standardizedFileURL]
    }
    func didUpdate(_ url: URL) -> Bool { updated.contains(url.standardizedFileURL) }
    func error(for url: URL) -> String? { updateErrors[url.standardizedFileURL] }

    @discardableResult
    func saveExampleChange(for url: URL) async -> Bool {
        let key = url.standardizedFileURL
        guard !applying, !updated.contains(key), let practice = practices[key], practice.lesson == .changes else { return false }
        applying = true; updateErrors[key] = nil
        defer { applying = false }
        do {
            try await practice.saveExampleChange()
            updated.insert(key)
            return true
        } catch {
            updateErrors[key] = error.localizedDescription
            return false
        }
    }
}

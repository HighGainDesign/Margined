import Foundation
import XCTest
@testable import MarginediOS

@MainActor final class MobileImageFolderTests: XCTestCase {
    func testTwoRememberedRootsRestoreNestedImagesAndDeduplicateSelection() async throws {
        let fixture = try FolderFixture()
        defer { fixture.clean() }
        let scopes = FolderScopes()
        let first = MobileImageFolders(defaults: fixture.defaults, environment: scopes.environment)
        try await first.remember(fixture.first)
        try await first.remember(fixture.second)
        try await first.remember(fixture.first)
        XCTAssertEqual(first.folders.count, 2)
        XCTAssertEqual(scopes.active(fixture.first), 1)
        XCTAssertEqual(scopes.active(fixture.second), 1)
        let restored = MobileImageFolders(defaults: fixture.defaults, environment: scopes.environment)
        await restored.restore()
        XCTAssertEqual(restored.folders.count, 2)
        XCTAssertTrue(restored.errors.isEmpty)
        XCTAssertEqual(scopes.active(fixture.first), 2)
        XCTAssertEqual(scopes.active(fixture.second), 2)
        XCTAssertEqual(try Data(contentsOf: fixture.first.appendingPathComponent("nested/one.svg")), Data("first image".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.second.appendingPathComponent("nested/one.svg")), Data("second image".utf8))
        await restored.restore()
        XCTAssertEqual(scopes.active(fixture.first), 2, "Repeated restoration must not leak scopes")
    }

    func testForgettingOneRootStopsOnlyItsScopeAndPersistsAcrossLaunch() async throws {
        let fixture = try FolderFixture()
        defer { fixture.clean() }
        let scopes = FolderScopes()
        let store = MobileImageFolders(defaults: fixture.defaults, environment: scopes.environment)
        try await store.remember(fixture.first); try await store.remember(fixture.second)
        let first = try XCTUnwrap(store.folders.first { $0.title == fixture.first.lastPathComponent })
        store.forget(first.id)
        XCTAssertEqual(scopes.active(fixture.first), 0)
        XCTAssertEqual(scopes.active(fixture.second), 1)
        let restored = MobileImageFolders(defaults: fixture.defaults, environment: scopes.environment)
        await restored.restore()
        XCTAssertEqual(restored.folders.map(\.title), [fixture.second.lastPathComponent])
        XCTAssertEqual(scopes.active(fixture.first), 0)
        XCTAssertEqual(scopes.active(fixture.second), 2)
    }

    func testFilesAreNotStoredAsFolderGrantsAndFailedRestoreKeepsTheEntryRemovable() async throws {
        let fixture = try FolderFixture()
        defer { fixture.clean() }
        let scopes = FolderScopes()
        let store = MobileImageFolders(defaults: fixture.defaults, environment: scopes.environment)
        do {
            try await store.remember(fixture.first.appendingPathComponent("nested/one.svg"))
            XCTFail("An individual image is not a project folder")
        } catch { }
        XCTAssertTrue(store.folders.isEmpty)
        try await store.remember(fixture.first)
        try FileManager.default.removeItem(at: fixture.first)
        let restored = MobileImageFolders(defaults: fixture.defaults, environment: scopes.environment)
        await restored.restore()
        XCTAssertEqual(restored.folders.count, 1, "Unavailable roots must remain visible for removal or reselection")
        XCTAssertEqual(restored.errors.count, 1)
        XCTAssertEqual(scopes.active(fixture.first), 1, "The failed second acquisition must release its scope")
        if let id = restored.folders.first?.id { restored.forget(id) }
        XCTAssertTrue(restored.errors.isEmpty)
        XCTAssertTrue(MobileImageFolders(defaults: fixture.defaults).folders.isEmpty)
    }
}

private struct FolderFixture {
    let root: URL
    let first: URL
    let second: URL
    let suite: String
    let defaults: UserDefaults
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        first = root.appendingPathComponent("Project", isDirectory: true)
        second = root.appendingPathComponent("Other Images", isDirectory: true)
        suite = "Margined-image-folders-" + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        for (folder, text) in [(first, "first image"), (second, "second image")] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: folder.appendingPathComponent("nested/one.svg"))
        }
    }
    func clean() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class FolderScopes: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [URL: Int] = [:]
    func active(_ url: URL) -> Int { lock.withLock { counts[url, default: 0] } }
    var environment: MobileDocumentEnvironment {
        .init(startAccessing: { [self] url in lock.withLock { counts[url, default: 0] += 1 }; return true },
              stopAccessing: { [self] url in lock.withLock { counts[url, default: 0] -= 1 } },
              willCoordinate: { _, _ in })
    }
}

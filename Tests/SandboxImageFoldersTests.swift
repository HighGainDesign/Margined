#if MARGINED_APP_STORE
import Foundation
import XCTest
@testable import Margined

@MainActor
final class SandboxImageFoldersTests: XCTestCase {
    func testFolderPermissionIsRememberedAcrossStoreInstances() throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let first = SandboxImageFolders(defaults: fixture.defaults)
        try first.allow(fixture.folder)
        XCTAssertEqual(first.folderURLs.map(\.standardizedFileURL), [fixture.folder.standardizedFileURL])
        first.close()
        let reopened = SandboxImageFolders(defaults: fixture.defaults)
        defer { reopened.close() }
        XCTAssertEqual(reopened.folderURLs.map(\.standardizedFileURL), [fixture.folder.standardizedFileURL])
        XCTAssertEqual(try Data(contentsOf: fixture.file), Data("image fixture".utf8))
    }

    func testCorruptBookmarkDoesNotPreventRestoringAValidFolder() throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let first = SandboxImageFolders(defaults: fixture.defaults)
        try first.allow(fixture.folder)
        let saved = try XCTUnwrap(fixture.defaults.array(forKey: SandboxImageFolders.bookmarksKey) as? [Data])
        first.close()
        fixture.defaults.set([Data([0, 1, 2])] + saved, forKey: SandboxImageFolders.bookmarksKey)
        let reopened = SandboxImageFolders(defaults: fixture.defaults)
        defer { reopened.close() }
        XCTAssertEqual(reopened.folderURLs.map(\.standardizedFileURL), [fixture.folder.standardizedFileURL])
        XCTAssertEqual(try Data(contentsOf: fixture.file), Data("image fixture".utf8))
    }

    func testSelectingAFileCannotReplaceAnExistingFolderGrant() throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let store = SandboxImageFolders(defaults: fixture.defaults)
        defer { store.close() }
        try store.allow(fixture.folder)
        let saved = fixture.defaults.array(forKey: SandboxImageFolders.bookmarksKey) as? [Data]
        XCTAssertThrowsError(try store.allow(fixture.file))
        XCTAssertEqual(store.folderURLs.map(\.standardizedFileURL), [fixture.folder.standardizedFileURL])
        XCTAssertEqual(fixture.defaults.array(forKey: SandboxImageFolders.bookmarksKey) as? [Data], saved)
        XCTAssertEqual(try Data(contentsOf: fixture.file), Data("image fixture".utf8))
    }

    func testRepeatedGrantKeepsOtherFoldersAndDoesNotAccumulateDuplicates() throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let other = fixture.folder.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let store = SandboxImageFolders(defaults: fixture.defaults)
        defer { store.close() }
        try store.allow(fixture.folder)
        try store.allow(other)
        try store.allow(fixture.folder)
        XCTAssertEqual(Set(store.folderURLs.map(\.standardizedFileURL)),
                       Set([fixture.folder.standardizedFileURL, other.standardizedFileURL]))
        XCTAssertEqual((fixture.defaults.array(forKey: SandboxImageFolders.bookmarksKey) as? [Data])?.count, 2)
        store.close()
        XCTAssertTrue(store.folderURLs.isEmpty)
        let reopened = SandboxImageFolders(defaults: fixture.defaults)
        defer { reopened.close() }
        XCTAssertEqual(Set(reopened.folderURLs.map(\.standardizedFileURL)),
                       Set([fixture.folder.standardizedFileURL, other.standardizedFileURL]))
    }

    private struct Fixture {
        let folder: URL
        let file: URL
        let defaults: UserDefaults
        let suite: String

        func remove() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func fixture() throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("figure.txt")
        try Data("image fixture".utf8).write(to: file)
        let suite = "MarginedTests.ImageFolders." + UUID().uuidString
        return Fixture(folder: folder, file: file,
                       defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), suite: suite)
    }
}
#endif

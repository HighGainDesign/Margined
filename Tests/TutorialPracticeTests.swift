import Foundation
import XCTest
#if os(iOS)
@testable import MarginediOS
#else
@testable import Margined
#endif

final class TutorialPracticeTests: XCTestCase {
    func testLessonsFollowPlatformCapabilitiesAndKeepAStableOrder() {
        XCTAssertEqual(TutorialLesson.lessons(for: .mobile).first, .opening)
        XCTAssertEqual(TutorialLesson.lessons(for: .mobile).last, .images)
        XCTAssertFalse(TutorialLesson.lessons(for: .mobile).contains(.streaming))
        XCTAssertTrue(TutorialLesson.lessons(for: .mac).contains(.streaming))
        XCTAssertEqual(TutorialLesson.lessons(for: .sandboxedMac), TutorialLesson.lessons(for: .mac))
    }

    func testReplayingCreatesFreshCopiesWithoutTouchingAnExistingDocument() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("Practice.md"), bytes = Data("My own document".utf8)
        try bytes.write(to: existing)
        let first = try TutorialPractice.make(lesson: .checklists, under: root)
        let second = try TutorialPractice.make(lesson: .checklists, under: root)
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertTrue(first.url.path.hasPrefix(root.path + "/"))
        XCTAssertTrue(second.url.path.hasPrefix(root.path + "/"))
        XCTAssertEqual(try Data(contentsOf: existing), bytes)
        XCTAssertTrue(try String(contentsOf: first.url, encoding: .utf8).contains("- [ ]"))
    }

    func testDiscussionPracticeUsesTheExistingPortableThreadFormat() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let practice = try TutorialPractice.make(lesson: .discussions, under: root)
        let source = try String(contentsOf: practice.url, encoding: .utf8)
        let document = try DiscussionCodec.parse(source)
        XCTAssertEqual(document.threads.count, 1)
        XCTAssertEqual(document.threads.first?.messages.count, 2)
        XCTAssertNotEqual(document.threads.first?.messages.first?.id, document.threads.first?.messages.last?.id)
        XCTAssertFalse(document.threads.first?.target.exact.isEmpty ?? true)
    }

    func testExampleUpdateUsesTheGuardedWriterAndIsNotRepeated() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let practice = try TutorialPractice.make(lesson: .changes, under: root)
        let before = try Data(contentsOf: practice.url)
        try await practice.saveExampleChange()
        let after = try Data(contentsOf: practice.url)
        XCTAssertNotEqual(before, after)
        do { try await practice.saveExampleChange(); XCTFail("An obsolete baseline must not be rewritten") }
        catch { XCTAssertEqual(try Data(contentsOf: practice.url), after) }
    }

    func testExampleUpdateNeverOverwritesAnIndependentEdit() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let practice = try TutorialPractice.make(lesson: .changes, under: root)
        let changed = Data("An independently saved reply or checklist update.\n".utf8)
        try changed.write(to: practice.url)
        do { try await practice.saveExampleChange(); XCTFail("Stale practice must be rejected") }
        catch { XCTAssertEqual(try Data(contentsOf: practice.url), changed) }
    }

    func testReplacingPracticeWithASymlinkCannotModifyAnotherFile() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let practice = try TutorialPractice.make(lesson: .changes, under: root)
        let other = root.appendingPathComponent("Other.md"), bytes = try Data(contentsOf: practice.url)
        try bytes.write(to: other)
        try FileManager.default.removeItem(at: practice.url)
        try FileManager.default.createSymbolicLink(at: practice.url, withDestinationURL: other)
        do { try await practice.saveExampleChange(); XCTFail("A replaced pathname must be rejected") }
        catch { XCTAssertEqual(try Data(contentsOf: other), bytes) }
    }

    func testImagePracticeHasTwoLocalDirectoryBranches() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let practice = try TutorialPractice.make(lesson: .images, under: root)
        for relative in ["images/warm/marker.svg", "images/cool/marker.svg"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: practice.url.deletingLastPathComponent().appendingPathComponent(relative).path))
            XCTAssertTrue(try String(contentsOf: practice.url, encoding: .utf8).contains(relative))
        }
    }

    @MainActor
    func testGuideSessionOnlyUpdatesItsOwnRegisteredPracticeFiles() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let session = TutorialSession(platform: .mobile, root: root)
        let other = root.appendingPathComponent("My Document.md"), bytes = Data("My own document.".utf8)
        try bytes.write(to: other)
        let rejected = await session.saveExampleChange(for: other)
        XCTAssertFalse(rejected)
        XCTAssertEqual(try Data(contentsOf: other), bytes)
        let practiceURL = try await session.makePractice(.changes)
        XCTAssertNotNil(session.practice(for: practiceURL))
        let saved = await session.saveExampleChange(for: practiceURL)
        XCTAssertTrue(saved)
        XCTAssertTrue(session.didUpdate(practiceURL))
        XCTAssertEqual(try Data(contentsOf: other), bytes)
    }

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MarginedTour-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}

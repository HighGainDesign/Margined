import Foundation
import XCTest
@testable import Margined

final class ChecklistFileStoreTests: XCTestCase {
    func testWritesOnlyMarkerAndKeepsPermissionsAndLaterAgentEdit() async throws {
        let source = "# Agent checklist\n\n- [ ] Same\n- [ ] Same\n"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data(source.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        let rendered = try await MarkdownRenderer.shared.render(source, mapTasks: true)
        XCTAssertEqual(rendered.tasks.count, 2)
        let updated = try await ChecklistFileStore.setChecked(at: file, source: source, task: rendered.tasks[1], checked: true)
        XCTAssertEqual(updated, "# Agent checklist\n\n- [ ] Same\n- [x] Same\n")
        XCTAssertEqual(try MarkdownSource.read(file), updated)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o640)
        let agent = "# Agent checklist\n\n- [ ] Added by agent\n- [x] Same\n"
        try agent.write(to: file, atomically: true, encoding: .utf8)
        let current = try await MarkdownRenderer.shared.render(updated, mapTasks: true)
        do {
            _ = try await ChecklistFileStore.setChecked(at: file, source: updated, task: current.tasks[0], checked: true)
            XCTFail("Stale click must not overwrite agent updates")
        } catch { XCTAssertEqual(try MarkdownSource.read(file), agent) }
    }

    func testUTF16FileChangesOnlyTheMarkerByte() async throws {
        let source = "# 日本語\r\n- [X] Completed\r\n"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let data = Data([254,255]) + source.data(using: .utf16BigEndian)!
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let rendered = try await MarkdownRenderer.shared.render(source, mapTasks: true)
        let task = try XCTUnwrap(rendered.tasks.first)
        let updated = try await ChecklistFileStore.setChecked(at: file, source: source, task: task, checked: false)
        XCTAssertEqual(updated, source.replacingOccurrences(of: "[X]", with: "[ ]"))
        let saved = try Data(contentsOf: file)
        XCTAssertEqual(saved.count, data.count)
        XCTAssertEqual(zip(data, saved).filter { $0 != $1 }.count, 1)
        XCTAssertTrue(saved.starts(with: [254,255]))
    }
}

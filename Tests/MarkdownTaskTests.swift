import Foundation
import XCTest
import SwiftSoup
@testable import Margined

final class MarkdownTaskTests: XCTestCase {
    func testMapsOnlyActualTasksIncludingNestedQuotedOrderedAndUnicode() async throws {
        let text = """
        # Checklist
        - [ ] **Café** 日本語
          - [X] Child
        > - [ ] Quoted
        1. [ ] Ordered

        ```md
        - [ ] Not a task
        ```

        Prose [ ] checkbox
        """
        let result = try await MarkdownRenderer.shared.render(text, mapTasks: true)
        XCTAssertEqual(result.checkboxCount, 4)
        XCTAssertEqual(result.tasks.map(\.label), ["Café 日本語", "Child", "Quoted", "Ordered"])
        XCTAssertEqual(result.tasks.map(\.checked), [false, true, false, false])
        for task in result.tasks {
            let edited = try MarkdownTasks.patch(Data(text.utf8), expectedSource: text, task: task, checked: !task.checked)
            let newBytes = Array(edited), oldBytes = Array(text.utf8)
            XCTAssertEqual(zip(oldBytes, newBytes).filter { $0 != $1 }.count, 1)
            XCTAssertEqual(newBytes[task.utf8Offset], task.checked ? 32 : 120)
        }
        XCTAssertTrue(result.html.contains("data-margined-task"), result.html)
        let inputs = try SwiftSoup.parse(result.html).select("input")
        XCTAssertEqual(inputs.size(), 4)
        for input in inputs.array() {
            let html = try input.outerHtml()
            XCTAssertTrue(input.hasAttr("disabled"), html)
            XCTAssertTrue(input.hasAttr("data-margined-task"), html)
        }
    }

    func testDuplicateLabelsUseDistinctSourceMarkers() async throws {
        let source = "- [ ] Same\n- [ ] Same\n"
        let rendered = try await MarkdownRenderer.shared.render(source, mapTasks: true)
        XCTAssertEqual(rendered.tasks.count, 2)
        let changed = try MarkdownTasks.patch(Data(source.utf8), expectedSource: source, task: rendered.tasks[1], checked: true)
        XCTAssertEqual(String(decoding: changed, as: UTF8.self), "- [ ] Same\n- [x] Same\n")
    }

    func testAccessibleTaskNamesDescribeTextWithoutDuplicatingStateOrNestedItems() async throws {
        let source = "- [ ] **Review scope**\n  - [x] Nested task\n- [X] Café 日本語\n"
        for mapTasks in [false, true] {
            let result = try await MarkdownRenderer.shared.render(source, mapTasks: mapTasks)
            let inputs = try SwiftSoup.parse(result.html).select("input").array()
            XCTAssertEqual(try inputs.map { try $0.attr("aria-label") }, ["Review scope", "Nested task", "Café 日本語"])
        }
    }

    func testPreservesBOMEncodingLineEndingsAndUnrelatedBytes() async throws {
        let source = "# 日本語 🐻\r\n\r\n- [ ] Café\r\n"
        let rendered = try await MarkdownRenderer.shared.render(source, mapTasks: true)
        let task = try XCTUnwrap(rendered.tasks.first)
        let changed = source.replacingOccurrences(of: "[ ]", with: "[x]")
        let samples = [Data(source.utf8), Data([239,187,191]) + Data(source.utf8),
                       Data([255,254]) + source.data(using: .utf16LittleEndian)!,
                       Data([254,255]) + source.data(using: .utf16BigEndian)!]
        for data in samples {
            let patched = try MarkdownTasks.patch(data, expectedSource: source, task: task, checked: true)
            XCTAssertEqual(try MarkdownSource.decode(patched), changed)
            XCTAssertEqual(patched.count, data.count)
            XCTAssertEqual(zip(data, patched).filter { $0 != $1 }.count, 1)
        }
    }

    func testRejectsStaleSourceAndWrongMarker() async throws {
        let source = "- [ ] Original\n"
        let result = try await MarkdownRenderer.shared.render(source, mapTasks: true)
        let task = try XCTUnwrap(result.tasks.first)
        XCTAssertThrowsError(try MarkdownTasks.patch(Data("- [ ] Agent changed this\n".utf8), expectedSource: source, task: task, checked: true))
        let wrong = MarkdownTask(id: 0, utf8Offset: 0, marker: 32, label: "Wrong")
        XCTAssertThrowsError(try MarkdownTasks.patch(Data(source.utf8), expectedSource: source, task: wrong, checked: true))
    }

    func testChecklistMappingDoesNotCreateFalseReviewChanges() async throws {
        let source = "- [ ] Task\n\nOld text."
        let rendered = try await MarkdownRenderer.shared.render(source, baseline: source, mapTasks: true)
        XCTAssertEqual(rendered.changes.count, 0)
        XCTAssertEqual(rendered.tasks.count, 1)
        let update = try await MarkdownRenderer.shared.render("- [ ] Task\n\nNew text.", baseline: source, mapTasks: true)
        XCTAssertEqual(update.changes.count, 1)
        XCTAssertEqual(update.tasks.count, 1)
    }

    func testLinkFollowingTableIsNotDuplicatedWhenPreparingAccessibleTasks() async throws {
        let source = "- [ ] Task\n\n| Phase | Status |\n| --- | --- |\n| Plan | Ready |\n\n[Apple design guidance](https://developer.apple.com/)\n"
        let result = try await MarkdownRenderer.shared.render(source, baseline: source, mapTasks: true)
        let document = try SwiftSoup.parse(result.html)
        XCTAssertEqual(try document.select("a").size(), 1)
        XCTAssertEqual(try document.body()?.text().components(separatedBy: "Apple design guidance").count, 2, result.html)
        let captionSource = "| Phase | Status |\n| --- | --- |\n| Plan | Ready |\n\n[Table summary]\n\nSee [reference](https://example.com/).\n"
        let captioned = try await MarkdownRenderer.shared.render(captionSource)
        XCTAssertEqual(try SwiftSoup.parse(captioned.html).select("figcaption").text(), "Table summary")
    }

    func testCodeAndRawHTMLNeverBecomeEditableTasks() async throws {
        let source = "```\n- [ ] Code\n```\n\n<input type=checkbox>\n\nNot a list [ ] Task"
        let result = try await MarkdownRenderer.shared.render(source, mapTasks: true)
        XCTAssertTrue(result.tasks.isEmpty)
        XCTAssertEqual(result.checkboxCount, 0)
    }
    func testTableLinkIsNotDuplicatedWithHeadingAndNestedChecklistContext() async throws {
        let source = """
        # Project brief

        A small Markdown viewer for reviewing documents from an agent.

        ## Checklist

        - [x] Review the scope
        - [x] Collect evidence
        - [ ] Verify the release
          - [x] Check a nested item

        > - [ ] Review a quoted item

        ## Results

        | Phase | Owner | Status |
        | --- | --- | --- |
        | Plan | Writer | Ready |
        | Verify | Reader | Pending |

        [Apple design guidance](https://developer.apple.com/design/human-interface-guidelines/)

        ## Notes

        Keep the original formatting when changing checkmarks.

        ```swift
        let preview = "read-only by default"
        ```

        ## Next steps

        Return to the checklist after reviewing the table.
        """
        let result = try await MarkdownRenderer.shared.render(source, mapTasks: true)
        let document = try SwiftSoup.parse(result.html)
        XCTAssertEqual(try document.body()?.text().components(separatedBy: "Apple design guidance").count, 2, result.html)
    }

}

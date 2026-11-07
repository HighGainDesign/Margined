import XCTest
import SwiftSoup
@testable import MarginediOS

final class RenderingTests: XCTestCase {
    #if os(iOS)
    override func setUp() async throws {
        try await super.setUp()
        try await WebKitTestReadiness.diagramRendering()
    }
    #endif

    func testPipelineAndFencedTasksKeepTheirSourceMappings() async throws {
        for source in ["- [ ] One `echo a | cat`.\n- [x] Two `echo b | cat`.\n",
                       "- [ ] Run commands.\n  ```sh\n  echo a | cat\n  ```\n- [x] Finish.\n"] {
            let rendered = try await MarkdownRenderer.shared.render(source, mapTasks: true)
            XCTAssertEqual(rendered.checkboxCount, 2)
            XCTAssertEqual(rendered.tasks.count, 2)
            let task = try XCTUnwrap(rendered.tasks.first)
            let changed = try MarkdownTasks.patch(Data(source.utf8), expectedSource: source, task: task, checked: true)
            XCTAssertEqual(zip(Data(source.utf8), changed).filter { $0 != $1 }.count, 1)
        }
    }

    func testSingleCellTablesKeepLeadingOnlyRows() async throws {
        for source in ["| Heading\n| --- |\n| Value |\n", "| --- |\n| value\n"] {
            let rendered = try await MarkdownRenderer.shared.render(source)
            let document = try SwiftSoup.parse(rendered.html)
            XCTAssertEqual(try document.select("table").size(), 1)
            XCTAssertEqual(try document.select("tbody td, tbody th").text().lowercased(), "value")
            if source.contains("Heading") { XCTAssertEqual(try document.select("th").text(), "Heading") }
        }
    }

    #if DEBUG
    func testTrustedStartupLongerThanTheDiagramBudgetStillRenders() async throws {
        let artifact = await DiagramRenderer.renderForTesting("flowchart LR\nA[Read]-->B[Review]",
            minimumStartupDuration: .seconds(3.2))
        let image = try XCTUnwrap(artifact?.image, "Trusted WebKit startup must not consume the authored diagram's execution budget")
        XCTAssertTrue(image.hasPrefix("data:image/svg+xml;base64,"))
        let encoded = try XCTUnwrap(image.split(separator: ",", maxSplits: 1).last)
        let svg = try XCTUnwrap(Data(base64Encoded: String(encoded)))
        let document = try SwiftSoup.parse(String(decoding: svg, as: UTF8.self), "", Parser.xmlParser())
        XCTAssertEqual(try document.select("svg[role=img]").size(), 1)
        XCTAssertTrue(try document.text().contains("Read"))
        XCTAssertTrue(try document.text().contains("Review"))
    }

    func testTrustedStartupStillHasATotalDeadline() async {
        let artifact = await DiagramRenderer.renderForTesting("flowchart LR\nA-->B", minimumStartupDuration: .seconds(7))
        XCTAssertNil(artifact, "An indefinitely initializing worker must stop before accepting author source")
    }
    #endif

    func testSharedRenderingIncludesAlertsMathDiagramsAndMappedTasks() async throws {
        let source = "# Mobile reader\n\n> [!NOTE]\n> Read offline.\n\nFraction $\\frac{1}{2}$.\n\n```mermaid\nflowchart LR\nA[Read]-->B[Review]\n```\n\n- [ ] Check $x^2$\n"
        let result = try await MarkdownRenderer.shared.render(source, mapTasks: true, prepareSpeech: true)
        let doc = try SwiftSoup.parse(result.html)
        XCTAssertEqual(try doc.select("blockquote.margined-alert-note").size(), 1)
        XCTAssertEqual(try doc.select("math mfrac").size(), 1)
        XCTAssertEqual(try doc.select("figure.margined-diagram > img").size(), 1)
        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertFalse(try XCTUnwrap(result.speech).segments.isEmpty)
        XCTAssertEqual(try doc.select("script, iframe").size(), 0)
    }
}

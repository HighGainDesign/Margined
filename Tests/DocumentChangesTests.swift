import Foundation
import XCTest
import SwiftSoup
import WebKit
@testable import Margined

final class DocumentChangesTests: XCTestCase {
    func testAdditionEditRemovalAndUnchangedBlocks() async throws {
        let before = "# Plan\n\nKeep this paragraph.\n\nThe **old** plan has [details](https://example.com).\n\nRemove this paragraph.\n\n## End\n\nUnchanged ending."
        let after = "# Plan\n\nKeep this paragraph.\n\nThe **new** plan has [details](https://example.com).\n\n## End\n\nUnchanged ending.\n\nA new paragraph."
        let output = try await MarkdownRenderer.shared.render(after, baseline: before)
        XCTAssertEqual(output.changes.entries.map(\.kind), [.edited, .removed, .added])
        let document = try SwiftSoup.parse(output.html)
        XCTAssertEqual(try document.select(".margined-change").size(), 2)
        XCTAssertEqual(try document.select("strong mark").text(), "new")
        XCTAssertEqual(try document.select("a").first()?.attr("href"), "https://example.com")
        XCTAssertFalse(try document.select(".margined-change").text().contains("Keep this paragraph."))
        XCTAssertEqual(output.changes.entries[1].before, "Remove this paragraph.")
        XCTAssertNil(output.changes.entries[1].targetID)
    }

    func testTableCellChangeKeepsTableStructure() async throws {
        let before = "| Item | State |\n|---|---|\n| One | Pending |\n| Two | Ready |"
        let after = before.replacingOccurrences(of: "Pending", with: "Complete")
        let output = try await MarkdownRenderer.shared.render(after, baseline: before)
        let document = try SwiftSoup.parse(output.html)
        XCTAssertEqual(output.changes.count, 1)
        XCTAssertEqual(try document.select("table").size(), 1)
        XCTAssertEqual(try document.select("td.margined-change mark").text(), "Complete")
        XCTAssertEqual(try document.select("td").size(), 4)
    }

    func testIdenticalAndEquivalentMarkdownHaveNoHighlights() async throws {
        let identical = try await MarkdownRenderer.shared.render("# A\n\nNote.", baseline: "# A\n\nNote.")
        let equivalent = try await MarkdownRenderer.shared.render("**Bold**", baseline: "__Bold__")
        XCTAssertEqual(identical.changes.count, 0)
        XCTAssertEqual(equivalent.changes.count, 0)
    }

    func testUnicodeCodeAndUnsafeTextRemainIntact() async throws {
        let before = "Café **日本語 old**\n\n```swift\nlet x = 1\n```"
        let after = "Café **日本語 👁️ new**\n\n```swift\nlet x = 2\n```\n\n`<script>alert(1)</script>`"
        let output = try await MarkdownRenderer.shared.render(after, baseline: before)
        let document = try SwiftSoup.parse(output.html)
        XCTAssertTrue(try document.body()?.text(trimAndNormaliseWhitespace: false).contains("Café 日本語 👁️ new") == true)
        XCTAssertTrue(try document.select("pre code").text().contains("let x = 2"))
        XCTAssertEqual(try document.select("script").size(), 0)
        XCTAssertEqual(output.changes.count, 3)
    }

    func testDeletionOfWholeDocumentAppearsInSummary() async throws {
        let output = try await MarkdownRenderer.shared.render("", baseline: "# Deleted\n\nOld content.")
        XCTAssertEqual(output.changes.count, 2)
        XCTAssertTrue(output.changes.entries.allSatisfy { $0.kind == .removed })
        XCTAssertTrue(output.changes.navigable.isEmpty)
    }

    @MainActor
    func testBrowserPreservesChangedUnicodeSpacing() async throws {
        let output = try await MarkdownRenderer.shared.render("Café **日本語 👁️ new**", baseline: "Café **日本語 old**")
        let reader = ReaderState()
        let coordinator = MarkdownWebView.Coordinator(reader: reader)
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        coordinator.webView = webView
        webView.navigationDelegate = coordinator
        coordinator.load(output.html)
        for _ in 0..<100 where webView.url == nil || webView.isLoading {
            try await Task.sleep(for: .milliseconds(50))
        }
        let text = try await webView.evaluateJavaScript("document.querySelector('p').textContent") as? String
        XCTAssertEqual(text, "Café 日本語 👁️ new")
    }

    @MainActor
    func testMultipleSavesAccumulateUntilReviewed() async throws {
        let reader = ReaderState()
        reader.fileURL = URL(fileURLWithPath: "/tmp/notes.md")
        reader.source = "First version."
        reader.acceptFileUpdate("Second version.")
        try await waitForRender(reader)
        XCTAssertEqual(reader.changes.entries.first?.before, "First version.")
        reader.acceptFileUpdate("Third version.")
        try await waitForRender(reader)
        XCTAssertEqual(reader.changes.entries.first?.before, "First version.")
        reader.wide.toggle()
        reader.render()
        try await waitForRender(reader)
        XCTAssertEqual(reader.changes.count, 1)
        reader.markReviewed()
        try await waitForRender(reader)
        XCTAssertEqual(reader.changes.count, 0)
        reader.acceptFileUpdate("Fourth version.")
        try await waitForRender(reader)
        XCTAssertEqual(reader.changes.entries.first?.before, "Third version.")
        reader.stop()
    }

    @MainActor
    private func waitForRender(_ reader: ReaderState) async throws {
        // A unique final source must appear in the rendered page before assertions.
        let expected = reader.source
        for _ in 0..<100 {
            if let html = reader.rendered?.html, html.contains(expected.components(separatedBy: " ").first ?? ""),
               reader.changes.entries.first?.after == expected || reader.changes.count == 0 {
                // Allow a baseline/width-only render to finish too.
                try await Task.sleep(for: .milliseconds(40))
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Document render did not complete")
    }
}

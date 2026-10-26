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

    func testIdenticalBaselineRetainsCleanSnapshotForNextReview() async throws {
        let source = "# Plan\n\n- [ ] Review scope\n\n| Item | State |\n| --- | --- |\n| Alpha | Pending |\n"
        let first = try await MarkdownRenderer.shared.render(source, baseline: source, mapTasks: true,
            documentLanguage: "en", prepareSpeech: true)
        let baseline = try XCTUnwrap(first.comparisonBaseline)
        XCTAssertEqual(first.changes.count, 0)
        XCTAssertEqual(first.tasks.count, 1)
        XCTAssertEqual(first.speech?.segments.map(\.text), ["Plan", "Unchecked: Review scope", "Item: Alpha; State: Pending"])
        let cleanHTML = baseline.map(\.html).joined()
        XCTAssertFalse(cleanHTML.contains("data-margined-speech"))
        XCTAssertFalse(cleanHTML.contains("data-margined-task"))
        XCTAssertFalse(cleanHTML.contains("margined-change"))

        let updated = source.replacingOccurrences(of: "[ ]", with: "[x]").replacingOccurrences(of: "Pending", with: "Ready")
        let next = try await MarkdownRenderer.shared.render(updated, reviewedUnits: baseline, mapTasks: true,
            documentLanguage: "en", prepareSpeech: true)
        XCTAssertEqual(next.changes.count, 2)
        XCTAssertTrue(next.changes.entries.allSatisfy { $0.kind == .edited })
        XCTAssertTrue(next.changes.entries.contains { $0.before == "Pending" && $0.after == "Ready" })
        XCTAssertEqual(next.speech?.segments.map(\.text), ["Plan", "Checked: Review scope", "Item: Alpha; State: Ready"])
    }

    func testCanonicallyEquivalentSourceKeepsOriginalBaselineBytes() async throws {
        let before = "Caf\u{00e9} review."
        let current = "Cafe\u{0301} review."
        XCTAssertEqual(before, current)
        XCTAssertNotEqual(Array(before.utf8), Array(current.utf8))
        let output = try await MarkdownRenderer.shared.render(current, baseline: before, prepareSpeech: true)
        let baseline = try XCTUnwrap(output.comparisonBaseline)
        let unit = try XCTUnwrap(baseline.first)
        XCTAssertEqual(output.changes.count, 0)
        XCTAssertEqual(Array(unit.html.utf8), Array(before.utf8))
    }

    func testReviewedUnitsOverrideIdenticalCurrentSourceBaseline() async throws {
        let before = "The state is Pending."
        let current = "The state is Ready."
        let first = try await MarkdownRenderer.shared.render(before, baseline: before)
        let units = try XCTUnwrap(first.comparisonBaseline)
        let next = try await MarkdownRenderer.shared.render(current, baseline: current, reviewedUnits: units,
            prepareSpeech: true)
        XCTAssertEqual(next.comparisonBaseline, units)
        XCTAssertEqual(next.changes.count, 1)
        XCTAssertEqual(next.changes.entries.first?.before, before)
        XCTAssertEqual(next.changes.entries.first?.after, current)
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

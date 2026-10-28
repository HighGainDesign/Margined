import Foundation
import SwiftSoup
import XCTest
#if MARGINED_DISCUSSION_PROBE
#elseif os(iOS)
@testable import MarginediOS
#else
@testable import Margined
#endif

final class DiscussionAnchorTests: XCTestCase {
    func testVisibleProjectionIncludesSemanticContentAcrossFormatting() throws {
        let html = """
        <h1>Plan</h1><p>Cafe<em>́</em> <strong>bold</strong> and <a href="https://example.com">link</a>.</p>
        <ul><li><input type="checkbox" checked>Read <code>value</code><ul><li>Nested</li></ul></li></ul>
        <table><tr><th>Name</th><th>State</th></tr><tr><td>One</td><td>Ready</td></tr></table>
        <pre><code>let x = 1;\n  print(x)</code></pre><p><img src="x.png" alt="Diagram label"> after image.</p>
        """
        let projection = try DiscussionText.project(html: html, source: "fixture")
        XCTAssertEqual(projection.text, "Plan Café bold and link. Read value Nested Name State One Ready let x = 1; print(x) Diagram label after image.")
        XCTAssertEqual(projection.units.first?.kind, "h1")
        XCTAssertEqual(projection.units.last?.section, "Plan")
        let raw = projection.text as NSString
        let range = raw.range(of: "Café bold and link.")
        let selection = try XCTUnwrap(projection.selection(range, renderID: "render-1"))
        XCTAssertEqual(selection.target.exact, "Café bold and link.")
        XCTAssertEqual(selection.sourceID, projection.sourceID)
        XCTAssertEqual(selection.renderID, "render-1")
    }

    func testNormalizationAndGeneratedContextsUseUnicodeScalars() throws {
        XCTAssertEqual(DiscussionText.normalized(" \tCafe\u{301}\n\u{00a0}日本語\r\n 👁️ "), "Café 日本語 👁️")
        let projection = try DiscussionText.project(html: "<p>" + String(repeating: "🐈", count: 40) + " Target " + String(repeating: "界", count: 40) + "</p>", source: "unicode")
        let range = (projection.text as NSString).range(of: "Target")
        let selection = try XCTUnwrap(projection.selection(range, renderID: "r"))
        XCTAssertLessThanOrEqual(selection.target.prefix.unicodeScalars.count, 32)
        XCTAssertLessThanOrEqual(selection.target.suffix.unicodeScalars.count, 32)
        XCTAssertTrue(selection.target.prefix.hasSuffix("🐈 "))
        XCTAssertTrue(selection.target.suffix.hasPrefix(" 界"))
    }

    func testProjectionExcludesNotesControlsAndArtworkAndRejectsSelectionAcrossThem() throws {
        let html = """
        <!-- margined:thread v1\nnot prose\n-->
        <p>Before <span class="margined-math">x + y</span> after.</p>
        <figure class="margined-diagram"><pre><code>graph TD; A-->B</code></pre><img alt="Generated artwork"></figure>
        <p>End <input type="checkbox" checked><span aria-hidden="true">decoration</span><span hidden>hidden</span>.</p>
        """
        let projection = try DiscussionText.project(html: html, source: "artwork")
        XCTAssertEqual(projection.text, "Before after. End .")
        XCTAssertNil(projection.selection((projection.text as NSString).range(of: "Before after."), renderID: "r"))
        XCTAssertNotNil(projection.selection((projection.text as NSString).range(of: "after."), renderID: "r"))
        XCTAssertFalse(projection.barriers.isEmpty)
    }

    func testSelectionsCannotSplitComposedTextOrExceedTheCurrentProjection() throws {
        let projection = try DiscussionText.project(html: "<p>👁️ Café</p>", source: "range")
        XCTAssertNil(projection.selection(NSRange(location: 1, length: 1), renderID: "r"))
        XCTAssertNil(projection.selection(NSRange(location: -1, length: 3), renderID: "r"))
        XCTAssertNil(projection.selection(NSRange(location: 0, length: Int.max), renderID: "r"))
        XCTAssertNil(projection.selection(NSRange(location: 0, length: 0), renderID: "r"))
        XCTAssertNotNil(projection.selection(NSRange(location: 0, length: 3), renderID: "r"))
    }

    private func target(_ exact: String = "Target.", prefix: String, suffix: String) -> DiscussionTarget {
        DiscussionTarget(type: "TextQuoteSelector", exact: exact, prefix: prefix, suffix: suffix, section: nil)
    }
    private func document(_ target: DiscussionTarget) -> DiscussionDocument {
        let message = DiscussionMessage(id: "m1", author: "Reviewer", created: "2026-10-23T10:00:00Z", body: "Discuss.", inReplyTo: nil)
        let thread = DiscussionThread(id: "t1", state: .open, target: target, messages: [message], resolvedBy: nil, resolved: nil, attachmentHistory: [])
        let block = DiscussionBlock(range: 0..<0, line: 1, version: "v1", hasCertainExtent: true, thread: thread, syntax: nil, yamlOffset: 0)
        return DiscussionDocument(source: "", blocks: [block], diagnostics: [])
    }
    private func anchor(_ target: DiscussionTarget, html: String, previous: DiscussionTextProjection? = nil) throws -> DiscussionAnchorResult? {
        let current = try DiscussionText.project(html: html, source: "new", targets: ["t1": target])
        return DiscussionAnchors.resolve(document: document(target), current: current, previous: previous)["t1"]
    }

    func testContextsDisambiguateDuplicateQuotesAndUniqueMoves() throws {
        let saved = target(prefix: "One", suffix: "Two")
        let attached = try anchor(saved, html: "<p>Earlier Target. Other</p><p>One Target. Two</p>")
        XCTAssertEqual(attached?.status, .attached)
        XCTAssertEqual(attached?.range, NSRange(location: 26, length: 7))
        XCTAssertEqual(try anchor(saved, html: "<p>Moved text.</p><p>One Target. Two</p>")?.status, .attached)
        XCTAssertEqual(try anchor(saved, html: "<p>Changed Target. Different</p>")?.status, .needsConfirmation)
        XCTAssertEqual(try anchor(saved, html: "<p>No matching quotation.</p>")?.status, .missing)
    }

    func testConflictingCandidateContextsRemainAmbiguous() throws {
        let saved = target(prefix: "One", suffix: "Two")
        XCTAssertEqual(try anchor(saved, html: "<p>One Target. Changed</p><p>Different Target. Two</p>")?.status, .ambiguous)
        XCTAssertEqual(try anchor(saved, html: "<p>One Target. Two</p><p>One Target. Two</p>")?.status, .ambiguous)
    }

    func testContextFreeQuoteRequiresConfirmationExceptWholeDocument() throws {
        let saved = target(prefix: "", suffix: "")
        XCTAssertEqual(try anchor(saved, html: "<p>Intro Target. End</p>")?.status, .needsConfirmation)
        XCTAssertEqual(try anchor(saved, html: "<p>Target.</p>")?.status, .attached)
    }

    func testPreviousUniqueUnchangedPassageCanMoveWithChangedContext() throws {
        let saved = target(prefix: "Old before", suffix: "Old after")
        let old = try DiscussionText.project(html: "<p>Old before</p><p>Target.</p><p>Old after</p>", source: "old", targets: ["t1": saved])
        XCTAssertEqual(try anchor(saved, html: "<p>New intro</p><p>New context</p><p>Target.</p><p>New ending</p>", previous: old)?.status, .attached)
    }

    func testDeletedPassageDoesNotRetargetAnotherEqualQuote() throws {
        let saved = target(prefix: "Intro", suffix: "Middle")
        let old = try DiscussionText.project(html: "<p>Intro</p><p>Target.</p><p>Middle</p><p>Target.</p><p>End</p>", source: "old", targets: ["t1": saved])
        XCTAssertEqual(try anchor(saved, html: "<p>Intro</p><p>Middle</p><p>Target.</p><p>End</p>", previous: old)?.status, .missing)
        XCTAssertEqual(try anchor(saved, html: "<p>Intro</p><p>Target.</p><p>End</p>", previous: old)?.status, .needsConfirmation)
    }

    func testChangedExternalTargetDoesNotInheritOldPassageIdentity() throws {
        let oldTarget = target(prefix: "Intro", suffix: "End")
        let old = try DiscussionText.project(html: "<p>Intro</p><p>Target.</p><p>End</p>", source: "old", targets: ["t1": oldTarget])
        let newTarget = target(prefix: "Different", suffix: "Surroundings")
        XCTAssertEqual(try anchor(newTarget, html: "<p>Intro</p><p>Target.</p><p>End</p>", previous: old)?.status, .needsConfirmation)
    }
    func testKnownDeletionRemainsUnattachedDuringLaterRefreshes() throws {
        let saved = target(prefix: "Intro", suffix: "Middle")
        let old = try DiscussionText.project(html: "<p>Intro</p><p>Target.</p><p>Middle</p><p>Target.</p><p>End</p>", source: "old", targets: ["t1": saved])
        var deleted = try DiscussionText.project(html: "<p>Intro</p><p>Middle</p><p>Target.</p><p>End</p>", source: "deleted", targets: ["t1": saved])
        deleted.anchorResults = DiscussionAnchors.resolve(document: document(saved), current: deleted, previous: old)
        XCTAssertEqual(deleted.anchorResults["t1"]?.status, .missing)
        let later = try DiscussionText.project(html: "<p>Intro</p><p>Target.</p><p>Middle</p><p>End</p>", source: "new copy of context", targets: ["t1": saved])
        XCTAssertEqual(DiscussionAnchors.resolve(document: document(saved), current: later, previous: deleted)["t1"]?.status, .missing)
        var explicitlyReattached = later
        explicitlyReattached.attachmentVersions["t1"] = 1
        XCTAssertEqual(DiscussionAnchors.resolve(document: document(saved), current: explicitlyReattached, previous: deleted)["t1"]?.status, .attached)
    }

    func testBridgeAcceptsOnlyCurrentMainFrameAllowedThreadMessages() throws {
        let projection = try DiscussionText.project(html: "<p>A passage.</p>", source: "bridge")
        let context = DiscussionBridge.Context(token: "render-1", sourceID: projection.sourceID, enabled: true, allowedThreadIDs: ["t1"])
        let body: [String: Any] = ["kind": "openThread", "id": "t1", "token": "render-1", "sourceID": projection.sourceID]
        XCTAssertEqual(DiscussionBridge.request(body, isMainFrame: true, context: context, projection: projection), .openThread("t1"))
        XCTAssertNil(DiscussionBridge.request(body, isMainFrame: false, context: context, projection: projection))
        for (key, value) in [("token", "old"), ("sourceID", "old"), ("id", "unknown")] {
            var altered = body; altered[key] = value
            XCTAssertNil(DiscussionBridge.request(altered, isMainFrame: true, context: context, projection: projection))
        }
        let disabled = DiscussionBridge.Context(token: "render-1", sourceID: projection.sourceID, enabled: false, allowedThreadIDs: ["t1"])
        XCTAssertNil(DiscussionBridge.request(body, isMainFrame: true, context: disabled, projection: projection))
    }

    func testBridgeDerivesSelectionFromCurrentProjectionAndRejectsCoercedOffsets() throws {
        let projection = try DiscussionText.project(html: "<p>A passage.</p>", source: "bridge")
        let context = DiscussionBridge.Context(token: "r", sourceID: projection.sourceID, enabled: true, allowedThreadIDs: [])
        let body: [String: Any] = ["kind": "selection", "token": "r", "sourceID": projection.sourceID,
            "location": 2, "length": 8, "quote": "passage.", "startUnit": 0, "startOffset": 2, "endUnit": 0, "endOffset": 10]
        let expected = try XCTUnwrap(projection.selection(NSRange(location: 2, length: 8), renderID: "r"))
        XCTAssertEqual(DiscussionBridge.request(body, isMainFrame: true, context: context, projection: projection), .selection(expected))
        for bad: Any in [true, -1, 1.5, Double.nan, Double.infinity, "2", NSNumber(value: UInt64.max)] {
            var altered = body; altered["location"] = bad
            XCTAssertNil(DiscussionBridge.request(altered, isMainFrame: true, context: context, projection: projection))
        }
        for (key, bad) in [("quote", "Forged passage"), ("sourceID", "another-file")] {
            var altered = body; altered[key] = bad
            XCTAssertNil(DiscussionBridge.request(altered, isMainFrame: true, context: context, projection: projection))
        }
        var wrongDOM = body; wrongDOM["startOffset"] = 0
        XCTAssertNil(DiscussionBridge.request(wrongDOM, isMainFrame: true, context: context, projection: projection))
    }

    func testDisplayBreadcrumbCannotReattachAKnownDeletedPassage() throws {
        let saved = target(prefix: "Intro", suffix: "Middle")
        let old = try DiscussionText.project(html: "<p>Intro</p><p>Target.</p><p>Middle</p><p>Target.</p><p>End</p>", source: "old", targets: ["t1": saved])
        var deleted = try DiscussionText.project(html: "<p>Intro</p><p>Middle</p><p>Target.</p><p>End</p>", source: "deleted", targets: ["t1": saved])
        deleted.anchorResults = DiscussionAnchors.resolve(document: document(saved), current: deleted, previous: old)
        let renamedSection = DiscussionTarget(type: saved.type, exact: saved.exact, prefix: saved.prefix, suffix: saved.suffix, section: "Different heading")
        let later = try DiscussionText.project(html: "<p>Intro</p><p>Target.</p><p>Middle</p><p>End</p>", source: "copy", targets: ["t1": renamedSection])
        XCTAssertEqual(DiscussionAnchors.resolve(document: document(renamedSection), current: later, previous: deleted)["t1"]?.status, .missing)
    }

}

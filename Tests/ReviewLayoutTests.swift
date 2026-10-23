import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Margined

@MainActor
final class ReviewLayoutTests: XCTestCase {
    func testShowingFindAgainReturnsTypingFocusAfterDocumentNavigation() async throws {
        let fixture = try await makeFixture(width: 1_200)
        defer { fixture.window.close(); fixture.reader.stop(); try? FileManager.default.removeItem(at: fixture.file) }
        let web = try XCTUnwrap(findWebView(fixture.controller.view))
        fixture.reader.showFind = true
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(fixture.window.firstResponder is NSTextView)
        fixture.window.makeFirstResponder(web)
        fixture.reader.navigate(to: "table")
        try await Task.sleep(for: .milliseconds(10))
        fixture.reader.showFind = true // Same request the actual Cmd-F handler makes.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(fixture.window.firstResponder is NSTextView,
                      "Showing an already-open Find must return typing to its field")
        XCTAssertEqual(try MarkdownSource.read(fixture.file), fixture.updated)
    }

    func testQueryUpdatesDoNotRefocusFindWithoutARequest() async throws {
        let fixture = try await makeFixture(width: 1_200)
        defer { fixture.window.close(); fixture.reader.stop(); try? FileManager.default.removeItem(at: fixture.file) }
        fixture.reader.showFind = true
        try await Task.sleep(for: .milliseconds(300))
        let web = try XCTUnwrap(findWebView(fixture.controller.view))
        fixture.window.makeFirstResponder(web)
        let documentResponder = fixture.window.firstResponder
        fixture.reader.searchText = "Ready"
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(fixture.window.firstResponder === documentResponder,
                      "Updating the query must not steal focus back from the document")
        XCTAssertEqual(try MarkdownSource.read(fixture.file), fixture.updated)
    }

    func testWideReviewPanelOccupiesSpaceBesideTheDocument() async throws {
        let fixture = try await makeFixture(width: 1_200)
        defer { fixture.window.close(); fixture.reader.stop(); try? FileManager.default.removeItem(at: fixture.file) }
        let originalWebView = try XCTUnwrap(findWebView(fixture.controller.view))
        _ = try await originalWebView.evaluateJavaScript("window.marginedTestDocument = document; true")
        fixture.reader.showChanges = true
        let panel = try await waitForPanel(in: fixture.controller.view)
        let document = frameInScreen(originalWebView)
        XCTAssertGreaterThan(document.width, 350)
        XCTAssertGreaterThan(panel.width, 250)
        XCTAssertFalse(panel.intersects(document), "Review must not cover the text being reviewed")
        XCTAssertGreaterThanOrEqual(panel.minX, document.maxX - 1)
        XCTAssertTrue(findWebView(fixture.controller.view) === originalWebView)
        fixture.reader.showOutline = true
        let withOutline = try await waitForPanel(in: fixture.controller.view)
        XCTAssertGreaterThanOrEqual(withOutline.minX, frameInScreen(originalWebView).maxX - 1)
        XCTAssertTrue(findWebView(fixture.controller.view) === originalWebView)
        let sameDocument = try await originalWebView.evaluateJavaScript("window.marginedTestDocument === document") as! Bool
        XCTAssertTrue(sameDocument, "Changing review layout must retain the document")
        XCTAssertEqual(try MarkdownSource.read(fixture.file), fixture.updated)
    }

    func testNarrowReviewPanelMovesBelowWithoutRecreatingTheDocument() async throws {
        let fixture = try await makeFixture(width: 1_200)
        defer { fixture.window.close(); fixture.reader.stop(); try? FileManager.default.removeItem(at: fixture.file) }
        let originalWebView = try XCTUnwrap(findWebView(fixture.controller.view))
        _ = try await originalWebView.evaluateJavaScript("window.marginedTestDocument = document; true")
        fixture.reader.showChanges = true
        _ = try await waitForPanel(in: fixture.controller.view)
        fixture.window.setContentSize(NSSize(width: 480, height: 360))
        let panel = try await waitForPanel(in: fixture.controller.view, below: originalWebView)
        let document = frameInScreen(originalWebView)
        XCTAssertGreaterThan(document.height, 150)
        XCTAssertFalse(panel.intersects(document))
        XCTAssertLessThanOrEqual(panel.maxY, document.minY + 1)
        XCTAssertTrue(fixture.window.frame.insetBy(dx: -1, dy: -1).contains(panel), "Panel \(panel), window \(fixture.window.frame), document \(document)")
        XCTAssertTrue(findWebView(fixture.controller.view) === originalWebView, "Responsive layout must retain the reader")
        fixture.reader.showFind = true
        fixture.reader.showOutline = true
        _ = try await waitForPanel(in: fixture.controller.view, below: originalWebView)
        XCTAssertGreaterThan(frameInScreen(originalWebView).height, 150)
        XCTAssertTrue(findWebView(fixture.controller.view) === originalWebView)
        fixture.reader.showFind = false
        fixture.reader.showOutline = false
        fixture.window.setContentSize(NSSize(width: 1_200, height: 720))
        let besideAgain = try await waitForPanel(in: fixture.controller.view)
        XCTAssertGreaterThanOrEqual(besideAgain.minX, frameInScreen(originalWebView).maxX - 1)
        XCTAssertTrue(findWebView(fixture.controller.view) === originalWebView)
        fixture.reader.showChanges = false
        for _ in 0..<50 {
            if panelFrame(in: fixture.controller.view) == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(panelFrame(in: fixture.controller.view))
        XCTAssertTrue(findWebView(fixture.controller.view) === originalWebView)
        let sameDocument = try await originalWebView.evaluateJavaScript("window.marginedTestDocument === document") as! Bool
        XCTAssertTrue(sameDocument, "Changing review layout must retain the document")
        XCTAssertEqual(try MarkdownSource.read(fixture.file), fixture.updated)
    }

    private struct Fixture {
        let reader: ReaderState
        let controller: NSHostingController<ReaderView>
        let window: NSWindow
        let file: URL
        let updated: String
    }

    private func makeFixture(width: CGFloat) async throws -> Fixture {
        let source = "# Review test\n\nOriginal paragraph.\n\n## Table\n\n| Item | Result |\n| --- | --- |\n| A | Ready |\n"
        let updated = source.replacingOccurrences(of: "Original paragraph.", with: "Updated paragraph.") + "\nAdded paragraph.\n"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let reader = ReaderState(); reader.fileURL = file; reader.source = source; reader.render()
        let controller = NSHostingController(rootView: ReaderView(reader: reader))
        let window = LayoutTestWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: width, height: 720)); window.makeKeyAndOrderFront(nil)
        for _ in 0..<200 {
            if let web = findWebView(controller.view), web.url != nil, !web.isLoading, !reader.isRendering { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try updated.write(to: file, atomically: true, encoding: .utf8)
        reader.acceptFileUpdate(updated)
        for _ in 0..<200 {
            if !reader.isRendering, reader.changes.count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(reader.changes.count, 2)
        return Fixture(reader: reader, controller: controller, window: window, file: file, updated: updated)
    }

    private func waitForPanel(in view: NSView, below webView: WKWebView? = nil) async throws -> NSRect {
        for _ in 0..<100 {
            view.layoutSubtreeIfNeeded()
            if let frame = panelFrame(in: view), frame.width > 0, frame.height > 0,
               view.window!.frame.insetBy(dx: -1, dy: -1).contains(frame),
               webView == nil || frame.maxY <= frameInScreen(webView!).minY + 1 { return frame }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Review panel was not docked in the reader layout")
        return .zero
    }

    // Inspect the actual native split allocations. SwiftUI's virtual AX tree
    // is not populated in an in-process XCTest host without assistive clients.
    private func panelFrame(in view: NSView) -> NSRect? {
        if let split = view as? NSSplitView, split.arrangedSubviews.count == 2,
           let panel = split.arrangedSubviews.last, findWebView(panel) == nil {
            return frameInScreen(panel)
        }
        for child in view.subviews { if let frame = panelFrame(in: child) { return frame } }
        return nil
    }

    private func frameInScreen(_ view: NSView) -> NSRect {
        view.window!.convertToScreen(view.convert(view.bounds, to: nil))
    }

    private func findWebView(_ view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for child in view.subviews { if let web = findWebView(child) { return web } }
        return nil
    }

    /// Exercise the requested layout width even on CI's 1024-point display.
    /// Normal AppKit ordering otherwise shrinks a wide fixture to that screen.
    private final class LayoutTestWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }
}

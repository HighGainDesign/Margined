import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Margined

@MainActor
final class FindRegressionTests: XCTestCase {
    private typealias Fixture = (reader: ReaderState, host: NSHostingController<ReaderView>, window: NSWindow, web: WKWebView, document: MarkdownDocument)

    func testClearingQueryRemovesTheVisibleWebKitFindHighlight() async throws {
        let fixture = try await makeReader()
        defer { fixture.reader.stop(); fixture.document.close() }
        try await beginFind(in: fixture)
        let highlighted = try await waitForHighlight(in: fixture.web)
        if highlighted <= 10, ProcessInfo.processInfo.environment["MARGINED_CI_HEADLESS"] == "1" {
            let native = try await fixture.web.find("violet lighthouse", configuration: WKFindConfiguration())
            XCTAssertTrue(native.matchFound)
            let captured = try await waitForHighlight(in: fixture.web)
            if native.matchFound, captured <= 10 {
                throw XCTSkip("Hosted WKSnapshot omits the native Find decoration even for direct matched Find. Functional Find checks remain required; this visual case runs on an actual Mac.")
            }
        }
        XCTAssertGreaterThan(highlighted, 10, "The fixture must show WebKit's actual yellow match before checking cleanup")
        guard highlighted > 10 else { return }
        fixture.reader.searchText = ""
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(150))
        let remaining = try await yellowPixels(in: fixture.web)
        XCTAssertEqual(remaining, 0, "Clearing Find must remove its visible match, not merely reset model state")
    }

    func testNativeClearButtonUpdatesTheQueryWithoutClosingFind() async throws {
        let fixture = try await makeReader()
        defer { fixture.reader.stop(); fixture.document.close() }
        try await beginFind(in: fixture)
        let field = try XCTUnwrap(findSearch(in: fixture.host.view), "Find needs a native clear control")
        let cell = try XCTUnwrap(field.cell as? NSSearchFieldCell)
        let clear = try XCTUnwrap(cell.cancelButtonCell)
        clear.performClick(field)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fixture.reader.searchText, "")
        XCTAssertTrue(fixture.reader.showFind)
    }

    func testClearingFindPreservesADifferentDocumentSelection() async throws {
        let fixture = try await makeReader()
        defer { fixture.reader.stop(); fixture.document.close() }
        try await beginFind(in: fixture)
        let highlighted = try await waitForHighlight(in: fixture.web)
        _ = try await fixture.web.evaluateJavaScript("""
        const text=document.querySelector('main p').firstChild,range=document.createRange();
        range.setStart(text,text.data.indexOf('stands'));range.setEnd(text,text.length);
        getSelection().removeAllRanges();getSelection().addRange(range);true;
        """)
        fixture.reader.searchText = ""
        try await Task.sleep(for: .milliseconds(150))
        let selected = try await fixture.web.evaluateJavaScript("getSelection().toString()") as? String
        XCTAssertEqual(selected, "stands beside the harbor.")
        if highlighted > 10 {
            let yellow = try await yellowPixels(in: fixture.web)
            XCTAssertEqual(yellow, 0)
        }
    }

    private func beginFind(in fixture: Fixture) async throws {
        // Observe a real no-match -> match transition, rather than assuming
        // a default true result means the native query has completed.
        for (query, expected) in [("__missing_find_fixture_8c17__", false), ("violet lighthouse", true)] {
            let generation = fixture.reader.searchGeneration
            fixture.reader.searchText = query
            var completed = false
            for _ in 0..<200 {
                if fixture.reader.searchGeneration > generation, fixture.reader.searchFound == expected {
                    completed = true; break
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertTrue(completed, "The production Find pipeline must report the expected native match result")
            if !completed { throw CocoaError(.coderInvalidValue) }
        }
    }

    private func makeReader() async throws -> Fixture {
        var components = URLComponents()
        components.scheme = "margined"; components.host = "preview"
        components.queryItems = [URLQueryItem(name: "text", value: "# Find test\n\nThe violet lighthouse stands beside the harbor.\n"), URLQueryItem(name: "title", value: "Find test")]
        let request = try PreviewRequest(url: XCTUnwrap(components.url))
        let document = MarkdownDocument(preview: request)
        let reader = document.reader
        reader.showFind = true
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        do {
            let window = try XCTUnwrap(document.windowControllers.first?.window)
            let host = try XCTUnwrap(window.contentViewController as? NSHostingController<ReaderView>)
            window.appearance = NSAppearance(named: .aqua)
            NSApp.activate(ignoringOtherApps: true)
            document.showWindows()
            for _ in 0..<200 {
                if let web = findWeb(in: host.view), web.window === window,
                   findSearch(in: host.view) != nil, web.url != nil, !web.isLoading, !reader.isRendering,
                   (try? await web.evaluateJavaScript("document.querySelector('main')?.textContent.includes('violet lighthouse')")) as? Bool == true {
                    try await Task.sleep(for: .milliseconds(100))
                    return (reader, host, window, web, document)
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw CocoaError(.coderInvalidValue)
        } catch { reader.stop(); document.close(); throw error }
    }

    private func findWeb(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.findWeb(in: $0) }.first
    }
    private func findSearch(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        return view.subviews.lazy.compactMap { self.findSearch(in: $0) }.first
    }
    private func waitForHighlight(in web: WKWebView) async throws -> Int {
        for _ in 0..<30 {
            let count = try await yellowPixels(in: web)
            if count > 10 { return count }
            try await Task.sleep(for: .milliseconds(50))
        }
        return 0
    }
    private func yellowPixels(in web: WKWebView) async throws -> Int {
        let configuration = WKSnapshotConfiguration(); configuration.afterScreenUpdates = true
        let image = try await web.takeSnapshot(configuration: configuration)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        var count = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.75 && color.greenComponent > 0.65 && color.blueComponent < 0.4 { count += 1 }
            }
        }
        return count
    }
}

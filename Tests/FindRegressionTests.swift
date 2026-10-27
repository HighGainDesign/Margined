import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Margined

@MainActor
final class FindRegressionTests: XCTestCase {
    func testClearingQueryRemovesTheVisibleWebKitFindHighlight() async throws {
        let fixture = try await makeReader()
        defer { fixture.reader.stop(); fixture.window.close() }
        fixture.reader.searchText = "violet lighthouse"
        let highlighted = try await waitForHighlight(in: fixture.web, reader: fixture.reader)
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
        defer { fixture.reader.stop(); fixture.window.close() }
        fixture.reader.searchText = "violet lighthouse"
        for _ in 0..<20 { await Task.yield() }
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
        defer { fixture.reader.stop(); fixture.window.close() }
        fixture.reader.searchText = "violet lighthouse"
        let highlighted = try await waitForHighlight(in: fixture.web, reader: fixture.reader)
        XCTAssertGreaterThan(highlighted, 10)
        _ = try await fixture.web.evaluateJavaScript("""
        const text=document.querySelector('main p').firstChild,range=document.createRange();
        range.setStart(text,text.data.indexOf('stands'));range.setEnd(text,text.length);
        getSelection().removeAllRanges();getSelection().addRange(range);true;
        """)
        fixture.reader.searchText = ""
        try await Task.sleep(for: .milliseconds(150))
        let selected = try await fixture.web.evaluateJavaScript("getSelection().toString()") as? String
        XCTAssertEqual(selected, "stands beside the harbor.")
        let yellow = try await yellowPixels(in: fixture.web)
        XCTAssertEqual(yellow, 0)
    }

    private func makeReader() async throws -> (reader: ReaderState, host: NSHostingController<ReaderView>, window: NSWindow, web: WKWebView) {
        let reader = ReaderState()
        reader.source = "# Find test\n\nThe violet lighthouse stands beside the harbor.\n"
        reader.render()
        let host = NSHostingController(rootView: ReaderView(reader: reader))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 700),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = host
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        do {
            for _ in 0..<200 {
                if let web = findWeb(in: host.view), web.url != nil, !web.isLoading, !reader.isRendering,
                   (try? await web.evaluateJavaScript("document.querySelector('main')?.textContent.includes('violet lighthouse')")) as? Bool == true {
                    reader.showFind = true
                    for _ in 0..<100 {
                        host.view.layoutSubtreeIfNeeded()
                        if findSearch(in: host.view) != nil, web.window === window,
                           NSApp.isActive, window.isKeyWindow {
                            try await Task.sleep(for: .milliseconds(100))
                            return (reader,host,window,web)
                        }
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    throw CocoaError(.coderInvalidValue)
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw CocoaError(.coderInvalidValue)
        } catch { reader.stop(); window.close(); throw error }
    }
    private func findWeb(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.findWeb(in: $0) }.first
    }
    private func findSearch(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        return view.subviews.lazy.compactMap { self.findSearch(in: $0) }.first
    }
    private func waitForHighlight(in web: WKWebView, reader: ReaderState) async throws -> Int {
        for _ in 0..<60 {
            let count = try await yellowPixels(in: web)
            if count > 10 { return count }
            try await Task.sleep(for: .milliseconds(50))
        }
        let match = try await web.find("violet lighthouse", configuration: WKFindConfiguration())
        try await Task.sleep(for: .milliseconds(100))
        let afterNativeFind = try await yellowPixels(in: web)
        print("Find fixture diagnostics: active=\(NSApp.isActive), key=\(web.window?.isKeyWindow == true), query=\(reader.searchText), nativeMatch=\(match.matchFound), afterNativeFind=\(afterNativeFind), frame=\(web.frame)")
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

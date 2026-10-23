#if MARGINED_BENCHMARK
import AppKit
import WebKit
import XCTest
@testable import Margined

@MainActor
final class ViewingBenchmarkSessionTests: XCTestCase {
    func testFrameProbeRejectsStaleOrUnrenderedHeading() async throws {
        let web = try await loaded("<main id='document'><h1>MARGINED-BENCHMARK-NEW</h1><p>MARGINED-BENCHMARK-OLD</p></main>")
        let current = try await ViewingBenchmarkFrame.isCurrent(web, marker: "MARGINED-BENCHMARK-NEW")
        let stale = try await ViewingBenchmarkFrame.isCurrent(web, marker: "MARGINED-BENCHMARK-OLD")
        XCTAssertTrue(current)
        XCTAssertFalse(stale)
        let raw = try await loaded("<main id='document'># MARGINED-BENCHMARK-NEW</main>")
        let rawCurrent = try await ViewingBenchmarkFrame.isCurrent(raw, marker: "MARGINED-BENCHMARK-NEW")
        XCTAssertFalse(rawCurrent)
    }

    func testFrameProbeWaitsForUsableArtwork() async throws {
        let web = try await loaded("<main id='document'><h1>MARGINED-BENCHMARK-IMAGE</h1><img src='data:image/png;base64,broken'></main>")
        let ready = try await ViewingBenchmarkFrame.isCurrent(web, marker: "MARGINED-BENCHMARK-IMAGE")
        XCTAssertFalse(ready)
    }

    func testExpectedArtworkCannotPassAsSourceFallback() async throws {
        let web = try await loaded("<main id='document'><h1>MARGINED-BENCHMARK-ART</h1><span class='margined-math'>x^2</span><figure class='margined-diagram'><pre>flowchart LR A--&gt;B</pre></figure></main>")
        let ready = try await ViewingBenchmarkFrame.isCurrent(web, marker: "MARGINED-BENCHMARK-ART", expectedMath: 1, expectedDiagrams: 1)
        XCTAssertFalse(ready, "Readable source fallbacks are not successful rendered-artwork samples")
    }

    func testExpectedCompleteArtworkPasses() async throws {
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><rect width='10' height='10' fill='blue'/></svg>".utf8).base64EncodedString()
        let web = try await loaded("<main id='document'><h1>MARGINED-BENCHMARK-ART</h1><span class='margined-math'><math><mi>x</mi></math></span><figure class='margined-diagram'><img src='data:image/svg+xml;base64," + svg + "'></figure></main>")
        let ready = try await ViewingBenchmarkFrame.isCurrent(web, marker: "MARGINED-BENCHMARK-ART", expectedMath: 1, expectedDiagrams: 1)
        XCTAssertTrue(ready)
    }

    func testHiddenWindowCannotYieldASuccessfulFrame() async throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        defer { window.close() }
        do {
            _ = try await ViewingBenchmarkFrame.capture(web, window: window, marker: "MARGINED-BENCHMARK-HIDDEN")
            XCTFail("An invisible window must not produce a display latency sample")
        } catch ViewingBenchmarkSessionError.hiddenWindow { }
    }

    private func loaded(_ body: String) async throws -> WKWebView {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let delegate = BenchmarkNavigation()
        web.navigationDelegate = delegate
        web.loadHTMLString("<!doctype html><html><body>" + body + "</body></html>", baseURL: nil)
        for _ in 0..<500 {
            if delegate.finished { return web }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ViewingBenchmarkSessionError.timeout
    }
}

@MainActor
private final class BenchmarkNavigation: NSObject, WKNavigationDelegate {
    var finished = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
}
#endif

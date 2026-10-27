#if MARGINED_BENCHMARK
import UIKit
import WebKit
import XCTest
@testable import MarginediOS

@MainActor
final class MobileViewingBenchmarkTests: XCTestCase {
    func testStaleMarkerAndRawMarkdownCannotCountAsRendered() async throws {
        let web = try await loaded("<main id='document'><h1>MARGINED-BENCHMARK-NEW</h1><p>MARGINED-BENCHMARK-OLD</p></main>")
        let stale = try await MobileViewingBenchmarkFrame.isCurrent(web, marker: "MARGINED-BENCHMARK-OLD")
        XCTAssertFalse(stale)
        let raw = try await loaded("<pre># MARGINED-BENCHMARK-NEW</pre>")
        let fallback = try await MobileViewingBenchmarkFrame.isCurrent(raw, marker: "MARGINED-BENCHMARK-NEW")
        XCTAssertFalse(fallback)
    }

    func testUnfinishedArtworkCannotProduceFastSamples() async throws {
        let web = try await loaded("<main id='document'><h1>MARGINED-BENCHMARK-ART</h1><span class='margined-math'>x^2</span><figure class='margined-diagram'><pre>flowchart LR A--&gt;B</pre></figure></main>")
        let ready = try await MobileViewingBenchmarkFrame.isCurrent(web,
            marker: "MARGINED-BENCHMARK-ART", expectedMath: 1, expectedDiagrams: 1)
        XCTAssertFalse(ready, "Readable source fallback is not rendered artwork")
        let broken = try await loaded("<main id='document'><h1>MARGINED-BENCHMARK-IMAGE</h1><img src='data:image/png;base64,broken'></main>")
        let imageReady = try await MobileViewingBenchmarkFrame.isCurrent(broken, marker: "MARGINED-BENCHMARK-IMAGE")
        XCTAssertFalse(imageReady)
    }

    func testRenderedArtworkCanPassTheDOMCheck() async throws {
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><rect width='10' height='10' fill='blue'/></svg>".utf8).base64EncodedString()
        let web = try await loaded("<main id='document'><h1>MARGINED-BENCHMARK-ART</h1><span class='margined-math'><math><mi>x</mi></math></span><figure class='margined-diagram'><img src='data:image/svg+xml;base64," + svg + "'></figure></main>")
        let ready = try await MobileViewingBenchmarkFrame.isCurrent(web,
            marker: "MARGINED-BENCHMARK-ART", expectedMath: 1, expectedDiagrams: 1)
        XCTAssertTrue(ready)
    }

    func testHiddenViewCannotProduceAVisibleFrame() async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let window = UIWindow(frame: web.frame)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(web)
        window.isHidden = true
        defer { window.isHidden = true }
        do {
            _ = try await MobileViewingBenchmarkFrame.capture(web, marker: "MARGINED-BENCHMARK-HIDDEN")
            XCTFail("A hidden window must not count as a visible frame")
        } catch MobileViewingBenchmarkFailure.hiddenWindow { }
    }

    private func loaded(_ body: String) async throws -> WKWebView {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let delegate = MobileBenchmarkNavigation()
        web.navigationDelegate = delegate
        web.loadHTMLString("<!doctype html><html><body>" + body + "</body></html>", baseURL: nil)
        for _ in 0..<500 {
            if delegate.finished { return web }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "MobileBenchmarkTest", code: 1)
    }
}

@MainActor
private final class MobileBenchmarkNavigation: NSObject, WKNavigationDelegate {
    var finished = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
}
#endif

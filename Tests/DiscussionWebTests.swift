import Foundation
import SwiftSoup
import WebKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import XCTest
#if os(iOS)
@testable import MarginediOS
#else
@testable import Margined
#endif

@MainActor
final class DiscussionWebTests: XCTestCase {
    private let world = WKContentWorld.world(name: "MarginedDiscussionTest")

    private func browser(_ body: String) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 700, height: 700), configuration: configuration)
        #if os(iOS)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = UIViewController(); controller.view = view
        let window = UIWindow(windowScene: scene)
        window.frame = view.frame; window.rootViewController = controller
        window.makeKeyAndVisible()
        addTeardownBlock { await MainActor.run { window.isHidden = true; window.rootViewController = nil } }
        #else
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view; window.makeKeyAndOrderFront(nil)
        addTeardownBlock { await MainActor.run { window.contentView = nil; window.close() } }
        #endif
        XCTAssertNotNil(view.window, "Native geometry requires a window-hosted WebView")
        let ready = expectation(description: "document navigation finished")
        let navigation = DiscussionTestNavigation(ready)
        view.navigationDelegate = navigation
        let cssURL = try XCTUnwrap(Bundle.main.url(forResource: "reader", withExtension: "css"))
        let css = try String(contentsOf: cssURL, encoding: .utf8)
        traceDiscussionTestWebView(view, phase: "before-load")
        view.loadHTMLString("<html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width, initial-scale=1'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; style-src 'unsafe-inline'\"><style>" + css + "</style></head><body><main id='document'>" + body + "</main></body></html>", baseURL: nil)
        await fulfillment(of: [ready], timeout: 10)
        traceDiscussionTestWebView(view, phase: "after-navigation-wait")
        withExtendedLifetime(navigation) {}
        try await present(view)
        return view
    }
    private func present(_ view: WKWebView) async throws {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let image = try await view.takeSnapshot(configuration: configuration)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }
    private func call(_ operation: String, in view: WKWebView, projection: DiscussionTextProjection) async throws -> Any? {
        try await view.callAsyncJavaScript(DiscussionWebScripts.script,
            arguments: ["operation": operation, "token": "r", "sourceID": projection.sourceID, "allowedThreadIDs": ["t1"]],
            in: nil, contentWorld: world)
    }

    func testIsolatedProjectionMatchesSemanticSwiftProjection() async throws {
        let body = "<h1>Plan</h1><p>Cafe<em>́</em> <strong>bold</strong> and <a href='https://example.com'>link</a>.</p><ul><li><input type='checkbox' checked>Task</li></ul><table><tr><td>One</td><td>Two</td></tr></table><p><img alt='Image label'> End</p>"
        let projection = try DiscussionText.project(html: body, source: "fixture")
        let view = try await browser(body)
        let projectedValue = try await call("project", in: view, projection: projection)
        let value = try XCTUnwrap(projectedValue as? [String: Any])
        XCTAssertEqual(value["text"] as? String, "Plan Café bold and link. Task One Two Image label End")
        XCTAssertEqual(value["text"] as? String, projection.text)
        let units = try XCTUnwrap(value["units"] as? [[String: Any]])
        XCTAssertEqual(units.compactMap { $0["text"] as? String }, projection.units.map(\.text))
        XCTAssertEqual(units.compactMap { $0["location"] as? Int }, projection.units.map { $0.range.location })
    }

    func testNativeSelectionAcrossFormattedCombiningTextUsesCurrentRawMap() async throws {
        let body = "<p>Cafe<em>́</em> <strong>bold</strong> and <a href='https://example.com'>link</a>.</p>"
        let projection = try DiscussionText.project(html: body, source: "selection")
        let view = try await browser(body)
        _ = try await call("configure", in: view, projection: projection)
        _ = try await view.callAsyncJavaScript("""
        const p = document.querySelector('p'), link = document.querySelector('a');
        const range = document.createRange(); range.setStart(p.firstChild,0); range.setEnd(link.firstChild,4);
        getSelection().removeAllRanges(); getSelection().addRange(range); return true;
        """, arguments: [:], in: nil, contentWorld: world)
        let bodyValue = try await call("selection", in: view, projection: projection)
        let context = DiscussionBridge.Context(token: "r", sourceID: projection.sourceID, enabled: true, allowedThreadIDs: ["t1"])
        let expected = try XCTUnwrap(projection.selection(NSRange(location: 0, length: 18), renderID: "r"))
        XCTAssertEqual(expected.target.exact, "Café bold and link")
        XCTAssertEqual(DiscussionBridge.request(bodyValue as Any, isMainFrame: true, context: context, projection: projection), .selection(expected))
    }

    func testUnsupportedArtworkCannotBecomePartOfASelectedPassage() async throws {
        let body = "<p>Before <span class='margined-math'>x+y</span> after.</p>"
        let projection = try DiscussionText.project(html: body, source: "math")
        let view = try await browser(body)
        let projectedValue = try await call("project", in: view, projection: projection)
        let value = try XCTUnwrap(projectedValue as? [String: Any])
        XCTAssertEqual(value["text"] as? String, "Before after.")
        XCTAssertEqual(value["barriers"] as? [Int], projection.barriers)
        _ = try await view.callAsyncJavaScript("const r=document.createRange();r.selectNodeContents(document.querySelector('p'));getSelection().removeAllRanges();getSelection().addRange(r);return true;", arguments: [:], in: nil, contentWorld: world)
        let selection = try await call("selection", in: view, projection: projection)
        XCTAssertTrue(selection == nil || selection is NSNull)
    }

    func testImageAltParticipatesInAnActualDOMSelection() async throws {
        let body = "<p>Before <img alt='Portrait 👁️'> after.</p>"
        let projection = try DiscussionText.project(html: body, source: "image")
        let view = try await browser(body)
        _ = try await view.callAsyncJavaScript("const r=document.createRange();r.selectNodeContents(document.querySelector('p'));getSelection().removeAllRanges();getSelection().addRange(r);return true;", arguments: [:], in: nil, contentWorld: world)
        let value = try await call("selection", in: view, projection: projection)
        let expected = try XCTUnwrap(projection.selection(NSRange(location: 0, length: projection.text.utf16.count), renderID: "r"))
        XCTAssertEqual(expected.target.exact, "Before Portrait 👁️ after.")
        let context = DiscussionBridge.Context(token: "r", sourceID: projection.sourceID, enabled: true, allowedThreadIDs: [])
        XCTAssertEqual(DiscussionBridge.request(value as Any, isMainFrame: true, context: context, projection: projection), .selection(expected))
    }

    func testSelectionAfterHTMLCRLFUsesBrowserTextOffsets() async throws {
        for body in ["<pre><code>First\r\nSecond</code></pre>", "<pre><code>First&#13;\nSecond</code></pre>"] {
            let projection = try DiscussionText.project(html: body, source: "crlf")
            let view = try await browser(body)
            _ = try await view.callAsyncJavaScript("const t=document.querySelector('code').firstChild,r=document.createRange();const start=t.data.indexOf('Second');r.setStart(t,start);r.setEnd(t,t.length);getSelection().removeAllRanges();getSelection().addRange(r);return true;", arguments: [:], in: nil, contentWorld: world)
            let value = try await call("selection", in: view, projection: projection)
            let expected = try XCTUnwrap(projection.selection(NSRange(location: 6, length: 6), renderID: "r"))
            let context = DiscussionBridge.Context(token: "r", sourceID: projection.sourceID, enabled: true, allowedThreadIDs: [])
            XCTAssertEqual(DiscussionBridge.request(value as Any, isMainFrame: true, context: context, projection: projection), .selection(expected), body)
        }
    }

    private func decorationArguments(_ projection: DiscussionTextProjection, quote: String, ids: [String]) throws -> [String: Any] {
        let selected = try XCTUnwrap(projection.selection((projection.text as NSString).range(of: quote), renderID: "r"))
        let anchors: [[String: Any]] = ids.map { id in
            ["id": id, "location": selected.range.location, "length": selected.range.length,
             "startUnit": selected.domRange.start.unit, "startOffset": selected.domRange.start.offset,
             "endUnit": selected.domRange.end.unit, "endOffset": selected.domRange.end.offset]
        }
        return ["operation": "configure", "token": "r", "sourceID": projection.sourceID,
            "allowedThreadIDs": ids, "anchors": anchors, "expectedText": projection.text,
            "visible": true, "selectedID": ids.first ?? "", "markerLabel": "Open discussion"]
    }
    func testPassageDecorationsUseActualGeometryWithoutChangingTextFocusOrScroll() async throws {
        let body = "<h1 tabindex='-1'>Plan</h1>" + String(repeating: "<p>Padding paragraph.</p>", count: 25) + "<p>Cafe<em>́</em> <strong>bold</strong> passage.</p>"
        let projection = try DiscussionText.project(html: body, source: "geometry")
        let view = try await browser(body)
        var arguments = try decorationArguments(projection, quote: "Café bold passage.", ids: ["t1", "t2"])
        _ = try await view.callAsyncJavaScript(DiscussionWebScripts.script, arguments: arguments, in: nil, contentWorld: world)
        _ = try await view.callAsyncJavaScript("window.scrollTo({top:200,behavior:'instant'});document.querySelector('h1').focus({preventScroll:true});return true;", arguments: [:], in: nil, contentWorld: world)
        try await present(view)
        let before = try await view.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertGreaterThan(before ?? 0, 0, "The requested initial scroll must be presented before comparing it")
        arguments["operation"] = "decorate"
        let geometry = try await view.callAsyncJavaScript(DiscussionWebScripts.script, arguments: arguments, in: nil, contentWorld: world) as? [String: Any]
        XCTAssertEqual((geometry?["anchors"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["t1", "t2"])
        XCTAssertGreaterThan(geometry?["bodyFont"] as? Double ?? 0, 0)
        let count = try await view.evaluateJavaScript("document.querySelectorAll('[data-margined-thread]').length") as? Int
        XCTAssertEqual(count, 1, "Two threads on one passage share an accessible marker")
        let projected = try await call("project", in: view, projection: projection) as? [String: Any]
        XCTAssertEqual(projected?["text"] as? String, projection.text)
        try await present(view)
        let after = try await view.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertEqual(after, before)
        let focused = try await view.evaluateJavaScript("document.activeElement.localName") as? String
        XCTAssertEqual(focused, "h1")
        arguments["visible"] = false
        _ = try await view.callAsyncJavaScript(DiscussionWebScripts.script, arguments: arguments, in: nil, contentWorld: world)
        let hidden = try await view.evaluateJavaScript("document.querySelectorAll('[data-margined-thread]').length") as? Int
        XCTAssertEqual(hidden, 0)
    }
    func testOnlyExplicitGoToPassageScrollsToTheCurrentAllowedAnchor() async throws {
        let body = "<h1>Plan</h1>" + String(repeating: "<p>Padding paragraph.</p>", count: 45) + "<p>Target passage.</p>"
        let projection = try DiscussionText.project(html: body, source: "go-to")
        let view = try await browser(body)
        var arguments = try decorationArguments(projection, quote: "Target passage.", ids: ["t1"])
        _ = try await view.callAsyncJavaScript(DiscussionWebScripts.script, arguments: arguments, in: nil, contentWorld: world)
        arguments["operation"] = "decorate"
        _ = try await view.callAsyncJavaScript(DiscussionWebScripts.script, arguments: arguments, in: nil, contentWorld: world)
        try await present(view)
        let before = try await view.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertEqual(before, 0)
        arguments["operation"] = "goTo"; arguments["threadID"] = "unknown"; arguments["focus"] = true
        let forbidden = try await view.callAsyncJavaScript(DiscussionWebScripts.script, arguments: arguments, in: nil, contentWorld: world) as? Bool
        XCTAssertEqual(forbidden, false)
        arguments["threadID"] = "t1"
        let moved = try await view.callAsyncJavaScript(DiscussionWebScripts.script, arguments: arguments, in: nil, contentWorld: world) as? Bool
        XCTAssertEqual(moved, true)
        try await present(view)
        let after = try await view.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertGreaterThan(after ?? 0, 0)
        let focused = try await view.evaluateJavaScript("document.activeElement.textContent") as? String
        XCTAssertEqual(focused, "Target passage.")
    }

    func testSyntheticMarkerClickDoesNotSendADiscussionAction() async throws {
        let projection = try DiscussionText.project(html: "<p>Text.</p>", source: "marker")
        let view = try await browser("<p>Text.</p>")
        let forbidden = XCTestExpectation(description: "untrusted event must not post")
        forbidden.isInverted = true
        let receiver = DiscussionTestReceiver(forbidden)
        view.configuration.userContentController.add(receiver, contentWorld: world, name: "discussion")
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "discussion", contentWorld: world) }
        let configured = try await call("configure", in: view, projection: projection) as? Bool
        XCTAssertEqual(configured, true)
        guard configured == true else { return }
        _ = try await view.callAsyncJavaScript("const b=document.createElement('button');b.dataset.marginedThread='t1';document.body.appendChild(b);b.click();return true;", arguments: [:], in: nil, contentWorld: world)
        await fulfillment(of: [forbidden], timeout: 0.25)
    }
}

@MainActor
private final class DiscussionTestNavigation: NSObject, WKNavigationDelegate {
    private let ready: XCTestExpectation
    init(_ ready: XCTestExpectation) { self.ready = ready }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { traceDiscussionTestWebView(webView, phase: "did-start") }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { traceDiscussionTestWebView(webView, phase: "did-commit") }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { traceDiscussionTestWebView(webView, phase: "did-finish"); ready.fulfill() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { traceDiscussionTestWebView(webView, phase: "process-terminated") }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { XCTFail(error.localizedDescription); ready.fulfill() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { XCTFail(error.localizedDescription); ready.fulfill() }
}
@MainActor
private final class DiscussionTestReceiver: NSObject, WKScriptMessageHandler {
    private let received: XCTestExpectation
    init(_ received: XCTestExpectation) { self.received = received }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { received.fulfill() }
}

@MainActor
private func traceDiscussionTestWebView(_ view: WKWebView, phase: String) {
    #if os(iOS)
    let active = UIApplication.shared.applicationState == .active
    let foreground = view.window?.windowScene?.activationState == .foregroundActive
    let detail = "appActive=\(active) attached=\(view.window != nil) foreground=\(foreground) key=\(view.window?.isKeyWindow == true)"
    FileHandle.standardError.write(Data("WebKitTest discussion \(phase) \(detail) loading=\(view.isLoading) progress=\(view.estimatedProgress)\n".utf8))
    #endif
}

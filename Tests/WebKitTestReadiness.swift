import Foundation
import WebKit

/// Native functional fixtures must finish process/navigation setup before
/// measuring behavior. Hosted iOS WebContent startup has taken up to 29 seconds;
/// the individual content, selection and layout assertions keep their own waits.
@MainActor
enum WebKitTestReadiness {
    static let navigationTimeout: TimeInterval = 60

    static func navigation(_ view: () -> WKWebView?, expectedURL: URL? = nil) async -> WKWebView? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(navigationTimeout))
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if let web = view(), !web.isLoading, web.estimatedProgress == 1,
               let url = web.url, expectedURL == nil || url == expectedURL {
                return web
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}

#if os(iOS)
extension WebKitTestReadiness {
    private static var diagramPreparation: Task<Void, Error>?

    /// Functional output assertions start after the simulator's trusted WebKit
    /// services are ready. Product workers retain their own unchanged budgets.
    static func diagramRendering() async throws {
        if let diagramPreparation { return try await diagramPreparation.value }
        let preparation = Task { @MainActor in
            try await DiagramRenderingBootstrap().prepare()
        }
        diagramPreparation = preparation
        try await preparation.value
    }
}

@MainActor
private final class DiagramRenderingBootstrap: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private static let world = WKContentWorld.world(name: "MarginedRenderingTestReadiness")
    private var web: WKWebView?
    private var completion: CheckedContinuation<Void, Error>?
    private var deadline: Task<Void, Never>?

    private enum Failure: Error {
        case missingBundledRenderer, trustedRendererFailed, navigationFailed, processTerminated, startupTimedOut
    }

    func prepare() async throws {
        guard let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
              let library = try? String(contentsOf: url, encoding: .utf8) else { throw Failure.missingBundledRenderer }
        let started = ContinuousClock.now
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            completion = continuation
            let controller = WKUserContentController()
            controller.add(self, contentWorld: Self.world, name: "renderingReady")
            // This fixed graph primes simulator process/font/layout startup. Its
            // SVG is discarded; DiagramRenderer and its image cache are untouched.
            let handshake = """
            ;(async () => {
                const renderer = globalThis.marginedMermaid;
                renderer.initialize({startOnLoad:false, securityLevel:'strict', htmlLabels:false,
                    flowchart:{htmlLabels:false}, fontFamily:'Arial'});
                const result = await renderer.render('marginedTestReadiness', 'flowchart LR; Bootstrap-->Ready');
                if (!result.svg) throw new Error('No trusted readiness SVG');
                window.webkit.messageHandlers.renderingReady.postMessage('ready');
            })().catch(() => window.webkit.messageHandlers.renderingReady.postMessage('failed'));
            """
            controller.addUserScript(WKUserScript(source: library + handshake,
                injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world))
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            configuration.userContentController = controller
            let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
            web = page; page.navigationDelegate = self
            print("WEBKIT-RENDERING-READINESS starting trusted bootstrap (60s setup limit; product deadlines unchanged)")
            deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(WebKitTestReadiness.navigationTimeout))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(Failure.startupTimedOut))
            }
            page.loadHTMLString("""
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'">
            </head><body></body></html>
            """, baseURL: nil)
        }
        print("WEBKIT-RENDERING-READINESS ready after \(started.duration(to: .now)); functional assertions start now")
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let completion else { return }
        self.completion = nil
        deadline?.cancel(); deadline = nil
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "renderingReady", contentWorld: Self.world)
        web?.navigationDelegate = nil; web?.stopLoading(); web = nil
        completion.resume(with: result)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        finish(message.body as? String == "ready" ? .success(()) : .failure(Failure.trustedRendererFailed))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(Failure.navigationFailed)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(Failure.navigationFailed)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(Failure.processTerminated)) }
}
#endif

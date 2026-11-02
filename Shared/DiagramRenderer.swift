import CryptoKit
import Foundation
import SwiftSoup
import WebKit

struct DiagramArtifact: Sendable {
    let image: String
    let description: String
}

/// Bound expensive diagram work across documents; cache only in memory.
actor DiagramRenderer {
    static let shared = DiagramRenderer()
    #if DEBUG && os(iOS)
    /// Exercises the real private WebKit worker without sharing its cache.
    static func renderForTesting(_ source: String, minimumStartupDuration: Duration) async -> DiagramArtifact? {
        await DiagramWorker.renderForTesting(source, minimumStartupDuration: minimumStartupDuration)
    }
    #endif
    private var cache: [String: DiagramArtifact] = [:]
    private var order: [String] = []
    private var bytes = 0
    private var active = 0

    func render(_ source: String) async -> DiagramArtifact? {
        guard !Task.isCancelled, source.utf8.count <= 20_000 else { return nil }
        let key = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        if let cached = cache[key] { trace("cache-hit"); return cached }
        // Do not queue unlimited private documents behind a slow graph.
        guard active < 2 else { trace("capacity-rejected"); return nil }
        active += 1
        defer { active -= 1 }
        guard let artifact = await DiagramWorker.render(source) else { return nil }
        if cache[key] == nil {
            cache[key] = artifact; order.append(key); bytes += artifact.image.utf8.count
            while bytes > 8_000_000 || order.count > 64 {
                let old = order.removeFirst()
                bytes -= cache.removeValue(forKey: old)?.image.utf8.count ?? 0
            }
        }
        return artifact
    }

    private func trace(_ event: StaticString) {
        #if DEBUG
        print("DIAGRAM-RENDERER event=\(event) active=\(active) cache_entries=\(cache.count)")
        #endif
    }
}

/// This view never displays author HTML or navigates to author URLs. Only our
/// bundled renderer executes, in its own world, with a no-network CSP.
@MainActor
private final class DiagramWorker: NSObject, WKNavigationDelegate {
    private var web: WKWebView?
    private var completion: CheckedContinuation<DiagramArtifact?, Never>?
    private var timer: Task<Void, Never>?
    #if os(iOS)
    private var executionTimer: Task<Void, Never>?
    #endif
    private let source: String
    #if DEBUG
    private let diagnosticID = UUID()
    private let diagnosticStarted = DispatchTime.now().uptimeNanoseconds
    #endif
    #if DEBUG && os(iOS)
    private var minimumStartupDuration = Duration.zero
    private var budgetStarted = ContinuousClock.now
    private var startupTask: Task<Void, Never>?
    #endif
    private static let world = WKContentWorld.world(name: "MarginedDiagramRenderer")
    private static let script: String? = {
        guard let url = Bundle(for: DiagramWorker.self).url(forResource: "mermaid.min", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    init(_ source: String) { self.source = source }

    static func render(_ source: String) async -> DiagramArtifact? {
        let worker = DiagramWorker(source)
        return await run(worker)
    }

    #if DEBUG && os(iOS)
    static func renderForTesting(_ source: String, minimumStartupDuration: Duration) async -> DiagramArtifact? {
        let worker = DiagramWorker(source)
        worker.minimumStartupDuration = minimumStartupDuration
        return await run(worker)
    }
    #endif

    private static func run(_ worker: DiagramWorker) async -> DiagramArtifact? {
        return await withTaskCancellationHandler {
            await worker.start()
        } onCancel: {
            Task { @MainActor in worker.trace("cancel"); worker.finish(nil) }
        }
    }

    private func start() async -> DiagramArtifact? {
        trace("start")
        guard !Task.isCancelled else { trace("cancel-before-start"); return nil }
        return await withCheckedContinuation { completion in
            self.completion = completion
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.defaultWebpagePreferences.allowsContentJavaScript = false
            let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700), configuration: config)
            self.web = web; web.navigationDelegate = self
            #if DEBUG && os(iOS)
            budgetStarted = .now
            #endif
            timer = Task { [weak self] in
                #if os(iOS)
                // Cold WebKit startup and loading the trusted bundled library
                // need their own allowance. All phases still share this cap.
                try? await Task.sleep(for: .seconds(6))
                #else
                try? await Task.sleep(for: .seconds(3))
                #endif
                if !Task.isCancelled { self?.trace("deadline", status: "overall"); self?.finish(nil) }
            }
            web.loadHTMLString("""
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'">
            </head><body></body></html>
            """, baseURL: nil)
        }
    }

    private func finish(_ result: DiagramArtifact?) {
        guard let completion else { return }
        trace("finish", status: result == nil ? "nil" : "artifact")
        self.completion = nil
        timer?.cancel(); timer = nil
        #if os(iOS)
        executionTimer?.cancel(); executionTimer = nil
        #endif
        #if DEBUG && os(iOS)
        startupTask?.cancel(); startupTask = nil
        #endif
        web?.stopLoading(); web?.navigationDelegate = nil; web = nil
        completion.resume(returning: result)
    }

    /// Temporary diagnostics never include author content or arbitrary error metadata.
    private func trace(_ phase: StaticString, status: StaticString? = nil, error: (any Error)? = nil) {
        #if DEBUG
        let elapsed = (DispatchTime.now().uptimeNanoseconds - diagnosticStarted) / 1_000_000
        var detail = status.map { " status=\($0)" } ?? ""
        if let error {
            let nativeError = error as NSError
            let domain = ["WKErrorDomain", NSURLErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain].contains(nativeError.domain) ? nativeError.domain : "other"
            detail += " error_domain=\(domain) error_code=\(nativeError.code)"
        }
        print("DIAGRAM-WORKER id=\(diagnosticID) elapsed_ms=\(elapsed) phase=\(phase)\(detail)")
        #endif
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        trace("navigation-fail", error: error); finish(nil)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        trace("navigation-provisional-fail", error: error); finish(nil)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        trace("process-termination"); finish(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        trace("navigation-finish")
        guard let script = Self.script else { trace("library-unavailable"); finish(nil); return }
        trace("library-injection-start")
        webView.evaluateJavaScript(script, in: nil, in: Self.world) { [weak self, weak webView] result in
            guard let self, let webView, self.completion != nil else { return }
            switch result {
            case .success: self.trace("library-injection-end", status: "success")
            case .failure(let error): self.trace("library-injection-end", status: "failure", error: error)
            }
            guard case .success = result else { self.finish(nil); return }
            #if os(iOS)
            self.initializeLibrary(in: webView)
            #else
            self.renderDiagram(in: webView)
            #endif
        }
    }

    private static let initializationScript = """
            const m = globalThis.marginedMermaid;
            const secure = [...new Set([...Object.keys(m.mermaidAPI.defaultConfig), 'secure', 'securityLevel', 'startOnLoad', 'maxTextSize', 'maxEdges', 'htmlLabels', 'themeCSS', 'fontFamily'])];
            m.initialize({startOnLoad:false, securityLevel:'strict', secure,
                maxTextSize:20000, maxEdges:200, suppressErrorRendering:true,
                htmlLabels:false, flowchart:{htmlLabels:false}, theme:'default',
                fontFamily:'Arial', deterministicIds:true, deterministicIDSeed:'margined'});
            """

    #if os(iOS)
    private func initializeLibrary(in webView: WKWebView) {
        trace("initialize-start")
        // Author source is first passed to WebKit only after trusted setup.
        webView.callAsyncJavaScript(Self.initializationScript, arguments: [:], in: nil, in: Self.world) { [weak self, weak webView] result in
            guard let self, let webView, completion != nil else { return }
            switch result {
            case .success: trace("initialize-end", status: "success")
            case .failure(let error): trace("initialize-end", status: "failure", error: error)
            }
            guard case .success = result else { finish(nil); return }
            #if DEBUG
            startupTask = Task { [weak self, weak webView] in
                guard let self else { return }
                try? await Task.sleep(until: budgetStarted.advanced(by: minimumStartupDuration), clock: .continuous)
                guard !Task.isCancelled, completion != nil, let webView else { return }
                beginExecution(in: webView)
            }
            #else
            beginExecution(in: webView)
            #endif
        }
    }

    private func beginExecution(in webView: WKWebView) {
        guard completion != nil else { return }
        executionTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.trace("deadline", status: "execution"); self?.finish(nil) }
        }
        renderDiagram(in: webView, initialize: false)
    }
    #endif

    private func renderDiagram(in webView: WKWebView, initialize: Bool = true) {
        // macOS retains its existing combined call; these spans deliberately overlap.
        if initialize { trace("initialize-start", status: "combined-with-execution") }
        trace("execution-start", status: initialize ? "includes-initialization" : "initialized")
        let script = (initialize ? Self.initializationScript : "const m = globalThis.marginedMermaid;") + """
            const {svg} = await m.render('marginedDiagram', source);
            // Mermaid includes animation @keyframes even for static diagrams.
            // Let the browser parse CSS, retaining ordinary style rules only.
            // Native sanitation still rejects resource URLs and active elements.
            const doc = new DOMParser().parseFromString(svg, 'image/svg+xml');
            for (const style of doc.querySelectorAll('style')) {
                const sheet = new CSSStyleSheet();
                sheet.replaceSync(style.textContent);
                style.textContent = Array.from(sheet.cssRules).filter(rule => rule.type === 1).map(rule => {
                    for (const property of Array.from(rule.style)) {
                        const value = rule.style.getPropertyValue(property);
                        const withoutLocal = value.replace(/url\\(\\s*["']?(?:about:blank)?#[A-Za-z0-9_.:-]+["']?\\s*\\)/gi, '');
                        if (property.startsWith('animation') || property.startsWith('transition') ||
                            /\\b(?:url|expression)\\s*\\(/i.test(withoutLocal) || /[@\\\\]/.test(value)) rule.style.removeProperty(property);
                    }
                    return rule.cssText;
                }).join(' ');
            }
            return new XMLSerializer().serializeToString(doc.documentElement);
            """
        webView.callAsyncJavaScript(script, arguments: ["source": source], in: nil, in: Self.world) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if initialize { self.trace("initialize-end", status: "combined-with-execution") }
                self.trace("execution-end", status: "success")
            case .failure(let error):
                if initialize { self.trace("initialize-end", status: "combined-with-execution", error: error) }
                self.trace("execution-end", status: "failure", error: error)
            }
            if case .success(let svg as String) = result {
                let artifact = Self.sanitize(svg)
                self.trace("sanitize", status: artifact == nil ? "rejected" : "accepted")
                self.finish(artifact)
            } else { self.finish(nil) }
        }
    }

    private static func sanitize(_ svg: String) -> DiagramArtifact? {
        guard svg.utf8.count <= 2_000_000,
              let document = try? SwiftSoup.parse(svg, "", Parser.xmlParser()),
              let root = try? document.select("svg").first() else { return nil }
        let tags: Set<String> = ["svg", "g", "defs", "style", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "text", "tspan", "textpath", "title", "desc", "marker", "clippath", "lineargradient", "radialgradient", "stop"]
        let localURL = try! NSRegularExpression(pattern: #"url\(\s*["']?(?:about:blank)?#([A-Za-z0-9_.:-]+)["']?\s*\)"#)
        let unsafeFunction = try! NSRegularExpression(pattern: #"\b(?:url|expression)\s*\("#, options: .caseInsensitive)
        func cleanCSS(_ value: String) -> String? {
            let range = NSRange(value.startIndex..., in: value)
            let normalized = localURL.stringByReplacingMatches(in: value, range: range, withTemplate: "url(#$1)")
            let withoutLocal = localURL.stringByReplacingMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized), withTemplate: "")
            guard unsafeFunction.firstMatch(in: withoutLocal, range: NSRange(withoutLocal.startIndex..., in: withoutLocal)) == nil,
                  !withoutLocal.contains("@"), !withoutLocal.contains("\\") else { return nil }
            return normalized
        }
        guard let elements = try? root.getAllElements().array() else { return nil }
        for element in elements {
            guard tags.contains(element.tagName().lowercased()) else { try? element.remove(); continue }
            for attr in element.getAttributes()?.asList() ?? [] {
                let key = attr.getKey().lowercased(), value = attr.getValue()
                if key.hasPrefix("on") || ["href", "xlink:href", "src", "srcset"].contains(key) {
                    try? element.removeAttr(attr.getKey())
                } else if key == "style" || value.lowercased().contains("url") {
                    if let clean = cleanCSS(value) { try? element.attr(attr.getKey(), clean) }
                    else { try? element.removeAttr(attr.getKey()) }
                }
            }
            if element.tagName() == "style" {
                guard let text = try? element.html(), let clean = cleanCSS(text) else { try? element.remove(); continue }
                try? element.html(clean)
            }
        }
        try? root.attr("xmlns", "http://www.w3.org/2000/svg")
        let title = (try? root.select("title").text()) ?? ""
        let description = (try? root.select("desc").text()) ?? ""
        let alt = [title, description].filter { !$0.isEmpty }.joined(separator: ". ")
        // Expose the drawing as one named image rather than every SVG path.
        try? root.attr("role", "img")
        try? root.attr("aria-label", alt.isEmpty ? String(localized: "Mermaid diagram") : alt)
        guard let output = try? root.outerHtml() else { return nil }
        return DiagramArtifact(image: "data:image/svg+xml;base64," + Data(output.utf8).base64EncodedString(),
                               description: alt.isEmpty ? String(localized: "Mermaid diagram") : alt)
    }
}

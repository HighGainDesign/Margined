import SwiftUI
import WebKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct DiscussionSpeechHighlight: Equatable, Sendable {
    let elementID: String?
    let follow: Bool
    static let inactive = DiscussionSpeechHighlight(elementID: nil, follow: false)
}

#if os(iOS)
struct DiscussionHistoryWebView: UIViewRepresentable {
    let html: String
    let fontSize: Double
    let imageGeneration: Int
    let scope: DiscussionHistoryScope
    var speech: DiscussionSpeechHighlight = .inactive
    func makeCoordinator() -> DiscussionHistoryCoordinator { .init(scope: scope) }
    func makeUIView(context: Context) -> WKWebView { context.coordinator.makeWebView() }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.update(html: html, fontSize: fontSize, imageGeneration: imageGeneration, speech: speech)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: DiscussionHistoryCoordinator) { coordinator.invalidate() }
}
#else
struct DiscussionHistoryWebView: NSViewRepresentable {
    let html: String
    let fontSize: Double
    let imageGeneration: Int
    let scope: DiscussionHistoryScope
    var speech: DiscussionSpeechHighlight = .inactive
    func makeCoordinator() -> DiscussionHistoryCoordinator { .init(scope: scope) }
    func makeNSView(context: Context) -> WKWebView { context.coordinator.makeWebView() }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.update(html: html, fontSize: fontSize, imageGeneration: imageGeneration, speech: speech)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: DiscussionHistoryCoordinator) { coordinator.invalidate() }
}
#endif

/// Owns only WebKit's lifetime and rendering operations. There are no mutation
/// message handlers, and no reference to an editable document or draft model.
@MainActor
final class DiscussionHistoryCoordinator: NSObject, WKNavigationDelegate {
    private static let world = WKContentWorld.world(name: "MarginedDiscussionHistory")
    private static let documentScript: String = {
        guard let url = Bundle.main.url(forResource: "reader-document", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "return false;" }
        return text
    }()
    private let scope: DiscussionHistoryScope
    private let images: DiscussionHistoryImages
    private weak var webView: WKWebView?
    private var html: String?
    private var imageGeneration = -1
    private var fontSize = 16.0
    private var speech = DiscussionSpeechHighlight.inactive
    private var speechKey: String?
    private static let speechScript: String = {
        guard let url = Bundle.main.url(forResource: "reader-speech", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "return false;" }
        return "if (document.documentElement.getAttribute('data-margined-history-token') !== documentToken) return false;\n" + text
    }()
    private var generation = 0
    private var token = UUID().uuidString
    private var ready = false
    private var invalidated = false
    private var navigation: WKNavigation?
    private var loading: Task<Void, Never>?
    private var position: [String: Any]?

    init(scope: DiscussionHistoryScope) {
        self.scope = scope
        images = DiscussionHistoryImages(scope: scope)
        super.init()
    }

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(images, forURLScheme: "margined-resource")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.allowsLinkPreview = false
        #if os(iOS)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.accessibilityLabel = String(localized: "Discussion history")
        #else
        view.setAccessibilityLabel(String(localized: "Discussion history"))
        #endif
        webView = view
        return view
    }

    func invalidate() {
        invalidated = true; generation += 1
        loading?.cancel(); loading = nil
        images.invalidate()
        webView?.navigationDelegate = nil
        webView?.stopLoading(); webView = nil
    }

    func update(html: String, fontSize: Double, imageGeneration: Int, speech: DiscussionSpeechHighlight = .inactive) {
        guard !invalidated, scope.isCurrent() else { invalidate(); return }
        self.speech = speech
        let fontChanged = self.fontSize != fontSize
        self.fontSize = fontSize
        if self.imageGeneration != imageGeneration {
            self.imageGeneration = imageGeneration
            images.renew()
        }
        let page = ImageResourceNamespace.html(html, token: images.generation)
        if self.html != page {
            self.html = page
            load(page)
        } else if fontChanged, ready {
            let expected = generation
            Task { [weak self] in
                guard let self, valid(expected), let webView else { return }
                _ = try? await webView.callAsyncJavaScript(Self.finishScript,
                    arguments: ["documentToken": token, "fontSize": fontSize, "position": NSNull()],
                    in: nil, contentWorld: Self.world)
                guard valid(expected) else { return }
                speechKey = nil; synchronizeSpeech()
            }
        }
        synchronizeSpeech()
    }

    private func synchronizeSpeech() {
        guard ready, let webView else { return }
        let key = "\(generation):\(speech.elementID ?? "none"):\(speech.follow)"
        guard key != speechKey else { return }
        speechKey = key
        let expected = generation, highlight = speech
        Task { [weak self] in
            guard let self, valid(expected), speechKey == key else { return }
            _ = try? await webView.callAsyncJavaScript(Self.speechScript,
                arguments: ["documentToken": token, "operation": "highlight",
                            "elementID": highlight.elementID ?? "", "follow": highlight.follow],
                in: nil, contentWorld: Self.world)
        }
    }

    private func valid(_ expected: Int) -> Bool {
        !invalidated && !Task.isCancelled && expected == generation && scope.isCurrent()
    }

    private func load(_ page: String) {
        guard let webView else { return }
        let reconcile = ready
        generation += 1
        let expected = generation, previousToken = token
        token = UUID().uuidString
        let nextToken = token
        ready = false
        loading?.cancel()
        loading = Task { [weak self] in
            guard let self, valid(expected) else { return }
            if reconcile {
                let updated = try? await webView.callAsyncJavaScript(Self.reconcileScript,
                    arguments: ["html": page, "restoreFocus": Self.hasFocus(webView),
                        "expectedToken": previousToken, "nextToken": nextToken, "fontSize": fontSize],
                    in: nil, contentWorld: Self.world) as? Bool
                guard valid(expected) else { return }
                if updated == true { ready = true; navigation = nil; speechKey = nil; synchronizeSpeech(); return }
            }
            if webView.url != nil {
                position = try? await webView.callAsyncJavaScript(Self.captureScript,
                    arguments: ["documentToken": previousToken], in: nil, contentWorld: Self.world) as? [String: Any]
            }
            guard valid(expected) else { return }
            var tagged = page
            if let opening = tagged.range(of: "<html", options: .caseInsensitive) {
                tagged.replaceSubrange(opening, with: "<html data-margined-history-token=\"\(nextToken)\"")
            }
            navigation = webView.loadHTMLString(tagged, baseURL: scope.fileURL?.deletingLastPathComponent())
        }
    }

    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        guard !invalidated, scope.isCurrent(), navigation === self.navigation else { return }
        ready = true
        let expected = generation, position = position
        self.position = nil
        Task { [weak self] in
            guard let self, valid(expected) else { return }
            _ = try? await view.callAsyncJavaScript(Self.finishScript,
                arguments: ["documentToken": token, "fontSize": fontSize, "position": position as Any? ?? NSNull()],
                in: nil, contentWorld: Self.world)
            guard valid(expected) else { return }
            speechKey = nil; synchronizeSpeech()
        }
    }

    func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard !invalidated, scope.isCurrent(), let url = action.request.url,
              action.targetFrame?.isMainFrame != false else { return .cancel }
        if action.navigationType != .linkActivated {
            return url.absoluteString == "about:blank" || url == scope.fileURL?.deletingLastPathComponent() ? .allow : .cancel
        }
        if url.fragment != nil && url.withoutHistoryFragment == view.url?.withoutHistoryFragment { return .allow }
        switch url.scheme?.lowercased() {
        case "https", "http", "mailto":
            #if os(iOS)
            await UIApplication.shared.open(url)
            #else
            NSWorkspace.shared.open(url)
            #endif
        case "file": scope.openFile(url)
        default: break
        }
        return .cancel
    }

    private static func hasFocus(_ view: WKWebView) -> Bool {
        #if os(iOS)
        func focused(_ view: UIView) -> Bool { view.isFirstResponder || view.subviews.contains(where: focused) }
        return focused(view)
        #else
        guard let responder = view.window?.firstResponder else { return false }
        return responder === view || (responder as? NSView)?.isDescendant(of: view) == true
        #endif
    }

    private static let captureScript = """
    if (document.documentElement.getAttribute('data-margined-history-token') !== documentToken) return null;
    const operation = 'capture', restoreFocus = false;
    \(documentScript)
    """
    private static let reconcileScript = """
    if (document.documentElement.getAttribute('data-margined-history-token') !== expectedToken) return false;
    function documentOperation(operation, position, restoreFocus) {
    \(documentScript)
    }
    const saved = documentOperation('capture', null, false);
    if (!documentOperation('update', null, restoreFocus)) return false;
    document.documentElement.setAttribute('data-margined-history-token', nextToken);
    document.body.style.fontSize = `${fontSize}px`;
    document.body.style.webkitTextSizeAdjust = '100%';
    documentOperation('restore', saved, restoreFocus);
    return true;
    """
    private static let finishScript = """
    if (document.documentElement.getAttribute('data-margined-history-token') !== documentToken) return false;
    function documentOperation(operation, position, restoreFocus) {
    \(documentScript)
    }
    const saved = position || documentOperation('capture', null, false);
    document.body.style.fontSize = `${fontSize}px`;
    document.body.style.webkitTextSizeAdjust = '100%';
    return documentOperation('restore', saved, false);
    """
}

/// Immutable file scope plus a per-page resource namespace prevents an old
/// history from reading or reporting failures in the next document.
@MainActor
private final class DiscussionHistoryImages: NSObject, WKURLSchemeHandler {
    private let loader = ImageSchemeHandler()
    private let scope: DiscussionHistoryScope
    private var active = true
    private(set) var generation = UUID().uuidString
    init(scope: DiscussionHistoryScope) {
        self.scope = scope
        super.init()
        loader.documentURL = scope.fileURL
        loader.loadFailed = { [weak self] message in
            guard let self, active, scope.isCurrent() else { return }
            scope.imageFailed(message)
        }
    }
    func renew() { loader.cancelPendingLoads(); generation = UUID().uuidString }
    func invalidate() { active = false; loader.cancelPendingLoads(); loader.loadFailed = nil }
    func webView(_ view: WKWebView, start task: any WKURLSchemeTask) {
        guard active, scope.isCurrent(), let url = task.request.url,
              ImageResourceNamespace.authorizes(url, token: generation) else {
            task.didFailWithError(URLError(.cancelled)); return
        }
        loader.webView(view, start: task)
    }
    func webView(_ view: WKWebView, stop task: any WKURLSchemeTask) { loader.webView(view, stop: task) }
}

private extension URL {
    var withoutHistoryFragment: URL? {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = nil
        return components.url
    }
}

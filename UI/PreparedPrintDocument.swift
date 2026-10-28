import Foundation
import WebKit

/// A frozen, read-only page retained until the system print job finishes.
@MainActor
final class PreparedPrintDocument: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private let images = ImageSchemeHandler()
    private var scope: PrintFileScope?
    private var completion: CheckedContinuation<Void, any Error>?
    private var deadline: Task<Void, Never>?
    private var finishing: Task<Void, Never>?
    private var navigation: WKNavigation?
    private var cancelled = false
    private let baseURL: URL?

    private init(fileURL: URL?) {
        baseURL = fileURL?.deletingLastPathComponent()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(images, forURLScheme: "margined-resource")
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 816, height: 1056), configuration: configuration)
        super.init()
        if let fileURL { scope = PrintFileScope(fileURL) }
        images.documentURL = fileURL
        webView.navigationDelegate = self
        webView.allowsLinkPreview = false
    }

    static func prepare(_ output: RenderedMarkdown, title: String, fileURL: URL?,
                        includeDiscussions: Bool, loadRemoteImages: Bool) async throws -> PreparedPrintDocument {
        try Task.checkCancellation()
        let page = try await MarkdownRenderer.shared.printHTML(output, title: title,
            includeDiscussions: includeDiscussions, loadRemoteImages: loadRemoteImages)
        try Task.checkCancellation()
        let prepared = PreparedPrintDocument(fileURL: fileURL)
        do {
            try await withTaskCancellationHandler {
                try await prepared.load(page)
            } onCancel: {
                Task { @MainActor in prepared.cancel() }
            }
            try Task.checkCancellation()
            return prepared
        } catch {
            prepared.cancel()
            throw error
        }
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        finish(.failure(CancellationError()))
        finishing?.cancel(); finishing = nil
        images.cancelPendingLoads()
        webView.navigationDelegate = nil
        webView.stopLoading()
        scope = nil
    }

    private func load(_ html: String) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
                self?.finish(.failure(URLError(.timedOut)))
            }
            let page = ImageResourceNamespace.html(html, token: UUID().uuidString)
            navigation = webView.loadHTMLString(page, baseURL: baseURL)
            if navigation == nil { finish(.failure(URLError(.cannotLoadFromNetwork))) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !cancelled, navigation === self.navigation, completion != nil else { return }
        finishing = Task { [weak self] in
            guard let self else { return }
            do {
                // didFinish commits the page; also settle every image before
                // handing it to a printer or PDF renderer. Failed images retain alt text.
                _ = try await webView.callAsyncJavaScript("""
                await Promise.all(Array.from(document.images, image => image.complete ? Promise.resolve() :
                    new Promise(resolve => {
                        image.addEventListener('load', resolve, {once:true});
                        image.addEventListener('error', resolve, {once:true});
                    })));
                await document.fonts.ready;
                void document.documentElement.offsetHeight;
                return true;
                """, arguments: [:], in: nil, contentWorld: .world(name: "MarginedPrint"))
                try Task.checkCancellation()
                guard !cancelled else { return }
                finish(.success(()))
            } catch { finish(.failure(error)) }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if navigation === self.navigation { finish(.failure(error)) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if navigation === self.navigation { finish(.failure(error)) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(URLError(.cannotLoadFromNetwork)))
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard !cancelled, action.navigationType != .linkActivated,
              action.targetFrame?.isMainFrame != false, let url = action.request.url,
              url.absoluteString == "about:blank" || url == baseURL else { return .cancel }
        return .allow
    }
    private func finish(_ result: Result<Void, any Error>) {
        deadline?.cancel(); deadline = nil
        let waiting = completion; completion = nil
        waiting?.resume(with: result)
    }
}

private final class PrintFileScope {
    private let url: URL
    private let accessed: Bool
    init(_ url: URL) { self.url = url; accessed = url.startAccessingSecurityScopedResource() }
    deinit { if accessed { url.stopAccessingSecurityScopedResource() } }
}

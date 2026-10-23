import CoreFoundation
import SwiftUI
import UIKit
import WebKit

/// The rendered page has no author JavaScript. App-owned navigation, tasks and
/// speech run in a separate content world and share the Mac DOM reconciler.
struct MobileWebView: UIViewRepresentable {
    let reader: MobileReaderState
    private let inputs: Inputs
    @Environment(\.sizeCategory) private var sizeCategory

    @MainActor
    init(reader: MobileReaderState) {
        self.reader = reader
        // Capture observable values while SwiftUI evaluates the parent's body.
        // Reading them only in updateUIView can miss an intent when the parent
        // produces another representable holding the same reader reference.
        inputs = Inputs(reader: reader)
    }

    private struct Inputs: Equatable {
        let readerID: UUID
        let documentGeneration: UUID
        let html: String?
        let source: String
        let fileURL: URL?
        let zoom: Double
        let imageGeneration: Int
        let navigationGeneration: Int
        let navigationTarget: String?
        let searchGeneration: Int
        let searchText: String
        let searchBackwards: Bool
        let rendering: Bool
        let saving: Bool
        let confirmation: Bool
        let checklist: Bool
        let holding: Bool
        let pendingUpdate: Bool
        let speechRequest: UUID?
        let speechMode: String
        let speechOwner: UUID?
        let speechActive: Bool
        let speechElement: String?
        let speechFollow: Bool

        @MainActor
        init(reader: MobileReaderState) {
            readerID = reader.id
            documentGeneration = reader.documentGeneration
            html = reader.rendered?.html
            source = reader.source
            fileURL = reader.fileURL
            zoom = reader.zoom
            imageGeneration = reader.imageReloadGeneration
            navigationGeneration = reader.navigationGeneration
            navigationTarget = reader.navigationTarget
            searchGeneration = reader.searchGeneration
            searchText = reader.searchText
            searchBackwards = reader.searchBackwards
            rendering = reader.isRendering
            saving = reader.checklistSaving
            confirmation = reader.showChecklistConfirmation
            checklist = reader.checklistMode
            holding = reader.playbackHolding
            pendingUpdate = reader.hasPendingFileUpdate
            speechRequest = reader.speechStartRequest
            speechMode = reader.speechStartMode
            speechOwner = reader.playback.ownerID
            speechActive = reader.playback.session.isActive
            speechElement = reader.playback.session.currentSegment?.elementID
            speechFollow = reader.playback.session.followReading
        }
    }

    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        return configuration
    }

    func makeCoordinator() -> Coordinator { Coordinator(reader: reader) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = Self.configuration()
        configuration.setURLSchemeHandler(context.coordinator.images, forURLScheme: "margined-resource")
        configuration.userContentController.add(context.coordinator, contentWorld: Coordinator.contentWorld, name: "taskToggle")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsLinkPreview = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.accessibilityLabel = String(localized: "Markdown document")
        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard inputs.readerID == reader.id else { return }
        context.coordinator.update(category: sizeCategory.uiCategory)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.invalidate()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "taskToggle", contentWorld: Coordinator.contentWorld)
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let contentWorld = WKContentWorld.world(name: "MarginedMobileDocument")
        let reader: MobileReaderState
        let images = MobileImageSchemeHandler()
        weak var webView: WKWebView?
        private var html: String?
        private var documentGeneration: UUID?
        private var loadedFile: URL?
        private var resourceToken = UUID().uuidString
        private var imageGeneration = -1
        private var navigationGeneration = -1
        private var searchGeneration = -1
        private var generation = 0
        private var activeNavigation: WKNavigation?
        private var contentReady = false
        private var token = UUID().uuidString
        private var category: UIContentSizeCategory = .large
        private var typographyKey = ""
        private var taskKey = ""
        private var speechKey = ""
        private var speechRequestID: UUID?
        private var readingPosition: [String: Any]?
        private var pendingNavigation: String?
        private var loadingTask: Task<Void, Never>?
        private var isInvalidated = false

        init(reader: MobileReaderState) {
            self.reader = reader
            super.init()
            images.loadFailed = { [weak reader] in reader?.localImageError = $0 }
        }

        func invalidate() {
            isInvalidated = true
            generation += 1
            loadingTask?.cancel()
            loadingTask = nil
            webView = nil
        }

        func update(category: UIContentSizeCategory) {
            guard !isInvalidated else { return }
            self.category = category
            if documentGeneration != reader.documentGeneration {
                documentGeneration = reader.documentGeneration
                generation += 1
                loadingTask?.cancel()
                loadingTask = nil
                activeNavigation = nil
                contentReady = false
                html = nil
                loadedFile = nil
                readingPosition = nil
                pendingNavigation = nil
                token = UUID().uuidString
                resourceToken = UUID().uuidString
                webView?.stopLoading()
                // New document identity also covers a new Drafts snapshot, for
                // which both the previous and new file URL are nil.
                webView?.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
            }
            images.documentURL = reader.fileURL
            images.generation = resourceToken
            if let rendered = reader.rendered {
                let resourceChange = imageGeneration != reader.imageReloadGeneration || loadedFile != reader.fileURL
                if html != rendered.html || resourceChange {
                    if resourceChange { resourceToken = UUID().uuidString }
                    images.generation = resourceToken
                    imageGeneration = reader.imageReloadGeneration
                    loadedFile = reader.fileURL
                    let preservePosition = html != nil
                    html = rendered.html
                    load(MobileWebResources.html(rendered.html, token: resourceToken), forceNavigation: resourceChange, preservePosition: preservePosition)
                }
            }
            synchronizeTypography()
            configureTasks()
            synchronizeSpeech()
            if navigationGeneration != reader.navigationGeneration {
                navigationGeneration = reader.navigationGeneration
                if let target = reader.navigationTarget { navigate(target) }
            }
            if searchGeneration != reader.searchGeneration {
                searchGeneration = reader.searchGeneration
                find()
            }
        }

        private func load(_ html: String, forceNavigation: Bool, preservePosition: Bool) {
            guard let webView else { return }
            let reconcile = contentReady && !forceNavigation
            generation += 1
            let expectedGeneration = generation
            contentReady = false
            let previousToken = token
            token = UUID().uuidString
            let currentToken = token
            typographyKey = ""
            taskKey = ""
            speechKey = ""
            loadingTask?.cancel()
            loadingTask = Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                if reconcile {
                    let renderedCategory = category, renderedZoom = reader.zoom
                    let updated = try? await webView.callAsyncJavaScript(MobileWebTypography.reconcileScript,
                        arguments: ["html": html, "restoreFocus": Self.hasDocumentFocus(webView),
                                    "fontSize": Double(MobileWebTypography.fontSize(category: renderedCategory, zoom: renderedZoom)),
                                    "expectedToken": previousToken, "nextToken": currentToken],
                        in: nil, contentWorld: Self.contentWorld) as? Bool
                    guard valid(expectedGeneration) else { return }
                    if updated == true {
                        typographyKey = "\(renderedCategory.rawValue):\(renderedZoom)"
                        contentReady = true
                        activeNavigation = nil
                        ready()
                        return
                    }
                }
                if preservePosition, webView.url != nil {
                    readingPosition = try? await webView.callAsyncJavaScript(Self.guarded(MobileWebScripts.document),
                        arguments: ["operation": "capture", "documentToken": previousToken], in: nil, contentWorld: Self.contentWorld) as? [String: Any]
                }
                guard valid(expectedGeneration) else { return }
                var page = html
                if let opening = page.range(of: "<html", options: .caseInsensitive) {
                    page.replaceSubrange(opening, with: "<html data-margined-mobile-token=\"\(currentToken)\"")
                }
                activeNavigation = webView.loadHTMLString(page, baseURL: loadedFile?.deletingLastPathComponent())
            }
        }

        private func valid(_ expectedGeneration: Int) -> Bool {
            !isInvalidated && !Task.isCancelled && expectedGeneration == generation
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !isInvalidated, navigation === activeNavigation else { return }
            contentReady = true
            let expectedGeneration = generation
            let position = readingPosition
            readingPosition = nil
            Task { [weak self] in
                guard let self, valid(expectedGeneration) else { return }
                if let position {
                    _ = try? await webView.callAsyncJavaScript(Self.guarded(MobileWebScripts.document),
                        arguments: ["operation": "restore", "position": position, "restoreFocus": false, "documentToken": token],
                        in: nil, contentWorld: Self.contentWorld)
                }
                guard valid(expectedGeneration) else { return }
                ready()
            }
        }

        private func ready() {
            synchronizeTypography()
            configureTasks()
            synchronizeSpeech()
            if let target = pendingNavigation { pendingNavigation = nil; navigate(target) }
            if !reader.searchText.isEmpty { find() }
        }

        private func synchronizeTypography() {
            guard contentReady, let webView else { return }
            let key = "\(category.rawValue):\(reader.zoom)"
            guard key != typographyKey else { return }
            typographyKey = key
            let expectedGeneration = generation
            let category = category, zoom = reader.zoom, token = token
            Task { [weak self] in
                guard let self, valid(expectedGeneration), typographyKey == key else { return }
                do { try await MobileWebTypography.apply(to: webView, category: category, zoom: zoom, expectedToken: token) }
                catch { if valid(expectedGeneration) { reader.errorMessage = error.localizedDescription } }
            }
        }

        private var tasksEnabled: Bool {
            contentReady && !isInvalidated && reader.fileURL != nil && loadedFile == reader.fileURL &&
                !reader.playbackHolding && !reader.hasPendingFileUpdate && !reader.checklistSaving &&
                !reader.isRendering && !reader.showChecklistConfirmation && html == reader.rendered?.html &&
                reader.rendered?.taskSource == reader.source
        }

        private func configureTasks() {
            guard contentReady, let webView else { return }
            let enabled = tasksEnabled, canSave = reader.checklistMode
            let token = token
            let key = "\(token):\(enabled):\(canSave):\(reader.checklistSaving):\(reader.isRendering):\(reader.playbackHolding)"
            guard taskKey != key else { return }
            taskKey = key
            let expectedGeneration = generation
            Task { [weak self] in
                guard let self, valid(expectedGeneration), taskKey == key else { return }
                _ = try? await webView.callAsyncJavaScript("""
                if (document.documentElement.getAttribute('data-margined-mobile-token') !== token) return false;
                window.marginedTaskState = {enabled, canSave, token};
                for (const input of document.querySelectorAll('input[data-margined-task]')) {
                    if (!enabled && document.activeElement === input) window.marginedPendingTaskFocus = input;
                    input.disabled = !enabled;
                    if (!saving && !rendering) input.checked = input.defaultChecked;
                    input.title = holding ? holdingTitle : (canSave ? saveTitle : consentTitle);
                }
                if (enabled) {
                    const pending = window.marginedPendingTaskFocus;
                    if (restoreFocus && pending?.isConnected && (document.activeElement === document.body || document.activeElement === pending)) pending.focus({preventScroll:true});
                    window.marginedPendingTaskFocus = null;
                }
                if (!window.marginedTaskListener) {
                    window.marginedTaskListener = true;
                    document.addEventListener('change', event => {
                        const input = event.target, state = window.marginedTaskState;
                        if (!event.isTrusted || !state?.enabled || !(input instanceof HTMLInputElement) || !input.hasAttribute('data-margined-task')) return;
                        const checked = input.checked;
                        window.marginedPendingTaskFocus = input;
                        if (!state.canSave) input.checked = input.defaultChecked;
                        for (const box of document.querySelectorAll('input[data-margined-task]')) box.disabled = true;
                        window.webkit.messageHandlers.taskToggle.postMessage({id:Number(input.dataset.marginedTask), checked, token:state.token});
                    });
                }
                return true;
                """, arguments: ["enabled": enabled, "canSave": canSave, "token": token,
                    "saving": reader.checklistSaving, "rendering": reader.isRendering, "holding": reader.playbackHolding,
                    "restoreFocus": Self.hasDocumentFocus(webView),
                    "holdingTitle": String(localized: "Stop Read Aloud before saving checkmarks."),
                    "saveTitle": String(localized: "Save this checkbox change to the Markdown file"),
                    "consentTitle": String(localized: "Click to save checkmarks in this file")],
                    in: nil, contentWorld: Self.contentWorld)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "taskToggle",
                  let request = MobileTaskBridge.request(message.body, isMainFrame: message.frameInfo.isMainFrame,
                    enabled: tasksEnabled, token: token, tasks: reader.rendered?.tasks ?? []) else { return }
            if !reader.requestTaskChecked(request.id, checked: request.checked) {
                taskKey = ""
                configureTasks()
            }
        }

        private static func guarded(_ script: String) -> String {
            """
            if (document.documentElement.getAttribute('data-margined-mobile-token') !== documentToken) return null;
            \(script)
            """
        }

        private static func hasDocumentFocus(_ view: UIView) -> Bool {
            view.isFirstResponder || view.subviews.contains(where: hasDocumentFocus)
        }

        private func synchronizeSpeech() {
            guard contentReady, let webView else { return }
            if let requestID = reader.speechStartRequest, speechRequestID != requestID {
                speechRequestID = requestID
                let expectedGeneration = generation, mode = reader.speechStartMode
                Task { [weak self] in
                    guard let self, valid(expectedGeneration) else { return }
                    let result = try? await webView.callAsyncJavaScript(Self.guarded(MobileWebScripts.speech),
                        arguments: ["operation": "locate", "mode": mode, "documentToken": token], in: nil, contentWorld: Self.contentWorld) as? [String: Any]
                    guard valid(expectedGeneration), reader.speechStartRequest == requestID else {
                        speechRequestID = nil
                        synchronizeSpeech()
                        return
                    }
                    reader.completeSpeechStart(requestID: requestID, elementID: result?["elementID"] as? String, offset: result?["offset"] as? Int ?? 0)
                }
            }
            let session = reader.playback.session
            let owned = reader.playback.ownerID == reader.id
            let element = owned && session.isActive ? session.currentSegment?.elementID : nil
            let follow = owned && session.followReading
            let key = "\(element ?? "none"):\(follow)"
            guard key != speechKey else { return }
            speechKey = key
            let expectedGeneration = generation
            Task { [weak self] in
                guard let self, valid(expectedGeneration), speechKey == key else { return }
                _ = try? await webView.callAsyncJavaScript(Self.guarded(MobileWebScripts.speech),
                    arguments: ["operation": "highlight", "elementID": element ?? "", "follow": follow, "documentToken": token],
                    in: nil, contentWorld: Self.contentWorld)
            }
        }

        private func navigate(_ target: String) {
            guard let webView else { return }
            guard contentReady else { pendingNavigation = target; return }
            let expectedGeneration = generation
            Task { [weak self] in
                guard let self, valid(expectedGeneration), reader.navigationTarget == target else { return }
                _ = try? await webView.callAsyncJavaScript(Self.guarded(MobileWebScripts.document),
                    arguments: ["operation": "navigate", "kind": "element", "id": target, "focus": true, "documentToken": token],
                    in: nil, contentWorld: Self.contentWorld)
            }
        }

        private func find() {
            guard let webView else { return }
            guard !reader.searchText.isEmpty else { reader.searchMatch = nil; return }
            guard contentReady else { return }
            let query = reader.searchText, expectedSearch = reader.searchGeneration, expectedGeneration = generation
            let configuration = WKFindConfiguration()
            configuration.backwards = reader.searchBackwards
            configuration.caseSensitive = false
            configuration.wraps = true
            Task { [weak self] in
                let result = try? await webView.find(query, configuration: configuration)
                guard let self, valid(expectedGeneration), reader.searchGeneration == expectedSearch else { return }
                reader.searchMatch = result?.matchFound == true
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            guard !isInvalidated, navigation === activeNavigation, (error as NSError).code != NSURLErrorCancelled else { return }
            reader.errorMessage = error.localizedDescription
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard !isInvalidated, let url = navigationAction.request.url,
                  navigationAction.targetFrame?.isMainFrame != false else { return .cancel }
            if navigationAction.navigationType != .linkActivated {
                let initial = loadedFile?.deletingLastPathComponent()
                return url.absoluteString == "about:blank" || url == initial ? .allow : .cancel
            }
            if url.fragment != nil && url.withoutFragment == webView.url?.withoutFragment { return .allow }
            switch url.scheme?.lowercased() {
            case "https", "http", "mailto":
                await UIApplication.shared.open(url)
            case "file" where ["md", "markdown", "mdown", "mkd", "mkdn"].contains(url.pathExtension.lowercased()):
                Task { [weak reader] in await reader?.open(url: url) }
            default: break
            }
            return .cancel
        }
    }
}

/// Narrow native gate in addition to the isolated listener's isTrusted check.
/// Never trust a stale page, subframe, coerced boolean ID or unmapped checkbox.
enum MobileTaskBridge {
    struct Request: Equatable { let id: Int; let checked: Bool }

    static func request(_ body: Any, isMainFrame: Bool, enabled: Bool, token: String, tasks: [MarkdownTask]) -> Request? {
        guard isMainFrame, enabled, let values = body as? [String: Any], values["token"] as? String == token,
              let number = values["id"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let state = values["checked"] as? NSNumber, CFGetTypeID(state) == CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= Double(Int32.max),
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              tasks.contains(where: { $0.id == number.intValue }) else { return nil }
        return Request(id: number.intValue, checked: state.boolValue)
    }
}

/// Namespace custom-scheme image requests to the currently authorized resource
/// tree. A new file or explicit folder reload cannot reuse another file's cache.
enum MobileWebResources {
    static func authorizes(_ url: URL, token: String) -> Bool {
        guard url.scheme == "margined-resource", url.host == "local",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let generations = parts.queryItems?.filter { $0.name == "generation" } ?? []
        return generations.count == 1 && generations[0].value == token
    }

    static func html(_ html: String, token: String) -> String {
        html.replacingOccurrences(of: #"(<img\b[^>]*\ssrc=")(margined-resource://local/[^"]*)(")"#,
            with: "$1$2?generation=\(token)$3", options: .regularExpression)
    }
}

@MainActor
final class MobileImageSchemeHandler: NSObject, WKURLSchemeHandler {
    private let loader = ImageSchemeHandler()
    var generation = "" {
        didSet { if generation != oldValue { loader.cancelPendingLoads() } }
    }
    var documentURL: URL? {
        get { loader.documentURL }
        set { loader.documentURL = newValue }
    }
    var loadFailed: ((String) -> Void)? {
        get { loader.loadFailed }
        set { loader.loadFailed = newValue }
    }
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, MobileWebResources.authorizes(url, token: generation) else {
            // A canceled page must never read an identically named image from
            // the next document, nor report that old failure in the new reader.
            task.didFailWithError(URLError(.cancelled))
            return
        }
        loader.webView(webView, start: task)
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) { loader.webView(webView, stop: task) }
}

@MainActor
enum MobileWebTypography {
    static func fontSize(category: UIContentSizeCategory, zoom: Double) -> CGFloat {
        let zoom = zoom.isFinite ? min(3, max(0.5, zoom)) : 1
        return UIFontMetrics(forTextStyle: .body).scaledValue(for: 16,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: category)) * zoom
    }

    static let reconcileScript = """
    if (typeof expectedToken !== 'undefined' && document.documentElement.getAttribute('data-margined-mobile-token') !== expectedToken) return false;
    function documentOperation(operation, position) {
    \(MobileWebScripts.document)
    }
    const saved = documentOperation('capture', null);
    const updated = documentOperation('update', null);
    if (updated) {
        document.body.style.fontSize = `${fontSize}px`;
        document.body.style.webkitTextSizeAdjust = '100%';
        if (typeof nextToken !== 'undefined') document.documentElement.setAttribute('data-margined-mobile-token', nextToken);
        documentOperation('restore', saved);
    }
    return updated;
    """

    static func apply(to webView: WKWebView, category: UIContentSizeCategory, zoom: Double, expectedToken: String = "") async throws {
        // A body style leaves the renderer's head unchanged, so the next task
        // tick can reconcile in place. Font scaling never changes authored images.
        _ = try await webView.callAsyncJavaScript("""
        if (expectedToken && document.documentElement.getAttribute('data-margined-mobile-token') !== expectedToken) return false;
        function documentOperation(operation, position, restoreFocus) {
        \(MobileWebScripts.document)
        }
        const saved = documentOperation('capture', null, false);
        document.body.style.fontSize = `${fontSize}px`;
        document.body.style.webkitTextSizeAdjust = '100%';
        return documentOperation('restore', saved, false);
        """, arguments: ["fontSize": Double(fontSize(category: category, zoom: zoom)), "expectedToken": expectedToken],
        in: nil, contentWorld: MobileWebView.Coordinator.contentWorld)
    }
}

private enum MobileWebScripts {
    static let document = load("reader-document")
    static let speech = load("reader-speech")
    private static func load(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "return false;" }
        return text
    }
}

private extension ContentSizeCategory {
    var uiCategory: UIContentSizeCategory {
        switch self {
        case .extraSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .extraLarge: .extraLarge
        case .extraExtraLarge: .extraExtraLarge
        case .extraExtraExtraLarge: .extraExtraExtraLarge
        case .accessibilityMedium: .accessibilityMedium
        case .accessibilityLarge: .accessibilityLarge
        case .accessibilityExtraLarge: .accessibilityExtraLarge
        case .accessibilityExtraExtraLarge: .accessibilityExtraExtraLarge
        case .accessibilityExtraExtraExtraLarge: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}

private extension URL {
    var withoutFragment: URL? {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = nil
        return components.url
    }
}

import CoreFoundation
import SwiftUI
import UIKit
import WebKit

/// The rendered page has no author JavaScript. App-owned navigation, tasks and
/// speech run in a separate content world and share the Mac DOM reconciler.
struct MobileWebView: UIViewRepresentable {
    let reader: MobileReaderState
    private let inputs: Inputs
    private let retainedPage: MobileReadingPage?
    @Environment(\.sizeCategory) private var sizeCategory

    @MainActor
    init(reader: MobileReaderState, retainedPage: MobileReadingPage? = nil) {
        self.reader = reader
        self.retainedPage = retainedPage
        // Capture observable values while SwiftUI evaluates the parent's body.
        // Reading them only in updateUIView can miss an intent when the parent
        // produces another representable holding the same reader reference.
        inputs = Inputs(reader: reader)
    }

    private struct Inputs: Equatable {
        let readerID: UUID
        let inspector: MobileReaderState.Inspector?
        let discussionFilter: DiscussionSession.Filter
        let discussionSelection: DiscussionSession.DraftKey?
        let discussionRequest: Int
        let discussionPassageRequest: UUID?
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
            inspector = reader.inspector
            discussionFilter = reader.discussions.filter
            discussionSelection = reader.discussions.selection
            discussionRequest = reader.discussionSelectionGeneration
            discussionPassageRequest = reader.discussionPassageRequest?.id
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
            saving = reader.fileSaving
            confirmation = reader.showChecklistConfirmation
            checklist = reader.checklistMode
            holding = reader.playbackHolding
            pendingUpdate = reader.hasPendingFileUpdate
            speechRequest = reader.speechStartRequest
            speechMode = reader.speechStartMode
            speechOwner = reader.playback.ownerID
            speechActive = reader.playback.conversationID == nil && reader.playback.session.isActive
            speechElement = reader.playback.conversationID == nil ? reader.playback.session.currentSegment?.elementID : nil
            speechFollow = reader.playback.session.followReading
        }
    }

    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        return configuration
    }

    func makeCoordinator() -> Coordinator {
        if let retainedPage {
            precondition(retainedPage.coordinator.reader === reader)
            return retainedPage.coordinator
        }
        return Coordinator(reader: reader)
    }

    func makeUIView(context: Context) -> WKWebView {
        retainedPage?.webView ?? Self.createUIView(coordinator: context.coordinator)
    }

    @MainActor
    static func createUIView(coordinator: Coordinator) -> WKWebView {
        let configuration = Self.configuration()
        configuration.setURLSchemeHandler(coordinator.images, forURLScheme: "margined-resource")
        configuration.userContentController.add(coordinator, contentWorld: Coordinator.contentWorld, name: "taskToggle")
        configuration.userContentController.add(coordinator, contentWorld: Coordinator.discussionWorld, name: "discussion")
        let webView = MobileDocumentWebView(frame: .zero, configuration: configuration)
        webView.geometryChanged = { [weak coordinator] in coordinator?.requestPassageVisibilityCheck() }
        webView.navigationDelegate = coordinator
        webView.allowsLinkPreview = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.accessibilityLabel = String(localized: "Markdown document")
        coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard inputs.readerID == reader.id else { return }
        context.coordinator.update(category: sizeCategory.uiCategory)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        // A compact native destination can dismantle its hidden root view.
        // The workspace keeps that page alive until the document workspace ends.
        guard !coordinator.isWorkspaceRetained else { return }
        disposeUIView(webView, coordinator: coordinator)
    }

    @MainActor
    static func disposeUIView(_ webView: WKWebView, coordinator: Coordinator) {
        (webView as? MobileDocumentWebView)?.geometryChanged = nil
        coordinator.invalidate()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "taskToggle", contentWorld: Coordinator.contentWorld)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "discussion", contentWorld: Coordinator.discussionWorld)
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let contentWorld = WKContentWorld.world(name: "MarginedMobileDocument")
        static let discussionWorld = WKContentWorld.world(name: "MarginedMobileDiscussions")
        private static let findWorld = WKContentWorld.world(name: "MarginedMobileFind")
        private var discussionConfiguration: String?
        private var discussionSelectionGeneration = 0
        private var discussionDecorationKey: String?
        let reader: MobileReaderState
        var isWorkspaceRetained = false
        let images = MobileImageSchemeHandler()
        weak var webView: WKWebView?
        private var html: String?
        private var documentGeneration: UUID?
        private var loadedFile: URL?
        private var resourceToken = UUID().uuidString
        private var imageGeneration = -1
        private var navigationGeneration = -1
        private var searchGeneration = -1
        private var lastFindQuery: String?
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
        private var passageVisibilityCheckQueued = false
        private var passageTransition: UUID?
        private var passageInFlight: UUID?
        private var loadingTask: Task<Void, Never>?
        private var isInvalidated = false

        init(reader: MobileReaderState) {
            self.reader = reader
            super.init()
            images.loadFailed = { [weak self] error in
                guard let self, !isInvalidated, documentGeneration == reader.documentGeneration else { return }
                reader.localImageError = error
            }
        }

        func invalidate() {
            images.cancelPendingLoads()
            isInvalidated = true
            generation += 1
            loadingTask?.cancel()
            loadingTask = nil
            webView = nil
        }

        func update(category: UIContentSizeCategory) {
            guard !isInvalidated else { return }
            defer { configureDiscussions() }
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
                lastFindQuery = nil
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
                    load(ImageResourceNamespace.html(rendered.html, token: resourceToken), forceNavigation: resourceChange, preservePosition: preservePosition)
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
            !isInvalidated && !Task.isCancelled && expectedGeneration == generation &&
                documentGeneration == reader.documentGeneration
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !isInvalidated, documentGeneration == reader.documentGeneration,
                  navigation === activeNavigation else { return }
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
            defer { configureDiscussions() }
            observeReadingPositionDuringResize()
            synchronizeTypography()
            configureTasks()
            synchronizeSpeech()
            if let target = pendingNavigation { pendingNavigation = nil; navigate(target) }
            if !reader.searchText.isEmpty { find() }
        }

        private func observeReadingPositionDuringResize() {
            guard contentReady, let webView else { return }
            let expectedGeneration = generation, documentToken = token
            Task { [weak self] in
                guard let self, valid(expectedGeneration), token == documentToken else { return }
                _ = try? await webView.callAsyncJavaScript(Self.guarded(MobileWebScripts.document),
                    arguments: ["operation": "observeResize", "restoreFocus": false, "documentToken": documentToken],
                    in: nil, contentWorld: Self.contentWorld)
            }
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
            contentReady && !isInvalidated && documentGeneration == reader.documentGeneration &&
                reader.fileURL != nil && loadedFile == reader.fileURL &&
                !reader.playbackHolding && !reader.hasPendingFileUpdate && !reader.fileSaving &&
                !reader.isRendering && !reader.showChecklistConfirmation && html == reader.rendered?.html &&
                reader.rendered?.taskSource == reader.source
        }

        private func configureTasks() {
            guard contentReady, let webView else { return }
            let enabled = tasksEnabled, canSave = reader.checklistMode
            let token = token
            let key = "\(token):\(enabled):\(canSave):\(reader.fileSaving):\(reader.isRendering):\(reader.playbackHolding)"
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
                    "saving": reader.fileSaving, "rendering": reader.isRendering, "holding": reader.playbackHolding,
                    "restoreFocus": Self.hasDocumentFocus(webView),
                    "holdingTitle": String(localized: "Stop Read Aloud before saving checkmarks."),
                    "saveTitle": String(localized: "Save this checkbox change to the Markdown file"),
                    "consentTitle": String(localized: "Click to save checkmarks in this file")],
                    in: nil, contentWorld: Self.contentWorld)
            }
        }

        fileprivate func requestPassageVisibilityCheck() {
            guard !isInvalidated, reader.discussionPassageRequest != nil,
                  !passageVisibilityCheckQueued else { return }
            passageVisibilityCheckQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.passageVisibilityCheckQueued = false
                self.configureDiscussions()
            }
        }

        private func canRevealPassage(_ request: UUID) -> Bool {
            guard let webView, let window = webView.window,
                  webView.bounds.width > 0, webView.bounds.height > 0,
                  webView.convert(webView.bounds, to: window).intersects(window.bounds) else { return false }
            var ancestor: UIView? = webView
            while let view = ancestor {
                guard !view.isHidden, view.alpha > 0 else { return false }
                ancestor = view.superview
            }
            var responder: UIResponder? = webView
            while let current = responder {
                if let controller = current as? UIViewController,
                   let navigation = controller.navigationController {
                    if let transition = navigation.transitionCoordinator {
                        if passageTransition != request {
                            passageTransition = request
                            let registered = transition.animate(alongsideTransition: nil) { [weak self] _ in
                                guard let self else { return }
                                if self.passageTransition == request { self.passageTransition = nil }
                                self.requestPassageVisibilityCheck()
                            }
                            if !registered { passageTransition = nil }
                        }
                        return false
                    }
                    guard let top = navigation.topViewController?.viewIfLoaded else { return false }
                    return webView.isDescendant(of: top)
                }
                responder = current.next
            }
            return false
        }

        private func configureDiscussions() {
            guard contentReady, !reader.isRendering, html == reader.rendered?.html,
                  let projection = reader.rendered?.discussionText, let webView else { return }
            let token = String(generation), ids = reader.rendered?.discussions?.threads.map(\.id) ?? []
            let key = token + ":" + projection.sourceID
            let selected: String
            if case let .thread(id) = reader.discussions.selection { selected = id } else { selected = "" }
            let visible = reader.inspector == .discussions
            let passage = reader.discussionPassageRequest
            let wantsPassage = passage.map {
                reader.matchesDiscussionVersion($0.version) && $0.sourceID == projection.sourceID &&
                projection.anchorResults[$0.threadID]?.status == .attached
            } ?? false
            if let passage, !wantsPassage {
                Task { [weak self] in
                    guard let self, reader.discussionPassageRequest?.id == passage.id else { return }
                    reader.discussionPassageRequest = nil
                }
            }
            let decorationKey = key + ":" + String(visible) + ":" + selected + ":" + reader.discussions.filter.rawValue +
                ":" + (wantsPassage ? passage?.id.uuidString ?? "" : "")
            let configure = discussionConfiguration != key
            let decorate = discussionDecorationKey != decorationKey
            let wantsSelection = discussionSelectionGeneration != reader.discussionSelectionGeneration
            guard configure || decorate || wantsSelection || wantsPassage else { return }
            discussionConfiguration = key; discussionDecorationKey = decorationKey
            let selectionGeneration = reader.discussionSelectionGeneration
            discussionSelectionGeneration = selectionGeneration
            var anchoredThreads = reader.filteredDiscussionThreads
            if wantsPassage, let passage, !anchoredThreads.contains(where: { $0.id == passage.threadID }),
               let thread = reader.rendered?.discussions?.threads.first(where: { $0.id == passage.threadID }) {
                anchoredThreads.append(thread)
            }
            let anchors: [[String: Any]] = anchoredThreads.compactMap { thread in
                let id = thread.id
                guard let anchor = projection.anchorResults[id], anchor.status == .attached, let range = anchor.range,
                      let selection = projection.selection(range, renderID: token) else { return nil }
                return ["id": id, "location": selection.range.location, "length": selection.range.length,
                    "startUnit": selection.domRange.start.unit, "startOffset": selection.domRange.start.offset,
                    "endUnit": selection.domRange.end.unit, "endOffset": selection.domRange.end.offset]
            }
            Task { [weak self] in
                guard let self else { return }
                let context = DiscussionBridge.Context(token: token, sourceID: projection.sourceID, enabled: true, allowedThreadIDs: Set(ids))
                var arguments: [String: Any] = ["operation": "configure", "token": token,
                    "sourceID": projection.sourceID, "allowedThreadIDs": ids]
                if configure {
                    _ = try? await webView.callAsyncJavaScript(DiscussionWebScripts.script, arguments: arguments,
                        in: nil, contentWorld: Self.discussionWorld)
                }
                guard contentReady, String(generation) == token, html == reader.rendered?.html,
                      reader.rendered?.discussionText?.sourceID == projection.sourceID else { return }
                if decorate, discussionDecorationKey == decorationKey {
                    arguments.merge(["operation": "decorate", "anchors": anchors, "expectedText": projection.text,
                        "visible": visible, "selectedID": selected, "markerLabel": String(localized: "Open discussion")], uniquingKeysWith: { _, value in value })
                    let value = try? await webView.callAsyncJavaScript(DiscussionWebScripts.script, arguments: arguments,
                        in: nil, contentWorld: Self.discussionWorld)
                    if discussionDecorationKey == decorationKey, let value,
                       let snapshot = DiscussionMarginSnapshot.read(value, context: context) { reader.acceptDiscussionMargin(snapshot) }
                }
                if wantsPassage, let passage, reader.discussionPassageRequest?.id == passage.id,
                   passageInFlight != passage.id, reader.matchesDiscussionVersion(passage.version),
                   passage.sourceID == projection.sourceID, canRevealPassage(passage.id) {
                    passageInFlight = passage.id
                    defer { if passageInFlight == passage.id { passageInFlight = nil } }
                    arguments.merge(["operation": "goTo", "threadID": passage.threadID, "focus": true],
                        uniquingKeysWith: { _, value in value })
                    let moved = try? await webView.callAsyncJavaScript(DiscussionWebScripts.script,
                        arguments: arguments, in: nil, contentWorld: Self.discussionWorld) as? Bool
                    guard contentReady, String(generation) == token,
                          reader.matchesDiscussionVersion(passage.version),
                          reader.discussionPassageRequest?.id == passage.id else { return }
                    if moved == true { reader.discussionPassageRequest = nil }
                }
                if wantsSelection, reader.discussionSelectionGeneration == selectionGeneration {
                    arguments["operation"] = "selection"
                    let value = try? await webView.callAsyncJavaScript(DiscussionWebScripts.script, arguments: arguments,
                        in: nil, contentWorld: Self.discussionWorld)
                    guard contentReady, String(generation) == token, html == reader.rendered?.html,
                          reader.discussionSelectionGeneration == selectionGeneration else { return }
                    if let value, case let .selection(selection) = DiscussionBridge.request(value, isMainFrame: true,
                        context: context, projection: projection) { reader.acceptNewDiscussionSelection(selection) }
                    else { reader.acceptNewDiscussionSelection(nil) }
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !isInvalidated, documentGeneration == reader.documentGeneration else { return }
            if message.name == "discussion" {
                guard contentReady, !reader.isRendering, html == reader.rendered?.html,
                      let projection = reader.rendered?.discussionText, message.frameInfo.isMainFrame else { return }
                let context = DiscussionBridge.Context(token: String(generation), sourceID: projection.sourceID,
                    enabled: true, allowedThreadIDs: Set(reader.rendered?.discussions?.threads.map(\.id) ?? []))
                if let value = DiscussionMarginSnapshot.read(message.body, context: context) { reader.acceptDiscussionMargin(value) }
                else if case let .openThread(id) = DiscussionBridge.request(message.body, isMainFrame: true,
                    context: context, projection: projection) { reader.openDiscussion(id) }
                return
            }
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
            let element = owned && reader.playback.conversationID == nil && session.isActive ? session.currentSegment?.elementID : nil
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
            let query = reader.searchText
            if query.isEmpty { reader.searchMatch = nil }
            guard contentReady else { return }
            guard !query.isEmpty || lastFindQuery != nil else { return }
            let expectedSearch = reader.searchGeneration, expectedGeneration = generation
            let configuration = WKFindConfiguration()
            configuration.backwards = reader.searchBackwards
            configuration.caseSensitive = false
            configuration.wraps = true
            Task { [weak self] in
                guard let self, valid(expectedGeneration), reader.searchGeneration == expectedSearch else { return }
                if query.isEmpty {
                    await clearFind(in: webView, previousQuery: lastFindQuery ?? "",
                                    search: expectedSearch, document: expectedGeneration)
                    return
                }
                lastFindQuery = query
                let result = try? await webView.find(query, configuration: configuration)
                guard valid(expectedGeneration), reader.searchGeneration == expectedSearch else { return }
                reader.searchMatch = result?.matchFound == true
            }
        }

        private func clearFind(in webView: WKWebView, previousQuery: String, search: Int, document: Int) async {
            lastFindQuery = nil
            let restoreToken = UUID().uuidString
            // An empty WKWebView.find is a no-op. As on Mac, an impossible
            // query dismisses its Find overlay while retaining a different
            // passage selection the user may be preparing to discuss.
            _ = try? await webView.callAsyncJavaScript("""
            const selection=getSelection();
            const different=selection && !selection.isCollapsed && selection.rangeCount===1 &&
                selection.toString().normalize('NFC').toLowerCase()!==query.normalize('NFC').toLowerCase();
            window.__marginedFindRestore={token,range:different ? selection.getRangeAt(0).cloneRange() : null};
            return true;
            """, arguments: ["query": previousQuery, "token": restoreToken], in: nil, contentWorld: Self.findWorld)
            if valid(document), reader.searchGeneration == search, contentReady {
                _ = try? await webView.find("\u{0}", configuration: WKFindConfiguration())
            }
            let current = valid(document) && reader.searchGeneration == search && contentReady
            _ = try? await webView.callAsyncJavaScript("""
            const saved=window.__marginedFindRestore;
            if(!saved || saved.token!==token) return false;
            delete window.__marginedFindRestore;
            const selection=getSelection(),range=saved.range;
            if(restore && range?.startContainer.isConnected && range.endContainer.isConnected && selection?.isCollapsed) {
                selection.removeAllRanges();selection.addRange(range);
            }
            return true;
            """, arguments: ["token": restoreToken, "restore": current], in: nil, contentWorld: Self.findWorld)
            if current { reader.searchMatch = nil }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            guard !isInvalidated, navigation === activeNavigation, (error as NSError).code != NSURLErrorCancelled else { return }
            reader.errorMessage = error.localizedDescription
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard !isInvalidated, documentGeneration == reader.documentGeneration,
                  let url = navigationAction.request.url,
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
                let context = reader.documentGeneration
                Task { [weak reader] in
                    guard let reader, reader.documentGeneration == context else { return }
                    await reader.open(url: url)
                }
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
        guard let url = task.request.url, ImageResourceNamespace.authorizes(url, token: generation) else {
            // A canceled page must never read an identically named image from
            // the next document, nor report that old failure in the new reader.
            task.didFailWithError(URLError(.cancelled))
            return
        }
        loader.webView(webView, start: task)
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) { loader.webView(webView, stop: task) }
    func cancelPendingLoads() { loader.cancelPendingLoads() }
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

extension ContentSizeCategory {
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

@MainActor
private final class MobileDocumentWebView: WKWebView {
    var geometryChanged: (() -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        geometryChanged?()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        geometryChanged?()
    }
}

/// Retains native page identity independently of NavigationStack's transient roots.
/// The workspace owns this object; the reader model does not retain its coordinator.
@MainActor
final class MobileReadingPage: ObservableObject {
    let coordinator: MobileWebView.Coordinator
    let webView: WKWebView
    init(reader: MobileReaderState) {
        coordinator = MobileWebView.Coordinator(reader: reader)
        coordinator.isWorkspaceRetained = true
        webView = MobileWebView.createUIView(coordinator: coordinator)
    }
    deinit {
        let view = webView, bridge = coordinator
        Task { @MainActor in MobileWebView.disposeUIView(view, coordinator: bridge) }
    }
}

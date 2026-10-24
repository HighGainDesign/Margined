import AppKit
import SwiftUI
import WebKit

struct MarkdownWebView: NSViewRepresentable {
    let reader: ReaderState
    let html: String
    var discussionSelectionRequest = 0
    var discussionsVisible = false
    var discussionFilter = DiscussionSession.Filter.open
    var selectedDiscussion: DiscussionSession.DraftKey?
    var discussionPassageRequest = 0
    var speechRequestID: UUID? = nil
    var speechElementID: String? = nil
    var speechFollowReading = true
    var playbackHolding = false
    var checklistEnabled = false
    var checklistSaving = false
    var checklistRendering = false
    var checklistPromptPresented = false

    func makeCoordinator() -> Coordinator { Coordinator(reader: reader) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(context.coordinator.images, forURLScheme: "margined-resource")
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.userContentController.add(context.coordinator, contentWorld: Coordinator.taskWorld, name: "taskToggle")
        configuration.userContentController.add(context.coordinator, contentWorld: Coordinator.discussionWorld, name: "discussion")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setAccessibilityLabel(String(localized: "Markdown document"))
        webView.allowsLinkPreview = false
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.images.documentURL = reader.fileURL
        webView.pageZoom = reader.zoom
        if coordinator.html != html || coordinator.imageReloadGeneration != reader.imageReloadGeneration {
            let resourcesChanged = coordinator.imageReloadGeneration != reader.imageReloadGeneration
            coordinator.html = html
            coordinator.imageReloadGeneration = reader.imageReloadGeneration
            coordinator.load(html, forceNavigation: resourcesChanged)
        }
        if coordinator.navigationGeneration != reader.navigationGeneration, let request = reader.navigationRequest {
            coordinator.navigationGeneration = reader.navigationGeneration
            coordinator.navigate(request)
        }
        coordinator.configureTasks()
        coordinator.synchronizeSpeech()
        if coordinator.searchGeneration != reader.searchGeneration {
            coordinator.searchGeneration = reader.searchGeneration
            coordinator.find()
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "taskToggle", contentWorld: Coordinator.taskWorld)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "discussion", contentWorld: Coordinator.discussionWorld)
        webView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let taskWorld = WKContentWorld.world(name: "MarginedChecklist")
        static let discussionWorld = WKContentWorld.world(name: "MarginedDiscussions")
        private var discussionConfiguration: String?
        private var discussionSelectionGeneration = 0
        private var discussionDecorationKey: String?
        private var discussionPassageGeneration = 0
        let reader: ReaderState
        let images = ImageSchemeHandler()
        weak var webView: WKWebView?
        var html: String?
        var imageReloadGeneration = -1
        var navigationGeneration = -1
        var searchGeneration = -1
        private var speechRequestID: UUID?
        private var speechHighlightKey: String?
        private var readingPosition: [String: Any]?
        private var readingPositionFocusIntent = -1
        private static let documentScript: String = {
            guard let url = Bundle.main.url(forResource: "reader-document", withExtension: "js"),
                  let script = try? String(contentsOf: url, encoding: .utf8) else { return "return false;" }
            return script
        }()
        private static let speechScript: String = {
            guard let url = Bundle.main.url(forResource: "reader-speech", withExtension: "js"),
                  let value = try? String(contentsOf: url, encoding: .utf8) else { return "return null;" }
            return value
        }()
        private var loadGeneration = 0
        private var activeLoadGeneration = 0
        private var activeNavigation: WKNavigation?
        private var contentReady = false
        private var pendingTarget: ReaderNavigation?
        private var taskConfiguration: String?
        private var taskFocus: (file: URL, source: String, updated: String, task: MarkdownTask, focusIntent: Int)?

        init(reader: ReaderState) {
            self.reader = reader
            images.loadFailed = { [weak reader] in reader?.localImageError = $0 }
        }

        func load(_ html: String, forceNavigation: Bool = false) {
            guard let webView else { return }
            let canUpdateContent = contentReady && !forceNavigation
            speechHighlightKey = nil
            loadGeneration += 1
            contentReady = false
            taskConfiguration = nil
            let generation = loadGeneration
            Task { [weak self] in
                guard let self else { return }
                guard generation == loadGeneration else { return }
                if canUpdateContent {
                    // Reconcile sanitized nodes and preserve the visible reading
                    // anchor in the same page, before the next paint.
                    let updated = try? await webView.callAsyncJavaScript(Self.documentScript,
                        arguments: ["operation": "update", "html": html,
                                    "restoreFocus": Self.hasDocumentFocus(webView)],
                        in: nil, contentWorld: Self.taskWorld) as? Bool
                    guard generation == loadGeneration else { return }
                    if updated == true {
                        activeLoadGeneration = generation
                        activeNavigation = nil
                        contentReady = true
                        configureTasks()
                        synchronizeSpeech()
                        if let target = pendingTarget { pendingTarget = nil; navigate(target) }
                        if !reader.searchText.isEmpty { find() }
                        return
                    }
                }
                // JavaScript requested before the first navigation can wait for
                // a document to exist. Load the first page without that wait.
                if webView.url != nil {
                    let intent = reader.focusIntentGeneration
                    let position = try? await webView.callAsyncJavaScript(Self.documentScript,
                        arguments: ["operation": "capture"], in: nil, contentWorld: Self.taskWorld) as? [String: Any]
                    guard generation == loadGeneration else { return }
                    readingPositionFocusIntent = intent
                    readingPosition = position
                }
                guard generation == loadGeneration else { return }
                activeLoadGeneration = generation
                activeNavigation = webView.loadHTMLString(html, baseURL: reader.fileURL?.deletingLastPathComponent())
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === activeNavigation, activeLoadGeneration == loadGeneration else { return }
            contentReady = true
            let position = readingPosition
            let generation = loadGeneration, focusIntent = readingPositionFocusIntent
            let target = pendingTarget
            pendingTarget = nil
            Task {
                guard generation == loadGeneration, contentReady else { return }
                if let position {
                    _ = try? await webView.callAsyncJavaScript(Self.documentScript,
                        arguments: ["operation": "restore", "position": position,
                                    "restoreFocus": focusIntent == reader.focusIntentGeneration && Self.hasDocumentFocus(webView)], in: nil, contentWorld: Self.taskWorld)
                }
                guard generation == loadGeneration, contentReady else { return }
                if let target { navigate(target) }
            }
            configureTasks()
            synchronizeSpeech()
            if !reader.searchText.isEmpty { find() }
        }

        func synchronizeSpeech() {
            guard contentReady, let webView, let speech = reader.existingSpeech else { return }
            if let request = speech.startRequest, speechRequestID != request.id {
                speechRequestID = request.id
                let generation = loadGeneration
                Task { [weak self, weak speech] in
                    guard let self, let speech else { return }
                    let result = try? await webView.callAsyncJavaScript(Self.speechScript,
                        arguments: ["operation": "locate", "mode": request.mode.rawValue], in: nil, contentWorld: Self.taskWorld) as? [String: Any]
                    guard generation == loadGeneration else { speechRequestID = nil; synchronizeSpeech(); return }
                    speech.completeStart(request, elementID: result?["elementID"] as? String, offset: result?["offset"] as? Int ?? 0)
                }
            }
            let element = speech.session.isActive ? speech.session.currentSegment?.elementID : nil
            let follow = speech.session.followReading
            let key = "\(element ?? "none"):\(follow)"
            guard speechHighlightKey != key else { return }
            speechHighlightKey = key
            let generation = loadGeneration
            Task { [weak self] in
                guard let self, generation == loadGeneration, speechHighlightKey == key else { return }
                _ = try? await webView.callAsyncJavaScript(Self.speechScript,
                    arguments: ["operation": "highlight", "elementID": element ?? "", "follow": follow],
                    in: nil, contentWorld: Self.taskWorld)
            }
        }

        func configureTasks() {
            guard contentReady, let webView else { return }
            defer { configureDiscussions() }
            let enabled = !reader.playbackHolding && reader.fileURL != nil && !reader.isStreamingPreview && !reader.hasPendingFileUpdate && !reader.checklistSaving && !reader.isRendering && !reader.showChecklistConfirmation && html == reader.rendered?.html
            let canSave = reader.checklistMode
            let token = String(activeLoadGeneration)
            let focusIntent = reader.focusIntentGeneration
            let configuration = "\(focusIntent):\(token):\(enabled):\(canSave):\(reader.checklistSaving):\(reader.isRendering):\(reader.showChecklistConfirmation):\(reader.playbackHolding)"
            guard taskConfiguration != configuration else { return }
            taskConfiguration = configuration
            var focusID = -1
            if enabled, let pending = taskFocus {
                if reader.focusIntentGeneration == pending.focusIntent,
                   Self.hasDocumentFocus(webView),
                   reader.fileURL == pending.file,
                   reader.source == pending.source || reader.source == pending.updated,
                   let task = reader.rendered?.tasks.first(where: { $0.id == pending.task.id }),
                   task.utf8Offset == pending.task.utf8Offset, task.label == pending.task.label {
                    focusID = task.id
                }
                taskFocus = nil
            }
            Task { [weak self] in
                guard let self, contentReady, String(activeLoadGeneration) == token, taskConfiguration == configuration, reader.focusIntentGeneration == focusIntent else { return }
                do {
                    // Restore DOM focus only while WebKit still owns the native
                    // responder. Ordinary Tab/click moves must win over this save.
                    _ = try await webView.callAsyncJavaScript("""
                    if (!window.marginedTaskFocusListener) {
                        window.marginedTaskFocusListener = true;
                        document.addEventListener('focusin', event => {
                            const pending = window.marginedPendingTaskFocus;
                            if (pending && event.target !== pending.node) pending.moved = true;
                        });
                    }
                    if (!enabled && !window.marginedPendingTaskFocus) {
                        const selection = getSelection();
                        window.marginedPendingTaskFocus = {node:document.activeElement, intent:focusIntent, moved:false,
                            selection:selection?.rangeCount ? {anchor:selection.anchorNode, anchorOffset:selection.anchorOffset,
                                focus:selection.focusNode, focusOffset:selection.focusOffset} : null};
                    }
                    window.marginedTaskState = { enabled, canSave, token };
                    for (const input of document.querySelectorAll('input[data-margined-task]')) {
                        input.disabled = !enabled;
                        if (!saving && !rendering) input.checked = input.defaultChecked;
                        input.title = holding ? holdingTitle : (canSave ? saveTitle : consentTitle);
                    }
                    if (enabled) {
                        const pendingFocus = window.marginedPendingTaskFocus;
                        const mayRestore = restoreFocus && !pendingFocus?.moved &&
                            (document.activeElement === document.body || document.activeElement === pendingFocus?.node);
                        if (focusID >= 0 && mayRestore) {
                            document.querySelector(`input[data-margined-task="${focusID}"]`)?.focus({preventScroll: true});
                        } else if (mayRestore && window.marginedPendingTaskFocus?.intent === focusIntent && window.marginedPendingTaskFocus.node.isConnected) {
                            const pending = window.marginedPendingTaskFocus;
                            pending.node.focus({preventScroll:true});
                            const selection = pending.selection;
                            if (selection?.anchor?.isConnected && selection?.focus?.isConnected) {
                                const limit = node => node.nodeType === Node.TEXT_NODE ? node.length : node.childNodes.length;
                                getSelection().setBaseAndExtent(selection.anchor, Math.min(selection.anchorOffset,limit(selection.anchor)),
                                    selection.focus, Math.min(selection.focusOffset,limit(selection.focus)));
                            }
                        }
                        window.marginedPendingTaskFocus = null;
                    }
                    if (!window.marginedTaskListener) {
                        window.marginedTaskListener = true;
                        document.addEventListener('change', event => {
                            const input = event.target;
                            const state = window.marginedTaskState;
                            if (!event.isTrusted || !state.enabled || !(input instanceof HTMLInputElement) || !input.hasAttribute('data-margined-task')) return;
                            const checked = input.checked;
                            if (!state.canSave) input.checked = input.defaultChecked;
                            for (const box of document.querySelectorAll('input[data-margined-task]')) box.disabled = true;
                            window.webkit.messageHandlers.taskToggle.postMessage({id: Number(input.dataset.marginedTask), checked, token: state.token});
                        });
                    }
                    """, arguments: ["holding": reader.playbackHolding, "holdingTitle": String(localized: "Stop Read Aloud before saving checkmarks."), "enabled": enabled, "canSave": canSave, "token": token, "saving": reader.checklistSaving, "rendering": reader.isRendering, "focusID": focusID, "focusIntent": focusIntent, "restoreFocus": Self.hasDocumentFocus(webView), "saveTitle": String(localized: "Save this checkbox change to the Markdown file"), "consentTitle": String(localized: "Click to save checkmarks in this file")], in: nil, contentWorld: Self.taskWorld)
                } catch {
                    if reader.checklistMode { reader.checklistError = String(localized: "Could not activate checklist controls: \(error.localizedDescription)") }
                }
            }
        }

        private func configureDiscussions() {
            guard contentReady, !reader.isRendering, html == reader.rendered?.html,
                  let projection = reader.rendered?.discussionText, let webView else { return }
            let token = String(activeLoadGeneration), ids = reader.rendered?.discussions?.threads.map(\.id) ?? []
            let key = token + ":" + projection.sourceID
            let selected: String
            if case let .thread(id) = reader.discussions.selection { selected = id } else { selected = "" }
            let visible = reader.showDiscussions
            let decorationKey = key + ":" + String(visible) + ":" + selected + ":" + reader.discussions.filter.rawValue
            let configure = discussionConfiguration != key
            let decorate = discussionDecorationKey != decorationKey
            let wantsSelection = discussionSelectionGeneration != reader.discussionSelectionGeneration
            let wantsPassage = discussionPassageGeneration != reader.discussionPassageGeneration
            guard configure || decorate || wantsSelection || wantsPassage else { return }
            discussionConfiguration = key; discussionDecorationKey = decorationKey
            let selectionGeneration = reader.discussionSelectionGeneration
            let passageGeneration = reader.discussionPassageGeneration, passageID = reader.discussionPassageID
            discussionSelectionGeneration = selectionGeneration; discussionPassageGeneration = passageGeneration
            let anchors: [[String: Any]] = reader.filteredDiscussionThreads.compactMap { thread in
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
                guard contentReady, String(activeLoadGeneration) == token, html == reader.rendered?.html,
                      reader.rendered?.discussionText?.sourceID == projection.sourceID else { return }
                if decorate, discussionDecorationKey == decorationKey {
                    arguments.merge(["operation": "decorate", "anchors": anchors, "expectedText": projection.text,
                        "visible": visible, "selectedID": selected, "markerLabel": String(localized: "Open discussion")], uniquingKeysWith: { _, value in value })
                    let value = try? await webView.callAsyncJavaScript(DiscussionWebScripts.script, arguments: arguments,
                        in: nil, contentWorld: Self.discussionWorld)
                    if discussionDecorationKey == decorationKey, let value,
                       let snapshot = DiscussionMarginSnapshot.read(value, context: context) { reader.acceptDiscussionMargin(snapshot) }
                }
                if wantsSelection, reader.discussionSelectionGeneration == selectionGeneration {
                    arguments["operation"] = "selection"
                    let value = try? await webView.callAsyncJavaScript(DiscussionWebScripts.script, arguments: arguments,
                        in: nil, contentWorld: Self.discussionWorld)
                    guard contentReady, String(activeLoadGeneration) == token, html == reader.rendered?.html,
                          reader.discussionSelectionGeneration == selectionGeneration else { return }
                    if let value, case let .selection(selection) = DiscussionBridge.request(value, isMainFrame: true,
                        context: context, projection: projection) { reader.acceptNewDiscussionSelection(selection) }
                    else { reader.acceptNewDiscussionSelection(nil) }
                }
                if wantsPassage, let passageID, reader.discussionPassageGeneration == passageGeneration,
                   String(activeLoadGeneration) == token, reader.rendered?.discussionText?.sourceID == projection.sourceID {
                    webView.window?.makeFirstResponder(webView)
                    arguments.merge(["operation": "goTo", "threadID": passageID, "focus": true], uniquingKeysWith: { _, value in value })
                    let moved = try? await webView.callAsyncJavaScript(DiscussionWebScripts.script, arguments: arguments,
                        in: nil, contentWorld: Self.discussionWorld) as? Bool
                    if moved == true, let quote = reader.rendered?.discussions?.threads.first(where: { $0.id == passageID })?.target.exact {
                        reader.announcements.schedule(quote, topic: .navigation)
                    }
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "discussion" {
                guard contentReady, !reader.isRendering, html == reader.rendered?.html,
                      let projection = reader.rendered?.discussionText else { return }
                let context = DiscussionBridge.Context(token: String(activeLoadGeneration), sourceID: projection.sourceID,
                    enabled: true, allowedThreadIDs: Set(reader.rendered?.discussions?.threads.map(\.id) ?? []))
                guard message.frameInfo.isMainFrame else { return }
                if let snapshot = DiscussionMarginSnapshot.read(message.body, context: context) { reader.acceptDiscussionMargin(snapshot) }
                else if case let .openThread(id) = DiscussionBridge.request(message.body, isMainFrame: true,
                    context: context, projection: projection) { reader.openDiscussion(id) }
                return
            }

            guard contentReady, message.frameInfo.isMainFrame, message.name == "taskToggle",
                  let body = message.body as? [String: Any],
                  body["token"] as? String == String(activeLoadGeneration),
                  let id = body["id"] as? Int, let checked = body["checked"] as? Bool else { return }
            guard let file = reader.fileURL, let task = reader.rendered?.tasks.first(where: { $0.id == id }),
                  let patched = try? MarkdownTasks.patch(Data(reader.source.utf8), expectedSource: reader.source, task: task, checked: checked) else { return }
            let source = reader.source
            if reader.requestTaskChecked(id, checked: checked) {
                taskFocus = (file, source, String(decoding: patched, as: UTF8.self), task, reader.focusIntentGeneration)
            }
        }

        private static func hasDocumentFocus(_ webView: WKWebView) -> Bool {
            guard let responder = webView.window?.firstResponder else { return false }
            return responder === webView || (responder as? NSView)?.isDescendant(of: webView) == true
        }

        func navigate(_ request: ReaderNavigation) {
            guard let webView else { return }
            guard contentReady else { pendingTarget = request; return }
            Task { [weak self] in
                guard let self, reader.navigationRequest == request else { return }
                let focus = request.focus && reader.focusIntentGeneration == request.focusIntent
                if focus { webView.window?.makeFirstResponder(webView) }
                var arguments: [String: Any] = ["operation": "navigate", "focus": focus]
                switch request.destination {
                case .element(let id): arguments["kind"] = "element"; arguments["id"] = id
                case .uncheckedTask(let backwards): arguments["kind"] = "unchecked"; arguments["backwards"] = backwards
                case .readingPosition: arguments["kind"] = "reading"
                }
                let found = try? await webView.callAsyncJavaScript(Self.documentScript,
                    arguments: arguments, in: nil, contentWorld: Self.taskWorld) as? Bool
                if found == false, reader.navigationRequest == request {
                    if case .uncheckedTask = request.destination {
                        reader.announcements.schedule(String(localized: "No unchecked tasks."), topic: .navigation)
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            if (error as NSError).code != NSURLErrorCancelled { reader.errorMessage = error.localizedDescription }
        }

        func find() {
            guard let webView else { return }
            // An empty field has no search request. In particular, do not
            // queue unnecessary native Find work during initial loading.
            guard !reader.searchText.isEmpty else { reader.searchFound = true; return }
            guard contentReady else { return } // didFinish searches the latest query.
            let configuration = WKFindConfiguration()
            configuration.backwards = reader.searchBackwards
            configuration.caseSensitive = false
            configuration.wraps = true
            let query = reader.searchText
            let generation = reader.searchGeneration
            Task { [weak self] in
                let result = try? await webView.find(query, configuration: configuration)
                guard let self, generation == reader.searchGeneration else { return }
                reader.searchFound = result?.matchFound == true || query.isEmpty
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType == .linkActivated else {
                return ["about", "file"].contains(navigationAction.request.url?.scheme ?? "") ? .allow : .cancel
            }
            guard let url = navigationAction.request.url else { return .cancel }
            if url.fragment != nil && (url.scheme == "about" || url.deletingFragment == webView.url?.deletingFragment) {
                return .allow
            }
            switch url.scheme?.lowercased() {
            case "http", "https", "mailto": NSWorkspace.shared.open(url)
            case "file":
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if let error { NSApp.presentError(error) }
                }
            default: break
            }
            return .cancel
        }
    }
}

private extension URL {
    var deletingFragment: URL? {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = nil
        return components.url
    }
}

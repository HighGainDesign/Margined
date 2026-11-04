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

/// Retained by the owning document/thread; never written to a file or global cache.
/// A successor coordinator awaits the outgoing page's semantic capture before
/// restoring, so fast hide/show cannot race an old callback into its new page.
@MainActor
final class DiscussionHistoryPresentationState {
    private var position: Data?
    private var pending: Task<Data?, Never>?
    private var revision = UUID()
    private var owner: UUID?
    func activate(_ owner: UUID) { self.owner = owner }
    func capture(owner: UUID, _ operation: @escaping @MainActor () async -> [String: Any]?) {
        guard self.owner == owner else { return }
        let revision = UUID()
        self.revision = revision
        let pending = Task {
            guard let result = await operation() else { return nil as Data? }
            return try? JSONSerialization.data(withJSONObject: result)
        }
        self.pending = pending
        Task { [weak self] in
            let result = await pending.value
            guard let self, self.revision == revision else { return }
            if let result { self.position = result }
            self.pending = nil
        }
    }
    func restorePosition() async -> [String: Any]? {
        let data: Data?
        if let pending, let captured = await pending.value { data = captured }
        else { data = position }
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

#if os(iOS)
struct DiscussionHistoryWebView: UIViewRepresentable {
    let html: String
    let fontSize: Double
    let imageGeneration: Int
    let scope: DiscussionHistoryScope
    var speech: DiscussionSpeechHighlight = .inactive
    var previewLines = 4
    var targetedMessageID: String? = nil
    func makeCoordinator() -> DiscussionHistoryCoordinator { .init(scope: scope) }
    func makeUIView(context: Context) -> WKWebView { context.coordinator.makeWebView() }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.update(html: html, fontSize: fontSize, imageGeneration: imageGeneration, speech: speech, previewLines: previewLines, targetedMessageID: targetedMessageID)
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
    var previewLines = 4
    var targetedMessageID: String? = nil
    func makeCoordinator() -> DiscussionHistoryCoordinator { .init(scope: scope) }
    func makeNSView(context: Context) -> WKWebView { context.coordinator.makeWebView() }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.update(html: html, fontSize: fontSize, imageGeneration: imageGeneration, speech: speech, previewLines: previewLines, targetedMessageID: targetedMessageID)
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
    private var previewLines = 4
    private var targetedMessageID: String?
    private var speechKey: String?
    private static let speechScript: String = {
        guard let url = Bundle.main.url(forResource: "reader-speech", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "return false;" }
        return "if (document.documentElement.getAttribute('data-margined-history-token') !== documentToken) return false;\n" +
            "window.marginedHistoryDisclosure?.reveal(Array.from(document.querySelectorAll('[data-margined-speech]')).find(node => node.dataset.marginedSpeech === elementID));\n" + text
    }()
    private var generation = 0
    private var token = UUID().uuidString
    private var ready = false
    private struct PresentationRestore {
        let generation: Int
        let id = UUID()
    }
    private var presentationRestore: PresentationRestore?
    private var reconciliationGeneration: Int?
    private var presentationCaptureTask: Task<Void, Never>?
    private var invalidated = false
    private var suspended = false
    private var navigation: WKNavigation?
    private var loading: Task<Void, Never>?
    private var position: [String: Any]?
    private let presentationOwner = UUID()

    init(scope: DiscussionHistoryScope) {
        self.scope = scope
        images = DiscussionHistoryImages(scope: scope)
        super.init()
        scope.presentationState?.activate(presentationOwner)
    }

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        #if DEBUG && os(iOS)
        // TEMPORARY: enable the existing bounded, passive history trace in iOS diagnostics.
        configuration.userContentController.addUserScript(WKUserScript(
            source: "window.marginedResizeDiagnostics={events:[],dropped:0,phase:'ios-history-startup',captureToNative:true};",
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world))
        #endif
        configuration.setURLSchemeHandler(images, forURLScheme: "margined-resource")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.allowsLinkPreview = false
        #if os(iOS)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.delegate = self
        view.accessibilityLabel = String(localized: "Discussion history")
        #else
        view.setAccessibilityLabel(String(localized: "Discussion history"))
        #endif
        webView = view
        return view
    }

    func invalidate() {
        capturePresentationPosition()
        invalidated = true; generation += 1; presentationRestore = nil
        loading?.cancel(); loading = nil
        images.invalidate()
        webView?.navigationDelegate = nil
        webView?.stopLoading(); webView = nil
    }

    func update(html: String, fontSize: Double, imageGeneration: Int, speech: DiscussionSpeechHighlight = .inactive, previewLines: Int = 4, targetedMessageID: String? = nil) {
        guard !invalidated else { return }
        guard scope.isCurrent() else {
            // Navigation and docking can temporarily hide a retained view.
            // Cancel its work without retiring the coordinator's lifetime.
            if !suspended {
                capturePresentationPosition()
                suspended = true; generation += 1; ready = false; presentationRestore = nil
                loading?.cancel(); loading = nil
                self.html = nil; images.renew()
            }
            return
        }
        suspended = false
        self.speech = speech
        let disclosureChanged = self.previewLines != previewLines || self.targetedMessageID != targetedMessageID
        self.previewLines = previewLines == 3 ? 3 : 4
        self.targetedMessageID = targetedMessageID
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
        } else if fontChanged || disclosureChanged, ready {
            let expected = generation
            Task { [weak self] in
                guard let self, valid(expected), let webView else { return }
                _ = try? await webView.callAsyncJavaScript(Self.finishScript,
                    arguments: finishArguments(position: nil),
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
        // A successor load owns restoration, even when it reconciles in place
        // and therefore receives no replacement native didFinish callback.
        presentationRestore = nil; reconciliationGeneration = nil
        let expected = generation, previousToken = token
        token = UUID().uuidString
        let nextToken = token
        ready = false
        loading?.cancel()
        loading = Task { [weak self] in
            guard let self, valid(expected) else { return }
            if reconcile {
                reconciliationGeneration = expected
                defer { if reconciliationGeneration == expected { reconciliationGeneration = nil } }
                let updated = try? await webView.callAsyncJavaScript(Self.reconcileScript,
                    arguments: ["html": page, "restoreFocus": Self.hasFocus(webView),
                        "expectedToken": previousToken, "nextToken": nextToken, "fontSize": fontSize,
                        "nativeResizeRestoration": Self.nativeResizeRestoration,
                        "previewLines": previewLines, "targetedMessageID": targetedMessageID ?? "",
                        "showFull": String(localized: "Show full comment"), "showLess": String(localized: "Show less")],
                    in: nil, contentWorld: Self.world) as? Bool
                guard valid(expected) else { return }
                if updated == true { ready = true; navigation = nil; speechKey = nil; synchronizeSpeech(); return }
            }
            if webView.url != nil {
                let captured = try? await webView.callAsyncJavaScript(Self.captureScript,
                    arguments: ["documentToken": previousToken], in: nil, contentWorld: Self.world) as? [String: Any]
                position = Self.positionFromDiagnosticCapture(captured)
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
        let restore = PresentationRestore(generation: generation)
        presentationRestore = restore
        let expected = restore.generation, position = position
        self.position = nil
        Task { [weak self] in
            guard let self else { return }
            // An obsolete task cannot retire a newer restoration's lease.
            defer {
                if presentationRestore?.id == restore.id,
                   presentationRestore?.generation == expected { presentationRestore = nil }
            }
            guard valid(expected) else { return }
            let restored = await scope.presentationState?.restorePosition()
            guard valid(expected) else { return }
            _ = try? await view.callAsyncJavaScript(Self.finishScript,
                arguments: finishArguments(position: position ?? restored),
                in: nil, contentWorld: Self.world)
            guard valid(expected) else { return }
            speechKey = nil; synchronizeSpeech()
        }
    }

    private func finishArguments(position: [String: Any]?) -> [String: Any] {
        ["documentToken": token, "fontSize": fontSize, "position": position as Any? ?? NSNull(),
         "nativeResizeRestoration": Self.nativeResizeRestoration,
         "previewLines": previewLines, "targetedMessageID": targetedMessageID ?? "",
         "showFull": String(localized: "Show full comment"), "showLess": String(localized: "Show less")]
    }

    private static var nativeResizeRestoration: Bool {
        #if os(iOS) && MARGINED_NATIVE_RESIZE_EXPERIMENT
        true
        #else
        false
        #endif
    }

    private func capturePresentationPosition() {
        presentationCaptureTask?.cancel(); presentationCaptureTask = nil
        // WebKit may commit its in-place DOM before the awaiting native task
        // marks it ready. That generation can capture a committed current-token
        // page, but can never bypass a generation-owned restoration lease.
        guard (ready || reconciliationGeneration == generation), presentationRestore == nil,
              !invalidated, let webView, let state = scope.presentationState else { return }
        let token = token
        state.capture(owner: presentationOwner) {
            let captured = try? await webView.callAsyncJavaScript(Self.captureScript,
                arguments: ["documentToken": token], in: nil, contentWorld: Self.world) as? [String: Any]
            return Self.positionFromDiagnosticCapture(captured)
        }
    }

    private static func positionFromDiagnosticCapture(_ captured: [String: Any]?) -> [String: Any]? {
        guard var position = captured else { return nil }
        // Strip temporary evidence before the original position reaches retained state.
        if let trace = position.removeValue(forKey: "__marginedResizeCaptureDiagnostics") {
            let candidates = position["candidates"] as? [[String: Any]] ?? []
            let first = candidates.first
            let summary: [String: Any] = ["x":position["x"] ?? NSNull(), "y":position["y"] ?? NSNull(),
                "top":position["top"] ?? NSNull(), "count":candidates.count,
                "firstID":first?["id"] ?? NSNull(), "firstTag":first?["tag"] ?? NSNull(),
                "firstLength":first?["length"] ?? NSNull()]
            let report: [String: Any] = ["afterExistingCaptureAwait":true, "capturedPosition":summary, "trace":trace]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                print("IOS-HISTORY-CAPTURE-TRACE " + String(decoding:data,as:UTF8.self))
            }
        }
        return position
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

    /// Installed only in the history's isolated world. Full sanitized bodies
    /// remain in the DOM; clipping never changes source, export or speech text.
    private static let disclosureScript = """
    const disclosure = window.marginedHistoryDisclosure ??= {expanded:Object.create(null)};
    if (position?.disclosure) disclosure.expanded = Object.assign(Object.create(null), position.disclosure);
    disclosure.token = documentToken;
    disclosure.lines = previewLines;
    disclosure.target = targetedMessageID;
    disclosure.controls ??= new WeakMap();
    const authorized = () => document.documentElement.getAttribute('data-margined-history-token') === disclosure.token;
    // Text ranges retain paragraph spacing and mixed inline metrics. Choose a
    // gap after a complete line rather than spending the cap on top margins.
    const previewHeight = (body, count, line) => {
        const box = body.getBoundingClientRect(), rects = [];
        const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
        while (walker.nextNode()) {
            const node = walker.currentNode;
            if (!node.textContent.trim()) continue;
            const range = document.createRange(); range.selectNodeContents(node);
            rects.push(...Array.from(range.getClientRects()).filter(rect => rect.width > 0 && rect.height > 0));
        }
        const lines = [];
        for (const rect of rects.sort((a,b) => a.top-b.top || a.bottom-b.bottom)) {
            const last = lines.at(-1);
            if (last && rect.top < last.bottom-1) {
                last.top = Math.min(last.top,rect.top); last.bottom = Math.max(last.bottom,rect.bottom);
            } else lines.push({top:rect.top,bottom:rect.bottom});
        }
        const first = Array.from(body.childNodes).find(node => node.nodeType === Node.ELEMENT_NODE || node.textContent.trim());
        const offset = first?.nodeType === Node.ELEMENT_NODE ? Math.max(0,first.getBoundingClientRect().top-box.top) : 0;
        let height = offset + line*count;
        if (lines.length > count && lines[0].top-box.top < offset+line*2) {
            const last = lines[count-1], next = lines[count];
            height = last.bottom + Math.min((next.top-last.bottom)/2,line/2) - box.top;
        }
        // Large artwork keeps a bounded crop instead of extending a text-line
        // preview across an image. Never end that fallback through text.
        const media = Array.from(body.querySelectorAll('img,svg,video,canvas')).some(node => {
            const rect = node.getBoundingClientRect();
            return rect.height > line*2 && rect.top < box.top+height;
        });
        if (media) height = offset + line*count;
        const crossing = lines.find(rect => rect.top < box.top+height && rect.bottom > box.top+height);
        if (crossing) height = crossing.top-box.top;
        return Math.max(0,height);
    };
    disclosure.layout = () => {
        if (!authorized()) return;
        const articles = Array.from(document.querySelectorAll('article[data-message-id]'));
        const validIDs = new Set(articles.map(a=>a.dataset.messageId));
        for (const id of Object.keys(disclosure.expanded)) if (!validIDs.has(id)) delete disclosure.expanded[id];
        for (const article of articles) {
            const body = article.querySelector('.discussion-message-body');
            if (!body) continue;
            const header = article.querySelector(':scope > header');
            article.style.display = ''; article.style.gridTemplateColumns = ''; article.style.columnGap = '';
            body.style.gridColumn = ''; body.style.gridRow = '';
            if (header) { header.style.gridColumn = ''; header.style.gridRow = ''; }
            const controls = Array.from(body.querySelectorAll('a[href],button,input,select,textarea,[tabindex],audio[controls],video[controls],summary'));
            for (const control of controls) {
                const original = disclosure.controls.get(control);
                if (!original) continue;
                for (const name of ['tabindex','inert']) {
                    if (original[name] === null) control.removeAttribute(name); else control.setAttribute(name,original[name]);
                }
                disclosure.controls.delete(control);
            }
            body.style.maxHeight = ''; body.style.overflow = '';
            const line = parseFloat(getComputedStyle(body).lineHeight) || parseFloat(getComputedStyle(body).fontSize)*1.5;
            const long = body.getBoundingClientRect().height > line*8+1;
            if (article === articles.at(-1) || article.dataset.messageId === disclosure.target) disclosure.expanded[article.dataset.messageId] = true;
            const forced = article === articles.at(-1) || article.dataset.messageId === disclosure.target;
            let button = article.querySelector(':scope > button[data-history-disclosure]');
            if (!long || forced) { button?.remove(); continue; }
            const expanded = disclosure.expanded[article.dataset.messageId] === true;
            // Normal grid flow reserves a compact header column for the glyph.
            // Its full hit area can never cover either preview or full content.
            article.style.display = 'grid'; article.style.gridTemplateColumns = 'minmax(0,1fr) auto';
            article.style.columnGap = '8px';
            if (header) { header.style.gridColumn = '1'; header.style.gridRow = '1'; }
            body.style.gridColumn = '1 / -1'; body.style.gridRow = '2';
            if (!body.id) body.id = article.id + '-content';
            if (!button) {
                button = document.createElement('button');
                button.type = 'button'; button.id = article.id + '-disclosure'; button.dataset.historyDisclosure = '';
                button.style.cssText = 'grid-column:2;grid-row:1;align-self:start;width:28px;height:24px;border:1px solid color-mix(in srgb,currentColor 20%,transparent);border-radius:6px;background:Canvas;color:CanvasText;cursor:pointer;display:grid;place-items:center;padding:0;';
                const icon = document.createElementNS('http://www.w3.org/2000/svg','svg');
                icon.setAttribute('width','12'); icon.setAttribute('height','12'); icon.setAttribute('viewBox','0 0 12 12'); icon.setAttribute('aria-hidden','true');
                const path = document.createElementNS('http://www.w3.org/2000/svg','path');
                path.setAttribute('d','M2 4l4 4 4-4'); path.setAttribute('fill','none'); path.setAttribute('stroke','currentColor'); path.setAttribute('stroke-width','1.5');
                icon.append(path); button.append(icon); article.insertBefore(button,body);
                button.addEventListener('click', () => {
                    if (!authorized()) return;
                    const rect = button.getBoundingClientRect(), triggerVisible = rect.bottom > 0 && rect.top < innerHeight;
                    const saved = disclosure.capture();
                    disclosure.expanded[article.dataset.messageId] = button.getAttribute('aria-expanded') !== 'true';
                    disclosure.layout();
                    documentOperation('restore',saved,false);
                    if (triggerVisible && button.getAttribute('aria-expanded') === 'false' && article.getBoundingClientRect().bottom < 0)
                        article.scrollIntoView({block:'start',behavior:'instant'});
                });
            }
            button.style.width = matchMedia('(pointer:coarse)').matches ? '44px' : '28px';
            button.style.height = matchMedia('(pointer:coarse)').matches ? '44px' : '24px';
            button.setAttribute('aria-controls',body.id);
            button.setAttribute('aria-expanded',String(expanded));
            button.setAttribute('aria-label',expanded ? showLess : showFull);
            button.title = expanded ? showLess : showFull;
            button.firstChild.style.transform = expanded ? 'rotate(180deg)' : '';
            if (!expanded) {
                body.style.maxHeight = `${previewHeight(body,disclosure.lines,line)}px`; body.style.overflow = 'hidden'; body.scrollTop = 0;
                const clip = body.getBoundingClientRect();
                for (const control of controls) {
                    const hidden = Array.from(control.getClientRects()).every(rect => rect.bottom <= clip.top || rect.top >= clip.bottom || rect.right <= clip.left || rect.left >= clip.right);
                    if (!hidden) continue;
                    disclosure.controls.set(control,{tabindex:control.getAttribute('tabindex'),inert:control.getAttribute('inert')});
                    control.setAttribute('tabindex','-1'); control.inert = true;
                }
            }
        }
    };
    disclosure.capture = () => {
        const saved = documentOperation('capture',null,false);
        if (!saved) return saved;
        // A clipped paragraph still has a DOM rectangle. Only painted body
        // content can own the semantic anchor saved for a later presentation.
        const nodes = Array.from(document.querySelectorAll('#document h1,#document h2,#document h3,#document h4,#document h5,#document h6,#document p,#document li,#document pre,#document tr,#document dt,#document dd,#document figure'));
        const painted = nodes.filter(node=>{
            const rect = node.getBoundingClientRect(), body = node.closest('.discussion-message-body');
            const clip = body?.style.overflow === 'hidden' ? body.getBoundingClientRect() : null;
            return rect.height > 0 && (!clip || rect.top < clip.bottom && rect.bottom > clip.top);
        });
        const visible = painted.filter(node=>{
            const rect = node.getBoundingClientRect(); return rect.bottom > 0 && rect.top < innerHeight;
        }).sort((a,b)=>Math.abs(a.getBoundingClientRect().top)-Math.abs(b.getBoundingClientRect().top));
        if (visible.length) {
            const node = visible[0], index = painted.indexOf(node);
            saved.top = node.getBoundingClientRect().top;
            saved.candidates = [node,...painted.slice(index+1),...painted.slice(0,index).reverse()].slice(0,128)
                .map(node=>({id:node.id,tag:node.tagName,text:node.textContent.slice(0,1024),length:node.textContent.length,label:node.getAttribute('aria-label')}));
        }
        saved.disclosure = disclosure.expanded;
        return saved;
    };
    disclosure.reveal = node => {
        if (!authorized()) return;
        const article = node?.closest('article[data-message-id]');
        if (article && disclosure.expanded[article.dataset.messageId] !== true) {
            disclosure.expanded[article.dataset.messageId] = true; disclosure.layout();
        }
    };
    if (!disclosure.listening) {
        disclosure.listening = true;
        window.addEventListener('resize',()=>disclosure.layout());
        document.addEventListener('load',()=>disclosure.layout(),true);
        document.addEventListener('click',event=>{
            const link = event.target.closest?.('a[href]');
            if (!link) return;
            const url = new URL(link.href,document.baseURI);
            if (url.origin !== location.origin || url.pathname !== location.pathname || !url.hash) return;
            let id; try { id = decodeURIComponent(url.hash.slice(1)); } catch { return; }
            disclosure.reveal(document.getElementById(id));
        },true);
        window.addEventListener('hashchange',()=>{
            let id; try { id = decodeURIComponent(location.hash.slice(1)); } catch { return; }
            const node = document.getElementById(id); disclosure.reveal(node);
            node?.scrollIntoView({block:'start',behavior:'instant'});
        });
    }
    disclosure.layout();
    """

    private static let captureScript = """
    if (document.documentElement.getAttribute('data-margined-history-token') !== documentToken) return null;
    function capture() {
    const operation = 'capture', restoreFocus = false;
    \(documentScript)
    }
    const saved = window.marginedHistoryDisclosure?.capture() ?? capture();
    if (saved) saved.disclosure = window.marginedHistoryDisclosure?.expanded ?? {};
    const diagnostics = window.marginedResizeDiagnostics;
    if (saved && diagnostics?.captureToNative) {
        // Reuse this capture's position and existing IPC response; no extra DOM reads.
        const first=saved.candidates?.[0];
        diagnostics.events.push({event:'presentation-capture',operation:'captureScript',time:performance.now(),phase:diagnostics.phase,
            saved:{x:saved.x,y:saved.y,top:saved.top,count:saved.candidates?.length ?? 0,
                first:first ? {id:first.id,tag:first.tag,length:first.length} : null}});
        if(diagnostics.events.length>500){diagnostics.events.splice(20,1);diagnostics.dropped++;}
        saved.__marginedResizeCaptureDiagnostics=JSON.parse(JSON.stringify(diagnostics));
    }
    return saved;
    """
    private static let reconcileScript = """
    if (document.documentElement.getAttribute('data-margined-history-token') !== expectedToken) return false;
    function documentOperation(operation, position, restoreFocus, documentToken) {
    const documentTokenAttribute = 'data-margined-history-token';
    \(documentScript)
    }
    const saved = window.marginedHistoryDisclosure?.capture() ?? documentOperation('capture', null, false);
    if (!documentOperation('update', null, restoreFocus)) return false;
    document.documentElement.setAttribute('data-margined-history-token', nextToken);
    document.body.style.fontSize = `${fontSize}px`;
    document.body.style.webkitTextSizeAdjust = '100%';
    const documentToken = nextToken, position = null;
    \(disclosureScript)
    documentOperation('restore', saved, restoreFocus);
    documentOperation('observeResize', null, false, nextToken);
    return true;
    """
    private static let finishScript = """
    if (document.documentElement.getAttribute('data-margined-history-token') !== documentToken) return false;
    function documentOperation(operation, position, restoreFocus, documentToken) {
    const documentTokenAttribute = 'data-margined-history-token';
    \(documentScript)
    }
    await document.fonts.ready;
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    if (document.documentElement.getAttribute('data-margined-history-token') !== documentToken) return false;
    const saved = position || window.marginedHistoryDisclosure?.capture() || documentOperation('capture', null, false);
    document.body.style.fontSize = `${fontSize}px`;
    document.body.style.webkitTextSizeAdjust = '100%';
    \(disclosureScript)
    documentOperation('restore', saved, false);
    documentOperation('observeResize', null, false, documentToken);
    return true;
    """
}

#if os(iOS)
extension DiscussionHistoryCoordinator: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard ready, presentationRestore == nil, !invalidated, scope.presentationState != nil else { return }
        presentationCaptureTask?.cancel()
        presentationCaptureTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            self?.capturePresentationPosition()
        }
    }
}
#endif

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

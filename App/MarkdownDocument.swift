import AppKit
import SwiftUI
import WebKit
import os
import ObjectiveC

@MainActor
final class MarkdownDocument: NSDocument {
    // AppKit constructs concurrent-reading documents on its opening queue.
    // Create UI state only when first accessed by the main actor.
    lazy var reader = ReaderState()
    nonisolated private let loadedSource = OSAllocatedUnfairLock(initialState: LoadedSource())

    nonisolated override init() { super.init() }

    init(preview: PreviewRequest) {
        super.init()
        reader.source = preview.text
        reader.title = preview.title.isEmpty ? String(localized: "Drafts Preview") : preview.title
        displayName = reader.title
        let loaded = LoadedSource(text: reader.source, url: nil, title: reader.title)
        loadedSource.withLock { $0 = loaded }
    }

    init(streamingPreview: Bool) {
        super.init()
        reader.isStreamingPreview = streamingPreview
        reader.title = String(localized: "Live Streaming Preview")
        displayName = reader.title
        let loaded = LoadedSource(title: reader.title)
        loadedSource.withLock { $0 = loaded }
    }

    override class var autosavesInPlace: Bool { false }
    override var isDocumentEdited: Bool { false }
    nonisolated override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }

    override func read(from url: URL, ofType typeName: String) throws {
        let snapshot = try SourceFileEdit.capture(url)
        let text = try snapshot.source
        loadedSource.withLock { $0 = LoadedSource(text: text, url: url, title: url.lastPathComponent, snapshot: snapshot) }
    }

    override func makeWindowControllers() {
        let loaded = loadedSource.withLock { $0 }
        reader.source = loaded.text
        reader.fileURL = loaded.url
        reader.title = loaded.title
        reader.installLoadedSnapshot(loaded.snapshot)
        let controller = NSHostingController(rootView: ReaderView(reader: reader))
        let window = NSWindow(contentViewController: controller)
        window.title = reader.title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 920, height: 760))
        window.minSize = NSSize(width: 480, height: 320)
        window.center()
        addWindowController(NSWindowController(window: window))
        (NSApp.delegate as? AppDelegate)?.documentDidOpen()
    }

    private var checklistClosePending = false

    private var printableWebView: WKWebView? {
        func find(in view: NSView) -> WKWebView? {
            if let webView = view as? WKWebView { return webView }
            for child in view.subviews {
                if let webView = find(in: child) { return webView }
            }
            return nil
        }
        return windowControllers.compactMap { $0.window?.contentView }.compactMap { find(in: $0) }.first
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(printDocument(_:)) {
            return reader.rendered != nil && printableWebView?.url != nil && printableWebView?.isLoading == false
        }
        return super.validateUserInterfaceItem(item)
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        guard let webView = printableWebView, webView.url != nil, !webView.isLoading else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "The document is still loading. Try printing again in a moment.")])
        }
        // Print the displayed version, including paused streams and held file updates.
        // WebKit paginates the rendered DOM using @media print, without window chrome.
        let info = printInfo.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.dictionary().addEntries(from: printSettings)
        let operation = webView.printOperation(with: info)
        // WebKit requests page data on the main run loop while AppKit spools it.
        operation.canSpawnSeparateThread = true
        operation.jobTitle = displayName
        return operation
    }

    @MainActor private final class CloseRequest {
        let delegate: Any
        let selector: Selector?
        let context: UnsafeMutableRawPointer?
        init(delegate: Any, selector: Selector?, context: UnsafeMutableRawPointer?) {
            self.delegate = delegate; self.selector = selector; self.context = context
        }
    }
    private var draftCloseCallbacks: [@MainActor (Bool) -> Void] = []
    private var draftCloseAlertPresented = false

    override func canClose(withDelegate delegate: Any, shouldClose selector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        let request = CloseRequest(delegate: delegate, selector: selector, context: contextInfo)
        if reader.fileSaving {
            Task { [self, request] in
                while reader.fileSaving { try? await Task.sleep(for: .milliseconds(10)) }
                validateClose(request)
            }
        } else { validateClose(request) }
    }
    private func validateClose(_ request: CloseRequest) {
        guard reader.discussions.hasUnpostedDrafts else {
            allowClose(request)
            return
        }
        confirmDiscardDrafts { [self, request] allowed in
            if allowed {
                allowClose(request)
            } else { replyCannotClose(request) }
        }
    }
    private func allowClose(_ request: CloseRequest) {
        super.canClose(withDelegate: request.delegate, shouldClose: request.selector, contextInfo: request.context)
    }
    private func replyCannotClose(_ request: CloseRequest) {
        guard let selector = request.selector else { return }
        let delegate = request.delegate as AnyObject
        guard let type = object_getClass(delegate), let method = class_getInstanceMethod(type, selector) else { return }
        // NSDocument prescribes this legacy delegate callback, including the
        // opaque context pointer. Keep the ABI bridge in this one small method.
        typealias Callback = @convention(c) (AnyObject, Selector, NSDocument, ObjCBool, UnsafeMutableRawPointer?) -> Void
        let callback = unsafeBitCast(method_getImplementation(method), to: Callback.self)
        callback(delegate, selector, self, ObjCBool(false), request.context)
    }
    private func confirmDiscardDrafts(_ completion: @escaping @MainActor (Bool) -> Void) {
        guard reader.discussions.hasUnpostedDrafts else { completion(true); return }
        guard let window = windowControllers.compactMap(\.window).first else { completion(false); return }
        draftCloseCallbacks.append(completion)
        guard !draftCloseAlertPresented else { return }
        draftCloseAlertPresented = true
        let alert = DiscussionDraftAlert.make()
        alert.beginSheetModal(for: window) { [self] response in
            let allowed = response == .alertSecondButtonReturn
            if allowed { reader.discussions.discardDrafts() }
            let callbacks = draftCloseCallbacks
            draftCloseCallbacks.removeAll(); draftCloseAlertPresented = false
            for callback in callbacks { callback(allowed) }
        }
    }

    override func close() {
        if reader.fileSaving {
            guard !checklistClosePending else { return }
            checklistClosePending = true
            Task { [self] in
                while reader.fileSaving { try? await Task.sleep(for: .milliseconds(10)) }
                checklistClosePending = false
                close()
            }
            return
        }
        if reader.discussions.hasUnpostedDrafts {
            confirmDiscardDrafts { [self] allowed in if allowed { close() } }
            return
        }
        reader.stop()
        super.close()
    }
}

private struct LoadedSource: Sendable {
    var text = ""
    var url: URL?
    var title = "Markdown"
    var snapshot: SourceFileEdit.Snapshot? = nil
}

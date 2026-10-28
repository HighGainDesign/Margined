import AppKit

/// A selectable, read-only snapshot. No document writer or live file presenter
/// is attached to this window; closing it cannot change the Markdown file.
@MainActor
final class ReaderDiscussionSourceWindow: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private static var windows: [UUID: ReaderDiscussionSourceWindow] = [:]
    private let context: UUID
    private let textView: NSTextView
    private var zoom: Double
    private weak var reader: ReaderState?

    static func show(source: String, title: String, context: UUID, zoom: Double, appearance: DocumentAppearance, reader: ReaderState) {
        let controller = windows[context] ?? ReaderDiscussionSourceWindow(context: context)
        windows[context] = controller
        controller.reader = reader
        controller.textView.string = source
        controller.zoom = zoom
        controller.applyFont()
        controller.window?.title = String(localized: "Source — \(title)")
        switch appearance {
        case .system: controller.window?.appearance = nil
        case .light: controller.window?.appearance = NSAppearance(named: .aqua)
        case .dark: controller.window?.appearance = NSAppearance(named: .darkAqua)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(controller.textView)
    }

    private init(context: UUID) {
        self.context = context
        zoom = 1
        let rect = NSRect(x: 0, y: 0, width: 760, height: 620)
        textView = NSTextView(frame: rect)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainerInset = NSSize(width: 18, height: 16)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel(String(localized: "Markdown source, read only"))

        let scroll = NSScrollView(frame: rect)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        let caption = NSTextField(wrappingLabelWithString: String(localized: "Read-only source snapshot. Includes saved discussions and metadata. Unposted comments are not included."))
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor
        let content = NSView(frame: rect)
        content.addSubview(caption); content.addSubview(scroll)
        caption.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            caption.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            caption.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            scroll.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.contentView = content
        window.contentMinSize = NSSize(width: 420, height: 300)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { nil }

    @objc func stopSpeech(_ sender: Any?) { reader?.existingSpeech?.stop() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(stopSpeech(_:)) && (reader?.existingSpeech?.session.isActive == true || reader?.existingSpeech?.isPreparing == true)
    }

    func showFind() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(item)
    }
    func changeZoom(by amount: Double) { zoom = min(3, max(0.65, zoom + amount)); applyFont() }
    func actualSize() { zoom = 1; applyFont() }
    private func applyFont() { textView.font = .monospacedSystemFont(ofSize: 13 * zoom, weight: .regular) }

    func windowWillClose(_ notification: Notification) {
        if Self.windows[context] === self { Self.windows.removeValue(forKey: context) }
    }
}

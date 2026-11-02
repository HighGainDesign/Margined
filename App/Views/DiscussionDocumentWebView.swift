import AppKit
import WebKit

/// Only document pages use this adapter; discussion history retains its system menu.
@MainActor
final class DiscussionDocumentWebView: WKWebView {
    var canDiscussSelection: () -> Bool = { false }
    var onDiscussSelection: (() -> Void)?
    private static let itemID = NSUserInterfaceItemIdentifier("MarginedDiscussSelection")

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items where item.identifier == Self.itemID { menu.removeItem(item) }
        guard canDiscussSelection() else { return }
        let item = NSMenuItem(title: String(localized: "Discuss Selection"), action: #selector(discussSelection(_:)), keyEquivalent: "")
        item.identifier = Self.itemID; item.target = self
        menu.addItem(item)
    }

    @objc func discussSelection(_ sender: Any?) {
        guard canDiscussSelection() else { return }
        onDiscussSelection?()
    }
}

import AppKit

/// Both document close and app quit use the same safe keyboard defaults.
@MainActor enum DiscussionDraftAlert {
    static func make(quitting: Bool = false) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = quitting ? String(localized: "Discard unposted replies and quit?") : String(localized: "Discard unposted replies?")
        alert.informativeText = quitting
            ? String(localized: "Keep Margined open to finish your comments and replies, or discard the unposted text and quit.")
            : String(localized: "Keep this document open to finish your comments and replies, or discard the unposted text.")
        alert.alertStyle = .warning
        let keep = alert.addButton(withTitle: String(localized: "Keep Open"))
        let discard = alert.addButton(withTitle: quitting ? String(localized: "Discard Drafts and Quit") : String(localized: "Discard Drafts"))
        discard.hasDestructiveAction = true
        alert.window.defaultButtonCell = keep.cell as? NSButtonCell
        return alert
    }
}

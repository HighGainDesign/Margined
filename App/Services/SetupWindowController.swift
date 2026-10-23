import AppKit
import SwiftUI

@MainActor
final class SetupWindowController: NSWindowController, NSWindowDelegate {
    let session: SetupSession

    init(session: SetupSession = SetupSession()) {
        self.session = session
        let window = NSWindow()
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: SetupView(session: session, done: { [weak self] in self?.close() }))
        window.title = String(localized: "Margined Setup")
        window.styleMask = [.titled, .closable, .resizable]
        window.contentMinSize = NSSize(width: 520, height: 440)
        window.setContentSize(NSSize(width: 620, height: 600))
        window.center()
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) { session.finish() }
}

import AppKit
import SwiftUI

@MainActor
final class SetupWindowController: NSWindowController, NSWindowDelegate {
    let session: SetupSession

    init(session: SetupSession = SetupSession(), tutorial: TutorialSession = TutorialSession()) {
        self.session = session
        let window = NSWindow()
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: SetupView(session: session, done: { [weak self] in self?.close() }, tutorial: tutorial))
        window.title = String(localized: "Take a Tour")
        window.styleMask = [.titled, .closable, .resizable]
        window.contentMinSize = NSSize(width: 520, height: 440)
        window.setContentSize(NSSize(width: 860, height: 620))
        window.center()
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) { session.finish() }
}

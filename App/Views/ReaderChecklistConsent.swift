import AppKit
import SwiftUI

/// SwiftUI's alert bridge can close an NSAlert during NSHostingView.layout,
/// recursively entering the macOS update cycle. Queue native sheet operations
/// outside layout; ReaderState still owns consent and validates every write.
struct ReaderChecklistConsent: NSViewRepresentable {
    let reader: ReaderState
    let confirmation: ReaderState.ChecklistConfirmation?

    func makeNSView(context: Context) -> Presenter { Presenter(reader: reader) }
    func updateNSView(_ view: Presenter, context: Context) { view.update(confirmation) }
    static func dismantleNSView(_ view: Presenter, coordinator: ()) { view.invalidate() }

    final class Presenter: NSView {
        private weak var reader: ReaderState?
        private var requested: ReaderState.ChecklistConfirmation?
        private var active: (id: UUID, alert: NSAlert)?
        private var queued = false
        private var invalidated = false

        init(reader: ReaderState) { self.reader = reader; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            schedule()
        }

        func update(_ confirmation: ReaderState.ChecklistConfirmation?) {
            requested = confirmation
            schedule()
        }

        private func schedule() {
            guard !queued, !invalidated else { return }
            queued = true
            DispatchQueue.main.async { [weak self] in self?.reconcile() }
        }

        private func reconcile() {
            queued = false
            guard !invalidated else { return }
            if let active, active.id == requested?.id,
               let window, window.isVisible, active.alert.window.sheetParent === window { return }
            dismiss()
            guard let request = requested, let reader,
                  reader.showChecklistConfirmation, reader.pendingChecklistConfirmation?.id == request.id,
                  let window, window.isVisible, window.attachedSheet == nil else { return }
            let alert = NSAlert()
            alert.messageText = String(localized: "Save checkmarks to this file?")
            alert.informativeText = String(localized: "Checkmarks in “\(request.fileURL.lastPathComponent)” save automatically. Other text stays unchanged, and you can undo each change.")
            alert.addButton(withTitle: String(localized: "Save Checkmarks"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            active = (request.id, alert)
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, active?.id == request.id else { return }
                active = nil
                guard let reader = self.reader, reader.showChecklistConfirmation,
                      reader.pendingChecklistConfirmation?.id == request.id else { return }
                if response == .alertFirstButtonReturn { reader.confirmChecklistSaving() }
                else { reader.cancelChecklistConfirmation() }
            }
        }

        private func dismiss() {
            guard let previous = active else { return }
            // Invalidate the callback before endSheet can synchronously invoke it.
            active = nil
            if let parent = previous.alert.window.sheetParent {
                parent.endSheet(previous.alert.window, returnCode: .abort)
            }
        }

        func invalidate() {
            invalidated = true
            let requestID = requested?.id
            requested = nil
            let previous = active
            active = nil
            // Dismantling is also part of SwiftUI layout. Retain only the sheet
            // until its queued close; never retain a closed reader or presenter.
            DispatchQueue.main.async { [weak reader] in
                if let previous, let parent = previous.alert.window.sheetParent {
                    parent.endSheet(previous.alert.window, returnCode: .abort)
                }
                if let requestID, reader?.pendingChecklistConfirmation?.id == requestID {
                    reader?.cancelChecklistConfirmation()
                }
            }
        }
    }
}

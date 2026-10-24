import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One owned native picker. Finish its dismissal before publishing the review.
struct MobileDiscussionFilePickerPresenter: UIViewControllerRepresentable {
    let reader: MobileReaderState
    // Read while the parent evaluates body so request changes reach updateUIViewController.
    private let requestID: UUID?
    @MainActor init(reader: MobileReaderState) {
        self.reader = reader; requestID = reader.discussionCopyRequest?.id
    }
    func makeCoordinator() -> Coordinator { Coordinator(reader: reader) }
    func makeUIViewController(context: Context) -> Host {
        let host = Host(); context.coordinator.host = host
        host.ready = { [weak coordinator = context.coordinator] in coordinator?.update() }
        return host
    }
    func updateUIViewController(_ controller: Host, context: Context) { context.coordinator.update() }
    static func dismantleUIViewController(_ controller: Host, coordinator: Coordinator) { coordinator.invalidate() }
    final class Host: UIViewController {
        var ready: (@MainActor () -> Void)?
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); ready?() }
    }
    @MainActor final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let reader: MobileReaderState
        weak var host: Host?
        private var picker: UIDocumentPickerViewController?
        private var request: MobileDiscussionCopyRequest?
        private var finishing = false
        private var invalidated = false
        init(reader: MobileReaderState) { self.reader = reader }
        func update() {
            guard !invalidated, !finishing else { return }
            if let request, reader.discussionCopyRequest?.id != request.id {
                finishing = true; picker?.delegate = nil
                picker?.dismiss(animated: false) { [weak self] in
                    self?.picker = nil; self?.request = nil; self?.finishing = false; self?.update()
                }
                return
            }
            guard request == nil, let host, host.viewIfLoaded?.window != nil,
                  host.presentedViewController == nil, let selected = reader.discussionCopyRequest else { return }
            guard reader.matchesDiscussionVersion(selected.version) else {
                reader.cancelDiscussionCopyPicker(selected.id)
                reader.discussionError = DiscussionReconciliation.Failure.staleSource.localizedDescription; return
            }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType(importedAs: "net.daringfireball.markdown"), .plainText], asCopy: false)
            picker.allowsMultipleSelection = false; picker.shouldShowFileExtensions = true; picker.delegate = self
            request = selected; self.picker = picker
            host.present(picker, animated: true)
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(controller, selected: urls.first)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(controller, selected: nil) }
        private func finish(_ controller: UIDocumentPickerViewController, selected: URL?) {
            guard !invalidated, !finishing, picker === controller, let request else { return }
            finishing = true; controller.delegate = nil
            let scope = selected.map { PickedScope($0) }
            controller.dismiss(animated: true) { [weak self, reader] in
                Task { @MainActor [scope] in
                    defer { withExtendedLifetime(scope) {} }
                    guard let self, !self.invalidated else { reader.cancelDiscussionCopyPicker(request.id); return }
                    if let selected { await reader.completeDiscussionCopyPicker(selected, request: request) }
                    else { reader.cancelDiscussionCopyPicker(request.id) }
                    self.picker = nil; self.request = nil; self.finishing = false
                }
            }
        }
        func invalidate() {
            invalidated = true; picker?.delegate = nil; picker?.dismiss(animated: false)
            if let request { reader.cancelDiscussionCopyPicker(request.id) }
            picker = nil; request = nil
        }
    }
}

@MainActor private final class PickedScope {
    let url: URL
    let started: Bool
    init(_ url: URL) { self.url = url; started = url.startAccessingSecurityScopedResource() }
    deinit { if started { url.stopAccessingSecurityScopedResource() } }
}

/// Its identity boundary keeps a prior presentation's callbacks bound to its ID.
struct MobileDiscussionSheetPresenter: View {
    let reader: MobileReaderState
    let sheet: MobileDiscussionSheet
    @State private var presented = false
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .sheet(isPresented: $presented, onDismiss: { reader.dismissDiscussionSheet(sheet.id) }) {
                switch sheet {
                case let .passage(picker):
                    NavigationStack { MobileDiscussionPassagePickerView(reader: reader, picker: picker) }
                case let .importReview(review):
                    NavigationStack { MobileDiscussionImportView(reader: reader, review: review) }
                        .interactiveDismissDisabled(reader.fileSaving)
                }
            }
            .task { if reader.discussionSheet?.id == sheet.id { presented = true } }
    }
}

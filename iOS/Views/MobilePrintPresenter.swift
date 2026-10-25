import SwiftUI
import UIKit

/// The workspace owns preparation and the system panel, independently of its
/// transient navigation destinations. Every completion is tied to one request.
struct MobilePrintPresenter: UIViewControllerRepresentable {
    let reader: MobileReaderState
    private let requestID: UUID?
    private let documentContext: UUID
    private let hasDocument: Bool

    @MainActor init(reader: MobileReaderState) {
        self.reader = reader
        requestID = reader.printRequest?.id
        documentContext = reader.documentGeneration
        hasDocument = reader.hasDocument
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
        override func loadView() {
            view = UIView(); view.backgroundColor = .clear
        }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); ready?() }
    }

    @MainActor final class Coordinator: NSObject, UIPrintInteractionControllerDelegate {
        // UIKit exposes one system print controller. An old scene must never
        // dismiss, clear or replace another scene's formatter or completion.
        private static weak var owner: Coordinator?
        private let reader: MobileReaderState
        weak var host: Host?
        private var request: MobilePrintRequest?
        private var preparation: Task<Void, Never>?
        private var preparedPage: PreparedPrintDocument?
        private var invalidated = false

        init(reader: MobileReaderState) { self.reader = reader }

        func update() {
            guard !invalidated else { return }
            if let request, !isCurrent(request) { finish(request.id, dismiss: true) }
            guard request == nil, reader.hasDocument, let selected = reader.printRequest,
                  selected.context == reader.documentGeneration,
                  let host, host.viewIfLoaded?.window != nil else { return }
            guard Self.owner == nil else {
                reader.errorMessage = String(localized: "Another document is printing. Finish that print dialog, then try again.")
                reader.finishPrint(selected.id); return
            }
            guard UIPrintInteractionController.isPrintingAvailable else {
                reader.errorMessage = String(localized: "Printing is unavailable on this device.")
                reader.finishPrint(selected.id); return
            }
            Self.owner = self; request = selected
            preparation = Task { [weak self] in
                guard let self else { return }
                do {
                    let page = try await PreparedPrintDocument.prepare(selected.output, title: selected.title,
                        fileURL: selected.fileURL, includeDiscussions: selected.includeDiscussions,
                        loadRemoteImages: selected.loadRemoteImages)
                    guard !Task.isCancelled, isCurrent(selected), let host = self.host,
                          host.viewIfLoaded?.window != nil else {
                        page.cancel(); finish(selected.id, dismiss: false); return
                    }
                    preparedPage = page
                    let printer = UIPrintInteractionController.shared
                    let info = UIPrintInfo(dictionary: nil)
                    info.jobName = selected.title; info.outputType = .general
                    printer.printInfo = info; printer.delegate = self
                    printer.printFormatter = page.webView.viewPrintFormatter()
                    let completed: UIPrintInteractionController.CompletionHandler = { [weak self] _, _, error in
                        Task { @MainActor in self?.finish(selected.id, error: error, dismiss: false) }
                    }
                    let presented: Bool
                    // UIKit requires an anchor for its iPad presentation API;
                    // the current host's traits and bounds belong to this scene.
                    if host.traitCollection.userInterfaceIdiom == .pad {
                        let anchor = CGRect(x: max(0, host.view.bounds.maxX - 24), y: 0, width: 1, height: 1)
                        presented = printer.present(from: anchor, in: host.view, animated: true, completionHandler: completed)
                    } else {
                        presented = printer.present(animated: true, completionHandler: completed)
                    }
                    if !presented {
                        finish(selected.id, error: PrintFailure.presentation, dismiss: false)
                    }
                } catch is CancellationError { finish(selected.id, dismiss: false) }
                catch { finish(selected.id, error: error, dismiss: false) }
            }
        }

        func printInteractionControllerParentViewController(_ printInteractionController: UIPrintInteractionController) -> UIViewController? { host }

        private func isCurrent(_ value: MobilePrintRequest) -> Bool {
            !invalidated && reader.hasDocument && reader.documentGeneration == value.context &&
                reader.printRequest?.id == value.id
        }
        private func finish(_ requestID: UUID, error: (any Error)? = nil, dismiss: Bool) {
            guard let request, request.id == requestID else { return }
            preparation?.cancel(); preparation = nil
            if Self.owner === self {
                let printer = UIPrintInteractionController.shared
                if dismiss { printer.dismiss(animated: false) }
                printer.delegate = nil; printer.printFormatter = nil
                printer.printPageRenderer = nil; printer.printingItem = nil; printer.printingItems = nil
                printer.printInfo = nil
                Self.owner = nil
            }
            preparedPage?.cancel(); preparedPage = nil
            self.request = nil
            if reader.documentGeneration == request.context, reader.printRequest?.id == requestID {
                if let error { reader.errorMessage = error.localizedDescription }
                reader.finishPrint(requestID)
            }
        }
        func invalidate() {
            invalidated = true
            if let request { finish(request.id, dismiss: true) }
        }
    }
}

private enum PrintFailure: LocalizedError {
    case presentation
    var errorDescription: String? { String(localized: "Couldn't open the print dialog. Try again.") }
}

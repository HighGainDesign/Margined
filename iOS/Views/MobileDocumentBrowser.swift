import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Files owns discovery and thumbnails; the existing reader owns the document.
struct MobileDocumentBrowser: View {
    let open: (URL) async -> Bool
    let tour: () -> Void
    let settings: () -> Void
    private let types = [UTType(importedAs: "net.daringfireball.markdown")]

    var body: some View {
        if #available(iOS 18, *) {
            DocumentLaunchView("Margined", for: types) {
                Button("Take a Tour", systemImage: "sparkles", action: tour)
                Button("Settings", systemImage: "gearshape", action: settings)
            } onDocumentOpen: { url in
                OpeningDocument(url: url, open: open)
            }
        } else {
            LegacyDocumentBrowser(types: types, open: open, tour: tour, settings: settings)
        }
    }

    private struct OpeningDocument: View {
        let url: URL
        let open: (URL) async -> Bool
        @Environment(\.dismiss) private var dismiss
        var body: some View {
            ProgressView().task {
                // The launch surface moves its editor between presentations.
                // The reader owns opening, as with Files/Open With; a transient
                // disappearance of this placeholder must not cancel that I/O.
                let opening = Task { await open(url) }
                if !(await opening.value) { dismiss() }
            }
        }
    }
}

/// iOS 17 uses the native browser without the newer branded launch surface.
private struct LegacyDocumentBrowser: UIViewControllerRepresentable {
    let types: [UTType]
    let open: (URL) async -> Bool
    let tour: () -> Void
    let settings: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIDocumentBrowserViewController {
        let browser = UIDocumentBrowserViewController(forOpening: types)
        browser.delegate = context.coordinator
        browser.allowsDocumentCreation = false
        browser.allowsPickingMultipleItems = false
        browser.additionalTrailingNavigationBarButtonItems = [
            UIBarButtonItem(title: String(localized: "Take a Tour"), primaryAction: UIAction { _ in context.coordinator.parent.tour() }),
            UIBarButtonItem(image: UIImage(systemName: "gearshape"), primaryAction: UIAction(title: String(localized: "Settings")) { _ in context.coordinator.parent.settings() })
        ]
        browser.additionalTrailingNavigationBarButtonItems.last?.accessibilityLabel = String(localized: "Settings")
        return browser
    }
    func updateUIViewController(_ browser: UIDocumentBrowserViewController, context: Context) { context.coordinator.parent = self }

    @MainActor final class Coordinator: NSObject, @preconcurrency UIDocumentBrowserViewControllerDelegate {
        var parent: LegacyDocumentBrowser
        init(parent: LegacyDocumentBrowser) { self.parent = parent }
        func documentBrowser(_ controller: UIDocumentBrowserViewController, didPickDocumentsAt documentURLs: [URL]) {
            guard let url = documentURLs.first else { return }
            Task { _ = await parent.open(url) }
        }
    }
}

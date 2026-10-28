import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Files owns provider locations, Recents, search and display modes. The app
/// supplies only its launch actions and keeps the existing document owner.
struct MobileDocumentBrowser: View {
    let open: (URL) async -> Bool
    let tour: () -> Void
    let settings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: "Margined").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                        Text("Read, review, discuss.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Settings", systemImage: "gearshape", action: settings)
                        .labelStyle(.iconOnly).buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
                        .accessibilityIdentifier("browser.settings")
                }
                Button("Take a Tour", systemImage: "sparkles", action: tour)
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("browser.tour")
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            NativeFilesBrowser(open: open)
        }.background(.background)
    }
}

private struct NativeFilesBrowser: UIViewControllerRepresentable {
    let open: (URL) async -> Bool
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIDocumentBrowserViewController {
        let browser = UIDocumentBrowserViewController(forOpening: [UTType(importedAs: "net.daringfireball.markdown")])
        browser.delegate = context.coordinator
        browser.allowsDocumentCreation = false
        browser.allowsPickingMultipleItems = false
        return browser
    }
    func updateUIViewController(_ browser: UIDocumentBrowserViewController, context: Context) { context.coordinator.parent = self }

    @MainActor final class Coordinator: NSObject, @preconcurrency UIDocumentBrowserViewControllerDelegate {
        var parent: NativeFilesBrowser
        init(parent: NativeFilesBrowser) { self.parent = parent }
        func documentBrowser(_ controller: UIDocumentBrowserViewController, didPickDocumentsAt documentURLs: [URL]) {
            guard let url = documentURLs.first else { return }
            Task { _ = await parent.open(url) }
        }
    }
}

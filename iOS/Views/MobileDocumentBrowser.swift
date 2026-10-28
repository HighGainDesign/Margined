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
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ViewThatFits(in: .vertical) {
                    fullHeader.fixedSize(horizontal: false, vertical: true)
                    compactHeader.fixedSize(horizontal: false, vertical: true)
                    ScrollView { compactHeader }
                }.frame(maxHeight: max(64, min(220, geometry.size.height * 0.32)))
                NativeFilesBrowser(open: open).frame(maxWidth: .infinity, maxHeight: .infinity)
            }.background(.background)
        }
    }

    private var fullHeader: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "Margined").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    Text("Read, review, discuss.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                settingsButton
            }
            tourButton
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compactHeader: some View {
        HStack(spacing: 12) { tourButton; Spacer(minLength: 8); settingsButton }.padding(12)
    }
    private var tourButton: some View {
        Button("Take a Tour", systemImage: "sparkles", action: tour)
            .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("browser.tour")
    }
    private var settingsButton: some View {
        Button("Settings", systemImage: "gearshape", action: settings)
            .labelStyle(.iconOnly).buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
            .accessibilityIdentifier("browser.settings")
    }

}

private struct NativeFilesBrowser: UIViewControllerRepresentable {
    let open: (URL) async -> Bool
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIDocumentBrowserViewController {
        let browser = UIDocumentBrowserViewController(forOpening: [UTType(importedAs: "net.daringfireball.markdown"), .plainText])
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

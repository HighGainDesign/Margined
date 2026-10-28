import SwiftUI
import UniformTypeIdentifiers

/// Shared by the first-launch sheet and the Settings navigation destination.
struct MobileSetupGuide: View {
    @Bindable var imageFolders: MobileImageFolders
    var foldersChanged: () -> Void
    @State private var showFolderPicker = false
    @State private var folderError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 40)).foregroundStyle(.blue).accessibilityHidden(true)
                    Text("Welcome to Margined").font(.title.bold()).accessibilityAddTraits(.isHeader)
                    Text("Open Markdown from Files to read, listen, and follow changes.")
                        .foregroundStyle(.secondary)
                }.padding(.vertical, 12)
            }
            Section {
                Text("Opening a file doesn’t grant access to nearby images. Choose a folder that contains your document and its images; subfolders are included.")
                Text("You can select all of Dropbox when Files allows it, or remember several smaller folders. Manage or forget them in Settings.")
                    .foregroundStyle(.secondary)
                Button("Choose Image Folders…", systemImage: "folder.badge.plus") {
                    showFolderPicker = true
                }.frame(minHeight: 44)
                if !imageFolders.folders.isEmpty {
                    ForEach(imageFolders.folders) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Label { Text(verbatim: entry.title) } icon: { Image(systemName: "folder") }
                                .accessibilityLabel(String(localized: "Image folder: \(entry.title)"))
                            if let error = imageFolders.errors[entry.id] {
                                Text(error).font(.footnote).foregroundStyle(.red)
                            }
                        }
                    }
                }
                if let folderError {
                    Label(folderError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            } header: { Text("Images from your folders").textCase(nil) }
            Section {
                Text("On iOS 27, Files currently shows Markdown as plain text instead of using Margined’s Quick Look extension. This also affects some earlier iOS releases.")
                Text("Choose Open With → Margined or Share → Margined to open the formatted document.")
            } header: { Text("Quick Look in Files").textCase(nil) } footer: {
                Text("You can reopen this guide from Settings → Getting Started.")
            }
        }
        .navigationTitle("Getting Started").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls):
                let scopes = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
                Task {
                    defer { for (url, started) in scopes where started { url.stopAccessingSecurityScopedResource() } }
                    folderError = nil
                    for url in urls {
                        do { try await imageFolders.remember(url) }
                        catch { folderError = error.localizedDescription }
                    }
                    foldersChanged()
                }
            case let .failure(error):
                if (error as? CocoaError)?.code != .userCancelled { folderError = error.localizedDescription }
            }
        }
    }
}

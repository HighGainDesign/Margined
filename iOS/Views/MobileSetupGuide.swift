import SwiftUI
import UniformTypeIdentifiers

/// The home screen and Settings share the same replayable tutorial session.
struct MobileSetupGuide: View {
    @Bindable var imageFolders: MobileImageFolders
    var foldersChanged: () -> Void
    @Bindable var tutorial: TutorialSession
    var openPractice: (TutorialLesson) -> Void
    @State private var showFolderPicker = false
    @State private var folderError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TutorialGuide(session: tutorial, done: { dismiss() }, openPractice: openPractice) { lesson in
            if lesson == .images {
                VStack(alignment: .leading, spacing: 12) {
                    Button("Choose Image Folders…", systemImage: "folder.badge.plus") { showFolderPicker = true }
                        .frame(minHeight: 44)
                    ForEach(imageFolders.folders) { entry in
                        Label(entry.title, systemImage: "folder").lineLimit(2)
                        if let error = imageFolders.errors[entry.id] { Text(error).foregroundStyle(.red) }
                    }
                    if let folderError {
                        Label(folderError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
            }
        } footer: { EmptyView() }
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

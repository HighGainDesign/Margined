import SwiftUI
import UniformTypeIdentifiers

struct MobileRootView: View {
    @State private var reader: MobileReaderState
    @State private var library = MobileDocumentLibrary()
    let imageFolders: MobileImageFolders
    @State private var showPicker = false
    @State private var pickingFolder = false
    private enum Sheet: String, Identifiable { case settings, guide; var id: String { rawValue } }
    @State private var activeSheet: Sheet?
    @AppStorage("mobileSetupGuideSeen", store: ReaderPreferences.defaults) private var setupGuideSeen = false
    @Environment(\.scenePhase) private var scenePhase

    init(playback: MobilePlaybackOwner, imageFolders: MobileImageFolders) {
        self.imageFolders = imageFolders
        _reader = State(initialValue: MobileReaderState(playback: playback))
    }

    var body: some View {
        Group {
            if reader.hasDocument {
                MobileDocumentWorkspace(reader: reader, openFolder: { pickFolder() },
                    closeFile: { Task { await reader.close() } })
            } else {
                NavigationStack { libraryView.navigationTitle("Margined").navigationBarTitleDisplayMode(.inline) }
            }
        }
        .overlay { if reader.isOpening || imageFolders.isRestoring { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .fileImporter(isPresented: $showPicker,
            allowedContentTypes: pickingFolder ? [.folder] : [UTType(importedAs: "net.daringfireball.markdown"), .plainText],
            allowsMultipleSelection: pickingFolder) { result in
                switch result {
                case .success(let urls):
                    let scopes = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
                    let folder = pickingFolder
                    Task {
                        defer { for (url, started) in scopes where started { url.stopAccessingSecurityScopedResource() } }
                        if folder {
                            for url in urls {
                                do { try await imageFolders.remember(url) }
                                catch { reader.errorMessage = error.localizedDescription }
                            }
                            reader.retryLocalImages()
                        } else if let url = urls.first { await open(url) }
                    }
                case .failure(let error): reader.errorMessage = error.localizedDescription
                }
            }
        .confirmationDialog("Discard unposted replies?", isPresented: $reader.showDraftDiscardConfirmation, titleVisibility: .visible) {
            Button("Keep Open", role: .cancel) { reader.cancelDocumentTransition() }
            Button("Discard Drafts", role: .destructive) { Task { await reader.confirmDiscardDrafts() } }
        } message: {
            Text("Keep this document open to finish your comments and replies, or discard the unposted text.")
        }
        .sheet(item: $activeSheet) { destination in
            switch destination {
            case .settings: MobileSettingsView(reader: reader, imageFolders: imageFolders)
            case .guide:
                NavigationStack { MobileSetupGuide(imageFolders: imageFolders, foldersChanged: { reader.retryLocalImages() }) }
            }
        }
        .onChange(of: activeSheet) { previous, current in
            // The guide's nested Files picker does not change this destination.
            if previous == .guide && current == nil { setupGuideSeen = true }
        }
        .task {
            await imageFolders.restore()
            if !setupGuideSeen && activeSheet == nil { activeSheet = .guide }
        }
        .onOpenURL { url in
            let scope = url.isFileURL && url.startAccessingSecurityScopedResource()
            Task {
                defer { if scope { url.stopAccessingSecurityScopedResource() } }
                if url.isFileURL { await open(url) }
                else { await reader.openPreview(url: url) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            Task { await reader.setPresented(phase == .active) }
        }
    }

    private var libraryView: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    Image(systemName: "doc.richtext").font(.system(size: 48)).foregroundStyle(.blue).accessibilityHidden(true)
                    Text("Your Markdown, clearly.").font(.title2.bold())
                    Text("Open a document from Files to read, follow changes, or listen.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button(action: { pickFile() }) { Label("Open Document…", systemImage: "folder") }
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Button("Open Sample Document") { Task { await openSample() } }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
            }
            if !library.recents.isEmpty {
                Section("Recent Documents") {
                    ForEach(library.recents) { item in
                        Button {
                            Task {
                                do { await open(try await library.resolve(item.id)) }
                                catch { reader.errorMessage = error.localizedDescription }
                            }
                        } label: { Label(item.title, systemImage: "doc.text").foregroundStyle(.primary) }
                    }
                    .onDelete { indices in
                        let ids = indices.map { library.recents[$0].id }
                        for id in ids { library.remove(id: id) }
                    }
                }
            }
            if let error = reader.errorMessage { Section { Text(error).foregroundStyle(.red).accessibilityLabel(error) } }
        }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Settings", systemImage: "gearshape") { activeSheet = .settings } } }
    }

    private func pickFile() { pickingFolder = false; showPicker = true }
    private func pickFolder() { pickingFolder = true; showPicker = true }
    private func open(_ url: URL) async {
        await imageFolders.restore()
        await reader.open(url: url)
        if reader.fileURL == url { try? await library.remember(url) }
    }
    private func openSample() async {
        do {
            let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let sampleFolder = folder.appendingPathComponent("Margined Sample", isDirectory: true)
            try FileManager.default.createDirectory(at: sampleFolder, withIntermediateDirectories: true)
            let image = sampleFolder.appendingPathComponent("sample.svg")
            if !FileManager.default.fileExists(atPath: image.path), let sample = Bundle.main.url(forResource: "sample", withExtension: "svg") {
                try FileManager.default.copyItem(at: sample, to: image)
            }
            let url = sampleFolder.appendingPathComponent("Welcome.md")
            if !FileManager.default.fileExists(atPath: url.path), let sample = Bundle.main.url(forResource: "Welcome", withExtension: "md") {
                try FileManager.default.copyItem(at: sample, to: url)
            }
            await open(url)
        } catch { reader.errorMessage = error.localizedDescription }
    }
}

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
    @AppStorage(ReaderPreferences.appearanceKey, store: ReaderPreferences.defaults) private var appearance = DocumentAppearance.system
    @Environment(\.scenePhase) private var scenePhase

    init(playback: MobilePlaybackOwner, imageFolders: MobileImageFolders, reader: MobileReaderState? = nil) {
        self.imageFolders = imageFolders
        _reader = State(initialValue: reader ?? MobileReaderState(playback: playback))
    }

    var body: some View {
        Group {
            if reader.hasDocument {
                MobileDocumentWorkspace(reader: reader, openFolder: { pickFolder() },
                    closeFile: { Task { await reader.close() } }).id(reader.id)
            } else {
                libraryView
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
            Group {
                switch destination {
                case .settings: MobileSettingsView(reader: reader, imageFolders: imageFolders)
                case .guide:
                    NavigationStack { MobileSetupGuide(imageFolders: imageFolders, foldersChanged: { reader.retryLocalImages() }) }
                }
            }
            .preferredColorScheme(appearance == .system ? nil : (appearance == .dark ? .dark : .light))
        }
        .onChange(of: activeSheet) { previous, current in
            // The guide's nested Files picker does not change this destination.
            if previous == .guide && current == nil { setupGuideSeen = true }
        }
        .task {
            #if MARGINED_BENCHMARK
            if MobileViewingBenchmarkSession.startIfRequested(reader: reader,
                open: { url in await open(url) }) { return }
            #endif
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
        .onChange(of: reader.discussionCopyOpenRequest) { _, request in
            guard let request else { return }
            let original = reader
            do {
                if let copy = try original.takeDiscussionCopyToOpen(request) {
                    reader = copy
                    Task {
                        await original.close()
                        if let url = copy.fileURL { try? await library.remember(url) }
                    }
                }
            } catch { original.discussionError = error.localizedDescription }
        }
        .onChange(of: scenePhase) { _, phase in
            Task { await reader.setPresented(phase == .active) }
        }
        .onChange(of: appearance, initial: true) { _, value in
            if reader.appearance != value { reader.appearance = value }
        }
        .preferredColorScheme(appearance == .system ? nil : (appearance == .dark ? .dark : .light))
    }

    private var libraryView: some View {
        MobileDocumentBrowser(open: { await open($0) }, tour: { activeSheet = .guide }, settings: { activeSheet = .settings })
            .safeAreaInset(edge: .bottom) {
                if let error = reader.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).padding().background(.bar)
                }
            }
    }

    private func pickFile() { pickingFolder = false; showPicker = true }
    private func pickFolder() { pickingFolder = true; showPicker = true }
    @discardableResult private func open(_ url: URL) async -> Bool {
        await imageFolders.restore()
        await reader.open(url: url)
        if reader.fileURL == url { try? await library.remember(url) }
        return reader.hasDocument
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

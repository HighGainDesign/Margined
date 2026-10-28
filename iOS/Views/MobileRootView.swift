import SwiftUI
import UniformTypeIdentifiers

struct MobileRootView: View {
    @State private var reader: MobileReaderState
    @State private var library = MobileDocumentLibrary()
    @State private var tutorial: TutorialSession
    @State private var pendingPractice: URL?
    let imageFolders: MobileImageFolders
    @State private var showPicker = false
    @State private var pickingFolder = false
    private enum Sheet: String, Identifiable { case settings, guide; var id: String { rawValue } }
    @State private var activeSheet: Sheet?
    @AppStorage("mobileSetupGuideSeen", store: ReaderPreferences.defaults) private var setupGuideSeen = false
    @AppStorage(ReaderPreferences.appearanceKey, store: ReaderPreferences.defaults) private var appearance = DocumentAppearance.system
    @Environment(\.scenePhase) private var scenePhase

    init(playback: MobilePlaybackOwner, imageFolders: MobileImageFolders, reader: MobileReaderState? = nil, tutorial: TutorialSession? = nil) {
        self.imageFolders = imageFolders
        _reader = State(initialValue: reader ?? MobileReaderState(playback: playback))
        _tutorial = State(initialValue: tutorial ?? TutorialSession(platform: .mobile))
    }

    var body: some View {
        Group {
            if reader.hasDocument {
                MobileDocumentWorkspace(reader: reader, openFolder: { pickFolder() },
                    closeFile: { Task { await reader.close() } })
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if let practice = tutorial.practice(for: reader.fileURL) {
                            TutorialPracticeBar(session: tutorial, practice: practice, tour: { activeSheet = .guide })
                        }
                    }.id(reader.id)
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
        .sheet(item: $activeSheet, onDismiss: openPendingPractice) { destination in
            Group {
                switch destination {
                case .settings: MobileSettingsView(reader: reader, imageFolders: imageFolders, tutorial: tutorial, openPractice: preparePractice)
                case .guide:
                    MobileSetupGuide(imageFolders: imageFolders, foldersChanged: { reader.retryLocalImages() }, tutorial: tutorial, openPractice: preparePractice)
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

    private func pickFolder() { pickingFolder = true; showPicker = true }
    @discardableResult private func open(_ url: URL) async -> Bool {
        await imageFolders.restore()
        await reader.open(url: url)
        if reader.fileURL == url { try? await library.remember(url) }
        return reader.hasDocument
    }
    private func preparePractice(_ lesson: TutorialLesson) {
        Task {
            do {
                pendingPractice = try await tutorial.makePractice(lesson)
                activeSheet = nil
            } catch is CancellationError { }
            catch { tutorial.error = error.localizedDescription }
        }
    }
    private func openPendingPractice() {
        guard let url = pendingPractice else { return }
        pendingPractice = nil
        Task { await open(url) }
    }
}

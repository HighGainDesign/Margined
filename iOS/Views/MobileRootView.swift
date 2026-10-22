import SwiftUI
import UniformTypeIdentifiers

struct MobileRootView: View {
    @State private var reader: MobileReaderState
    @State private var library = MobileDocumentLibrary()
    @State private var showPicker = false
    @State private var pickingFolder = false
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    init(playback: MobilePlaybackOwner) {
        _reader = State(initialValue: MobileReaderState(playback: playback))
    }

    var body: some View {
        NavigationStack {
            Group {
                if reader.hasDocument {
                    MobileReaderView(reader: reader, openFile: { pickFile() }, openFolder: { pickFolder() },
                        closeFile: { Task { await reader.close() } }, settings: { showSettings = true })
                } else { libraryView }
            }
            .navigationTitle(reader.hasDocument ? reader.title : "MDView")
            .navigationBarTitleDisplayMode(.inline)
            .overlay { if reader.isOpening { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        }
        .fileImporter(isPresented: $showPicker,
            allowedContentTypes: pickingFolder ? [.folder] : [UTType(importedAs: "net.daringfireball.markdown"), .plainText],
            allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let scope = url.startAccessingSecurityScopedResource()
                    let folder = pickingFolder
                    Task {
                        defer { if scope { url.stopAccessingSecurityScopedResource() } }
                        if folder { await reader.addFolderAccess(url) }
                        else { await open(url) }
                    }
                case .failure(let error): reader.errorMessage = error.localizedDescription
                }
            }
        .sheet(isPresented: $showSettings) { MobileSettingsView(reader: reader) }
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
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Settings", systemImage: "gearshape") { showSettings = true } } }
    }

    private func pickFile() { pickingFolder = false; showPicker = true }
    private func pickFolder() { pickingFolder = true; showPicker = true }
    private func open(_ url: URL) async {
        await reader.open(url: url)
        if reader.fileURL == url { try? await library.remember(url) }
    }
    private func openSample() async {
        do {
            let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let sampleFolder = folder.appendingPathComponent("MDView Sample", isDirectory: true)
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

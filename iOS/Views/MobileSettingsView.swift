import SwiftUI
import UniformTypeIdentifiers

struct MobileSettingsView: View {
    @Bindable var reader: MobileReaderState
    @Bindable var imageFolders: MobileImageFolders
    @State private var showFolderPicker = false
    @State private var folderError: String?
    @AppStorage(ReaderPreferences.appearanceKey, store: ReaderPreferences.defaults) private var appearance = DocumentAppearance.system.rawValue
    @AppStorage("fullWidthByDefault", store: ReaderPreferences.defaults) private var fullWidth = true
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Document Appearance", selection: $appearance) {
                        ForEach(DocumentAppearance.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }
                }
                Section {
                    Toggle("Use Full Width by Default", isOn: $fullWidth)
                } header: { Text("Reading Width") } footer: {
                    Text("The default for newly opened documents. Change the current document’s width from its More menu.")
                }
                Section("Images and Embedded HTML") {
                    LabeledContent("Local Images", value: String(localized: "Automatic"))
                    Text("Local images load automatically from folders you select in Files. Choose a project folder to include its subfolders, or add several folders.").font(.footnote).foregroundStyle(.secondary)
                    LabeledContent("Remote Images", value: String(localized: "Off by default"))
                    Text("Load Remote Images in the document’s More menu contacts image hosts, which can reveal that you opened the document.").font(.footnote).foregroundStyle(.secondary)
                    Text("Safe formatting and image sizes are supported. Scripts, forms and other active content are removed.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Local Image Folders") {
                    ForEach(imageFolders.folders) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(entry.title, systemImage: "folder").lineLimit(2)
                                Spacer()
                                Button("Forget", role: .destructive) {
                                    imageFolders.forget(entry.id); reader.retryLocalImages()
                                }
                                .accessibilityLabel(String(localized: "Forget image folder \(entry.title)"))
                            }
                            if let error = imageFolders.errors[entry.id] {
                                Text(error).font(.footnote).foregroundStyle(.red)
                            }
                        }
                    }
                    Button("Add Image Folders…", systemImage: "folder.badge.plus") { showFolderPicker = true }
                    if let folderError { Text(folderError).font(.footnote).foregroundStyle(.red) }
                }
                Section("Read Aloud") {
                    Toggle("Follow Reading", isOn: Binding(get: { reader.playback.preferences.followReading }, set: { reader.playback.setFollowReading($0) }))
                    Toggle("Include Code Blocks", isOn: Binding(get: { reader.playback.preferences.options.includeCode }, set: { reader.playback.preferences.options.includeCode = $0; reader.speechOptionsChanged() }))
                    Toggle("Speak Link Destinations", isOn: Binding(get: { reader.playback.preferences.options.includeLinkDestinations }, set: { reader.playback.preferences.options.includeLinkDestinations = $0; reader.speechOptionsChanged() }))
                    Button("Clear Reading History", role: .destructive) { reader.playback.clearHistory() }
                }
                Section {
                    NavigationLink {
                        MobileSetupGuide(imageFolders: imageFolders, foldersChanged: { reader.retryLocalImages() })
                    } label: { Label("Getting Started", systemImage: "questionmark.circle") }
                }
                Section { Text("Margined 2.0 · iOS development build").foregroundStyle(.secondary) }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
                    reader.retryLocalImages()
                }
            case let .failure(error): folderError = error.localizedDescription
            }
        }
        .onChange(of: appearance) { _, value in reader.appearance = DocumentAppearance(rawValue: value) ?? .system }
    }
}

struct MobileSpeechPlayer: View {
    @Bindable var reader: MobileReaderState
    private var playback: MobilePlaybackOwner { reader.playback }
    private var ownsPlayback: Bool { playback.ownerID == reader.id }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "speaker.wave.2").accessibilityHidden(true)
                Text(ownsPlayback ? (playback.session.currentSegment?.text ?? String(localized: "Read Aloud")) : String(localized: "Read Aloud"))
                    .font(.subheadline).lineLimit(2)
                Spacer()
                if ownsPlayback { Button("Stop Read Aloud", systemImage: "stop.fill") { playback.stop() }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44) }
            }
            HStack(spacing: 16) {
                Button("Previous Section", systemImage: "backward.end.fill") { playback.previousSection() }.frame(minWidth: 44, minHeight: 44).disabled(!ownsPlayback)
                Button {
                    if ownsPlayback, playback.session.status == .playing { playback.pause() }
                    else if ownsPlayback, playback.session.status == .paused { playback.resume() }
                    else { reader.resumeSpeechPosition() }
                } label: {
                    Label(ownsPlayback && playback.session.status == .playing ? "Pause" : "Play", systemImage: ownsPlayback && playback.session.status == .playing ? "pause.fill" : "play.fill")
                        .font(.title2)
                }.frame(minWidth: 44, minHeight: 44).disabled(reader.isRendering || reader.checklistSaving || reader.showChecklistConfirmation)
                Button("Next Section", systemImage: "forward.end.fill") { playback.nextSection() }.frame(minWidth: 44, minHeight: 44).disabled(!ownsPlayback)
                Spacer(minLength: 0)
                Menu {
                    Button("Read from Beginning") { reader.startSpeech(mode: "beginning") }
                    Button("Read from Here") { reader.startSpeech() }
                    Button("Read Selection") { reader.startSpeech(mode: "selection") }
                    Picker("Speed", selection: Binding(get: { playback.preferences.rate }, set: { playback.setRate($0) })) {
                        ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { Text($0.formatted() + "×").tag($0) }
                    }
                    Picker("Voice", selection: Binding(get: { playback.preferences.voice(for: reader.rendered?.documentLanguage) ?? "" }, set: { value in
                        let voice = value.isEmpty ? nil : value
                        if ownsPlayback { playback.setVoice(voice) }
                        else { playback.preferences.setVoice(voice, for: reader.rendered?.documentLanguage) }
                    })) {
                        Text("Automatic").tag("")
                        ForEach(playback.session.availableVoices, id: \.id) { voice in Text(voice.name + " · " + voice.language).tag(voice.id) }
                    }
                } label: { Label("Playback Options", systemImage: "slider.horizontal.3") }
                    .frame(minWidth: 44, minHeight: 44)
            }.labelStyle(.iconOnly).frame(minHeight: 44)
            if ownsPlayback, let notice = playback.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }.padding(16).background(.bar)
        .onAppear { playback.refreshVoices() }
    }
}

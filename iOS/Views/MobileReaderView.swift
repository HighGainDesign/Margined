import SwiftUI

struct MobileReaderView: View {
    @Bindable var reader: MobileReaderState
    let openFile: () -> Void
    let openFolder: () -> Void
    let closeFile: () -> Void
    let settings: () -> Void
    @State private var showOutline = false
    @State private var showChanges = false
    @State private var showFind = false
    @State private var showPlayer = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if showFind { findBar }
                if reader.hasPendingFileUpdate { latestBar }
                if reader.checklistMode { checklistBar }
                if let error = reader.errorMessage { message(error, isError: true) }
                if let error = reader.localImageError {
                    HStack {
                        Label(error, systemImage: "photo.badge.exclamationmark").font(.caption).lineLimit(3)
                        Spacer()
                        Button("Open Image Folder…", action: openFolder).font(.caption)
                    }.padding(12).background(.bar)
                }
                MobileWebView(reader: reader)
                statusBar
                if showPlayer || reader.playback.ownerID == reader.id { MobileSpeechPlayer(reader: reader) }
            }
            if showChanges, sizeClass == .regular {
                Divider()
                MobileChangesView(reader: reader, close: { showChanges = false }, reveal: { reader.showSelectedChange() })
                    .frame(width: 340)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button("Outline", systemImage: "list.bullet.indent") { showOutline = true }
                    .disabled(reader.rendered?.headings.isEmpty != false)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if reader.changes.count > 0 {
                    Button { showChanges.toggle() } label: { Label("Review Changes", systemImage: "text.badge.checkmark").badge(reader.changes.count) }
                        .accessibilityLabel(String(localized: "Review Changes") + ", \(reader.changes.count)")
                }
                Menu {
                    Button("Find…", systemImage: "magnifyingglass") { showFind.toggle() }
                    Button("Read Aloud", systemImage: "speaker.wave.2") { showPlayer = true; reader.startSpeech() }
                    if reader.fileURL != nil {
                        Button(reader.fileUpdatesPaused ? "Resume Updates" : "Pause Updates", systemImage: reader.fileUpdatesPaused ? "play" : "pause") {
                            reader.setFileUpdatesPaused(!reader.fileUpdatesPaused)
                        }
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await reader.refresh() } }
                    }
                    Section {
                        Toggle("Full Width", isOn: $reader.wide)
                        Toggle("Load Remote Images", isOn: $reader.loadRemoteImages)
                        Button("Larger Text", systemImage: "textformat.size.larger") { reader.changeZoom(by: 0.1) }
                        Button("Smaller Text", systemImage: "textformat.size.smaller") { reader.changeZoom(by: -0.1) }
                    }
                    Section {
                        Button("Undo Checkbox Change", systemImage: "arrow.uturn.backward") { reader.undoChecklist() }.disabled(!reader.canUndoChecklist)
                        Button("Redo Checkbox Change", systemImage: "arrow.uturn.forward") { reader.redoChecklist() }.disabled(!reader.canRedoChecklist)
                        if reader.checklistMode { Button("Stop Saving Checkmarks") { reader.stopSavingCheckmarks() } }
                    }
                    Section {
                        Button("Open Document…", systemImage: "folder", action: openFile)
                        Button("Close Document", systemImage: "xmark", action: closeFile)
                        Button("Settings", systemImage: "gearshape", action: settings)
                    }
                } label: { Label("More", systemImage: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showOutline) {
            NavigationStack {
                List(reader.rendered?.headings ?? []) { heading in
                    Button(heading.title) { showOutline = false; reader.navigate(to: heading.id) }
                        .padding(.leading, CGFloat(max(0, heading.level - 1)) * 12)
                }
                .navigationTitle("Outline").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showOutline = false } } }
            }
        }
        .sheet(isPresented: Binding(get: { showChanges && sizeClass != .regular }, set: { showChanges = $0 })) {
            MobileChangesView(reader: reader, close: { showChanges = false }, reveal: {
                showChanges = false; reader.showSelectedChange()
            })
            .presentationDetents([.medium, .large])
        }
        .alert("Save Checkmarks to This File?", isPresented: $reader.showChecklistConfirmation) {
            Button("Cancel", role: .cancel) { reader.cancelChecklistConfirmation() }
            Button("Save Checkmarks") { reader.confirmChecklistSaving() }
        } message: {
            Text("Each checkbox change saves automatically to the Markdown file. You can undo it. Other apps and agents will see your progress.")
        }
        .onChange(of: reader.wide) { _, _ in reader.render() }
        .onChange(of: reader.loadRemoteImages) { _, _ in reader.render() }
        .onChange(of: reader.appearance) { _, _ in reader.render() }
    }

    private var findBar: some View {
        VStack(spacing: 4) {
            HStack {
                TextField("Find in Document", text: $reader.searchText).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search).onSubmit { reader.find() }
                Button("Close Find", systemImage: "xmark") { showFind = false; reader.searchText = "" }
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            }
            HStack {
                if reader.searchMatch == false { Text("No matches").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Previous Match", systemImage: "chevron.up") { reader.find(backwards: true) }.frame(minWidth: 44, minHeight: 44)
                Button("Next Match", systemImage: "chevron.down") { reader.find() }.frame(minWidth: 44, minHeight: 44)
            }.labelStyle(.iconOnly).buttonStyle(.bordered)
        }.padding(.horizontal, 12).padding(.vertical, 4).background(.bar)
            .onChange(of: reader.searchText) { _, _ in reader.find() }
    }
    private var checklistBar: some View {
        HStack {
            Label("Checkmarks save to this file.", systemImage: "checklist")
            Spacer()
            Button("Undo") { reader.undoChecklist() }.disabled(!reader.canUndoChecklist)
        }.font(.caption).padding(12).background(.bar)
    }
    private var latestBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A newer saved version is waiting.").font(.subheadline.bold())
            HStack {
                Button("Show Latest") { reader.showLatest() }
                if reader.playbackHolding { Button("Read Latest") { reader.showLatest(readAloud: true) } }
            }.buttonStyle(.bordered)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.bar)
    }
    private var statusBar: some View {
        HStack {
            if reader.isRendering || reader.checklistSaving { ProgressView().controlSize(.mini) }
            if reader.fileUpdatesPaused { Label("Updates Paused", systemImage: "pause.circle") }
            else if reader.fileURL == nil { Text("Snapshot") }
            else { Label("File Updates On", systemImage: "arrow.triangle.2.circlepath") }
            Spacer()
            Text("\(reader.rendered?.wordCount ?? 0) words")
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8).background(.bar)
    }
    private func message(_ text: String, isError: Bool) -> some View {
        HStack(alignment: .top) {
            Label(text, systemImage: "exclamationmark.triangle").font(.caption)
            Spacer()
            Button("Dismiss", systemImage: "xmark") { reader.errorMessage = nil }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
        }.foregroundStyle(isError ? .red : .secondary).padding(12).background(.bar)
    }
}

struct MobileChangesView: View {
    @Bindable var reader: MobileReaderState
    let close: () -> Void
    let reveal: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Review Changes").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Close Review", systemImage: "xmark", action: close).labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            }
            if let change = reader.selectedChange {
                HStack {
                    Button("Previous Change", systemImage: "chevron.left") { reader.stepChange(backwards: true) }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    Spacer()
                    Text("Change \(reader.currentChangeIndex + 1) of \(reader.changes.count)").font(.subheadline).monospacedDigit()
                    Spacer()
                    Button("Next Change", systemImage: "chevron.right") { reader.stepChange() }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(change.kind.localizedTitle, systemImage: change.kind == .removed ? "minus.circle" : "text.badge.plus").font(.headline)
                        if !change.before.isEmpty {
                            Text("Previous text").font(.caption.bold()).foregroundStyle(.secondary)
                            Text(change.beforeDescription ?? change.before).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !change.after.isEmpty {
                            Text("Current text").font(.caption.bold()).foregroundStyle(.secondary)
                            Text(change.afterDescription ?? change.after).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                Button("Show in Document", action: reveal).disabled(change.targetID == nil)
                Button("Mark This Reviewed") { reader.markCurrentChangeReviewed() }.buttonStyle(.borderedProminent).disabled(reader.isRendering)
                Button("Mark All Reviewed") { reader.markAllReviewed() }.disabled(reader.isRendering)
            } else {
                ContentUnavailableView("All Changes Reviewed", systemImage: "checkmark.circle")
            }
            Spacer(minLength: 0)
        }.padding(20).background(.background)
    }
}

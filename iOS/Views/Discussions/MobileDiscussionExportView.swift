import SwiftUI
import UniformTypeIdentifiers

struct MobileDiscussionExportView: View {
    let reader: MobileReaderState
    let export: MobileDiscussionExport
    @State private var filename: String
    @State private var folder: MobileDiscussionExportFolder?
    @State private var showFolderPicker = false
    @State private var folderError: String?
    @Environment(\.dismiss) private var dismiss
    init(reader: MobileReaderState, export: MobileDiscussionExport) {
        self.reader = reader; self.export = export
        let base = (reader.title as NSString).deletingPathExtension
        _filename = State(initialValue: (base.isEmpty ? String(localized: "Document") : base) + " " + export.suffix + ".md")
    }
    private var leaf: String? {
        let name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { return nil }
        return (name as NSString).pathExtension.lowercased() == "md" ? name : name + ".md"
    }
    private var stale: Bool { !reader.matchesDiscussionVersion(export.version) || !reader.source.utf8.elementsEqual(export.source.utf8) }
    var body: some View {
        Form {
            Section {
                if export.kind == .clean { Text("This copy removes \(export.removedBlocks) saved discussion blocks.") }
                if export.kind == .savedCopy {
                    Text("Save a new Markdown file, then open it to continue your discussion. Unposted comments move only when you choose Open Copy and Move Drafts.")
                } else { Text("Unposted comments are not included.") }
                Text("Your original stays unchanged. Image files stay in their current folders.").foregroundStyle(.secondary)
            }
            if let result = reader.discussionExportResult {
                Section {
                    Label("Copy saved.", systemImage: "checkmark.circle")
                    Text(verbatim: result.url.lastPathComponent).textSelection(.enabled)
                    if result.reader != nil {
                        Button("Open Copy and Move Drafts", systemImage: "doc.badge.arrow.up") { reader.requestOpenDiscussionCopy(result.id) }
                            .frame(minHeight: 44).disabled(reader.fileSaving || stale)
                    }
                    ShareLink(item: result.url) { Label("Share…", systemImage: "square.and.arrow.up") }.frame(minHeight: 44)
                }
            } else {
                Section {
                    TextField("Filename", text: $filename).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button { showFolderPicker = true } label: {
                        Label(folder?.url.lastPathComponent ?? String(localized: "Choose Destination Folder…"), systemImage: "folder")
                    }.frame(minHeight: 44)
                    Text("Choose a new filename. Existing files are never replaced.").font(.footnote).foregroundStyle(.secondary)
                    Button("Create Copy") {
                        guard let folder, let leaf else { return }
                        reader.createDiscussionExport(export.id, at: folder.url.appendingPathComponent(leaf), folder: folder.url)
                    }.frame(minHeight: 44).disabled(folder == nil || leaf == nil || stale || reader.fileSaving)
                }.disabled(reader.fileSaving)
            }
            if stale { Section { Label("The document changed. Close this export and review the current version before trying again.", systemImage: "exclamationmark.triangle") } }
            if let error = folderError ?? reader.discussionError {
                Section { Label(error, systemImage: "exclamationmark.triangle").textSelection(.enabled) }
            }
            if reader.fileSaving { Section { ProgressView("Saving copy…") } }
        }
        .navigationTitle(export.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(reader.discussionExportResult == nil ? "Cancel" : "Done") {
                    guard reader.discussionExport?.id == export.id else { return }
                    reader.cancelDiscussionExport(export.id); dismiss()
                }.disabled(reader.fileSaving)
            }
        }
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            guard reader.discussionExport?.id == export.id else { return }
            switch result {
            case let .success(url): folder = MobileDiscussionExportFolder(url); folderError = nil
            case let .failure(error):
                if (error as? CocoaError)?.code != .userCancelled { folderError = error.localizedDescription }
            }
        }
    }
}

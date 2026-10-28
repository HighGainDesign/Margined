import SwiftUI

/// A deliberate, read-only comparison until the user confirms Import. The
/// session still validates the captured file identity and performs the write.
struct DiscussionImportView: View {
    @Bindable var reader: ReaderState
    let preview: DiscussionImportPreview
    @State private var choices: [String: DiscussionReconciliation.Choice] = [:]

    private var unresolved: Bool {
        preview.items.contains { $0.kind == .conflict && choices[$0.id] == nil }
    }
    private var hasChanges: Bool { preview.items.contains { $0.kind != .duplicate } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review Another Copy").font(.title2.bold())
            Text("Review comments and replies before importing. This document’s prose and the other file stay unchanged.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if !preview.incoming.diagnostics.isEmpty {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Some incoming discussions are unavailable", systemImage: "exclamationmark.triangle")
                                    .font(.headline)
                                Text("These blocks will not be imported. Inspect them in the other file’s source.")
                                ForEach(Array(preview.incoming.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                                    Text("Line \(diagnostic.line): \(diagnostic.message)").font(.callout)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                    }
                    if preview.items.isEmpty {
                        Text("No readable discussions were found in this copy.").foregroundStyle(.secondary)
                    }
                    ForEach(preview.items) { item in
                        DiscussionImportItemView(item: item, preview: preview,
                            choice: Binding(get: { choices[item.id] }, set: { choices[item.id] = $0 }))
                    }
                }.padding(2)
            }
            if let error = reader.discussionError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if unresolved {
                Text("Choose how to handle each conflict before importing.").font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Cancel") { reader.discardDiscussionImport() }
                    .keyboardShortcut(.cancelAction).disabled(reader.fileSaving)
                Spacer()
                if reader.fileSaving { ProgressView().controlSize(.small) }
                Button("Import Discussions") { reader.importDiscussions(choices: choices) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(unresolved || !hasChanges || reader.fileSaving || reader.isRendering || reader.hasPendingFileUpdate)
            }
        }
        .padding(24)
        .frame(minWidth: 600, idealWidth: 760, maxWidth: 860, minHeight: 420, idealHeight: 620, maxHeight: 780)
        .interactiveDismissDisabled(reader.fileSaving)
    }
}

private struct DiscussionImportItemView: View {
    let item: DiscussionImportPreview.Item
    let preview: DiscussionImportPreview
    @Binding var choice: DiscussionReconciliation.Choice?

    private var title: LocalizedStringKey {
        switch item.kind {
        case .newThread: "New Discussion"
        case .replies: "Additional Replies"
        case .duplicate: "Already in This Document"
        case .conflict: "Conflicting Discussion"
        }
    }
    private var unsafeIncoming: Bool {
        item.reasons.contains(.idCollision) || item.reasons.contains(.unavailableCurrent)
    }
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline)
                Text(verbatim: item.id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if item.kind == .conflict {
                    if item.reasons.contains(.rootChanged) { Text("Thread state, target or metadata differs.").font(.callout) }
                    if item.reasons.contains(.messageChanged) { Text("A shared message has different contents.").font(.callout) }
                    if unsafeIncoming {
                        Text("Identifiers conflict with another or unavailable discussion. Keep the current version or import a separately identified discussion.")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    if item.kind != .newThread {
                        VStack(alignment: .leading, spacing: 12) {
                            DiscussionImportVariant(title: "Current", document: preview.current, id: item.id)
                            if item.kind == .conflict { choiceButton("Keep Current", value: .keepCurrent) }
                        }.frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        DiscussionImportVariant(title: "Incoming", document: preview.incoming, id: item.id)
                        if item.kind == .conflict { choiceButton("Use Incoming", value: .useIncoming).disabled(unsafeIncoming) }
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                }
                if item.kind == .conflict {
                    choiceButton("Keep as Separate Discussion", value: .keepSeparate)
                    Text("Comments and replies found only in this document are kept. Separate discussions receive new identifiers.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if item.kind == .replies {
                    Text("Adds \(item.addedMessageIDs.count) replies. Existing messages keep their order.").font(.callout).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func choiceButton(_ title: LocalizedStringKey, value: DiscussionReconciliation.Choice) -> some View {
        HStack(spacing: 6) {
            Button(title) { choice = value }.buttonStyle(.bordered)
                .accessibilityValue(choice == value ? Text("Selected") : Text("Not selected"))
            if choice == value { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).accessibilityHidden(true) }
        }
    }
}

private struct DiscussionImportVariant: View {
    let title: LocalizedStringKey
    let document: DiscussionDocument
    let id: String
    @State private var showSource = false

    private var block: DiscussionBlock? { document.blocks.first { $0.thread?.id == id || $0.syntax?["id"]?.string == id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.bold())
            if let thread = block?.thread {
                Text(thread.state == .open ? "Open" : "Resolved").font(.caption).foregroundStyle(.secondary)
                if let section = thread.target.section { Text(verbatim: section).font(.caption).foregroundStyle(.secondary) }
                Text(verbatim: thread.target.exact).font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                ForEach(thread.messages, id: \.id) { message in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: message.author).font(.subheadline.bold())
                        Text(verbatim: message.created).font(.caption).foregroundStyle(.secondary)
                        if let reply = message.inReplyTo { Text("Reply to \(reply)").font(.caption).foregroundStyle(.secondary) }
                        Text(verbatim: message.body).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else { Text("Unavailable in this document. Inspect its source.").foregroundStyle(.secondary) }
            if let block {
                DisclosureGroup("Show Source", isExpanded: $showSource) {
                    if showSource {
                        Text(verbatim: String(decoding: Array(document.source.utf8)[block.range], as: UTF8.self))
                            .font(.system(.caption, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}

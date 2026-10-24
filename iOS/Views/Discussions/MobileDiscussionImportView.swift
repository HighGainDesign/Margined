import SwiftUI

struct MobileDiscussionImportView: View {
    let reader: MobileReaderState
    let review: MobileDiscussionImportReview
    @State private var choices: [String: DiscussionReconciliation.Choice] = [:]
    @Environment(\.dismiss) private var dismiss
    private var preview: DiscussionImportPreview { review.preview }
    private var unresolved: Bool { preview.items.contains { $0.kind == .conflict && choices[$0.id] == nil } }
    private var stale: Bool { !reader.matchesDiscussionVersion(review.version) }
    var body: some View {
        List {
            Section {
                Text("Review comments and replies before importing. This document’s prose and the other file stay unchanged.")
                    .foregroundStyle(.secondary)
                Text(verbatim: review.incomingName).font(.caption).foregroundStyle(.secondary)
            }
            if !preview.incoming.diagnostics.isEmpty {
                Section("Some incoming discussions are unavailable") {
                    Text("These blocks will not be imported. Inspect them in the other file’s source.")
                    ForEach(Array(preview.incoming.diagnostics.enumerated()), id: \.offset) { _, item in
                        Text("Line \(item.line): \(item.message)").font(.footnote).textSelection(.enabled)
                    }
                }
            }
            if preview.items.isEmpty { Text("No readable discussions were found in this copy.").foregroundStyle(.secondary) }
            ForEach(preview.items) { item in
                Section {
                    MobileDiscussionImportItem(item: item, preview: preview,
                        choice: Binding(get: { choices[item.id] }, set: { choices[item.id] = $0 }))
                }
            }
        }
        .navigationTitle("Review Another Copy").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if stale { Label("The document changed. Review the other copy again before importing.", systemImage: "exclamationmark.triangle") }
                else if let error = reader.discussionError { Label(error, systemImage: "exclamationmark.triangle") }
                if unresolved { Text("Choose how to handle each conflict before importing.").foregroundStyle(.secondary) }
                if reader.fileSaving { ProgressView("Saving discussions…") }
            }.font(.footnote).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    guard reader.discussionImportReview?.id == review.id else { return }
                    reader.cancelDiscussionImportReview(review.id); dismiss()
                }.disabled(reader.fileSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Import") { reader.confirmDiscussionImport(review.id, choices: choices) }
                    .disabled(unresolved || stale || !preview.items.contains { $0.kind != .duplicate } || !reader.canEditDiscussions)
            }
        }
    }
}

private struct MobileDiscussionImportItem: View {
    let item: DiscussionImportPreview.Item
    let preview: DiscussionImportPreview
    @Binding var choice: DiscussionReconciliation.Choice?
    private var unsafeIncoming: Bool { item.reasons.contains(.idCollision) || item.reasons.contains(.unavailableCurrent) }
    private var title: LocalizedStringKey {
        switch item.kind {
        case .newThread: "New Discussion"
        case .replies: "Additional Replies"
        case .duplicate: "Already in This Document"
        case .conflict: "Conflicting Discussion"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            if item.reasons.contains(.rootChanged) { Text("Thread state, target or metadata differs.").font(.callout) }
            if item.reasons.contains(.messageChanged) { Text("A shared message has different contents.").font(.callout) }
            if unsafeIncoming {
                Text("Identifiers conflict with another or unavailable discussion. Keep the current version or import a separately identified discussion.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if item.kind != .newThread { MobileDiscussionImportVariant(title: "Current", document: preview.current, id: item.id) }
            MobileDiscussionImportVariant(title: "Incoming", document: preview.incoming, id: item.id)
            if item.kind == .conflict {
                choiceButton("Keep Current", value: .keepCurrent)
                choiceButton("Use Incoming", value: .useIncoming).disabled(unsafeIncoming)
                choiceButton("Keep as Separate Discussion", value: .keepSeparate)
                Text("Comments and replies found only in this document are kept. Separate discussions receive new identifiers.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if item.kind == .replies {
                Text("Adds \(item.addedMessageIDs.count) replies. Existing messages keep their order.").font(.callout).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 8)
    }
    private func choiceButton(_ title: LocalizedStringKey, value: DiscussionReconciliation.Choice) -> some View {
        HStack {
            Button(title) { choice = value }.buttonStyle(.bordered).frame(minHeight: 44)
                .accessibilityValue(choice == value ? Text("Selected") : Text("Not selected"))
            if choice == value { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).accessibilityHidden(true) }
        }
    }
}

private struct MobileDiscussionImportVariant: View {
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
                Text(verbatim: thread.target.exact).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                ForEach(thread.messages, id: \.id) { message in
                    VStack(alignment: .leading, spacing: 5) {
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

struct MobileDiscussionFileActions: View {
    let reader: MobileReaderState
    var body: some View {
        Group {
            Button("Save Markdown Copy…", systemImage: "doc.badge.plus") { reader.requestDiscussionExport(.savedCopy) }
            Button("Save Markdown with Discussions…", systemImage: "doc.text") { reader.requestDiscussionExport(.markdown) }
            Button("Export Clean Copy…", systemImage: "doc") { reader.requestDiscussionExport(.clean) }
            Button("Export Conversations…", systemImage: "bubble.left.and.bubble.right") { reader.requestDiscussionExport(.conversation) }
            Button("Review Another Copy…", systemImage: "doc.on.doc") { reader.requestReviewAnotherCopy() }
        }
        .disabled(!reader.canEditDiscussions || reader.discussionImportLoading || reader.discussionCopyRequest != nil || reader.discussionSheet != nil)
    }
}

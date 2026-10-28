import SwiftUI

struct DiscussionComposer: View {
    let reader: ReaderState
    let key: DiscussionSession.DraftKey
    let isReply: Bool
    @FocusState private var focused: Bool

    private var bodyText: Binding<String> {
        Binding(get: { reader.discussions.drafts[key]?.body ?? "" },
                set: { reader.discussions.setDraft($0, for: key) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(reader.discussions.displayName.isEmpty
                 ? String(localized: "Your name will be stored with this comment.")
                 : String(localized: "Reply as \(reader.discussions.displayName)"))
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: bodyText)
                .font(.body).frame(minHeight: 96, maxHeight: 144)
                .padding(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .focused($focused)
                .accessibilityLabel(isReply ? "Reply" : "Comment")
                .accessibilityHint("Command-Return posts. Return starts a new line.")
            HStack {
                if reader.discussionSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button(isReply ? "Reply" : "Post") {
                    reader.discussions.selection = key
                    reader.postDiscussion()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(reader.fileSaving || reader.isRendering || bodyText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .task(id: reader.discussionComposerFocusGeneration) {
            guard reader.discussionComposerFocusGeneration > 0, reader.discussions.selection == key else { return }
            focused = true
        }
    }
}

struct DiscussionAuthorForm: View {
    let reader: ReaderState
    @State private var name = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a comment name").font(.headline)
            Text("This label is saved in the Markdown file. It is not a verified identity. Changing it later affects future messages only.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Your name", text: $name).textFieldStyle(.roundedBorder).focused($focused)
            HStack {
                Button("Cancel") { reader.cancelDiscussionAuthor() }
                Spacer()
                Button(reader.discussionAuthorButtonTitle) { reader.confirmDiscussionAuthor(name) }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .task { name = reader.discussions.displayName; focused = true }
    }
}

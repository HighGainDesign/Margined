import SwiftUI

struct DiscussionActionPrompts: View {
    let reader: ReaderState
    var body: some View {
        if reader.discussionReopenReply != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Reopen and post this reply?").font(.headline)
                Text("This discussion is resolved. Posting your reply reopens it and keeps every earlier message.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel") { reader.cancelDiscussionReopenReply() }
                    Spacer()
                    Button("Reopen and Reply") { reader.confirmDiscussionReopenReply() }.buttonStyle(.borderedProminent)
                }
            }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .disabled(reader.fileSaving)
        }
        if let decision = reader.discussionResolution {
            VStack(alignment: .leading, spacing: 10) {
                Text("Resolve with an unposted reply?").font(.headline)
                Text("Keep the discussion open, post your reply before resolving, or discard this draft and resolve.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Keep Open") { reader.confirmDiscussionResolution(.keepOpen) }
                Button("Post Reply and Resolve") { reader.confirmDiscussionResolution(.postDraft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(reader.discussions.drafts[.thread(decision.threadID)]?.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
                Button("Discard Draft and Resolve", role: .destructive) { reader.confirmDiscussionResolution(.discardDraft) }
            }
            .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .disabled(reader.fileSaving)
        }
        if let decision = reader.discussionReattachment {
            VStack(alignment: .leading, spacing: 10) {
                Text("Attach this discussion to a new passage?").font(.headline)
                quote("Previous passage", decision.originalTarget.exact)
                quote("New passage", decision.selection.target.exact)
                Text("The previous passage stays in the discussion’s history.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { reader.cancelDiscussionReattachment() }
                    Spacer()
                    Button("Attach to Selection") { reader.confirmDiscussionReattachment() }.buttonStyle(.borderedProminent)
                }
            }
            .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .disabled(reader.fileSaving)
        }
    }
    private func quote(_ title: LocalizedStringKey, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView { Text(verbatim: text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 100)
        }
    }
}

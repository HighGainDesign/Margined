import SwiftUI

/// Frozen semantic passages from the displayed document. Choosing one only
/// starts a draft or the existing reattachment comparison; it never writes.
struct DiscussionPassagePickerView: View {
    let reader: ReaderState
    let request: ReaderDiscussionPassagePicker
    @State private var query = ""
    @State private var selected: Int?
    @FocusState private var searching: Bool

    private var units: [DiscussionTextUnit] {
        guard !query.isEmpty else { return request.projection.units }
        return request.projection.units.filter {
            $0.text.localizedCaseInsensitiveContains(query) || ($0.section?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
    private var stale: Bool { !reader.matchesDiscussionVersion(request.request.version) || reader.hasPendingFileUpdate }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a Passage").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text(explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Find a passage", text: $query).textFieldStyle(.roundedBorder).focused($searching)
            List(selection: $selected) {
                ForEach(units, id: \.id) { unit in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(kind(unit)).font(.caption.weight(.medium))
                            if let section = unit.section { Text(verbatim: section).font(.caption).foregroundStyle(.secondary) }
                        }
                        Text(verbatim: unit.text).lineLimit(3)
                    }.padding(.vertical, 5).tag(unit.id).accessibilityElement(children: .combine)
                }
            }.accessibilityLabel("Document passages")
            if stale {
                Label("The document changed. Cancel and choose the passage again.", systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
            } else if let error = reader.discussionError {
                Label(error, systemImage: "exclamationmark.triangle").fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") { reader.cancelDiscussionPassage() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use Passage") { if let selected { reader.confirmDiscussionPassage(selected) } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(selected == nil || stale || reader.isRendering || reader.fileSaving)
            }
        }
        .padding(24).frame(minWidth: 420, idealWidth: 560, maxWidth: 680, minHeight: 360, idealHeight: 520)
        .task { searching = true }
        .onChange(of: query) { if let selected, !units.contains(where: { $0.id == selected }) { self.selected = nil } }
    }
    private var explanation: String {
        switch request.request.intent {
        case .add: String(localized: "Choose the text to discuss. Your comment stays unposted until you choose Post.")
        case .reattach: String(localized: "Choose replacement text. You will compare the old and new passages before attaching.")
        }
    }
    private func kind(_ unit: DiscussionTextUnit) -> String {
        switch unit.kind {
        case "h1", "h2", "h3", "h4", "h5", "h6": String(localized: "Heading")
        case "li": String(localized: "List item")
        case "pre": String(localized: "Code block")
        case "td", "th": String(localized: "Table cell")
        default: String(localized: "Passage")
        }
    }
}

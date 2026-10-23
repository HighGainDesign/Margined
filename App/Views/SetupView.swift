import SwiftUI

struct SetupView: View {
    @Bindable var session: SetupSession
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Make Margined part of your workflow").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text("Two optional ways to preview your Markdown.").foregroundStyle(.secondary)
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    IntegrationHeading(title: String(localized: "Finder Quick Look"), symbol: "doc.viewfinder",
                                       subtitle: String(localized: "Preview files without opening a document window."))
                    QuickLookInstructions()
                    ViewThatFits(in: .horizontal) {
                        HStack { quickLookAction.fixedSize(); Spacer(minLength: 12); quickLookNote.fixedSize() }
                        VStack(alignment: .leading, spacing: 8) { quickLookAction; quickLookNote }
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    IntegrationHeading(title: String(localized: "Drafts"), symbol: "square.and.pencil",
                                       subtitle: String(localized: "Add Preview in Margined to view a draft without changing it."))
                    ViewThatFits(in: .horizontal) {
                        HStack { draftsAction.fixedSize(); Spacer(minLength: 12); draftsNote.fixedSize() }
                        VStack(alignment: .leading, spacing: 8) { draftsAction; draftsNote }
                    }
                    if let status = session.draftsStatus {
                        Text(status).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("You can return to these options in Margined Settings.")
                .font(.callout).foregroundStyle(.secondary)
                    Text("Read Aloud controls are in every document’s toolbar.")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack { suppression; Spacer(minLength: 16); doneButton }
                VStack(alignment: .leading, spacing: 12) { suppression; HStack { Spacer(); doneButton } }
            }.padding(20).background(.bar)
        }
        .frame(minWidth: 520, minHeight: 440)
    }
    private var quickLookAction: some View {
        Button { session.openQuickLookSettings() } label: {
            Text("Open Extension Settings…").fixedSize(horizontal: false, vertical: true)
        }
    }
    private var quickLookNote: some View { Text("Enable once").font(.caption).foregroundStyle(.secondary) }
    private var draftsAction: some View {
        Button { Task { await session.installDraftsAction() } } label: {
            Text("Install Drafts Action…").fixedSize(horizontal: false, vertical: true)
        }.disabled(!session.draftsAvailable || session.installingDrafts)
    }
    private var draftsNote: some View {
        Text(session.draftsAvailable ? "Drafts detected" : "Drafts isn’t installed").font(.caption).foregroundStyle(.secondary)
    }
    private var suppression: some View { Toggle("Don’t show again", isOn: $session.dontShowAgain).toggleStyle(.checkbox) }
    private var doneButton: some View {
        Button("Done", action: done).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
    }
}

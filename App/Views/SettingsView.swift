import SwiftUI
import Observation

@MainActor @Observable
final class SettingsNavigation {
    enum Page: Hashable { case reading, speech, content, integrations }
    static let shared = SettingsNavigation()
    var page = Page.reading
}

struct SettingsView: View {
    @AppStorage("wideLayout") private var wideLayout = true
    @AppStorage(ReaderPreferences.appearanceKey, store: ReaderPreferences.defaults) private var documentAppearance = DocumentAppearance.system
    @State private var integration = SetupSession()
    @Bindable private var navigation = SettingsNavigation.shared

    var body: some View {
        TabView(selection: $navigation.page) {
            reading.tabItem { Label("Reading", systemImage: "book") }.tag(SettingsNavigation.Page.reading)
            ZStack {
                if navigation.page == .speech { SpeechSettingsView() }
            }.tabItem { Label("Read Aloud", systemImage: "headphones") }.tag(SettingsNavigation.Page.speech)
            content.tabItem { Label("Content", systemImage: "doc.richtext") }.tag(SettingsNavigation.Page.content)
            integrations.tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }.tag(SettingsNavigation.Page.integrations)
        }
        .padding(.top, 10)
        .frame(minWidth: 580, idealWidth: 620, minHeight: 500, idealHeight: 680)
    }
    private var reading: some View {
        Form {
            Section {
                Picker("Document appearance", selection: $documentAppearance) {
                    ForEach(DocumentAppearance.allCases, id: \.self) { appearance in Text(appearance.title).tag(appearance) }
                }.pickerStyle(.segmented)
                Toggle("Full width by default", isOn: $wideLayout)
            } header: { Text("Reading") }
            footer: {
                Text("Appearance updates all open documents and new Finder Quick Look previews. Width is the default for every document you open; use the Reading width button to change an individual window.")
            }
        }.formStyle(.grouped)
    }
    private var content: some View {
        Form {
            Section("Document content") {
                #if MARGINED_APP_STORE
                PolicyRow(String(localized: "Local images"), value: String(localized: "Folder access"), help: String(localized: "Choose image folders in a document’s Reading options when macOS blocks access. Margined remembers the folders you select. Finder Quick Look has separate file access."))
                #else
                PolicyRow(String(localized: "Local images"), value: String(localized: "Automatic"), help: String(localized: "Local images load automatically from relative paths, absolute paths, file URLs and symlinks wherever macOS allows access. Margined does not require image-folder grants. Image formats are handled by WebKit. Quick Look supports embedded data images only."))
                #endif
                PolicyRow(String(localized: "Remote images"), value: String(localized: "Off by default"), help: String(localized: "In a document’s Reading options (…) choose Load Remote Images to allow HTTPS images for that window. Hosts can see your IP address and image requests. Margined sends no document referrer. The choice resets on closing; Quick Look never loads remote images."))
                PolicyRow(String(localized: "Embedded HTML"), value: String(localized: "Sanitized formatting"), help: String(localized: "Safe HTML formatting and image width/height are supported. Scripts, interactive controls and embedded websites are blocked. Remote images still require this document’s opt-in."))
            }
        }.formStyle(.grouped)
    }
    private var integrations: some View {
        Form {
            Section("Live streaming") {
                IntegrationHeading(title: String(localized: "Live streaming"), symbol: "dot.radiowaves.left.and.right",
                                   subtitle: String(localized: "Follow an editor’s Marked-compatible preview stream."))
                Button("Open Live Preview") { (NSApp.delegate as? AppDelegate)?.showLiveStreamingPreview() }
            }
            Section("Finder Quick Look") {
                IntegrationHeading(title: String(localized: "Finder Quick Look"), symbol: "doc.viewfinder",
                                   subtitle: String(localized: "Preview Markdown in Finder with the Space bar."))
                Button("Open Extension Settings…") { integration.openQuickLookSettings() }
                    .help("Choose By Category → Quick Look, then enable Margined. Another enabled Markdown previewer may take priority.")
            }
            Section("Drafts") {
                IntegrationHeading(title: String(localized: "Drafts"), symbol: "square.and.pencil",
                                   subtitle: String(localized: "Preview the current draft without changing it."))
                Button("Install Drafts Action…") { Task { await integration.installDraftsAction() } }
                    .disabled(!integration.draftsAvailable || integration.installingDrafts)
                if !integration.draftsAvailable { Text("Drafts isn’t installed").font(.caption).foregroundStyle(.secondary) }
                if let status = integration.draftsStatus { Text(status).font(.callout).foregroundStyle(.secondary) }
            }
            Section { Button("Show Setup Guide…") { (NSApp.delegate as? AppDelegate)?.showStartupTips(force: true) } }
        }.formStyle(.grouped)
    }
}

private struct PolicyRow: View {
    let title: String
    let value: String
    let explanation: String
    @State private var showingHelp = false

    init(_ title: String, value: String, help: String) {
        self.title = title
        self.value = value
        explanation = help
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
            Button { showingHelp.toggle() } label: {
                Image(systemName: "info.circle").frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("About \(title)")
                .help(explanation)
                .popover(isPresented: $showingHelp, arrowEdge: .trailing) {
                    Text(explanation).font(.callout).padding(16).frame(width: 320)
                        .fixedSize(horizontal: false, vertical: true)
                }
        }.help(explanation)
    }
}

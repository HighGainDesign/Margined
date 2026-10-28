import SwiftUI

struct SetupView: View {
    @Bindable var session: SetupSession
    let done: () -> Void
    var tutorial = TutorialSession()
    var openPractice: (TutorialLesson) -> Void = { (NSApp.delegate as? AppDelegate)?.openTutorialPractice($0) }

    var body: some View {
        TutorialGuide(session: tutorial, done: done, openPractice: openPractice) { lesson in
            switch lesson {
            case .quickLook:
                VStack(alignment: .leading, spacing: 14) {
                    QuickLookInstructions()
                    Button("Open Extension Settings…") { session.openQuickLookSettings() }
                }
            case .streaming:
                VStack(alignment: .leading, spacing: 14) {
                    Button("Live Streaming Preview") { (NSApp.delegate as? AppDelegate)?.showLiveStreamingPreview() }
                    Button("Install Drafts Action…") { Task { await session.installDraftsAction() } }
                        .disabled(!session.draftsAvailable || session.installingDrafts)
                    if let status = session.draftsStatus { Text(status).foregroundStyle(.secondary) }
                }
            case .images:
                Button("Settings…") { (NSApp.delegate as? AppDelegate)?.openSettings() }
            default: EmptyView()
            }
        } footer: {
            Toggle("Don’t show again", isOn: $session.dontShowAgain)
        }
            .frame(minWidth: 520, minHeight: 440)
    }
}

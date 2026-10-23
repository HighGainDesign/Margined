import Foundation
import Observation

@MainActor @Observable
final class SetupSession {
    var dontShowAgain: Bool
    var installingDrafts = false
    var draftsStatus: String?
    let draftsAvailable: Bool
    private let defaults: UserDefaults
    private let openExtensions: @MainActor () -> Void
    private let importDrafts: @MainActor () async throws -> Void

    init(defaults: UserDefaults = .standard, draftsAvailable: Bool = DraftsIntegration.isAvailable,
         openExtensions: @escaping @MainActor () -> Void = QuickLookSettings.open,
         importDrafts: @escaping @MainActor () async throws -> Void = DraftsIntegration.installAction) {
        self.defaults = defaults
        self.draftsAvailable = draftsAvailable
        self.openExtensions = openExtensions
        self.importDrafts = importDrafts
        dontShowAgain = defaults.object(forKey: "hideStartupTips") as? Bool ?? true
    }

    func openQuickLookSettings() { openExtensions() }

    func installDraftsAction() async {
        guard draftsAvailable, !installingDrafts else { return }
        installingDrafts = true
        defer { installingDrafts = false }
        do {
            try await importDrafts()
            draftsStatus = String(localized: "Finish importing Preview in Margined in Drafts.")
        } catch {
            draftsStatus = error.localizedDescription
        }
    }

    func finish() { StartupTips.finish(dontShowAgain: dontShowAgain, defaults: defaults) }
}

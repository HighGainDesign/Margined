import AppKit

@MainActor
enum DraftsIntegration {
    private static let applicationID = "com.agiletortoise.Drafts-OSX"
    static var isAvailable: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: applicationID) != nil
    }

    static func installAction() async throws {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: applicationID) else {
            throw InstallError.draftsNotInstalled
        }
        guard let action = Bundle.main.url(forResource: "Preview in Margined", withExtension: "draftsAction") else {
            throw InstallError.actionNotBundled
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([action], withApplicationAt: application, configuration: configuration)
    }

    private enum InstallError: LocalizedError {
        case draftsNotInstalled, actionNotBundled
        var errorDescription: String? {
            switch self {
            case .draftsNotInstalled: String(localized: "Install Drafts before importing the Margined preview action.")
            case .actionNotBundled: String(localized: "The Drafts action is missing from this Margined build.")
            }
        }
    }
}

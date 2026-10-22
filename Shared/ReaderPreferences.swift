import Foundation

enum ReaderPreferences {
    // Team-prefixed groups need no provisioning profile for Developer ID macOS apps.
    static let groupIdentifier = "UX8BPNLPX5.design.highgain.mdview"
    static let appearanceKey = "documentAppearance"

    static var defaults: UserDefaults {
        #if DEBUG
        // Ad-hoc XCTest hosts have no team identity. Keep tests out of the user's
        // group container; signed Finder integration is verified separately.
        if ProcessInfo.processInfo.environment["MDVIEW_TEST_PREFERENCES"] == "1" {
            return UserDefaults(suiteName: "MDViewTests.ReaderPreferences.\(ProcessInfo.processInfo.processIdentifier)")!
        }
        #endif
        #if os(iOS)
        return UserDefaults.standard
        #else
        return UserDefaults(suiteName: groupIdentifier)!
        #endif
    }

    static func appearance(in defaults: UserDefaults) -> DocumentAppearance {
        defaults.string(forKey: appearanceKey).flatMap(DocumentAppearance.init(rawValue:)) ?? .system
    }

    static func migrateAppearance(from legacy: UserDefaults, to shared: UserDefaults) {
        guard shared.object(forKey: appearanceKey) == nil else { return }
        shared.set(appearance(in: legacy).rawValue, forKey: appearanceKey)
    }
}

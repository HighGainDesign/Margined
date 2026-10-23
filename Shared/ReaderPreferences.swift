import Foundation

enum ReaderPreferences {
    #if os(iOS)
    // The iOS app and preview extension share a provisioned mobile App Group.
    static let groupIdentifier = "group.design.highgain.margined"
    #else
    // Team-prefixed groups need no provisioning profile for Developer ID macOS apps.
    static let groupIdentifier = "UX8BPNLPX5.design.highgain.margined"
    #endif
    static let appearanceKey = "documentAppearance"

    static var defaults: UserDefaults {
        #if DEBUG
        // Ad-hoc XCTest hosts have no team identity. Keep tests out of the user's
        // group container; signed Finder integration is verified separately.
        if ProcessInfo.processInfo.environment["MARGINED_TEST_PREFERENCES"] == "1" {
            return UserDefaults(suiteName: "MarginedTests.ReaderPreferences.\(ProcessInfo.processInfo.processIdentifier)")!
        }
        #endif
        return UserDefaults(suiteName: groupIdentifier)!
    }

    static func appearance(in defaults: UserDefaults) -> DocumentAppearance {
        defaults.string(forKey: appearanceKey).flatMap(DocumentAppearance.init(rawValue:)) ?? .system
    }

}

import AppKit
import XCTest

/// XCTest launches its app without a user activation event. Ask Launch Services
/// to activate that exact running test host, never another installed copy.
@MainActor
func activateNativeTestApplication() async throws {
    guard !NSApp.isActive else { return }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.promptsUserIfNeeded = false
    configuration.addsToRecentItems = false
    configuration.allowsRunningApplicationSubstitution = false
    let application = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
    XCTAssertEqual(application.processIdentifier, ProcessInfo.processInfo.processIdentifier,
                   "Activate only this test host; never substitute the installed app")
    guard application.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
        throw CocoaError(.executableRuntimeMismatch)
    }
    for _ in 0..<100 {
        if NSApp.isActive { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Launch Services did not activate the native test host")
}

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

/// AX children are opaque objects; a SwiftUI accessibility proxy need not be an
/// NSObject subclass. Use selector availability and retain cycle protection.
@MainActor
func nativeTestButton(named names: [String], in root: Any, diagnose: Bool = false) -> AnyObject? {
    var visited: Set<ObjectIdentifier> = []
    var count = 0
    func walk(_ item: Any) -> AnyObject? {
        let element = item as AnyObject
        guard visited.insert(ObjectIdentifier(element)).inserted else { return nil }
        let role = element.accessibilityRole?() ?? .unknown
        let labels = [element.accessibilityLabel?(), element.accessibilityTitle?()].compactMap { $0 }
        let children = element.accessibilityChildren?() ?? []
        if diagnose, count < 150 {
            print("NATIVE-AX type=\(type(of: item)) NSObject=\(item is NSObject) role=\(role) names=\(labels) children=\(children.count) frame=\(String(describing: element.accessibilityFrame?()))")
            count += 1
        }
        if [.button, .link].contains(role), labels.contains(where: names.contains) {
            if !(item is NSObject) { print("NATIVE-AX-MATCH type=\(type(of: item)) names=\(labels) NSObject=false") }
            return element
        }
        for child in children { if let found = walk(child) { return found } }
        for child in (item as? NSView)?.subviews ?? [] { if let found = walk(child) { return found } }
        return nil
    }
    return walk(root)
}

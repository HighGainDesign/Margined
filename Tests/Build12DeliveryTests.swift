import AppKit
import SwiftUI
import XCTest
@testable import Margined

/// Exercises the native launch/tutorial surfaces before distributing a beta.
/// An external capture runner may opt into exact-window images; normal tests
/// never request screen-recording access or spawn a capture process.
@MainActor
final class Build12DeliveryTests: XCTestCase {
    func testWelcomeActionsAndGuideDefaultKeyboardAction() async throws {
        try await activateNativeTestApplication()
        let captureRoot = URL(fileURLWithPath: "/private/tmp/Margined-build12-visual", isDirectory: true)
        for (label, width, height, appearance) in [
            ("welcome-light", 840.0, 560.0, NSAppearance.Name.aqua),
            ("welcome-dark", 840.0, 560.0, NSAppearance.Name.darkAqua),
            ("welcome-compact", 480.0, 380.0, NSAppearance.Name.aqua)
        ] {
            let host = NSHostingController(rootView: WelcomeView(recentDocuments: [
                URL(fileURLWithPath: "/Users/demo/Documents/Product Brief.md"),
                URL(fileURLWithPath: "/Users/demo/Documents/Launch Checklist.md")
            ], open: {}, liveStreaming: {}, openRecent: { _ in }, tour: {}))
            let window = NSWindow(contentViewController: host)
            window.isReleasedWhenClosed = false
            window.styleMask = [.titled, .closable, .resizable]
            window.title = "Margined QA — " + label
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(NSSize(width: width, height: height))
            window.center(); window.makeKeyAndOrderFront(nil)
            for _ in 0..<20 { host.view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            for name in ["Open Markdown…", "Live Streaming Preview", "Take a Tour"] {
                if button(named: name, in: host.view) == nil {
                    _ = nativeTestButton(named: [name], in: window, diagnose: true)
                }
                XCTAssertNotNil(button(named: name, in: host.view), "Native launch action must remain accessible: \(name)")
            }
            try await captureIfRequested(window, label: label, root: captureRoot)
            window.close()
        }
        let suite = "MarginedTests.Build12Guide." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let setup = SetupSession(defaults: defaults, draftsAvailable: true, openExtensions: {}, importDrafts: {})
        setup.dontShowAgain = false
        let tutorial = TutorialSession(platform: .mac)
        tutorial.selection = .changes
        let controller = SetupWindowController(session: setup, tutorial: tutorial)
        defer { controller.close() }
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        for (label, width, height, appearance) in [
            ("guide-light", 860.0, 620.0, NSAppearance.Name.aqua),
            ("guide-dark", 860.0, 620.0, NSAppearance.Name.darkAqua),
            ("guide-compact", 520.0, 480.0, NSAppearance.Name.aqua)
        ] {
            window.title = "Margined QA — " + label
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(NSSize(width: width, height: height))
            window.makeKeyAndOrderFront(nil)
            for _ in 0..<20 { window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            let content = try XCTUnwrap(window.contentView)
            if button(named: "Done", in: content) == nil { _ = nativeTestButton(named: ["Done"], in: window, diagnose: true) }
            XCTAssertNotNil(button(named: "Done", in: content))
            try await captureIfRequested(window, label: label, root: captureRoot)
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        NSApp.sendEvent(enter)
        for _ in 0..<100 where window.isVisible { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(window.isVisible, "Return must activate the tutorial's native default Done action")
        XCTAssertTrue(StartupTips.shouldShow(defaults: defaults), "Closing must honor the user's unchanged suppression choice")
    }

    private func captureIfRequested(_ window: NSWindow, label: String, root: URL) async throws {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("enabled").path) else { return }
        let request = ["label": label, "window": String(window.windowNumber), "pid": String(ProcessInfo.processInfo.processIdentifier)]
        try JSONSerialization.data(withJSONObject: request).write(to: root.appendingPathComponent("request.json"), options: .atomic)
        for _ in 0..<160 {
            if let data = try? Data(contentsOf: root.appendingPathComponent("response.json")),
               let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any], response["label"] as? String == label {
                XCTAssertEqual(response["exit"] as? Int, 0, "External exact-window capture failed: \(response)")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("External capture runner did not acknowledge the owned QA window: \(label)")
    }

    private func button(named name: String, in root: NSView) -> AnyObject? {
        nativeTestButton(named: [name], in: root)
    }
}

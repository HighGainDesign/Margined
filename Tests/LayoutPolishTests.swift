import AppKit
import SwiftUI
import XCTest
@testable import Margined

@MainActor
final class LayoutPolishTests: XCTestCase {
    func testSetupFitsACompactWindowWithoutHorizontalOverflow() async throws {
        let name = "MarginedTests.SetupLayout.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let session = SetupSession(defaults: defaults, draftsAvailable: true, openExtensions: {}, importDrafts: {})
        let controller = SetupWindowController(session: session)
        controller.showWindow(nil); defer { controller.close() }
        let window = try XCTUnwrap(controller.window), view = try XCTUnwrap(window.contentView)
        window.setContentSize(NSSize(width: 520, height: 480))
        for _ in 0..<20 { view.layoutSubtreeIfNeeded(); await Task.yield() }
        XCTAssertEqual(view.bounds.width, 520, accuracy: 1)
        try assertScrollFits(view)

    }

    func testTranslatedSetupAndSettingsUseTheirAllocatedWindowBounds() async throws {
        let original = SettingsNavigation.shared.page
        defer { SettingsNavigation.shared.page = original }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Margined-1.5-layout", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for language in ["en", "es", "zh-Hans", "zh-Hant", "ja", "fr", "de"] {
            let session = SetupSession(draftsAvailable: true, openExtensions: {}, importDrafts: {})
            let setup = NSHostingController(rootView: SetupView(session: session, done: {}).environment(\.locale, Locale(identifier: language)))
            let window = NSWindow(contentViewController: setup)
            window.isReleasedWhenClosed = false; window.setContentSize(NSSize(width: 520, height: 480)); window.orderFront(nil)
            for _ in 0..<10 { setup.view.layoutSubtreeIfNeeded(); await Task.yield() }
            XCTAssertEqual(setup.view.bounds.width, 520, accuracy: 1, language)
            try assertScrollFits(setup.view)
            try capture(setup.view, at: directory.appendingPathComponent("setup-" + language + ".png"))
            window.close()
            let welcome = NSHostingController(rootView: WelcomeView(recentDocuments: [
                URL(fileURLWithPath: "/Users/demo/Documents/Product Brief.md"),
                URL(fileURLWithPath: "/Users/demo/Documents/Launch Checklist.md")], open: {}, liveStreaming: {}, openRecent: { _ in }, tour: {})
                .environment(\.locale, Locale(identifier: language)))
            let welcomeWindow = NSWindow(contentViewController: welcome)
            welcomeWindow.isReleasedWhenClosed = false; welcomeWindow.setContentSize(NSSize(width: 840, height: 560)); welcomeWindow.orderFront(nil)
            for _ in 0..<10 { welcome.view.layoutSubtreeIfNeeded(); await Task.yield() }
            try assertScrollFits(welcome.view)
            try capture(welcome.view, at: directory.appendingPathComponent("welcome-" + language + ".png"))
            welcomeWindow.close()
            let settings = NSHostingController(rootView: SettingsView().environment(\.locale, Locale(identifier: language)))
            let settingsWindow = NSWindow(contentViewController: settings)
            settingsWindow.isReleasedWhenClosed = false; settingsWindow.setContentSize(NSSize(width: 620, height: 680)); settingsWindow.orderFront(nil)
            for page in [SettingsNavigation.Page.reading, .speech, .content, .integrations] {
                SettingsNavigation.shared.page = page
                for _ in 0..<10 { settings.view.layoutSubtreeIfNeeded(); await Task.yield() }
                XCTAssertEqual(settings.view.bounds.width, 620, accuracy: 1)
                // The window server may clamp a tall request on smaller displays.
                XCTAssertGreaterThanOrEqual(settings.view.bounds.height, 500)
                XCTAssertEqual(settings.view.bounds.height, settingsWindow.contentLayoutRect.height, accuracy: 1)
                try capture(settings.view, at: directory.appendingPathComponent("settings-\(page)-\(language).png"))
            }
            settingsWindow.close()
        }
    }

    func testAllSettingsTabsRemainAvailableBeforeSpeechIsSelected() async throws {
        let original = SettingsNavigation.shared.page
        SettingsNavigation.shared.page = .reading
        defer { SettingsNavigation.shared.page = original }
        let host = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false; window.setContentSize(NSSize(width: 620, height: 680)); window.orderFront(nil)
        defer { window.close() }
        func find(_ view: NSView) -> NSTabView? {
            if let tabs = view as? NSTabView { return tabs }
            for child in view.subviews { if let tabs = find(child) { return tabs } }
            return nil
        }
        var tabs: NSTabView?
        for _ in 0..<100 {
            host.view.layoutSubtreeIfNeeded(); tabs = find(host.view)
            if tabs != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try XCTUnwrap(tabs).numberOfTabViewItems, 4,
                       "Read Aloud must be a selectable tab before it has ever been opened")
    }

    private func assertScrollFits(_ view: NSView) throws {
        var scrolls: [NSScrollView] = []
        func visit(_ node: NSView) {
            if let scroll = node as? NSScrollView { scrolls.append(scroll) }
            for child in node.subviews { visit(child) }
        }
        visit(view)
        let scroll = try XCTUnwrap(scrolls.first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertLessThanOrEqual(document.bounds.width, scroll.contentView.bounds.width + 1,
                                 "Setup content must scroll vertically without horizontal clipping")
    }

    private func capture(_ view: NSView, at url: URL) throws {
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
    }

}

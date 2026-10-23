import AppKit
import WebKit
import XCTest
@testable import Margined

final class SetupTests: XCTestCase {
    @MainActor
    func testIntegrationActionsKeepGuideOpenAndDoNotSuppressIt() async throws {
        let suite = "MarginedTests.Setup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var openedSettings = 0
        var importedDrafts = 0
        let session = SetupSession(defaults: defaults, draftsAvailable: true,
                                   openExtensions: { openedSettings += 1 },
                                   importDrafts: { importedDrafts += 1 })
        let controller = SetupWindowController(session: session)
        controller.showWindow(nil)
        defer { controller.close() }
        session.openQuickLookSettings()
        XCTAssertEqual(openedSettings, 1)
        XCTAssertTrue(controller.window?.isVisible == true)
        XCTAssertTrue(StartupTips.shouldShow(defaults: defaults))
        await session.installDraftsAction()
        XCTAssertEqual(importedDrafts, 1)
        XCTAssertTrue(controller.window?.isVisible == true)
        XCTAssertTrue(StartupTips.shouldShow(defaults: defaults))
        XCTAssertNotNil(session.draftsStatus)
        controller.close()
        XCTAssertFalse(StartupTips.shouldShow(defaults: defaults))
    }

    @MainActor
    func testGuideCanBeClosedWithoutSuppressingAndImportFailureAllowsRetry() async throws {
        let suite = "MarginedTests.SetupRetry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        enum Failure: Error { case cancelled }
        var attempts = 0
        let session = SetupSession(defaults: defaults, draftsAvailable: true, openExtensions: {},
                                   importDrafts: { attempts += 1; if attempts == 1 { throw Failure.cancelled } })
        session.dontShowAgain = false
        let controller = SetupWindowController(session: session)
        controller.showWindow(nil)
        await session.installDraftsAction()
        XCTAssertFalse(session.installingDrafts)
        XCTAssertTrue(controller.window?.isVisible == true)
        await session.installDraftsAction()
        XCTAssertEqual(attempts, 2)
        controller.close()
        XCTAssertTrue(StartupTips.shouldShow(defaults: defaults))
    }

    @MainActor
    func testForcedDocumentColorsOverrideOppositeHostAppearanceInWebKit() async throws {
        for (appearance, host, expectedPaper, expectedHighlight) in [
            (DocumentAppearance.light, NSAppearance.Name.darkAqua, "rgb(255, 255, 255)", "rgb(255, 227, 154)"),
            (DocumentAppearance.dark, NSAppearance.Name.aqua, "rgb(29, 31, 35)", "rgb(119, 83, 25)")
        ] {
            let rendered = try await MarkdownRenderer.shared.render("Changed blue word.", baseline: "Changed red word.", appearance: appearance)
            let reader = ReaderState()
            let coordinator = MarkdownWebView.Coordinator(reader: reader)
            let view = WKWebView(frame: .zero)
            view.appearance = NSAppearance(named: host)
            view.navigationDelegate = coordinator
            coordinator.webView = view
            coordinator.load(rendered.html)
            for _ in 0..<100 where view.isLoading || view.url == nil {
                try await Task.sleep(for: .milliseconds(50))
            }
            let paper = try await view.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") as? String
            let highlight = try await view.evaluateJavaScript("getComputedStyle(document.querySelector('.margined-word-change')).backgroundColor") as? String
            XCTAssertEqual(paper, expectedPaper)
            XCTAssertEqual(highlight, expectedHighlight)
        }
        let system = try await MarkdownRenderer.shared.render("System")
        XCTAssertTrue(system.html.contains("data-appearance=\"system\""))
        XCTAssertTrue(system.html.contains("name=\"color-scheme\" content=\"light dark\""))
    }
}

import SwiftUI
import UIKit
import XCTest
import WebKit
@testable import MarginediOS

@MainActor
final class MobileDocumentBrowserTests: XCTestCase {
    func testHomePresentsTheNativeFilesBrowser() async throws {
        let defaults = ReaderPreferences.defaults
        let previous = defaults.object(forKey: "mobileSetupGuideSeen")
        defaults.set(true, forKey: "mobileSetupGuideSeen")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: MobileRootView(playback: MobilePlaybackOwner(), imageFolders: MobileImageFolders()))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil
            defaults.set(previous, forKey: "mobileSetupGuideSeen")
        }
        for _ in 0..<150 {
            if browser(in: host) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(browser(in: host), "The home screen must host Apple's real browser for provider locations, Recents, search and grid/list controls")
    }

    func testNativeSelectionReturnsToTheBrowserAndPreservesUnpostedReplies() async throws {
        let defaults = ReaderPreferences.defaults
        let previous = defaults.object(forKey: "mobileSetupGuideSeen")
        defaults.set(true, forKey: "mobileSetupGuideSeen")
        let playback = MobilePlaybackOwner()
        let reader = MobileReaderState(playback: playback)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: MobileRootView(playback: playback, imageFolders: MobileImageFolders(), reader: reader))
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = folder.appendingPathComponent("First.md"), second = folder.appendingPathComponent("Second.md")
        let original = Data("# First native document\n\nA passage to discuss.\n".utf8)
        try original.write(to: first); try Data("# Second native document\n".utf8).write(to: second)
        defer {
            window.isHidden = true; window.rootViewController = nil
            defaults.set(previous, forKey: "mobileSetupGuideSeen")
            try? FileManager.default.removeItem(at: folder)
        }
        let mounted = await poll { self.browser(in: host)?.delegate != nil }; XCTAssertTrue(mounted, "The native browser must finish connecting its selection delegate")
        let firstBrowser = try XCTUnwrap(browser(in: host))
        firstBrowser.delegate?.documentBrowser?(firstBrowser, didPickDocumentsAt: [first])
        let opened = await poll { reader.fileURL == first && reader.hasDocument && self.web(in: host.view)?.isLoading == false }
        XCTAssertTrue(opened, "Exercise the actual native browser delegate; hasDocument=\(reader.hasDocument), opening=\(reader.isOpening), URL=\(String(describing: reader.fileURL)), error=\(String(describing: reader.errorMessage)), presented=\(String(describing: host.presentedViewController))")
        guard opened else { return }
        let web = try XCTUnwrap(web(in: host.view))
        let loaded = await pollAsync { try await web.evaluateJavaScript("document.querySelector('h1')?.textContent === 'First native document'") as? Bool == true }
        XCTAssertTrue(loaded)
        reader.discussions.setDraft("Keep this unposted reply.", for: .new(UUID()))
        await reader.close()
        XCTAssertTrue(reader.hasDocument)
        XCTAssertTrue(reader.showDraftDiscardConfirmation)
        let dialog = await poll { self.containsAlert(in: host) }
        XCTAssertTrue(dialog, "A native browser transition must not swallow the existing discard confirmation")
        reader.cancelDocumentTransition(); reader.discussions.discardDrafts()
        await reader.close()
        let returned = await poll { self.browser(in: host)?.view.window != nil }; XCTAssertTrue(returned)
        let nextBrowser = try XCTUnwrap(browser(in: host))
        nextBrowser.delegate?.documentBrowser?(nextBrowser, didPickDocumentsAt: [second])
        let secondOpened = await poll { reader.fileURL == second && reader.hasDocument && reader.rendered != nil }
        XCTAssertTrue(secondOpened)
        XCTAssertEqual(try Data(contentsOf: first), original)
        await reader.close()
    }

    func testAFailedNativeOpenLeavesTheBrowserUsable() async throws {
        let defaults = ReaderPreferences.defaults, previous = defaults.object(forKey: "mobileSetupGuideSeen")
        defaults.set(true, forKey: "mobileSetupGuideSeen")
        let playback = MobilePlaybackOwner()
        let reader = MobileReaderState(playback: playback)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: MobileRootView(playback: playback, imageFolders: MobileImageFolders(), reader: reader))
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; defaults.set(previous, forKey: "mobileSetupGuideSeen") }
        let mounted = await poll { self.browser(in: host)?.delegate != nil }; XCTAssertTrue(mounted, "The native browser must finish connecting its selection delegate")
        let browser = try XCTUnwrap(browser(in: host))
        // A missing URL is rejected by Files before it invokes the app. Use an
        // existing document whose invalid UTF-8 exercises the reader's failure.
        let invalid = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data([0xC3, 0x28]).write(to: invalid)
        defer { try? FileManager.default.removeItem(at: invalid) }
        browser.delegate?.documentBrowser?(browser, didPickDocumentsAt: [invalid])
        let failed = await poll { reader.errorMessage != nil && !reader.isOpening && !reader.hasDocument }
        XCTAssertTrue(failed, "hasDocument=\(reader.hasDocument), opening=\(reader.isOpening), error=\(String(describing: reader.errorMessage)), presented=\(String(describing: host.presentedViewController))")
        let returned = await poll { browser.view.window != nil && host.presentedViewController == nil }
        XCTAssertTrue(returned, "A failed reader open must not strand the native opening screen")
    }

    private func poll(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<400 { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
        return false
    }
    private func pollAsync(_ predicate: () async throws -> Bool) async -> Bool {
        for _ in 0..<400 { if (try? await predicate()) == true { return true }; try? await Task.sleep(for: .milliseconds(20)) }
        return false
    }
    private func web(in view: UIView) -> WKWebView? {
        if let value = view as? WKWebView { return value }
        for child in view.subviews { if let found = web(in: child) { return found } }
        return nil
    }
    private func containsAlert(in controller: UIViewController) -> Bool {
        if controller is UIAlertController { return true }
        for child in controller.children { if containsAlert(in: child) { return true } }
        return controller.presentedViewController.map { containsAlert(in: $0) } ?? false
    }

    private func browser(in controller: UIViewController) -> UIDocumentBrowserViewController? {
        if let browser = controller as? UIDocumentBrowserViewController { return browser }
        for child in controller.children { if let found = browser(in: child) { return found } }
        if let presented = controller.presentedViewController { return browser(in: presented) }
        return nil
    }
}

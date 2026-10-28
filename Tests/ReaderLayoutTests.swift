import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Margined

@MainActor
final class ReaderLayoutTests: XCTestCase {
    func testReaderPagesKeepCookiesAndRemoteImageConsentSeparate() async throws {
        let first = try await makeIsolatedPage(heading: "First", remoteImages: true)
        defer { first.window.close(); first.reader.stop() }
        let firstWeb = try await waitForIsolatedPage(in: first.controller, heading: "First")
        let firstStore = firstWeb.configuration.websiteDataStore
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "isolation.invalid", .path: "/", .name: "margined-owner", .value: "first-only"
        ]))
        await firstStore.httpCookieStore.setCookie(cookie)
        let firstCookies = await firstStore.httpCookieStore.allCookies()
        XCTAssertTrue(firstCookies.contains { $0.name == "margined-owner" && $0.value == "first-only" },
                      "The first store must actually contain the cookie before checking isolation")

        let second = try await makeIsolatedPage(heading: "Second")
        defer { second.window.close(); second.reader.stop() }
        let secondWeb = try await waitForIsolatedPage(in: second.controller, heading: "Second")
        let secondStore = secondWeb.configuration.websiteDataStore
        XCTAssertFalse(firstStore.isPersistent)
        XCTAssertFalse(secondStore.isPersistent)
        XCTAssertFalse(firstStore === secondStore)
        XCTAssertFalse(firstWeb === secondWeb)
        let secondCookies = await secondStore.httpCookieStore.allCookies()
        XCTAssertFalse(secondCookies.contains { $0.name == "margined-owner" })
        let policyScript = "return document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]')?.content ?? '';"
        let firstPolicy = try await firstWeb.callAsyncJavaScript(policyScript, arguments: [:], in: nil,
            contentWorld: .world(name: "MarginedPageIsolationTest")) as? String
        let secondPolicy = try await secondWeb.callAsyncJavaScript(policyScript, arguments: [:], in: nil,
            contentWorld: .world(name: "MarginedPageIsolationTest")) as? String
        XCTAssertTrue(try XCTUnwrap(firstPolicy).contains("https:"))
        XCTAssertFalse(try XCTUnwrap(secondPolicy).contains("https:"))
        XCTAssertFalse(second.reader.loadRemoteImages)
    }

    func testReaderPagesResolveTheSameImageNameInTheirOwnFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstFolder = root.appendingPathComponent("first", isDirectory: true)
        let secondFolder = root.appendingPathComponent("second", isDirectory: true)
        for folder in [firstFolder, secondFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try pageFixturePNG(width: 31).write(to: firstFolder.appendingPathComponent("figure.png"))
        try pageFixturePNG(width: 73).write(to: secondFolder.appendingPathComponent("figure.png"))
        let firstFile = firstFolder.appendingPathComponent("notes.md")
        let secondFile = secondFolder.appendingPathComponent("notes.md")
        let first = try await makeIsolatedPage(heading: "First image", fileURL: firstFile,
                                               image: "figure.png")
        defer { first.window.close(); first.reader.stop() }
        _ = try await waitForIsolatedPage(in: first.controller, heading: "First image", imageWidth: 31)
        let second = try await makeIsolatedPage(heading: "Second image", fileURL: secondFile,
                                                image: "figure.png")
        defer { second.window.close(); second.reader.stop() }
        _ = try await waitForIsolatedPage(in: second.controller, heading: "Second image", imageWidth: 73)
        XCTAssertNil(first.reader.localImageError)
        XCTAssertNil(second.reader.localImageError)
    }

    func testPreparationNavigationFailureDoesNotBecomeADocumentError() throws {
        let reader = ReaderState()
        let coordinator = MarkdownWebView.Coordinator(reader: reader)
        let web = WKWebView(frame: .zero)
        defer { web.stopLoading(); reader.stop() }
        coordinator.webView = web
        // A real navigation started before this reader owns a document load.
        let preparation = try XCTUnwrap(web.loadHTMLString("<!doctype html><title>Preparing</title>", baseURL: nil))
        coordinator.webView(web, didFailProvisionalNavigation: preparation,
                            withError: URLError(.cannotFindHost))
        XCTAssertNil(reader.errorMessage, "An unused page's navigation is not the current document's failure")
    }

    private func makeIsolatedPage(heading: String, fileURL: URL? = nil, image: String? = nil,
                                  remoteImages: Bool = false) async throws
        -> (reader: ReaderState, controller: NSHostingController<MarkdownWebView>, window: NSWindow) {
        let source = "# \(heading)\n\n" + (image.map { "![Fixture](\($0))\n" } ?? "Private document.\n")
        if let fileURL { try source.write(to: fileURL, atomically: true, encoding: .utf8) }
        let reader = ReaderState(); reader.fileURL = fileURL; reader.source = source
        reader.loadRemoteImages = remoteImages
        let output = try await MarkdownRenderer.shared.render(source, wide: true, loadRemoteImages: remoteImages)
        reader.rendered = output
        let controller = NSHostingController(rootView: MarkdownWebView(reader: reader, html: output.html))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 760),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        return (reader, controller, window)
    }

    private func waitForIsolatedPage(in controller: NSHostingController<MarkdownWebView>,
                                     heading: String, imageWidth: Int = 0) async throws -> WKWebView {
        for _ in 0..<200 {
            if let web = findWebView(controller.view), web.url != nil, !web.isLoading {
                let ready = try? await web.callAsyncJavaScript("""
                const image = document.querySelector('main#document img');
                return document.readyState === 'complete'
                    && document.querySelector('main#document h1')?.textContent === heading
                    && (width === 0 || (image?.complete && image.naturalWidth === width));
                """, arguments: ["heading": heading, "width": imageWidth], in: nil,
                contentWorld: .world(name: "MarginedPageIsolationTest")) as? Bool
                if ready == true { return web }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The actual reader page and its own image did not become ready")
        throw CocoaError(.coderInvalidValue)
    }

    private func pageFixturePNG(width: Int) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 3,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<width { for y in 0..<3 { bitmap.setColor(.blue, atX: x, y: y) } }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testArabicDocumentAtLargeZoomUsesRTLTextAndConfinesWideTables() async throws {
        let source = "# خطة العمل\n\nهذه وثيقة للمراجعة والقراءة.\n\n| المهمة | النتيجة |\n| --- | --- |\n| مهمة طويلة للمراجعة | نتيجة مفصلة للعمل المطلوب |\n\n```swift\nlet result = \"Example code\"\n```\n"
        let output = try await MarkdownRenderer.shared.render(source,wide:true,documentLanguage:"ar")
        let reader = ReaderState()
        let coordinator = MarkdownWebView.Coordinator(reader:reader)
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame:NSRect(x:0,y:0,width:480,height:500),configuration:configuration)
        let window = NSWindow(contentRect:web.frame,styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = web; window.makeKeyAndOrderFront(nil)
        defer { window.close(); reader.stop() }
        coordinator.webView = web; web.navigationDelegate = coordinator; web.pageZoom = 1.6
        coordinator.load(output.html)
        for _ in 0..<200 {
            if !web.isLoading, let ready = try? await web.evaluateJavaScript("!!document.querySelector('pre')") as? Bool, ready { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        let result = try await web.evaluateJavaScript("""
        ({direction:getComputedStyle(document.querySelector('main')).direction,
          code:getComputedStyle(document.querySelector('pre')).direction,
          overflow:document.documentElement.scrollWidth-document.documentElement.clientWidth})
        """) as! [String:Any]
        XCTAssertEqual(result["direction"] as? String,"rtl")
        XCTAssertEqual(result["code"] as? String,"ltr")
        XCTAssertLessThanOrEqual(result["overflow"] as! Double,1,"Wide tables must scroll inside their container")
    }

    func testRTLReaderWithOutlineAndReviewKeepsBothPanesReadable() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at:file) }
        let reader = ReaderState(); reader.fileURL = file; reader.source = "# Notes\n\nOriginal text.\n\n## Next\n\nMore text.\n"
        try reader.source.write(to:file,atomically:true,encoding:.utf8)
        let controller = NSHostingController(rootView:ReaderView(reader:reader).environment(\.layoutDirection,.rightToLeft))
        let window = NSWindow(contentViewController:controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width:1000,height:760)); window.makeKeyAndOrderFront(nil)
        defer { window.close(); reader.stop() }
        for _ in 0..<200 where reader.rendered == nil { try await Task.sleep(for:.milliseconds(20)) }
        let updated = "# Notes\n\nUpdated text.\n\n## Next\n\nMore text.\n"
        try updated.write(to:file,atomically:true,encoding:.utf8); reader.acceptFileUpdate(updated)
        reader.showOutline = true; reader.showChanges = true
        var documentRect:NSRect?, reviewRect:NSRect?
        for _ in 0..<200 {
            controller.view.layoutSubtreeIfNeeded()
            if let web = findWebView(controller.view), let panel = findReviewPanel(controller.view) {
                documentRect = web.convert(web.bounds,to:controller.view)
                reviewRect = panel.convert(panel.bounds,to:controller.view)
                if documentRect!.height > 150, reviewRect!.height > 150 { break }
            }
            try await Task.sleep(for:.milliseconds(20))
        }
        let document = try XCTUnwrap(documentRect), review = try XCTUnwrap(reviewRect)
        XCTAssertFalse(document.intersects(review))
        XCTAssertGreaterThan(document.width,240)
        XCTAssertGreaterThan(review.width,280)
        XCTAssertTrue(controller.view.bounds.insetBy(dx:-1,dy:-1).contains(review))
        XCTAssertEqual(try MarkdownSource.read(file),updated)
    }

    func testDoubleLengthInterfaceKeepsReaderAndSettingsUsable() async throws {
        // Run once normally and once from an isolated .xctestrun with
        // -NSDoubleLocalizedStrings YES set before Foundation caches strings.
        let expanded = ProcessInfo.processInfo.arguments.contains("-NSDoubleLocalizedStrings")
        XCTAssertEqual(String(localized: "Before"), expanded ? "Before Before" : "Before")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: file) }
        let reader = ReaderState(); reader.fileURL = file
        reader.source = "# Reading\n\nOriginal text.\n"
        try reader.source.write(to: file, atomically: true, encoding: .utf8)
        reader.render()
        let controller = NSHostingController(rootView: ReaderView(reader: reader).environment(\.layoutDirection, .rightToLeft))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1180, height: 760)); window.orderFront(nil)
        defer { window.close(); reader.stop() }
        for _ in 0..<200 {
            if let web = findWebView(controller.view), !web.isLoading,
               let ready = try? await web.evaluateJavaScript("!!document.querySelector('h1')") as? Bool, ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let updated = "# Reading\n\nUpdated text.\n"
        try updated.write(to: file, atomically: true, encoding: .utf8)
        reader.acceptFileUpdate(updated)
        reader.showOutline = true; reader.showChanges = true
        for _ in 0..<200 {
            controller.view.layoutSubtreeIfNeeded()
            if !reader.isRendering, reader.changes.count == 1, let web = findWebView(controller.view),
               let panel = findReviewPanel(controller.view), web.bounds.width > 240, panel.bounds.width > 280,
               let ready = try? await web.evaluateJavaScript("document.querySelector('main')?.textContent.includes('Updated text.')") as? Bool, ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(reader.changes.count, 1)
        let web = try XCTUnwrap(findWebView(controller.view)), panel = try XCTUnwrap(findReviewPanel(controller.view))
        XCTAssertFalse(web.convert(web.bounds, to: controller.view).intersects(panel.convert(panel.bounds, to: controller.view)))
        XCTAssertGreaterThan(web.bounds.width, 240)
        XCTAssertGreaterThan(panel.bounds.width, 280)
        try capture(controller.view, name: expanded ? "expanded-reader" : "normal-reader")
        let settings = NSHostingController(rootView: SettingsView().environment(\.layoutDirection, .rightToLeft))
        let settingsWindow = NSWindow(contentViewController: settings)
        settingsWindow.isReleasedWhenClosed = false
        // Match the app's Settings window setup rather than inspecting the
        // hosting controller's transient one-point initial view on CI.
        settingsWindow.setContentSize(NSSize(width: 600, height: 680))
        settingsWindow.orderFront(nil)
        defer { settingsWindow.close() }
        for _ in 0..<100 {
            settings.view.layoutSubtreeIfNeeded()
            if settings.view.bounds.width >= 590, settings.view.bounds.height >= 670 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(settings.view.bounds.width, 590)
        try capture(settings.view, name: expanded ? "expanded-settings" : "normal-settings")
    }

    private func capture(_ view: NSView, name: String) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Margined-1.3-layout-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func findWebView(_ view:NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for child in view.subviews { if let web = findWebView(child) { return web } }
        return nil
    }
    private func findReviewPanel(_ view:NSView) -> NSView? {
        if let split = view as? NSSplitView, split.arrangedSubviews.count == 2,
           let panel = split.arrangedSubviews.first(where:{findWebView($0) == nil}) { return panel }
        for child in view.subviews { if let panel = findReviewPanel(child) { return panel } }
        return nil
    }
}

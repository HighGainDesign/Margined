import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Margined

@MainActor
final class ReaderLayoutTests: XCTestCase {
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

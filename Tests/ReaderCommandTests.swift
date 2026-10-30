import AppKit
import XCTest
@testable import Margined

@MainActor
final class ReaderCommandTests: XCTestCase {
    func testFileExportsAreDiscoverableAndValidateAgainstTheCurrentDocument() async throws {
        let oldMenu = NSApp.mainMenu, oldWindows = NSApp.windowsMenu, oldServices = NSApp.servicesMenu
        let delegate = AppDelegate()
        try await activateNativeTestApplication()
        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            NSApp.mainMenu = oldMenu; NSApp.windowsMenu = oldWindows; NSApp.servicesMenu = oldServices
        }
        let file = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu)
        let names = ["Save Markdown Copy…", "Export Clean Copy…", "Export Conversations…"]
        let exports = names.compactMap { name in file.items.first { $0.title == name } }
        XCTAssertEqual(exports.count, 3, "Existing copy/export actions belong in File as well as the discussion menu")
        guard exports.count == 3 else { return }
        for item in exports { XCTAssertFalse(delegate.validateMenuItem(item)) }

        let request = try PreviewRequest(url: XCTUnwrap(URL(string: "margined://preview?text=%23%20Export%20test&title=Exports")))
        let document = MarkdownDocument(preview: request)
        NSDocumentController.shared.addDocument(document)
        defer { document.reader.stop(); document.close() }
        document.makeWindowControllers(); document.showWindows()
        NSApp.activate(ignoringOtherApps: true)
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        window.makeMain(); window.makeKeyAndOrderFront(nil)
        for _ in 0..<200 {
            if document.reader.rendered != nil, !document.reader.isRendering,
               NSDocumentController.shared.currentDocument === document { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(document.reader.rendered)
        XCTAssertTrue(NSDocumentController.shared.currentDocument === document,
            "active=\(NSApp.isActive) key=\(NSApp.keyWindow === window) main=\(NSApp.mainWindow === window) owner=\(window.windowController?.document === document)")
        XCTAssertFalse(document.reader.isRendering)
        for item in exports {
            XCTAssertTrue(item.target === delegate)
            XCTAssertNotNil(item.action)
            XCTAssertTrue(delegate.validateMenuItem(item))
        }
    }
}

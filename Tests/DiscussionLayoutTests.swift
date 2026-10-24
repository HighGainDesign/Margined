import AppKit
import SwiftUI
import Vision
import WebKit
import XCTest
@testable import Margined

/// Inspect the pixels of the already-mounted native inspector, rather than
/// deriving its position from the same layout function being tested.
@MainActor final class DiscussionLayoutTests: XCTestCase {
    func testDiscussionCardAlignsWithItsPassageBelowTheInspectorControls() async throws {
        var source = "# Plan\n\n" + String(repeating: "Padding paragraph.\n\n", count: 6)
        source += "Before.\n\nThe passage under discussion.\n\nAfter.\n"
        let thread = DiscussionThread(id: "alignment-thread", state: .open,
            target: .init(type: "TextQuoteSelector", exact: "The passage under discussion.", prefix: "Before.", suffix: "After.", section: "Plan"),
            messages: [.init(id: "alignment-message", author: "Reviewer", created: "2026-10-23T10:00:00Z", body: "Keep this card beside its passage.", inReplyTo: nil)],
            resolvedBy: nil, resolved: nil, attachmentHistory: [])
        let parsed = try DiscussionCodec.parse(source)
        source = try MarkdownSource.decode(MarkdownSourceEdits.apply(DiscussionEdits.splices(for: .newThread(thread), in: parsed),
            to: Data(source.utf8), expectedSource: source))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let original = Data(source.utf8); try original.write(to: file)
        let reader = ReaderState(); reader.fileURL = file; reader.source = source; reader.render()
        let controller = NSHostingController(rootView: ReaderView(reader: reader))
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(.init(width: 1_200, height: 780)); window.makeKeyAndOrderFront(nil)
        defer { reader.discussions.discardDrafts(); reader.stop(); window.close(); try? FileManager.default.removeItem(at: file) }
        try await settle { !reader.isRendering && self.webView(in: controller.view)?.isLoading == false }
        reader.showDiscussions = true
        try await settle { reader.discussionMargin?.anchors.first?.id == "alignment-thread" }
        let web = try XCTUnwrap(webView(in: controller.view))
        let anchor = try XCTUnwrap(reader.discussionMargin?.anchors.first)
        let root = controller.view
        // A snapshot waits for the web/native layout transaction to settle.
        _ = try await web.takeSnapshot(configuration: WKSnapshotConfiguration())
        root.layoutSubtreeIfNeeded()
        let point = web.convert(CGPoint(x: 0, y: anchor.top * reader.zoom), to: root)
        let passageTop = root.isFlipped ? point.y : root.bounds.height - point.y
        XCTAssertGreaterThan(passageTop, 300, "The passage must be below the fixed controls to expose duplicate insets")
        let image = try snapshot(root)
        let attachment = XCTAttachment(image: NSImage(cgImage: image, size: root.bounds.size))
        attachment.name = "Mounted discussion alignment"; attachment.lifetime = .keepAlways; add(attachment)
        let webFrame = web.convert(web.bounds, to: root)
        let authorTop = try await Self.recognizedTop("Reviewer", in: image, height: root.bounds.height,
            trailingColumn: webFrame.maxX / root.bounds.width)
        let delta = authorTop - passageTop
        XCTAssertGreaterThanOrEqual(delta, -8, "Author top \(authorTop), passage top \(passageTop)")
        XCTAssertLessThanOrEqual(delta, 40, "The card should align with its passage, allowing only its own inner padding; author top \(authorTop), passage top \(passageTop)")
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail("Mounted discussion did not settle")
    }
    private func webView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.webView(in: $0) }.first
    }
    private func snapshot(_ view: NSView) throws -> CGImage {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.cgImage)
    }
    nonisolated private static func recognizedTop(_ text: String, in image: CGImage, height: CGFloat, trailingColumn: CGFloat) async throws -> CGFloat {
        try await Task.detached(priority: .userInitiated) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
        request.regionOfInterest = CGRect(x: trailingColumn, y: 0, width: 1 - trailingColumn, height: 1)
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        // Vision can include the speech-bubble glyph in the heading's text row.
        // Choose the first row containing the author, rather than the repeated author in a message.
        let matches = (request.results ?? []).filter { $0.topCandidates(1).first?.string.range(of: text, options: .caseInsensitive) != nil }
        let row = try XCTUnwrap(matches.max { $0.boundingBox.maxY < $1.boundingBox.maxY },
            "Native snapshot must contain the card author before testing alignment; found \((request.results ?? []).compactMap { $0.topCandidates(1).first?.string })")
        return (1 - row.boundingBox.maxY) * height
        }.value
    }
}

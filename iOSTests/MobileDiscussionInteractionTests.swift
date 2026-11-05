import SwiftUI
import LinkPresentation
import UIKit
import WebKit
import Vision
import XCTest
@testable import MarginediOS

@MainActor final class MobileDiscussionInteractionTests: XCTestCase {
    #if MARGINED_NATIVE_COORDINATE_CALIBRATION
    /// Diagnostic measurements only. This case deliberately controls zoom,
    /// insets and position; it does not certify preservation during resizing.
    func testNativeCoordinateCalibrationAcrossZoomAndInsets() async throws {
        let paragraphs = (0..<100).map { "Calibration paragraph \($0) supplies normal flow content to measure the native and CSS coordinate mapping at several public zoom and inset settings." }.joined(separator: "\n\n")
        let f = try await fixture(tail: "\n\n" + paragraphs)
        let scroll = f.web.scrollView
        _ = try await f.web.callAsyncJavaScript("window.marginedReadingResize?.stop(); return true;",
            arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld)
        scroll.contentInsetAdjustmentBehavior = .never
        let configuration = WKSnapshotConfiguration(); configuration.afterScreenUpdates = true
        // Establish position once. A later scrollIntoView can reset native
        // zoom, which would silently turn a requested2x sample into unit scale.
        _ = try await f.web.callAsyncJavaScript("""
        await document.fonts.ready;
        document.querySelectorAll('main p')[38].scrollIntoView({block:'start',behavior:'instant'});
        return true;
        """, arguments: [:], in: nil, contentWorld: .defaultClient)
        func point(_ p: CGPoint) -> [Double] { [Double(p.x), Double(p.y)] }
        func rect(_ r: CGRect) -> [Double] { [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)] }
        func mapping(_ layer: CALayer, parent: CALayer) -> [String: Any] {
            ["bounds": rect(layer.bounds),
             "zero": point(layer.convert(.zero, to: parent)),
             "unitX": point(layer.convert(CGPoint(x: 1, y: 0), to: parent)),
             "unitY": point(layer.convert(CGPoint(x: 0, y: 1), to: parent)),
             "viewportInContent": rect(layer.convert(parent.bounds, from: parent))]
        }
        for stage in ["unit", "zoom2", "zoom2-insets", "unit-insets", "pageZoom1.5", "unit-restored"] {
            switch stage {
            case "zoom2":
                XCTAssertGreaterThanOrEqual(scroll.maximumZoomScale, 2)
                scroll.setZoomScale(2, animated: false)
            case "zoom2-insets": scroll.contentInset = UIEdgeInsets(top: 20, left: 12, bottom: 30, right: 18)
            case "unit-insets": scroll.setZoomScale(1, animated: false)
            case "pageZoom1.5": scroll.contentInset = .zero; f.web.pageZoom = 1.5
            case "unit-restored": f.web.pageZoom = 1
            default: break
            }
            let idle = await poll { !scroll.isZooming && !scroll.isZoomBouncing && !scroll.isDecelerating }
            XCTAssertTrue(idle)
            _ = try await f.web.takeSnapshot(configuration: configuration)
            var measuredVisualScale: Double?
            for sample in 0..<5 {
                let dom = try await f.web.callAsyncJavaScript("""
                await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
                const root=document.documentElement, p=document.querySelectorAll('main p')[38], r=p.getBoundingClientRect(), v=visualViewport;
                return {x:scrollX,y:scrollY,width:root.clientWidth,height:root.clientHeight,
                    contentWidth:root.scrollWidth,contentHeight:root.scrollHeight,
                    innerWidth,innerHeight,rect:[r.x,r.y,r.width,r.height],
                    visual:{width:v.width,height:v.height,scale:v.scale,x:v.offsetLeft,y:v.offsetTop,pageX:v.pageLeft,pageY:v.pageTop}};
                """, arguments: [:], in: nil, contentWorld: .defaultClient)
                measuredVisualScale = ((dom as? [String: Any])?["visual"] as? [String: Any])?["scale"] as? Double
                let children = scroll.subviews.filter { !$0.isHidden && $0.alpha > 0.01 && $0.bounds.height > 50 }.map { child -> [String: Any] in
                    var value = mapping(child.layer, parent: scroll.layer)
                    if let shown = child.layer.presentation(), let parent = scroll.layer.presentation() {
                        value["presentation"] = mapping(shown, parent: parent)
                    }
                    return value
                }
                let report: [String: Any] = ["stage": stage, "sample": sample,
                    "processID": Int(ProcessInfo.processInfo.processIdentifier), "time": CACurrentMediaTime(),
                    "dom": dom, "webBounds": rect(f.web.bounds), "scrollBounds": rect(scroll.bounds),
                    "offset": point(scroll.contentOffset), "contentSize": [Double(scroll.contentSize.width),Double(scroll.contentSize.height)],
                    "zoomScale": scroll.zoomScale, "pageZoom": f.web.pageZoom,
                    "zoomLimits": [scroll.minimumZoomScale,scroll.maximumZoomScale],
                    "insets": [scroll.adjustedContentInset.top,scroll.adjustedContentInset.left,scroll.adjustedContentInset.bottom,scroll.adjustedContentInset.right],
                    "children": children]
                let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                print("NATIVE-COORDINATE-CALIBRATION " + String(decoding: data, as: UTF8.self))
            }
            if stage.hasPrefix("zoom2") {
                XCTAssertEqual(Double(scroll.zoomScale), 2, accuracy: 0.001,
                    "Measure actual native2x rather than only a requested zoom")
                XCTAssertEqual(try XCTUnwrap(measuredVisualScale), 2, accuracy: 0.01,
                    "WebContent must also acknowledge actual2x for pinch-coordinate calibration")
            }
        }
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }
    #endif

    func testReplyOCRFindsOnlyTheWordBoundsInsideAMergedRow() throws {
        let image = replyOCRFixture("Reader • Reply")
        let bounds = try XCTUnwrap(recognizedBounds("Reply", in: XCTUnwrap(image.cgImage), size: image.size))
        XCTAssertGreaterThan(bounds.minX, 80, "Measure Reply rather than the neighboring Reader text")
        XCTAssertLessThan(bounds.width, 80, "Return the word's glyph bounds rather than the entire merged row")
        XCTAssertLessThanOrEqual(bounds.maxY, image.size.height)
    }

    func testReplyOCRRejectsMissingOrSimilarWords() throws {
        for row in ["Reader • Post", "Reader • Replying", "Reader • PreReply"] {
            let image = replyOCRFixture(row)
            XCTAssertNil(try recognizedBounds("Reply", in: XCTUnwrap(image.cgImage), size: image.size), row)
        }
    }

    private func replyOCRFixture(_ row: String) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 320, height: 70), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 70))
            (row as NSString).draw(at: CGPoint(x: 16, y: 16), withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.black])
        }
    }

    func testMountingANativeDraftEditorRestoresTheRetainedCaretBeforeObservingSelection() async throws {
        let f = try await fixture(withThread: true)
        let key = DiscussionSession.DraftKey.thread("t-mobile")
        let draft = "Retain this native editor selection."
        let caret = NSRange(location: 7, length: 4)
        f.reader.discussions.setDraft(draft, for: key)
        f.reader.discussionComposerSelections[key] = caret
        let host = UIHostingController(rootView: MobileDiscussionDraftEditor(reader: f.reader, key: key,
            text: Binding(get: { f.reader.discussions.drafts[key]?.body ?? "" },
                set: { f.reader.discussions.setDraft($0, for: key) }), document: f.reader.documentGeneration).frame(height: 100))
        let window = UIWindow(windowScene: try XCTUnwrap(f.window.windowScene))
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        window.rootViewController = host; window.makeKeyAndVisible()
        host.loadViewIfNeeded(); host.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; f.window.makeKey() }
        let mounted = await poll { self.editor(in: host.view)?.text == draft }
        XCTAssertTrue(mounted)
        let editor = try XCTUnwrap(self.editor(in: host.view))
        print("DRAFT-MOUNT retainedBefore=\(caret) retainedAfter=\(String(describing: f.reader.discussionComposerSelections[key])) native=\(editor.selectedRange)")
        XCTAssertEqual(f.reader.discussionComposerSelections[key], caret, "Initial native text assignment must not replace retained selection")
        XCTAssertEqual(editor.selectedRange, caret, "A newly mounted editor must restore the actual native caret")
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testCompactBackRetainsTheDiscussionListWhenTheWideInspectorMounts() async throws {
        try await assertDiscussionListIntentSurvivesRemount(startWide: false)
    }

    func testWideBackRetainsTheDiscussionListAfterACompactRoundTrip() async throws {
        try await assertDiscussionListIntentSurvivesRemount(startWide: true)
    }

    private func assertDiscussionListIntentSurvivesRemount(startWide: Bool) async throws {
        let f = try await fixture(withThread: true)
        let draft = "Retain this list-owned reply and caret."
        let caret = NSRange(location: 7, length: 4)
        let key = DiscussionSession.DraftKey.thread("t-mobile")
        f.reader.discussions.filter = .all
        f.reader.openDiscussion("t-mobile")
        f.reader.discussions.setDraft(draft, for: key)
        let opened = await poll { self.visibleEditor(in: f.host.view)?.text == draft }
        XCTAssertTrue(opened); guard opened else { return }
        let initiallySettled = await settledNavigation(f); XCTAssertTrue(initiallySettled)
        let editor = try XCTUnwrap(self.visibleEditor(in: f.host.view))
        let keyboard = MobileKeyboardFrameObservation(window: f.window)
        XCTAssertTrue(editor.becomeFirstResponder())
        let typingReady = await poll {
            editor.isFirstResponder && keyboard.frame.height > 100 && f.reader.discussionFocus?.input == .body
        }
        XCTAssertTrue(typingReady)
        // Select after the native keyboard/focus transition, as a user would.
        editor.selectedRange = caret
        editor.delegate?.textViewDidChangeSelection?(editor)
        let selectionReady = await poll {
            editor.selectedRange == caret && f.reader.discussionComposerSelections[key] == caret
        }
        XCTAssertTrue(selectionReady, "Seed an actual native editing caret before Back or resizing")
        XCTAssertEqual(f.reader.discussionComposerSelections[key], caret)
        if startWide {
            f.window.frame.size = CGSize(width: 1120, height: 780)
            f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
            let settled = await settledNavigation(f); XCTAssertTrue(settled && f.reader.discussionUsesMargin)
            // Invoke the same retained action as wide Back. Native button
            // activation is covered separately by the app UI gate.
            f.reader.backToDiscussionList()
        } else {
            MobileDocumentWorkspace(reader: f.reader, openFolder: {}, closeFile: {}).navigationBinding().wrappedValue = [.list]
        }
        let listIntent = await poll { f.reader.discussionRoute == nil }
        XCTAssertTrue(listIntent)
        let widths: [CGFloat] = startWide ? [390, 1120] : [1120]
        for width in widths {
            f.window.frame.size = CGSize(width: width, height: 780)
            f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
            let settled = await settledNavigation(f); XCTAssertTrue(settled)
            let listVisible = await poll { self.editor(in: f.host.view) == nil }
            XCTAssertTrue(listVisible, "Back must keep the filter/list visible after mounting at width \(width)")
            let text = try recognizedText(in: f.window)
            XCTAssertTrue(text.contains("Document Actions") && text.contains("All"), "The actual list/filter must be rendered: \(text)")
            XCTAssertNil(f.reader.discussionRoute)
            XCTAssertEqual(f.reader.discussions.selection, key)
            XCTAssertEqual(f.reader.discussions.filter, .all)
            XCTAssertEqual(f.reader.discussions.drafts[key]?.body, draft)
            XCTAssertEqual(f.reader.discussionComposerSelections[key], caret)
        }
        for width in [CGFloat(1120), CGFloat(390)] {
            f.window.frame.size = CGSize(width: width, height: 780)
            f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
            let settled = await settledNavigation(f); XCTAssertTrue(settled)
            f.reader.openDiscussion("t-mobile")
            let reopened = await poll { self.visibleEditor(in: f.host.view)?.text == draft }
            XCTAssertTrue(reopened)
            XCTAssertEqual(self.editor(in: f.host.view)?.selectedRange, caret)
            XCTAssertEqual(f.reader.discussionRoute, key)
        }
        XCTAssertEqual(Data(f.reader.source.utf8), f.original)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testGermanLargestTextTypingComposerFitsANarrowShortNativeHost() async throws {
        let f = try await fixture(withThread: true)
        let key = DiscussionSession.DraftKey.thread("t-mobile")
        f.reader.discussions.displayName = "A deliberately long saved author name"
        f.reader.discussions.setDraft("A narrow localized reply.", for: key)
        f.reader.discussionFocus = .init(id: UUID(), input: .body)
        let scene = try XCTUnwrap(f.window.windowScene)
        let host = UIHostingController(rootView: MobileDiscussionComposer(reader: f.reader, key: key, compact: true, shortTyping: true)
            .padding(.horizontal, 16).environment(\.locale, Locale(identifier: "de")))
        host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        window.rootViewController = host; window.makeKeyAndVisible()
        host.loadViewIfNeeded(); host.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; f.window.makeKey() }
        let mounted = await poll { self.editor(in: host.view)?.text == "A narrow localized reply." }
        XCTAssertTrue(mounted)
        let editor = try XCTUnwrap(self.editor(in: host.view))
        let frame = editor.convert(editor.bounds, to: window)
        XCTAssertGreaterThan(frame.width, 20, "The fixed action column must leave a usable native input")
        XCTAssertGreaterThanOrEqual(frame.minX, 0)
        XCTAssertLessThanOrEqual(frame.maxX, window.bounds.maxX)
        XCTAssertGreaterThanOrEqual(editor.font?.pointSize ?? 0, 35)
        // At this native text size the real German title exceeds the action
        // column, so ViewThatFits must choose the existing paperplane fallback.
        let german = try XCTUnwrap(Bundle(path: XCTUnwrap(Bundle.main.path(forResource: "de", ofType: "lproj"))))
        let title = german.localizedString(forKey: "Reply", value: nil, table: nil)
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: host.traitCollection)
        XCTAssertEqual(title, "Antworten")
        XCTAssertGreaterThan((title as NSString).size(withAttributes: [.font: font]).width, 190)
        let text = try recognizedText(in: window)
        XCTAssertFalse(text.contains(title), "The too-wide localized title must yield to its icon fallback: \(text)")
        let capture = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }); capture.name = "German-largest-text-narrow-composer"; capture.lifetime = .keepAlways; add(capture)
        func all(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(all) }
        print("LOCALIZED-COMPOSER frame=\(frame) nativeFont=\(editor.font?.pointSize ?? 0) titleWidth=\((title as NSString).size(withAttributes: [.font: font]).width) OCR=\(text) identified=\(all(host.view).filter { $0.accessibilityIdentifier != nil }.map { [$0.accessibilityIdentifier ?? "", String(describing: $0.convert($0.bounds, to: window)), $0.accessibilityLabel ?? ""] })")
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testTypingBeforeAnySoftwareKeyboardStaysInsideNativeNavigationContent() async throws {
        let f = try await fixture(withThread: true, useNativeSceneBounds: true)
        f.reader.discussions.displayName = "Reader"
        f.reader.openDiscussion("t-mobile")
        f.reader.discussions.setDraft("Retain this hardware keyboard draft.", for: .thread("t-mobile"))
        let mounted = await poll { self.editor(in: f.host.view)?.text == "Retain this hardware keyboard draft." }
        XCTAssertTrue(mounted); guard mounted else { return }
        let settled = await settledNavigation(f); XCTAssertTrue(settled)
        try await waitForInitialHistory(f)
        let historyReady = await pollAsync {
            guard let history = self.history(in: f.host.view, excluding: f.web) else { return false }
            return try await history.evaluateJavaScript("document.querySelector('article .discussion-message-body')?.textContent.includes('A portable note.')===true") as? Bool == true
        }
        XCTAssertTrue(historyReady)
        let readingHeight = f.web.bounds.height
        let keyboard = MobileKeyboardFrameObservation(window: f.window)
        func navigation(in controller: UIViewController) -> UINavigationController? {
            if let value = controller as? UINavigationController { return value }
            return controller.children.lazy.compactMap { navigation(in: $0) }.first
        }
        // Retained focus may precede the software keyboard animation and is
        // legitimate with hardware input. No responder or keyboard override.
        f.reader.discussionFocus = .init(id: UUID(), input: .name)
        f.reader.discussionSheetExpanded = true
        let naturalSize = f.window.bounds.size
        for size in [naturalSize, CGSize(width: 390, height: 320)] {
            f.window.frame.size = size
            f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
            let settled = await settledNavigation(f); XCTAssertTrue(settled)
            // Await real layout propagation, including the async native budget
            // callback, using the independent navigation-safe bounds themselves.
            let fits = await poll {
                guard let top = navigation(in: f.host)?.topViewController?.viewIfLoaded,
                      let name = self.nameField(in: f.host.view),
                      let history = self.history(in: f.host.view, excluding: f.web) else { return false }
                let content = top.convert(top.safeAreaLayoutGuide.layoutFrame, to: f.window)
                let nameFrame = name.convert(name.bounds, to: f.window)
                let historyFrame = history.convert(history.bounds, to: f.window)
                return name.bounds.height > 20 && history.bounds.height > 20 &&
                    (self.editor(in: f.host.view)?.bounds.height ?? 100) < 1 &&
                    nameFrame.maxY <= content.maxY + 1 && historyFrame.minY >= content.minY
            }
            XCTAssertTrue(fits, "Typing must settle inside independently measured native content at \(size)")
            let top = try XCTUnwrap(navigation(in: f.host)?.topViewController?.viewIfLoaded)
            let content = top.convert(top.safeAreaLayoutGuide.layoutFrame, to: f.window)
            let name = try XCTUnwrap(nameField(in: f.host.view))
            let history = try XCTUnwrap(history(in: f.host.view, excluding: f.web))
            let nameFrame = name.convert(name.bounds, to: f.window)
            let historyFrame = history.convert(history.bounds, to: f.window)
            XCTAssertEqual(keyboard.frame.height, 0, "Exercise no software keyboard")
            XCTAssertFalse(name.isFirstResponder)
            XCTAssertFalse(try XCTUnwrap(editor(in: f.host.view)).isFirstResponder)
            try await recordDuoGeometry(f, keyboard: keyboard, phase: "no-software-keyboard-typing-\(Int(size.width))x\(Int(size.height))")
            XCTAssertGreaterThanOrEqual(historyFrame.minY, content.minY, "Typing history cannot cover the native title")
            XCTAssertLessThanOrEqual(nameFrame.maxY, content.maxY + 1)
            // Native geometry can settle before SwiftUI has painted the new
            // action layout. Await the actual visible label, not just bounds.
            var paintedReply: CGRect?
            for _ in 0..<30 {
                paintedReply = try recognizedBounds("Reply", in: f.window)
                if paintedReply != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            if paintedReply == nil {
                recordSheetEvidence(f, name: "Before-Reply-OCR-no-software-keyboard-\(Int(size.width))x\(Int(size.height))")
                print("SHORT-REPLY-OCR size=\(size) text=\(try recognizedText(in: f.window))")
            }
            let reply = try XCTUnwrap(paintedReply, "Reply remains visible without a software keyboard")
            XCTAssertLessThanOrEqual(reply.maxY, content.maxY + 1)
            recordSheetEvidence(f, name: "Sheet-no-software-keyboard-\(Int(size.width))x\(Int(size.height))")
        }
        f.reader.endDiscussionEditing(); f.reader.discussionSheetExpanded = false
        f.window.frame.size = naturalSize
        f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
        let readingRestored = await poll { abs(f.web.bounds.height - readingHeight) < 1 }
        XCTAssertTrue(readingRestored, "Leaving typing must restore the original reading detent allocation")
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testCompactDiscussionSheetKeepsTheSelectedPassageInItsActualReaderViewport() async throws {
        let f = try await fixture(withThread: true, tail: String(repeating: "Later paragraph.\n\n", count: 90))
        _ = try await f.web.evaluateJavaScript("window.sheetReadingPage=document;true")
        f.reader.openDiscussion("t-mobile")
        f.reader.discussions.setDraft("An unposted sheet reply.", for: .thread("t-mobile"))
        let mounted = await poll { self.editor(in: f.host.view)?.text == "An unposted sheet reply." }
        XCTAssertTrue(mounted); guard mounted else { return }
        XCTAssertTrue(f.web.window === f.window, "Compact discussion must leave the actual retained reader mounted")
        var firstGeometry: [String: Any]?, lastGeometry: [String: Any] = [:]
        let allocated = await poll {
            guard let editor = self.editor(in: f.host.view) else { return false }
            let reader = f.web.convert(f.web.bounds, to: f.window)
            let composer = editor.convert(editor.bounds, to: f.window)
            let matches = f.web.bounds.height > 120 && reader.maxY <= composer.minY
            if !matches || firstGeometry != nil {
                lastGeometry = self.nativeReadingGeometry(f)
                lastGeometry["composerFrame"] = String(describing: composer)
                if firstGeometry == nil { firstGeometry = lastGeometry }
            }
            return matches
        }
        if let firstGeometry {
            recordReadingReadiness(["first": firstGeometry, "last": lastGeometry, "allocated": allocated],
                name: "Sheet-native-allocation-before-GoTo")
        }
        let readerFrame = f.web.convert(f.web.bounds, to: f.window)
        let editor = try XCTUnwrap(self.editor(in: f.host.view))
        let composerFrame = editor.convert(editor.bounds, to: f.window)
        XCTAssertGreaterThan(f.web.bounds.height, 120, "Reading detent reserves an actual unobscured reader viewport")
        XCTAssertLessThanOrEqual(readerFrame.maxY, composerFrame.minY,
            "A sheet cannot claim passage visibility while covering the reader viewport")
        XCTAssertTrue(allocated, "Commit the actual unobscured native reader allocation before testing Go to Passage")
        guard allocated else { return }
        f.reader.goToDiscussion("t-mobile", version: f.reader.currentDiscussionVersion)
        let revealed = await pollAsync {
            guard f.reader.discussionPassageRequest == nil, f.web.window === f.window else { return false }
            return try await f.web.evaluateJavaScript("window.sheetReadingPage===document && document.activeElement?.textContent.normalize('NFC').includes('Café bold passage.')===true && document.activeElement.getBoundingClientRect().top>=0 && document.activeElement.getBoundingClientRect().bottom<=innerHeight") as? Bool == true
        }
        XCTAssertTrue(revealed)
        XCTAssertEqual(f.reader.inspector, .discussions, "Go to Passage collapses the sheet while preserving its thread")
        XCTAssertEqual(f.reader.discussionRoute, .thread("t-mobile"))
        XCTAssertEqual(self.editor(in: f.host.view)?.text, "An unposted sheet reply.")
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        recordSheetEvidence(f, name: "Sheet-reading-passage")
    }

    func testCompactTypingExpandsAboveTheActualKeyboardAndGoToPassageRetainsCaret() async throws {
        let f = try await fixture(withThread: true, useNativeSceneBounds: true)
        f.reader.discussions.displayName = "Reader"
        f.reader.openDiscussion("t-mobile")
        f.reader.discussions.setDraft("Keep this reply and its caret.", for: .thread("t-mobile"))
        let mounted = await poll { self.editor(in: f.host.view)?.text == "Keep this reply and its caret." }
        XCTAssertTrue(mounted); guard mounted else { return }
        let navigationReady = await settledNavigation(f)
        XCTAssertTrue(navigationReady, "Establish the actual native navigation before selecting its live editor")
        let editor = try XCTUnwrap(self.visibleEditor(in: f.host.view))
        let readingHeight = f.web.bounds.height
        let keyboardObservation = MobileKeyboardFrameObservation(window: f.window)
        editor.selectedRange = NSRange(location: 5, length: 4)
        XCTAssertTrue(editor.becomeFirstResponder())
        let typing = await poll {
            let keyboard = keyboardObservation.frame
            return keyboard.height > 100 && editor.isFirstResponder && f.reader.discussionSheetExpanded &&
                editor.convert(editor.bounds, to: f.window).maxY <= keyboard.minY + 1 &&
                (self.history(in: f.host.view, excluding: f.web)?.bounds.height ?? 0) > 20
        }
        if !typing {
            try await recordDuoGeometry(f, keyboard: keyboardObservation, phase: "compact-typing")
            print("SHEET-KEYBOARD window=\(f.window.bounds) host=\(f.host.view.bounds) readingBefore=\(readingHeight) reader=\(f.web.bounds) editor=\(editor.convert(editor.bounds, to: f.window)) keyboard=\(keyboardObservation.frame) expanded=\(f.reader.discussionSheetExpanded) focused=\(editor.isFirstResponder)")
        }
        XCTAssertTrue(typing, "The real focused editor must expand the discussion above the real keyboard")
        XCTAssertTrue(self.visibleEditor(in: f.host.view) === editor, "Adaptive typing must retain its actual native draft editor")
        recordSheetEvidence(f, name: "Sheet-typing-keyboard", keyboard: keyboardObservation.frame)
        let replyBounds = try XCTUnwrap(recognizedBounds("Reply", in: f.window), "The actual Reply button stays visible while typing")
        XCTAssertLessThanOrEqual(replyBounds.maxY, keyboardObservation.frame.minY + 1)
        f.reader.goToDiscussion("t-mobile", version: f.reader.currentDiscussionVersion)
        let collapsed = await poll { !editor.isFirstResponder && f.web.bounds.height >= readingHeight - 1 }
        XCTAssertTrue(collapsed, "Passage navigation dismisses typing and restores the reading viewport")
        XCTAssertEqual(f.reader.inspector, .discussions)
        f.reader.backToDiscussionList(); f.reader.openDiscussion("t-mobile")
        let restored = await poll { self.editor(in: f.host.view)?.text == "Keep this reply and its caret." }
        XCTAssertTrue(restored)
        XCTAssertEqual(self.editor(in: f.host.view)?.selectedRange, NSRange(location: 5, length: 4))
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testTypingRetainsNativeNameAndBodyEditorsAcrossAuthorEditingWithoutLosingDraftOrCaret() async throws {
        let f = try await fixture(withThread: true, useNativeSceneBounds: true)
        f.reader.discussions.displayName = "Reader"
        f.reader.openDiscussion("t-mobile")
        let draft = "Keep this author-editing draft and caret."
        f.reader.discussions.setDraft(draft, for: .thread("t-mobile"))
        let mounted = await poll { self.visibleEditor(in: f.host.view)?.text == draft }
        XCTAssertTrue(mounted); guard mounted else { return }
        let settled = await settledNavigation(f); XCTAssertTrue(settled)
        let body = try XCTUnwrap(visibleEditor(in: f.host.view))
        let name = try XCTUnwrap(nameField(in: f.host.view))
        let selection = NSRange(location: 5, length: 4)
        body.selectedRange = selection
        let keyboard = MobileKeyboardFrameObservation(window: f.window)
        XCTAssertTrue(body.becomeFirstResponder())
        let typing = await poll { keyboard.frame.height > 100 && body.isFirstResponder && f.reader.discussionFocus?.input == .body }
        XCTAssertTrue(typing)
        // This unit host exposes no SwiftUI virtual accessibility elements.
        // Exercise native field focus here; actual author-action tap/AX remains
        // an app UI verification, not a claim made by this host test.
        XCTAssertTrue(name.becomeFirstResponder())
        let editingName = await poll {
            name.isFirstResponder && f.reader.discussionFocus?.input == .name &&
                name.convert(name.bounds, to: f.window).height > 20 &&
                name.convert(name.bounds, to: f.window).maxY <= keyboard.frame.minY + 1
        }
        XCTAssertTrue(editingName)
        XCTAssertTrue(nameField(in: f.host.view) === name)
        XCTAssertTrue(editor(in: f.host.view) === body)
        name.text = "Updated Author"; name.sendActions(for: .editingChanged)
        let renamed = await poll { f.reader.discussions.displayName == "Updated Author" }
        XCTAssertTrue(renamed)
        XCTAssertTrue(body.becomeFirstResponder())
        let returned = await poll {
            body.isFirstResponder && f.reader.discussionFocus?.input == .body &&
                body.convert(body.bounds, to: f.window).height >= 66 &&
                body.convert(body.bounds, to: f.window).maxY <= keyboard.frame.minY + 1
        }
        XCTAssertTrue(returned)
        XCTAssertTrue(editor(in: f.host.view) === body)
        XCTAssertEqual(body.text, draft); XCTAssertEqual(body.selectedRange, selection)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        body.resignFirstResponder()
    }

    func testDiscussionHistoryRetainsItsSemanticPositionAcrossHideAndWidthChanges() async throws {
        let f = try await fixture(withThread: true)
        let paragraphs = (0..<45).map { "History paragraph \($0) stays readable." }.joined(separator: "\n\n")
        _ = try appendHistoryReply(paragraphs, id: "m-sheet-history", file: f.file, threadID: "t-mobile")
        await f.reader.refresh(); await f.reader.waitForRendering(); f.reader.openDiscussion("t-mobile")
        try await waitForInitialHistory(f)
        let ready = await pollAsync {
            guard let history = self.history(in: f.host.view, excluding: f.web) else { return false }
            return try await history.evaluateJavaScript("document.querySelectorAll('article').length===2 && document.body.style.fontSize!==''") as? Bool == true
        }
        XCTAssertTrue(ready); guard ready else { return }
        let initial = try XCTUnwrap(self.history(in: f.host.view, excluding: f.web))
        _ = try await initial.evaluateJavaScript("Array.from(document.querySelectorAll('p')).find(p=>p.textContent.startsWith('History paragraph 18 ')).scrollIntoView({block:'start',behavior:'instant'});true")
        var lastHistoryReadiness: [String: Any] = [:]
        let initialPosition = await pollAsync {
            try await self.historyReadingPositionHasCommitted(initial, in: f, initial: true, evidence: &lastHistoryReadiness)
        }
        XCTAssertTrue(initialPosition, "Establish the paragraph in both DOM and native viewports before hiding history: \(lastHistoryReadiness)")
        guard initialPosition else { return }
        for width in [CGFloat(390), CGFloat(1120), CGFloat(390)] {
            f.reader.hideDiscussions()
            let hidden = await poll { self.history(in: f.host.view, excluding: f.web) == nil }
            XCTAssertTrue(hidden)
            f.window.frame.size.width = width
            f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
            f.reader.openDiscussion("t-mobile")
            lastHistoryReadiness = ["reason": "awaiting history viewport", "requestedWidth": width]
            let restored = await pollAsync {
                guard let history = self.history(in: f.host.view, excluding: f.web) else {
                    lastHistoryReadiness = ["reason": "history view is not mounted", "requestedWidth": width]
                    return false
                }
                return try await self.historyReadingPositionHasCommitted(history, in: f, initial: false, evidence: &lastHistoryReadiness)
            }
            if !restored, let history = self.history(in: f.host.view, excluding: f.web) {
                let values = try await history.evaluateJavaScript("(()=>{const p=Array.from(document.querySelectorAll('p')).find(p=>p.textContent.startsWith('History paragraph 18 '));return {y:scrollY,height:innerHeight,top:p?.getBoundingClientRect().top,font:document.body.style.fontSize};})()")
                let saved = await f.reader.discussionHistoryPosition(for: "t-mobile").restorePosition()
                print("SHEET-HISTORY width=\(width) metrics=\(String(describing: values)) saved=\(String(describing: saved)) readiness=\(lastHistoryReadiness)")
            }
            XCTAssertTrue(restored, "Reopening at width \(width) must restore the paragraph being read")
        }
    }

    func testNewSelectionSheetRevealsItsActualPassageAfterReservingReaderSpace() async throws {
        let paragraphs = (0..<80).map { "Selection paragraph \($0) has enough text to wrap across several lines in the phone reader." }.joined(separator: "\n\n")
        let f = try await fixture(tail: "\n\n" + paragraphs)
        _ = try await f.web.evaluateJavaScript("""
        (()=>{const p=Array.from(document.querySelectorAll('main p')).find(p=>p.textContent.startsWith('Selection paragraph 40 '));
        p.id='selected-sheet-passage';p.scrollIntoView({block:'center',behavior:'instant'});
        const r=document.createRange();r.selectNodeContents(p);getSelection().removeAllRanges();getSelection().addRange(r);return true;})()
        """)
        f.reader.requestAddDiscussion()
        let ready = await poll { self.editor(in: f.host.view) != nil && f.reader.discussions.selection != nil }
        XCTAssertTrue(ready); guard ready else { return }
        let revealed = await pollAsync {
            try await f.web.evaluateJavaScript("(()=>{const r=document.getElementById('selected-sheet-passage').getBoundingClientRect();return r.top>=0 && r.bottom<=innerHeight;})()") as? Bool == true
        }
        XCTAssertTrue(revealed, "The new draft must reveal the actual selected text in the reduced reader viewport")
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testCompactConversationUsesAvailableHeightAndKeepsEveryReplyAcrossRotation() async throws {
        let f = try await fixture(withThread: true)
        let paragraphs = (0..<35).map { "Saved history paragraph \($0)." }.joined(separator: "\n\n")
        let bytes = try appendHistoryReply(paragraphs + "\n\nLast saved message marker.",
            id: "m-long-history", file: f.file, threadID: "t-mobile")
        await f.reader.refresh(); await f.reader.waitForRendering()
        f.window.frame.size = CGSize(width: 626, height: 1194)
        f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
        let settled = await settledNavigation(f); XCTAssertTrue(settled)
        f.reader.openDiscussion("t-mobile")
        f.reader.discussionSheetExpanded = true
        f.reader.discussions.setDraft("Keep this unposted reply through rotation.", for: .thread("t-mobile"))
        try await waitForInitialHistory(f)
        let ready = await pollAsync {
            guard let history = self.history(in: f.host.view, excluding: f.web) else { return false }
            return try await history.evaluateJavaScript("document.querySelectorAll('article').length===2 && document.body.style.fontSize!==''") as? Bool == true
        }
        XCTAssertTrue(ready); guard ready else { return }
        let history = try XCTUnwrap(self.history(in: f.host.view, excluding: f.web))
        XCTAssertGreaterThan(history.bounds.height, 350,
            "A tall portrait conversation must use its available reading space rather than a fixed 240-point viewport")
        let configuration = WKSnapshotConfiguration(); configuration.afterScreenUpdates = true
        _ = try await history.takeSnapshot(configuration: configuration)
        _ = try await history.callAsyncJavaScript("await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame); return true;",
            arguments: [:], in: nil, contentWorld: .defaultClient)
        history.scrollView.setContentOffset(CGPoint(x: 0,
            y: max(0, history.scrollView.contentSize.height - history.scrollView.bounds.height)), animated: false)
        let tail = await pollAsync {
            try await history.evaluateJavaScript("""
            (()=>{const p=Array.from(document.querySelectorAll('article:last-of-type p')).find(p=>p.textContent.includes('Last saved message marker.')), r=p?.getBoundingClientRect();
            return p?.textContent.includes('Last saved message marker.') && r.bottom<=innerHeight+2 && r.top>=-2;})()
            """) as? Bool == true
        }
        if !tail {
            let metrics = try await history.evaluateJavaScript("""
            (()=>{const p=Array.from(document.querySelectorAll('article:last-of-type p')).find(p=>p.textContent.includes('Last saved message marker.'));
            const r=p?.getBoundingClientRect();return {font:document.body.style.fontSize,y:scrollY,height:innerHeight,
                page:document.documentElement.scrollHeight,top:r?.top??-1,bottom:r?.bottom??-1};})()
            """)
            print("MARGINED-HISTORY-TAIL \(String(describing: metrics)) nativeContent=\(history.scrollView.contentSize) offset=\(history.scrollView.contentOffset) bounds=\(history.bounds) insets=\(history.scrollView.adjustedContentInset)")
        }
        XCTAssertTrue(tail, "The native history scroll must reveal the last saved message")
        for size in [CGSize(width: 1194, height: 834), CGSize(width: 626, height: 1194)] {
            f.window.frame.size = size; f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
            let settled = await settledNavigation(f); XCTAssertTrue(settled)
            let restored = await pollAsync {
                guard let web = self.history(in: f.host.view, excluding: f.web) else { return false }
                return try await web.evaluateJavaScript("document.querySelectorAll('article').length===2 && document.body.textContent.includes('Last saved message marker.')") as? Bool == true
            }
            XCTAssertTrue(restored, "Every saved reply must remain available in either layout")
            XCTAssertEqual(self.editor(in: f.host.view)?.text, "Keep this unposted reply through rotation.")
            XCTAssertEqual(f.reader.discussions.selection, .thread("t-mobile"))
        }
        XCTAssertEqual(try Data(contentsOf: f.file), bytes)
    }

    func testFirstAddFromAnAnnotatedSelectionInTheDockedInspectorStartsItsComposer() async throws {
        let f = try await fixture(withThread: true)
        f.window.frame.size = CGSize(width: 1194, height: 834)
        f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
        let settled = await settledNavigation(f); XCTAssertTrue(settled)
        f.reader.inspector = .discussions
        let decorated = await pollAsync {
            try await f.web.evaluateJavaScript("document.querySelectorAll('[data-margined-thread]').length>0") as? Bool == true
        }
        XCTAssertTrue(decorated)
        _ = try await f.web.evaluateJavaScript("""
        const p=Array.from(document.querySelectorAll('main p')).find(p=>p.textContent.includes('bold'));
        const r=document.createRange();r.selectNodeContents(p);getSelection().removeAllRanges();getSelection().addRange(r);true;
        """)
        f.reader.requestAddDiscussion()
        let created = await poll { if case .new = f.reader.discussions.selection { return true }; return false }
        XCTAssertTrue(created, "One invocation must start the native composer for the selected annotated passage")
        XCTAssertNil(f.reader.discussionPassagePicker)
        if let key = f.reader.discussions.selection {
            XCTAssertEqual(f.reader.discussions.drafts[key]?.target?.exact, "Café bold passage.")
        }
        let mounted = await poll { self.editor(in: f.host.view) != nil }
        XCTAssertTrue(mounted)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testLargestTextTypingKeepsCaretReplyAndACompleteMessageLineAboveTheKeyboard() async throws {
        let f = try await fixture(withThread: true, useNativeSceneBounds: true)
        f.window.frame = try XCTUnwrap(f.window.windowScene).coordinateSpace.bounds
        f.host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
        f.reader.discussions.displayName = "Reader"
        f.reader.openDiscussion("t-mobile")
        let reply = "Keep this accessible reply and its caret."
        f.reader.discussions.setDraft(reply, for: .thread("t-mobile"))
        let mounted = await poll { self.editor(in: f.host.view)?.text == reply }
        XCTAssertTrue(mounted); guard mounted else { return }
        let editor = try XCTUnwrap(self.editor(in: f.host.view))
        let keyboard = MobileKeyboardFrameObservation(window: f.window)
        editor.selectedRange = NSRange(location: 5, length: 4)
        XCTAssertTrue(editor.becomeFirstResponder())
        let typing = await poll { keyboard.frame.height > 100 && editor.isFirstResponder && editor.convert(editor.bounds, to: f.window).maxY <= keyboard.frame.minY + 1 }
        if !typing { try await recordDuoGeometry(f, keyboard: keyboard, phase: "largest-typing") }
        XCTAssertTrue(typing)
        let history = try XCTUnwrap(self.history(in: f.host.view, excluding: f.web))
        let loaded = await pollAsync {
            try await history.evaluateJavaScript("document.querySelector('article .discussion-message-body p')?.textContent.includes('A portable note.')===true && parseFloat(document.body.style.fontSize)>=30") as? Bool == true
        }
        XCTAssertTrue(loaded); guard loaded else { return }
        _ = try await history.evaluateJavaScript("(()=>{const p=document.querySelector('article .discussion-message-body p'),r=document.createRange();r.selectNodeContents(p);const first=r.getClientRects()[0];scrollTo({top:Math.floor(scrollY+first.top),behavior:'instant'});return true;})()")
        let lineVisible = await pollAsync {
            try await history.evaluateJavaScript("(()=>{const p=document.querySelector('article .discussion-message-body p'),r=document.createRange();r.selectNodeContents(p);return Array.from(r.getClientRects()).some(b=>b.top>=0 && b.bottom<=innerHeight);})()") as? Bool == true
        }
        if !lineVisible {
            try await recordDuoGeometry(f, keyboard: keyboard, phase: "largest-line")
            let metrics = try await history.evaluateJavaScript("(()=>{const p=document.querySelector('article .discussion-message-body p'),r=document.createRange();r.selectNodeContents(p);return {height:innerHeight,font:document.body.style.fontSize,lines:Array.from(r.getClientRects()).map(b=>({top:b.top,bottom:b.bottom,height:b.height}))};})()")
            print("COMBINED-LINE \(String(describing: metrics)) native=\(history.convert(history.bounds, to: f.window)) editor=\(editor.convert(editor.bounds, to: f.window)) keyboard=\(keyboard.frame)")
        }
        XCTAssertTrue(lineVisible, "Largest text and the real keyboard must still allow one complete saved-message line")
        XCTAssertTrue(self.visibleEditor(in: f.host.view) === editor, "Largest-text adaptation must retain its actual native draft editor")
        let historyFrame = history.convert(history.bounds, to: f.window)
        XCTAssertGreaterThanOrEqual(historyFrame.minY, f.window.bounds.minY)
        XCTAssertLessThanOrEqual(historyFrame.maxY, keyboard.frame.minY + 1)
        if try recognizedBounds("Reply", in: f.window) == nil {
            recordSheetEvidence(f, name: "Largest-Reply-fit-failure", keyboard: keyboard.frame)
            let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: f.host.traitCollection)
            print("REPLY-FIT font=\(font.pointSize) text=\(("Reply" as NSString).size(withAttributes:[.font:font])) OCR=\(try recognizedText(in:f.window))")
        }
        let replyBounds = try XCTUnwrap(recognizedBounds("Reply", in: f.window), "The actual Reply button remains visible at largest text while typing")
        XCTAssertLessThanOrEqual(replyBounds.maxY, keyboard.frame.minY + 1)
        XCTAssertGreaterThanOrEqual(editor.font?.pointSize ?? 0, 35)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 5, length: 4))
        let caret = editor.convert(editor.caretRect(for: try XCTUnwrap(editor.selectedTextRange).start), to: f.window)
        XCTAssertGreaterThanOrEqual(caret.minY, historyFrame.maxY)
        XCTAssertLessThanOrEqual(caret.maxY, keyboard.frame.minY + 1)
        XCTAssertEqual(editor.text, reply)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        recordSheetEvidence(f, name: "Sheet-largest-text-keyboard", keyboard: keyboard.frame)
        let metrics = try await history.evaluateJavaScript("(()=>{const p=document.querySelector('article .discussion-message-body p'),r=document.createRange();r.selectNodeContents(p);return {height:innerHeight,font:document.body.style.fontSize,lines:Array.from(r.getClientRects()).map(b=>({top:b.top,bottom:b.bottom,height:b.height}))};})()")
        print("FINAL-LARGEST nativeFont=\(editor.font?.pointSize ?? 0) history=\(String(describing: metrics)) keyboard=\(keyboard.frame) editor=\(editor.convert(editor.bounds, to: f.window))")
        editor.resignFirstResponder()
    }

    func testNativeAccessibilityTextCategoryKeepsRoomyWindowsInTheCompactSheet() async throws {
        let f = try await fixture(withThread: true)
        f.window.frame.size = CGSize(width: 1120, height: 874)
        f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
        let wide = await settledNavigation(f); XCTAssertTrue(wide && f.reader.discussionUsesMargin)
        f.host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        f.host.view.setNeedsLayout(); f.host.view.layoutIfNeeded()
        f.reader.openDiscussion("t-mobile")
        let compact = await poll { !f.reader.discussionUsesMargin && self.editor(in: f.host.view) != nil }
        XCTAssertTrue(compact, "Actual native text category must govern docking, including a roomy window")
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testLargestTextLeavesConversationSpaceWhileKeepingAnUnpostedReply() async throws {
        let f = try await fixture(withThread: true)
        try await assertAccessibleConversationFits(f, expectedSource: f.original)
    }

    func testLongQuoteStillLeavesConversationSpaceAtLargestText() async throws {
        let f = try await fixture(withThread: true)
        let passage = String(repeating: "Keep the complete quoted passage available to the reader. ", count: 8)
            .trimmingCharacters(in: .whitespaces)
        let source = """
        # Plan

        Before.

        \(passage)

        After.

        <!-- margined:thread v1
        id: t-mobile
        state: open
        target:
          type: TextQuoteSelector
          exact: "\(passage)"
          prefix: "Before."
          suffix: "After."
        messages:
          - id: m-mobile
            author: Reviewer
            created: "2026-10-23T10:00:00Z"
            body: "A portable note."
        -->

        """
        let data = Data(source.utf8)
        try data.write(to: f.file, options: .atomic)
        await f.reader.refresh(); await f.reader.waitForRendering()
        try await assertAccessibleConversationFits(f, expectedSource: data)
    }

    private func assertAccessibleConversationFits(_ f: Fixture, expectedSource: Data) async throws {
        f.window.frame.size = CGSize(width: 402, height: 874)
        f.host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
        f.reader.openDiscussion("t-mobile")
        let reply = "Keep this unposted reply at the chosen text size."
        f.reader.discussions.setDraft(reply, for: .thread("t-mobile"))
        try await waitForInitialHistory(f)
        let ready = await pollAsync {
            guard let history = self.history(in: f.host.view, excluding: f.web),
                  self.editor(in: f.host.view)?.text == reply else { return false }
            return try await history.evaluateJavaScript("document.querySelector('article[data-message-id=m-mobile]')?.textContent.includes('A portable note.')===true && parseFloat(document.body.style.fontSize)>=30") as? Bool == true
        }
        XCTAssertTrue(ready, "Measure the mounted conversation and real native composer, not an empty placeholder")
        guard ready else { return }
        let history = try XCTUnwrap(self.history(in: f.host.view, excluding: f.web))
        let editor = try XCTUnwrap(self.editor(in: f.host.view))
        // The history now owns its scroll instead of sitting in another
        // ScrollView. Measure its actual unclipped native viewport.
        let frame = history.convert(history.bounds, to: f.host.view)
        let available = frame.intersection(f.host.view.bounds).height
        // Native layout at 3x can allocate 419 pixels for the 420-pixel target.
        // Keep the measurement unrounded: allow one physical pixel plus floating-point roundoff.
        let scale = f.window.screen.scale
        let availablePixels = available * scale
        let targetPixels = CGFloat(140) * scale
        let floatingRoundoff = 8 * targetPixels.ulp
        XCTAssertGreaterThanOrEqual(availablePixels + floatingRoundoff, targetPixels - 1,
            "At the largest text size, the conversation still needs 140 points within one physical pixel; available=\(available), scale=\(scale)")
        XCTAssertGreaterThanOrEqual(editor.font?.pointSize ?? 0, 35,
            "Making room must not shrink the user's chosen accessibility text")
        XCTAssertEqual(editor.text, reply)
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, reply)
        XCTAssertEqual(try Data(contentsOf: f.file), expectedSource)
        let image = UIGraphicsImageRenderer(bounds: f.window.bounds).image { _ in
            f.window.drawHierarchy(in: f.window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Largest-text-conversation"
        attachment.lifetime = .keepAlways; add(attachment)
    }

    func testGoToPassageReturnsToTheRetainedDocumentAndRejectsStaleActions() async throws {
        let tail = (0..<120).map { "Long paragraph \($0) keeps the quoted passage above the current reading position.\n\n" }.joined()
        let f = try await fixture(withThread: true, tail: tail)
        let keyboard = MobileKeyboardFrameObservation(window: f.window)
        let knownPage = try await f.web.evaluateJavaScript("""
        window.passageDocument=document;
        window.duoPassageTrace=[];
        window.duoPassageScrollEndSupported='onscrollend' in document || 'onscrollend' in window;
        const quote=Array.from(document.querySelectorAll('main p')).find(p=>p.textContent.normalize('NFC').includes('Café bold passage.'));
        const rect=n=>{const r=n?.getBoundingClientRect();return r?{top:r.top,bottom:r.bottom,height:r.height}:null;};
        function observePassage(event) {
            const active=document.activeElement;
            const row={event,time:performance.now(),samePage:window.passageDocument===document,innerWidth,innerHeight,y:scrollY,
                clientWidth:document.documentElement.clientWidth,visualHeight:visualViewport?.height,
                active:active?.tagName,activeQuote:active?.textContent.normalize('NFC').includes('Café bold passage.')===true,
                activeRect:rect(active),quoteRect:rect(quote),token:document.documentElement.getAttribute('data-margined-mobile-token'),
                hit:document.elementFromPoint(innerWidth/2,Math.min(80,innerHeight/4))?.closest('p')?.textContent.slice(0,100)};
            window.duoPassageTrace.push(row);if(window.duoPassageTrace.length>50)window.duoPassageTrace.shift();
        }
        for(const event of ['scroll','resize','focusin','focusout','scrollend'])window.addEventListener(event,()=>observePassage(event),{passive:true});
        document.addEventListener('scrollend',()=>observePassage('scrollend'),{passive:true});
        observePassage('beforeInitialScroll');scrollTo(0,document.body.scrollHeight);observePassage('requestedInitialScroll');
        window.passageDocument===document;
        """) as? Bool
        XCTAssertEqual(knownPage, true, "Establish the known document in the same world used by later identity checks")
        let scrolled = await pollAsync { try await f.web.evaluateJavaScript("scrollY>500") as? Bool == true }
        XCTAssertTrue(scrolled)
        f.reader.openDiscussion("t-mobile")
        f.reader.discussions.setDraft("Keep my reply when showing its passage.", for: .thread("t-mobile"))
        let compact = await poll { self.visibleEditor(in: f.host.view)?.text == "Keep my reply when showing its passage." }
        XCTAssertTrue(compact); guard compact else { return }
        let version = f.reader.currentDiscussionVersion
        f.reader.goToDiscussion("t-mobile", version: version)
        let returned = await settledNavigation(f); XCTAssertTrue(returned)
        XCTAssertEqual(f.reader.discussionRoute, .thread("t-mobile"))
        XCTAssertEqual(f.reader.inspector, .discussions)
        let passage = await pollAsync {
            guard f.reader.discussionPassageRequest == nil else { return false }
            return try await f.web.evaluateJavaScript("window.passageDocument===document && document.activeElement?.textContent.normalize('NFC').includes('Café bold passage.')===true && document.activeElement.getBoundingClientRect().top>=0 && document.activeElement.getBoundingClientRect().bottom<innerHeight") as? Bool == true
        }
        // Cancellation can finish the older native motion before focus. Require
        // its recorded end when supported, then verify the painted native viewport
        // and every observed post-success position within the original poll budget.
        let supportsScrollEnd = try await f.web.evaluateJavaScript("window.duoPassageScrollEndSupported") as? Bool == true
        func passageMotionIsCommitted() async throws -> Bool {
            let configuration = WKSnapshotConfiguration(); configuration.afterScreenUpdates = true
            _ = try await f.web.takeSnapshot(configuration: configuration)
            let metrics = try await f.web.callAsyncJavaScript("""
            const trace=window.duoPassageTrace??[];
            const visible=e=>e.active==='P' && e.activeQuote && e.quoteRect?.top>=0 && e.quoteRect.bottom<e.innerHeight;
            const focus=trace.find(e=>e.event==='focusin' && e.active==='P' && e.activeQuote);
            const success=focus && trace.find(e=>e.time>=focus.time && e.event==='scroll' && visible(e));
            const end=!requiresEnd || trace.some(e=>e.event==='scrollend');
            const active=document.activeElement,r=active.getBoundingClientRect();
            const current=window.passageDocument===document && active.tagName==='P' &&
                active.textContent.normalize('NFC').includes('Café bold passage.') && r.top>=0 && r.bottom<innerHeight;
            return {x:scrollX,y:scrollY,continuous:!!success && end && current &&
                trace.filter(e=>e.time>=success.time && ['scroll','resize','scrollend'].includes(e.event)).every(visible)};
            """, arguments: ["requiresEnd": supportsScrollEnd], in: nil, contentWorld: .page) as? [String: Any]
            let scroll = f.web.scrollView
            guard !scroll.isTracking, !scroll.isDragging, !scroll.isDecelerating,
                  let x = metrics?["x"] as? Double, let y = metrics?["y"] as? Double,
                  let presentation = scroll.layer.presentation()?.bounds else { return false }
            let offset = scroll.contentOffset, model = scroll.bounds
            let physicalPixel = 1 / f.window.screen.scale
            return metrics?["continuous"] as? Bool == true &&
                abs(x - Double(offset.x)) <= 1 && abs(y - Double(offset.y)) <= 1 &&
                abs(presentation.minX - model.minX) <= physicalPixel &&
                abs(presentation.minY - model.minY) <= physicalPixel
        }
        let observedEnd = await pollAsync { try await passageMotionIsCommitted() }
        // Also inspect every frame after completion, so a transient jump's end
        // cannot hide the observed older motion resuming a few frames later.
        let remainedVisible = try await f.web.callAsyncJavaScript("""
        for(let frame=0;frame<12;frame++) {
            await new Promise(resolve=>requestAnimationFrame(resolve));
            const a=document.activeElement,r=a.getBoundingClientRect();
            if(window.passageDocument!==document || a.tagName!=='P' || !a.textContent.normalize('NFC').includes('Café bold passage.') || r.top<0 || r.bottom>=innerHeight)return false;
        }
        return true;
        """,arguments:[:],in:nil,contentWorld:.page) as? Bool == true
        let stillCommitted = try await passageMotionIsCommitted()
        let motionFinished = observedEnd && remainedVisible && stillCommitted
        // The original predicate is frozen before failure-only evidence.
        if !passage || !motionFinished {
            try await recordDuoGeometry(f, keyboard: keyboard, phase: "goTo-compact-\(passage)")
            let trace = try await f.web.evaluateJavaScript("if(typeof observePassage==='function')observePassage('afterOriginalPredicate');({knownPage:!!window.passageDocument,samePage:window.passageDocument===document,scrollEndSupported:window.duoPassageScrollEndSupported,trace:window.duoPassageTrace??null})")
            let state = try await f.web.callAsyncJavaScript("""
            const s=window.__marginedDiscussions;
            return {token:s?.token,sourceID:s?.sourceID,selected:s?.layout?.selected,
                ranges:s?.layout?.ranges.map(i=>({id:i.id,rects:Array.from(i.range.getClientRects()).map(r=>({top:r.top,bottom:r.bottom,height:r.height}))}))};
            """, arguments:[:],in:nil,contentWorld:MobileWebView.Coordinator.discussionWorld)
            let data = try JSONSerialization.data(withJSONObject:["passage":passage,"motionFinished":motionFinished,"page":trace ?? NSNull(),"discussion":state ?? NSNull(),"request":String(describing:f.reader.discussionPassageRequest)],options:[.sortedKeys])
            print("GOTO-TRACE " + String(decoding:data,as:UTF8.self))
            recordSheetEvidence(f, name:"GoTo-compact-failure")
        }
        XCTAssertTrue(passage, "Go to Passage must focus and reveal the actual quote after compact navigation")
        XCTAssertTrue(motionFinished, "The explicit passage jump must stay visible after older scroll motion finishes")
        XCTAssertNil(f.reader.discussionPassageRequest)
        XCTAssertTrue(self.webView(in: f.host.view) === f.web)
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "Keep my reply when showing its passage.")
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)

        f.window.frame.size = CGSize(width: 1120, height: 780)
        f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
        let wide = await settledNavigation(f); XCTAssertTrue(wide)
        f.reader.openDiscussion("t-mobile")
        f.reader.discussions.filter = .resolved // The unposted reply still makes this open thread reachable.
        XCTAssertTrue(f.reader.filteredDiscussionThreads.isEmpty)
        _ = try await f.web.evaluateJavaScript("scrollTo(0,document.body.scrollHeight);true")
        f.reader.goToDiscussion("t-mobile", version: version)
        let excluded = await pollAsync {
            guard f.reader.discussionPassageRequest == nil else { return false }
            return try await f.web.evaluateJavaScript("document.activeElement?.textContent.normalize('NFC').includes('Café bold passage.')===true && document.activeElement.getBoundingClientRect().top>=0 && document.activeElement.getBoundingClientRect().bottom<innerHeight") as? Bool == true
        }
        XCTAssertTrue(excluded, "A retained reply outside the filter still needs a passage route")
        XCTAssertEqual(f.reader.discussions.filter, .resolved)
        XCTAssertNil(f.reader.discussionPassageRequest)

        let replacement = Data(try MarkdownSource.decode(f.original).replacingOccurrences(of: "Before.", with: "Before changed externally.").utf8)
        try replacement.write(to: f.file, options: .atomic)
        await f.reader.refresh(); await f.reader.waitForRendering()
        let inspector = f.reader.inspector
        f.reader.goToDiscussion("t-mobile", version: version)
        XCTAssertNil(f.reader.discussionPassageRequest, "An old source-version action cannot navigate the refreshed file")
        XCTAssertEqual(f.reader.inspector, inspector)
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "Keep my reply when showing its passage.")
        XCTAssertEqual(try Data(contentsOf: f.file), replacement)
    }

    func testHideReopensTheRetainedThreadWhileBackKeepsTheListAcrossWidths() async throws {
        let f = try await fixture(withThread: true)
        let key = DiscussionSession.DraftKey.thread("t-mobile")
        let draft = "Keep my unposted reply."
        let caret = NSRange(location: 5, length: 3)
        let historyPosition = f.reader.discussionHistoryPosition(for: "t-mobile")
        let document = f.reader.documentGeneration
        _ = try await f.web.evaluateJavaScript("window.hideDiscussionReadingPage=document;true")
        f.reader.discussions.filter = .all
        for width in [CGFloat(1120), CGFloat(390)] {
            f.window.frame.size = CGSize(width: width, height: 780)
            f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
            let settled = await settledNavigation(f); XCTAssertTrue(settled)
            XCTAssertEqual(f.reader.discussionUsesMargin, width == 1120)
            f.reader.openDiscussion("t-mobile")
            f.reader.discussions.setDraft(draft, for: key)
            if width == 1120 { try await waitForInitialHistory(f) }
            let initial = await pollAsync {
                guard let web = self.history(in: f.host.view, excluding: f.web) else { return false }
                return try await web.evaluateJavaScript("document.querySelector('article[data-message-id=m-mobile]')?.textContent.includes('A portable note.')===true") as? Bool == true
            }
            XCTAssertTrue(initial); guard initial else { return }
            let editor = try XCTUnwrap(self.editor(in: f.host.view))
            editor.selectedRange = caret; editor.delegate?.textViewDidChangeSelection?(editor)
            let workspace = MobileDocumentWorkspace(reader: f.reader, openFolder: {}, closeFile: {})
            let old = workspace.navigationBinding()
            let presentation = f.reader.discussionPresentationGeneration
            if f.reader.discussionUsesMargin { f.reader.hideDiscussions() }
            else { workspace.navigationBinding().wrappedValue = [] }
            let hidden = await poll { self.history(in: f.host.view, excluding: f.web) == nil }
            XCTAssertTrue(hidden)
            XCTAssertNil(f.reader.inspector)
            XCTAssertEqual(f.reader.discussionRoute, key, "Hide must retain thread intent at width \(width)")
            XCTAssertNotEqual(f.reader.discussionPresentationGeneration, presentation, "Hide invalidates queued native bindings even when retaining its route")
            f.reader.inspector = .discussions
            let reopened = await pollAsync {
                guard let web = self.history(in: f.host.view, excluding: f.web) else { return false }
                return try await web.evaluateJavaScript("document.querySelector('article[data-message-id=m-mobile]')?.textContent.includes('A portable note.')===true") as? Bool == true
            }
            XCTAssertTrue(reopened, "Hide/show must reload retained history without another openDiscussion call at width \(width)")
            XCTAssertEqual(self.editor(in: f.host.view)?.selectedRange, caret)
            old.wrappedValue = []
            XCTAssertEqual(f.reader.inspector, .discussions, "A pre-Hide binding cannot dismiss the reopened inspector")
            XCTAssertEqual(f.reader.discussionRoute, key)
            XCTAssertTrue(f.reader.discussionHistoryPosition(for: "t-mobile") === historyPosition)
            XCTAssertEqual(f.reader.discussions.drafts[key]?.body, draft)
            XCTAssertEqual(f.reader.discussionComposerSelections[key], caret)
        }
        f.reader.backToDiscussionList()
        for width in [CGFloat(390), CGFloat(1120)] {
            f.window.frame.size = CGSize(width: width, height: 780)
            f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
            let settled = await settledNavigation(f); XCTAssertTrue(settled)
            let list = await poll { self.editor(in: f.host.view) == nil && self.history(in: f.host.view, excluding: f.web) == nil }
            XCTAssertTrue(list, "Back remains the list at width \(width)")
            XCTAssertTrue(try recognizedText(in: f.window).contains("All"), "The actual discussion filter must be visible")
            XCTAssertNil(f.reader.discussionRoute)
            f.reader.hideDiscussions(); f.reader.inspector = .discussions
            let shown = await settledNavigation(f); XCTAssertTrue(shown)
            XCTAssertNil(f.reader.discussionRoute, "Hiding a list must retain list intent")
            XCTAssertNil(self.editor(in: f.host.view))
        }
        XCTAssertEqual(f.reader.discussions.selection, key)
        XCTAssertEqual(f.reader.discussions.drafts[key]?.body, draft)
        XCTAssertEqual(f.reader.discussionComposerSelections[key], caret)
        XCTAssertTrue(self.webView(in: f.host.view) === f.web)
        let samePage = try await f.web.evaluateJavaScript("window.hideDiscussionReadingPage===document") as? Bool
        XCTAssertEqual(samePage, true)
        XCTAssertEqual(Data(f.reader.source.utf8), f.original)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        let oldDocument = MobileDocumentWorkspace(reader: f.reader, openFolder: {}, closeFile: {}).navigationBinding()
        f.reader.discussions.discardDrafts(); await f.reader.close()
        oldDocument.wrappedValue = [.thread(key)]
        XCTAssertNotEqual(f.reader.documentGeneration, document)
        XCTAssertNil(f.reader.inspector); XCTAssertNil(f.reader.discussionRoute)
        XCTAssertTrue(f.reader.discussionComposerSelections.isEmpty)
        XCTAssertTrue(f.reader.discussionHistoryPositions.isEmpty)
    }

    func testCurrentFileDiagnosticsAreVisibleInCompactAndDockedDiscussions() async throws {
        let f = try await fixture(withThread: true)
        let parsed = try DiscussionCodec.parse(MarkdownSource.read(f.file))
        let block = try XCTUnwrap(parsed.blocks.first)
        let raw = String(decoding: Array(parsed.source.utf8)[block.range], as: UTF8.self)
        let duplicate = raw.replacingOccurrences(of: "t-mobile", with: "t-duplicate").replacingOccurrences(of: "m-mobile", with: "m-duplicate")
        let future = raw.replacingOccurrences(of: "v1\n", with: "v9\n")
        let malformed = raw.replacingOccurrences(of: "state: open", with: "state: [unterminated")
        let bytes = f.original + Data(("\n\n" + future + "\n\n" + malformed + "\n\n" + duplicate + "\n\n" + duplicate).utf8)
        try bytes.write(to: f.file, options: .atomic)
        await f.reader.refresh(); await f.reader.waitForRendering()
        XCTAssertFalse(try XCTUnwrap(f.reader.rendered?.discussions).diagnostics.isEmpty)
        XCTAssertEqual(f.reader.rendered?.discussions?.threads.map(\.id), ["t-mobile"])
        f.reader.inspector = .discussions
        for width in [CGFloat(390), CGFloat(1120)] {
            f.window.frame.size = CGSize(width: width, height: 780)
            f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
            let settled = await settledNavigation(f); XCTAssertTrue(settled)
            let warning = try recognizedText(in: f.window)
            XCTAssertTrue(warning.contains("Some discussions are unavailable"), "Current-file warnings must be visible at width \(width): \(warning)")
            XCTAssertTrue(warning.contains("Show Source"), "Recovery source must be available without editing Markdown")
        }
        XCTAssertEqual(Data(f.reader.source.utf8), bytes)
        XCTAssertEqual(try Data(contentsOf: f.file), bytes)
    }

    func testMobileConversationOffersExplicitPassageNavigation() async throws {
        let f = try await fixture(withThread: true)
        f.window.frame.size = CGSize(width: 1120, height: 780)
        f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
        let settled = await settledNavigation(f); XCTAssertTrue(settled)
        f.reader.openDiscussion("t-mobile")
        let composer = await poll { self.editor(in: f.host.view) != nil }; XCTAssertTrue(composer)
        let text = try recognizedText(in: f.window)
        XCTAssertTrue(text.contains("Go to Passage"), "A visible discussion needs a route to its actual passage: \(text)")
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    private func recordDuoGeometry(_ f: Fixture, keyboard: MobileKeyboardFrameObservation, phase: String) async throws {
        let window=f.window,screen=window.screen,root=f.host.view!
        func frame(_ view:UIView)->String { String(describing:view.convert(view.bounds,to:window)) }
        func all(_ view:UIView)->[UIView] { [view]+view.subviews.flatMap(all) }
        func dom(_ web:WKWebView,world:WKContentWorld) async throws -> Any {
            try await web.callAsyncJavaScript("""
            const r=document.querySelector('main')?.getBoundingClientRect();
            return {innerWidth,innerHeight,y:scrollY,client:document.documentElement.clientWidth,pageHeight:document.documentElement.scrollHeight,
                visual:visualViewport?{width:visualViewport.width,height:visualViewport.height,top:visualViewport.offsetTop,scale:visualViewport.scale}:null,
                font:document.body.style.fontSize,main:r?{top:r.top,bottom:r.bottom,width:r.width}:null,
                historyToken:document.documentElement.getAttribute('data-margined-history-token'),mobileToken:document.documentElement.getAttribute('data-margined-mobile-token'),
                observing:typeof window.marginedReadingResize?.stop==='function',articles:document.querySelectorAll('article').length};
            """,arguments:[:],in:nil,contentWorld:world) ?? NSNull()
        }
        var data:[String:Any]=["phase":phase,"windowFrame":String(describing:window.frame),"windowBounds":String(describing:window.bounds),
            "windowTransform":String(describing:window.transform),"windowSafe":String(describing:window.safeAreaInsets),"key":window.isKeyWindow,"hidden":window.isHidden,
            "windowOnScreen":String(describing:window.convert(window.bounds,to:screen.coordinateSpace)),"screen":String(describing:screen.bounds),
            "screenCoordinate":String(describing:screen.coordinateSpace.bounds),"screenFixed":String(describing:screen.fixedCoordinateSpace.bounds),"nativeScreen":String(describing:screen.nativeBounds),
            "sceneBounds":String(describing:window.windowScene?.coordinateSpace.bounds),"sceneID":window.windowScene?.session.persistentIdentifier ?? "none","orientation":window.windowScene?.interfaceOrientation.rawValue ?? -1,
            "hostFrame":String(describing:root.frame),"hostBounds":String(describing:root.bounds),"hostSafe":String(describing:root.safeAreaInsets),"hostTransform":String(describing:root.transform),
            "windowKeyboardGuide":String(describing:window.keyboardLayoutGuide.layoutFrame),"hostKeyboardGuide":String(describing:root.convert(root.keyboardLayoutGuide.layoutFrame,to:window)),
            "notificationFrame":String(describing:keyboard.frame),"notifications":keyboard.diagnostics,
            "readerFrame":frame(f.web),"readerBounds":String(describing:f.web.bounds),"readerSafe":String(describing:f.web.safeAreaInsets),
            "expanded":f.reader.discussionSheetExpanded,"focus":String(describing:f.reader.discussionFocus)]
        func nav(_ controller:UIViewController)->UINavigationController? {
            if let value=controller as? UINavigationController{return value}
            return controller.children.lazy.compactMap(nav).first
        }
        if let navigation=nav(f.host),let top=navigation.topViewController?.viewIfLoaded {
            data["navigation"]=["frame":frame(navigation.view),"bounds":String(describing:navigation.view.bounds),"safe":String(describing:navigation.view.safeAreaInsets),
                "topFrame":frame(top),"topBounds":String(describing:top.bounds),"topSafe":String(describing:top.safeAreaInsets),"topSafeFrame":String(describing:top.convert(top.safeAreaLayoutGuide.layoutFrame,to:window)),
                "topKeyboardGuide":String(describing:top.convert(top.keyboardLayoutGuide.layoutFrame,to:window)),"transition":navigation.transitionCoordinator != nil]
        }
        data["generation"]=["document":String(describing:f.reader.documentGeneration),"layout":String(describing:f.reader.discussionLayoutGeneration),"intent":String(describing:f.reader.discussionPresentationGeneration),"route":String(describing:f.reader.discussionRoute)]
        data["allEditors"]=all(root).compactMap{view->[String:Any]? in
            guard let editor=view as? UITextView,editor.isEditable else{return nil}
            return ["id":String(describing:ObjectIdentifier(editor)),"first":editor.isFirstResponder,"frame":frame(editor),"hidden":editor.isHidden,"ownedWindow":editor.window===window]
        }
        data["identifiedViews"]=all(root).filter{$0.accessibilityIdentifier=="compact-discussion-sheet" || $0 is UITextField || ($0.accessibilityIdentifier?.hasPrefix("discussion-") == true)}.prefix(12).map{view in
            ["class":String(describing:type(of:view)),"id":view.accessibilityIdentifier ?? "none","label":view.accessibilityLabel ?? "none","frame":frame(view)]
        }
        data["scenes"]=UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.map{scene in
            ["id":scene.session.persistentIdentifier,"activation":scene.activationState.rawValue,"orientation":scene.interfaceOrientation.rawValue,"bounds":String(describing:scene.coordinateSpace.bounds),"keyOwned":scene.keyWindow===window] as [String:Any]
        }
        data["keyboardHelpers"]=all(root).filter{String(describing:type(of:$0)).contains("MobileDiscussionKeyboardViewportView")}.map{view in
            ["class":String(describing:type(of:view)),"frame":frame(view),"bounds":String(describing:view.bounds),"safe":String(describing:view.safeAreaInsets),
             "ownedWindow":view.window===window,"occlusion":keyboard.lastScreenFrame.map{String(describing:view.convert($0,from:screen.coordinateSpace).intersection(view.bounds))} ?? "none"] as [String:Any]
        }
        if let editor=editor(in:root) {data["editor"]=["frame":frame(editor),"bounds":String(describing:editor.bounds),"safe":String(describing:editor.safeAreaInsets),"first":editor.isFirstResponder,"ownedWindow":editor.window===window,"font":editor.font?.pointSize ?? -1]}
        if let history=history(in:root,excluding:f.web) {
            data["history"]=["frame":frame(history),"bounds":String(describing:history.bounds),"safe":String(describing:history.safeAreaInsets),
                "scrollBounds":String(describing:history.scrollView.bounds),"scrollContent":String(describing:history.scrollView.contentSize),"scrollOffset":String(describing:history.scrollView.contentOffset),"scrollAdjusted":String(describing:history.scrollView.adjustedContentInset)]
            data["historyDOM"]=try await dom(history,world:.world(name:"MarginedDiscussionHistory"))
        }
        data["readerDOM"]=try await dom(f.web,world:MobileWebView.Coordinator.contentWorld)
        let encoded=try JSONSerialization.data(withJSONObject:data,options:[.sortedKeys]);print("DUO-MOBILE "+String(decoding:encoded,as:UTF8.self))
    }

    private func recordSheetEvidence(_ fixture: Fixture, name: String, keyboard: CGRect? = nil) {
        let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
            fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
        }
        let capture = XCTAttachment(image: image); capture.name = name; capture.lifetime = .keepAlways; add(capture)
        let editorFrame = editor(in: fixture.host.view).map { $0.convert($0.bounds, to: fixture.window) }
        let historyFrame = history(in: fixture.host.view, excluding: fixture.web).map { $0.convert($0.bounds, to: fixture.window) }
        let metrics = XCTAttachment(string: "reader=\(fixture.web.convert(fixture.web.bounds, to: fixture.window)) editor=\(String(describing: editorFrame)) history=\(String(describing: historyFrame)) keyboard=\(String(describing: keyboard)) expanded=\(fixture.reader.discussionSheetExpanded)")
        metrics.name = name + "-geometry"; metrics.lifetime = .keepAlways; add(metrics)
    }

    private func recognizedBounds(_ text: String, in window: UIWindow) throws -> CGRect? {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return try recognizedBounds(text, in: XCTUnwrap(image.cgImage), size: window.bounds.size)
    }

    private func recognizedBounds(_ text: String, in image: CGImage, size: CGSize) throws -> CGRect? {
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            // Vision may group neighboring controls in one text row. Match an
            // exact word and retain its glyph bounds for the clipping checks.
            var wordRange: Range<String.Index>?
            candidate.string.enumerateSubstrings(in: candidate.string.startIndex..<candidate.string.endIndex, options: .byWords) { word, range, _, stop in
                if word == text { wordRange = range; stop = true }
            }
            guard let wordRange, let box = try candidate.boundingBox(for: wordRange)?.boundingBox else { continue }
            return CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                width: box.width * size.width, height: box.height * size.height)
        }
        print("WORD-BOUNDS-OCR-MISS target=\(String(reflecting: text)) observations=\((request.results ?? []).compactMap { $0.topCandidates(1).first?.string })")
        return nil
    }

    private func recognizedText(in window: UIWindow) throws -> String {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    func testChangesAndConversationHistoryShareTheAdaptiveIPadPanel() async throws {
        let f = try await fixture(withThread: true)
        _ = try await f.web.evaluateJavaScript("window.panelReadingPage=document;true")
        f.reader.openDiscussion("t-mobile")
        f.reader.discussions.setDraft("Keep this reply while switching panels.", for: .thread("t-mobile"))
        try await waitForInitialHistory(f)
        for size in [CGSize(width: 1194, height: 834), CGSize(width: 834, height: 1194),
                     CGSize(width: 1376, height: 1032), CGSize(width: 1032, height: 1376)] {
            f.window.frame.size = size
            f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
            let discussionSettled = await settledNavigation(f)
            XCTAssertTrue(discussionSettled, "Discussion layout must settle at \(size)")
            guard discussionSettled else { return }
            let docked = f.reader.discussionUsesMargin
            if size.width == 834 {
                XCTAssertFalse(docked, "11-inch portrait keeps readable document width")
            } else if size.width >= 1194 {
                XCTAssertTrue(docked, "The two landscape controls must exercise the docked panel")
            } else {
                // A resized host can reserve native chrome inside a 13-inch
                // portrait frame. Judge its actual reading area, not its shell.
                func navigation(in controller: UIViewController) -> UINavigationController? {
                    if let value = controller as? UINavigationController { return value }
                    return controller.children.lazy.compactMap { navigation(in: $0) }.first
                }
                let top = try XCTUnwrap(navigation(in: f.host)?.topViewController?.viewIfLoaded)
                let minimum = DiscussionMarginLayout.minimumDocumentWidth(
                    bodyFont: f.reader.discussionMargin?.bodyFont ?? 16 * f.reader.zoom,
                    horizontalInsets: max(88, f.reader.discussionMargin?.horizontalInsets ?? 88), outlineWidth: 0)
                let expected = !top.traitCollection.preferredContentSizeCategory.isAccessibilityCategory &&
                    top.safeAreaLayoutGuide.layoutFrame.width >= minimum + 341
                XCTAssertEqual(docked, expected, "Portrait docking follows actual native usable width and text size")
            }
            let historyReady = await pollAsync {
                guard let history = self.history(in: f.host.view, excluding: f.web) else { return false }
                return try await history.evaluateJavaScript("document.querySelector('article[data-message-id=m-mobile]')?.textContent.includes('A portable note.')===true") as? Bool == true
            }
            XCTAssertTrue(historyReady, "The saved conversation must render before checking the panel")
            guard historyReady else { return }
            let discussionImage = UIGraphicsImageRenderer(bounds: f.window.bounds).image { _ in
                f.window.drawHierarchy(in: f.window.bounds, afterScreenUpdates: true)
            }
            let discussionCapture = XCTAttachment(image: discussionImage)
            discussionCapture.name = "Discussions-\(Int(size.width))x\(Int(size.height))"
            discussionCapture.lifetime = .keepAlways; add(discussionCapture)
            let readingWidth = f.web.bounds.width
            f.reader.inspector = .changes
            let reviewSettled = await settledNavigation(f)
            XCTAssertTrue(reviewSettled, "Changing inspector must preserve native navigation at \(size)")
            let presented = await poll {
                if docked { return f.host.presentedViewController == nil && abs(f.web.bounds.width - readingWidth) < 1 }
                return f.host.presentedViewController != nil
            }
            XCTAssertTrue(presented, "Review and discussions must use the same docking decision")
            let changesImage = UIGraphicsImageRenderer(bounds: f.window.bounds).image { _ in
                f.window.drawHierarchy(in: f.window.bounds, afterScreenUpdates: true)
            }
            let changesCapture = XCTAttachment(image: changesImage)
            changesCapture.name = "Changes-\(Int(size.width))x\(Int(size.height))"
            changesCapture.lifetime = .keepAlways; add(changesCapture)
            f.reader.inspector = .discussions
            let returned = await poll { self.visibleEditor(in: f.host.view)?.text == "Keep this reply while switching panels." }
            XCTAssertTrue(returned, "The selected conversation and reply remain reachable")
            XCTAssertEqual(f.reader.discussionRoute, .thread("t-mobile"))
            XCTAssertTrue(self.webView(in: f.host.view) === f.web)
            let retained = try await f.web.evaluateJavaScript("window.panelReadingPage===document") as? Bool
            XCTAssertEqual(retained, true)
        }
        XCTAssertEqual(try Data(contentsOf: f.file), f.original, "Layout never writes comments or checkmarks")
    }

    func testNativeWidthTracksParentResizeWhenContentKeepsItsSize() async throws {
        var reported: Double?
        let content = NavigationStack {
            Color.clear.frame(width: 120, height: 120)
                .modifier(MobileWorkspaceWidthReporter(viewport: CGSize(width: 1120, height: 780),
                    active: true, report: { reported = $0 }))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle("Width measurement")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: content)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1120, height: 780)
        window.rootViewController = host; window.makeKeyAndVisible()
        host.loadViewIfNeeded(); host.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        func navigation(in controller: UIViewController) -> UINavigationController? {
            if let value = controller as? UINavigationController { return value }
            return controller.children.lazy.compactMap { navigation(in: $0) }.first
        }
        func matchesNativeWidth() -> Bool {
            guard let nav = navigation(in: host), nav.transitionCoordinator == nil,
                  let top = nav.topViewController?.viewIfLoaded,
                  top.bounds.size == window.bounds.size, let reported else { return false }
            return abs(reported - Double(top.safeAreaLayoutGuide.layoutFrame.width)) < 1
        }
        let initial = await poll { matchesNativeWidth() }
        XCTAssertTrue(initial, "The native-width fixture must establish its initial wide measurement")
        guard initial else { return }
        let wide = try XCTUnwrap(reported)
        window.frame.size = CGSize(width: 390, height: 780)
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        let resized = await poll { matchesNativeWidth() && (reported ?? wide) < wide - 100 }
        XCTAssertTrue(resized,
                      "Available width must follow the native parent when the reader content keeps its own size")
    }

    func testActualFormattedSelectionStartsAnUnpostedNativeComposer() async throws {
        let f = try await fixture()
        _ = try await f.web.callAsyncJavaScript("""
        const paragraph=Array.from(document.querySelectorAll('main p')).find(p=>p.textContent.includes('bold'));
        const range=document.createRange();range.selectNodeContents(paragraph);
        getSelection().removeAllRanges();getSelection().addRange(range);return true;
        """, arguments: [:], in: nil, contentWorld: .defaultClient)
        f.reader.requestAddDiscussion()
        let selected = await poll { f.reader.discussions.selection != nil }
        XCTAssertTrue(selected, "Add Discussion must read the current native WebKit selection")
        if let key = f.reader.discussions.selection {
            XCTAssertEqual(f.reader.discussions.drafts[key]?.target?.exact, "Café bold passage.")
            XCTAssertEqual(f.reader.discussionRoute, key)
            f.reader.discussions.setDraft("Keep this unposted note.", for: key)
            let visible = await poll { self.editor(in: f.host.view)?.text == "Keep this unposted note." }
            XCTAssertTrue(visible, "The composer belongs to the native UI, outside the document WebView")
        }
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testDiscussionVisibilityDecoratesExistingPageWithoutReloadingOrWriting() async throws {
        let f = try await fixture(withThread: true)
        _ = try await f.web.evaluateJavaScript("window.mobileDiscussionPage=document;true")
        f.reader.inspector = .discussions
        let decorated = await pollAsync {
            try await f.web.evaluateJavaScript("document.querySelectorAll('[data-margined-thread]').length") as? Int == 1
        }
        XCTAssertTrue(decorated, "Showing discussions must install the shared isolated marker bridge")
        f.reader.hideDiscussions()
        let hidden = await pollAsync {
            try await f.web.evaluateJavaScript("document.querySelectorAll('[data-margined-thread]').length") as? Int == 0
        }
        XCTAssertTrue(hidden)
        XCTAssertNil(f.reader.inspector)
        let retained = try await f.web.evaluateJavaScript("window.mobileDiscussionPage===document") as? Bool
        XCTAssertEqual(retained, true)
        XCTAssertTrue(self.webView(in: f.host.view) === f.web)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testBackAndWidthChangesRetainReplyAndTheMountedReadingPage() async throws {
        let f = try await fixture(withThread: true)
        _ = try await f.web.evaluateJavaScript("window.mobileDiscussionPage=document;true")
        f.reader.openDiscussion("t-mobile")
        f.reader.discussions.setDraft("A reply retained across layouts.", for: .thread("t-mobile"))
        let composer = await poll { self.editor(in: f.host.view)?.text == "A reply retained across layouts." }
        XCTAssertTrue(composer, "Opening a thread must expose its native reply editor")
        XCTAssertEqual(f.reader.discussionRoute, .thread("t-mobile"))
        f.reader.backToDiscussionList()
        XCTAssertNil(f.reader.discussionRoute)
        XCTAssertEqual(f.reader.inspector, .discussions)
        f.reader.hideDiscussions()
        XCTAssertNil(f.reader.inspector)
        f.window.frame.size = CGSize(width: 1_024, height: 780)
        f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
        f.reader.openDiscussion("t-mobile")
        let visibleAfterResize = await poll { self.editor(in: f.host.view)?.text == "A reply retained across layouts." }
        XCTAssertTrue(visibleAfterResize)
        f.reader.inspector = .changes
        f.reader.inspector = .discussions
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "A reply retained across layouts.")
        f.reader.hideDiscussions()
        _ = await poll { self.webView(in: f.host.view) != nil }
        XCTAssertTrue(webView(in: f.host.view) === f.web)
        let retained = try await f.web.evaluateJavaScript("window.mobileDiscussionPage===document") as? Bool
        XCTAssertEqual(retained, true)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testLiveWindowResizingKeepsTheOpenReplyAndDocumentIdentity() async throws {
        let paragraphs = (0..<100).map { "Paragraph \($0) keeps the document long enough to test its reading position while an unfinished reply moves between compact navigation and the margin." }.joined(separator: "\n\n")
        let f = try await fixture(withThread: true, tail: "\n\n" + paragraphs)
        let context = f.reader.documentGeneration
        let observing = await pollAsync {
            try await f.web.callAsyncJavaScript("return typeof window.marginedReadingResize?.stop==='function';",
                arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld) as? Bool == true
        }
        XCTAssertTrue(observing, "Install the app observer before establishing its reading position")
        _ = try await f.web.callAsyncJavaScript("""
        await document.fonts.ready;
        window.mobileResizePage=document;
        const passage=Array.from(document.querySelectorAll('main p')).find(p=>p.textContent.startsWith('Paragraph 35 '));
        passage.id='resize-reading-passage';
        passage.scrollIntoView({block:'start',behavior:'instant'});
        await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
        return true;
        """, arguments: [:], in: nil, contentWorld: .defaultClient)
        try await settleMobileResizeObserver(f.web)
        var seed: [String: Any] = [:], seedEvidence: [String: Any] = [:]
        let seedReady = await pollAsync {
            try await self.resizeSeedHasCommitted(f, metrics: &seed, evidence: &seedEvidence)
        }
        XCTAssertTrue(seedReady, "Establish the native reading position before opening its conversation: \(seedEvidence)")
        XCTAssertEqual(seed["visible"] as? Bool, true, "Establish the actual passage before opening its conversation")
        XCTAssertGreaterThan(seed["scroll"] as? Double ?? 0, 0)
        guard seedReady else { return }
        f.reader.openDiscussion("t-mobile")
        f.reader.discussions.setDraft("An unfinished reply across both displays.", for: .thread("t-mobile"))
        let initial = await poll { self.visibleEditor(in: f.host.view)?.text == "An unfinished reply across both displays." }
        XCTAssertTrue(initial)
        // These are window shapes, not device detection or a simulated fold.
        // Safe areas and vertical system bars can make the same outer size use
        // different layouts; require retained state and exercise both modes.
        var sawMargin = false, sawCompact = false
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        var beforeHide: [String: Any] = [:]
        var lastStagePaint: UIImage?
        for size in [CGSize(width: 890, height: 626), CGSize(width: 626, height: 890),
                     CGSize(width: 466, height: 678), CGSize(width: 1_120, height: 780),
                     CGSize(width: 890, height: 626)] {
            f.window.frame.size = size
            f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
            let settled = await poll {
                self.visibleEditor(in: f.host.view)?.text == "An unfinished reply across both displays."
            }
            XCTAssertTrue(settled, "The same selected conversation and unposted reply must survive every live resize")
            let nativeSettled = await settledNavigation(f)
            XCTAssertTrue(nativeSettled, "The actual native top controller must finish resizing before assessing the layout")
            let widthCommitted = await pollAsync {
                try await self.readingWidthHasCommitted(f)
            }
            XCTAssertTrue(widthCommitted, "Commit the actual native reader width before its next resize")
            try await settleMobileResizeObserver(f.web)
            // Each next resize starts from the requested, displayed pane, not
            // merely two layers that still agree on the previous width.
            lastStagePaint = try await f.web.takeSnapshot(configuration: configuration)
            var stage: [String: Any] = [:]
            let passageSettled = await pollAsync {
                stage = try await self.resizeReadingMetrics(f.web)
                guard stage["visible"] as? Bool == true, let y = stage["scroll"] as? Double,
                      let width = stage["width"] as? Double else { return false }
                return self.readingWidthMatchesRequested(f, cssWidth: width) &&
                    abs(y - Double(f.web.scrollView.contentOffset.y)) <= 1
            }
            XCTAssertTrue(passageSettled, "The reading passage must be visible before the next intentional resize or hide")
            beforeHide = ["window": String(describing: size), "dom": stage,
                "readerBounds": String(describing: f.web.bounds), "nativeOffset": String(describing: f.web.scrollView.contentOffset),
                "nativePresentation": String(describing: f.web.scrollView.layer.presentation()?.bounds),
                "expectedWidth": requestedReadingWidth(f) as Any? ?? NSNull()]
            sawMargin = sawMargin || f.reader.discussionUsesMargin
            sawCompact = sawCompact || !f.reader.discussionUsesMargin
            XCTAssertEqual(f.reader.discussionRoute, .thread("t-mobile"))
            XCTAssertEqual(f.reader.documentGeneration, context)
            XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "An unfinished reply across both displays.")
        }
        XCTAssertTrue(sawMargin && sawCompact, "The test must actually move the reply between native navigation and the margin")
        f.reader.hideDiscussions()
        let visible = await poll { self.webView(in: f.host.view) === f.web }
        XCTAssertTrue(visible)
        let samePage = try await f.web.callAsyncJavaScript("return window.mobileResizePage===document;",
            arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        XCTAssertEqual(samePage, true, "Resizing must retain the mounted document instead of reloading it")
        let returned = await settledNavigation(f)
        XCTAssertTrue(returned, "Return must finish the native pop and display the retained reading page")
        let widthReturned = await pollAsync { try await self.readingWidthHasCommitted(f) }
        XCTAssertTrue(widthReturned, "Hiding the conversation must commit the full native reader allocation")
        // An unattached page cannot complete requestAnimationFrame. Preserve the
        // failed assertions above without hanging before XCTest can report them.
        guard visible, returned, widthReturned else { return }
        // The DOM can report its restored offset before the native viewport
        // commits it. Assess the returned reading page after screen updates.
        let image = try await f.web.takeSnapshot(configuration: configuration)
        let reading = try await resizeReadingMetrics(f.web)
        let nativeY = Double(f.web.scrollView.contentOffset.y)
        let domY = try XCTUnwrap(reading["scroll"] as? Double)
        let finalWidth = try XCTUnwrap(reading["width"] as? Double)
        let finalWidthMatches = readingWidthMatchesRequested(f, cssWidth: finalWidth)
        if reading["visible"] as? Bool != true || abs(domY - nativeY) > 1 || !finalWidthMatches {
            if let lastStagePaint {
                let before = XCTAttachment(image: lastStagePaint)
                before.name = "Last-resize-stage-paint-before-visibility-poll"
                before.lifetime = .keepAlways; add(before)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Resize-return-reading-position"
            attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertTrue(finalWidthMatches, "The final reading sample must describe the requested full reader allocation")
        XCTAssertEqual(domY, nativeY, accuracy: 1, "DOM and native viewport must describe the same painted reading position")
        XCTAssertEqual(reading["visible"] as? Bool, true,
                       "Returning from a compact conversation must retain the passage being read: before Hide \(beforeHide), after \(reading), native bounds \(f.web.bounds), offset \(f.web.scrollView.contentOffset)")
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testReadingResizeRetainsPassageWhenWindowDimensionsLagTheLayout() async throws {
        let paragraphs = (0..<100).map { "Paragraph \($0) keeps the document long enough to test its reading position while an unfinished reply moves between compact navigation and the margin." }.joined(separator: "\n\n")
        let f = try await fixture(withThread: true, tail: "\n\n" + paragraphs)
        f.window.frame.size = CGSize(width: 890, height: 626)
        f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
        let wide = await settledNavigation(f)
        XCTAssertTrue(wide)
        f.reader.openDiscussion("t-mobile")
        f.reader.discussions.setDraft("Keep the passage when closing this reply.", for: .thread("t-mobile"))
        let composer = await poll { self.visibleEditor(in: f.host.view)?.text == "Keep the passage when closing this reply." }
        XCTAssertTrue(composer)
        let settled = await settledNavigation(f)
        let committed = await pollAsync { try await self.readingWidthHasCommitted(f) }
        XCTAssertTrue(settled && committed && f.reader.discussionUsesMargin)
        guard settled, committed, f.reader.discussionUsesMargin else { return }
        let observing = await pollAsync {
            try await f.web.callAsyncJavaScript("return typeof window.marginedReadingResize?.stop==='function';",
                arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld) as? Bool == true
        }
        XCTAssertTrue(observing)
        // Establish the displayed discussion pane before the test's explicit
        // reading jump; opening it also changes the reader's native allocation.
        let configuration = WKSnapshotConfiguration(); configuration.afterScreenUpdates = true
        _ = try await f.web.takeSnapshot(configuration: configuration)
        try await settleMobileResizeObserver(f.web)
        _ = try await f.web.callAsyncJavaScript("""
        await document.fonts.ready;
        window.mobileResizePage=document;
        const passage=Array.from(document.querySelectorAll('main p')).find(p=>p.textContent.startsWith('Paragraph 35 '));
        passage.id='resize-reading-passage';
        passage.scrollIntoView({block:'start',behavior:'instant'});
        await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
        return true;
        """, arguments: [:], in: nil, contentWorld: .defaultClient)
        try await settleMobileResizeObserver(f.web)
        var initialReading: [String: Any] = [:], seedEvidence: [String: Any] = [:]
        let seedReady = await pollAsync {
            try await self.resizeSeedHasCommitted(f, metrics: &initialReading, evidence: &seedEvidence)
        }
        XCTAssertTrue(seedReady, "Establish the native reading position before changing its allocation: \(seedEvidence)")
        XCTAssertEqual(initialReading["visible"] as? Bool, true)
        guard seedReady, initialReading["visible"] as? Bool == true else { return }
        // Reproduce the captured WKWebView ordering: the resize event retains
        // the previous window dimensions while the actual layout widens. Only
        // the app's isolated world sees these stale values; layout stays real.
        _ = try await f.web.callAsyncJavaScript("""
        window.marginedTestWindowSize={};
        for(const name of ['innerWidth','innerHeight']) {
            window.marginedTestWindowSize[name]=Object.getOwnPropertyDescriptor(window,name) ?? null;
            Object.defineProperty(window,name,{configurable:true,value:window[name]});
        }
        return true;
        """, arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld)
        addTeardownBlock { @MainActor in
            _ = try? await f.web.callAsyncJavaScript("""
            for(const [name,descriptor] of Object.entries(window.marginedTestWindowSize ?? {})) {
                if(descriptor)Object.defineProperty(window,name,descriptor);else delete window[name];
            }
            delete window.marginedTestWindowSize;return true;
            """, arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld)
        }
        f.reader.hideDiscussions()
        let returned = await settledNavigation(f)
        let width = await pollAsync { try await self.readingWidthHasCommitted(f) }
        XCTAssertTrue(returned && width)
        guard returned, width else { return }
        _ = try await f.web.takeSnapshot(configuration: configuration)
        var reading: [String: Any] = [:], finalEvidence: [String: Any] = [:]
        var firstEvidence: [String: Any]?
        let positionCommitted = await pollAsync {
            let ready = try await self.resizeSeedHasCommitted(f, metrics: &reading, evidence: &finalEvidence)
            if !ready || firstEvidence != nil {
                finalEvidence["nativeGeometry"] = self.nativeReadingGeometry(f)
                if firstEvidence == nil { firstEvidence = finalEvidence }
            }
            return ready
        }
        if let firstEvidence {
            recordReadingReadiness(["first": firstEvidence, "last": finalEvidence, "committed": positionCommitted],
                name: "Lagging-window-native-reading-convergence")
        }
        XCTAssertTrue(positionCommitted, "Commit the same native/model/presentation reading passage after the single layout change: \(finalEvidence)")
        XCTAssertEqual(reading["visible"] as? Bool, true,
                       "Committed layout must restore the passage even when window dimensions stay stale: \(reading)")
        XCTAssertEqual(reading["samePage"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testResizingBetweenWideWindowsDoesNotRecreateDiscussionNavigation() async throws {
        let f = try await fixture(withThread: true)
        f.reader.openDiscussion("t-mobile")
        f.reader.discussions.setDraft("Keep this reply in the wide margin.", for: .thread("t-mobile"))
        f.window.frame.size = CGSize(width: 1120, height: 780)
        f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
        let initial = await settledNavigation(f)
        XCTAssertTrue(initial && f.reader.discussionUsesMargin)
        guard initial, f.reader.discussionUsesMargin else { return }
        let presentation = f.reader.discussionLayoutGeneration
        for size in [CGSize(width: 1240, height: 780), CGSize(width: 1120, height: 780),
                     CGSize(width: 1100, height: 780)] {
            f.window.frame.size = size
            f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
            let settled = await settledNavigation(f)
            XCTAssertTrue(settled && f.reader.discussionUsesMargin,
                          "Every window in this sequence must have native space for the margin")
            XCTAssertEqual(f.reader.discussionLayoutGeneration, presentation,
                           "A new viewport with no measurement yet must not tear down and recreate discussion navigation")
            XCTAssertEqual(f.reader.discussionRoute, .thread("t-mobile"))
            XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "Keep this reply in the wide margin.")
        }
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testOpeningConversationDuringThresholdResizeSettlesAndKeepsItsReply() async throws {
        let f = try await fixture(withThread: true)
        f.reader.openDiscussion("t-mobile")
        f.reader.discussions.setDraft("Keep this reply through the threshold transition.", for: .thread("t-mobile"))
        // This is the original failing sequence. Its 1000-point window has only
        // 828 usable points on Duo, so it must settle without assuming a margin.
        for size in [CGSize(width: 1000, height: 780), CGSize(width: 1120, height: 780),
                     CGSize(width: 1000, height: 780), CGSize(width: 890, height: 626)] {
            f.window.frame.size = size
            f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
            let settled = await settledNavigation(f)
            XCTAssertTrue(settled, "A threshold resize must settle into the layout that fits its actual navigation area")
            XCTAssertEqual(f.reader.discussionRoute, .thread("t-mobile"), "Resizing must keep the selected conversation")
            XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body,
                           "Keep this reply through the threshold transition.")
            if f.reader.discussionUsesMargin {
                let minimum = DiscussionMarginLayout.minimumDocumentWidth(
                    bodyFont: f.reader.discussionMargin?.bodyFont ?? 16 * f.reader.zoom,
                    horizontalInsets: f.reader.discussionMargin?.horizontalInsets ?? 48, outlineWidth: 0)
                XCTAssertGreaterThanOrEqual(f.web.bounds.width, minimum - 1,
                                           "A visible margin must preserve the minimum reading width")
            }
            XCTAssertEqual(try Data(contentsOf: f.file), f.original)
            guard settled else { return }
        }
    }

    func testSheetBackStillWorksAfterAMarginRoundTrip() async throws {
        let f = try await fixture(withThread: true)
        f.reader.openDiscussion("t-mobile")
        f.reader.discussions.setDraft("Keep this reply after going back.", for: .thread("t-mobile"))
        let opened = await poll { self.visibleEditor(in: f.host.view)?.text == "Keep this reply after going back." }
        XCTAssertTrue(opened)
        guard opened else { return }
        f.window.frame.size = CGSize(width: 1120, height: 780)
        f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
        let margin = await settledNavigation(f)
        XCTAssertTrue(margin && f.reader.discussionUsesMargin, "Exercise an actual native move into the margin")
        guard margin, f.reader.discussionUsesMargin else { return }
        f.window.frame.size = CGSize(width: 390, height: 780)
        f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
        let compact = await settledNavigation(f)
        XCTAssertTrue(compact && !f.reader.discussionUsesMargin)
        guard compact, !f.reader.discussionUsesMargin else { return }
        func navigation(in controller: UIViewController) -> UINavigationController? {
            if let value = controller as? UINavigationController { return value }
            return controller.children.lazy.compactMap { navigation(in: $0) }.first
        }
        let controller = try XCTUnwrap(navigation(in: f.host))
        XCTAssertEqual(controller.viewControllers.count, 1, "The retained document remains the navigation root")
        let workspace = MobileDocumentWorkspace(reader: f.reader, openFolder: {}, closeFile: {})
        workspace.navigationBinding().wrappedValue = [.list]
        let back = await poll { f.reader.discussionRoute == nil && f.reader.inspector == .discussions }
        XCTAssertTrue(back, "Current native Back must still return to the conversation list")
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "Keep this reply after going back.")
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testWindowResizingPreservesTheReadersVisiblePassage() async throws {
        let paragraphs = (0..<100).map { "Paragraph \($0) has enough words to wrap onto several lines in a narrower document window while keeping the same semantic reading passage." }.joined(separator: "\n\n")
        let f = try await fixture(tail: "\n\n" + paragraphs)
        let observing = await pollAsync {
            try await f.web.callAsyncJavaScript("return typeof window.marginedReadingResize?.stop==='function';",
                arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld) as? Bool == true
        }
        XCTAssertTrue(observing, "Install the actual app observer before seeding its reading position")
        _ = try await f.web.callAsyncJavaScript("""
        await document.fonts.ready;
        window.mobileResizePage = document;
        const passage=Array.from(document.querySelectorAll('main p')).find(p=>p.textContent.startsWith('Paragraph 35 '));
        passage.id='resize-reading-passage';
        passage.scrollIntoView({block:'start',behavior:'instant'});
        await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
        return true;
        """, arguments: [:], in: nil, contentWorld: .defaultClient)
        try await settleMobileResizeObserver(f.web)
        var initial: [String: Any] = [:], seedEvidence: [String: Any] = [:]
        let seedReady = await pollAsync {
            try await self.resizeSeedHasCommitted(f, metrics: &initial, evidence: &seedEvidence)
        }
        XCTAssertTrue(seedReady, "Establish the native reading position before the first resize: \(seedEvidence)")
        XCTAssertGreaterThan(try XCTUnwrap(initial["scroll"] as? Double), 0,
                             "The fixture must actually be partway through its rendered document")
        XCTAssertEqual(initial["visible"] as? Bool, true)
        guard seedReady else { return }
        for size in [CGSize(width: 890, height: 626), CGSize(width: 626, height: 890), CGSize(width: 466, height: 678)] {
            f.window.frame.size = size
            f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
            let nativeSettled = await settledNavigation(f)
            XCTAssertTrue(nativeSettled, "Settle the native navigation width policy before checking its reader viewport")
            let widthCommitted = await pollAsync {
                let width = try await f.web.evaluateJavaScript("innerWidth") as? Double
                return width.map { abs($0 - f.web.bounds.width) < 1 } == true
            }
            XCTAssertTrue(widthCommitted, "WebKit must commit the resized native viewport before assessing reading position")
            // A committed viewport can precede the observer's asynchronous
            // restoration. Wait for its actual result, not just the width.
            try await settleMobileResizeObserver(f.web)
            _ = await pollAsync {
                try await self.resizeReadingMetrics(f.web)["visible"] as? Bool == true
            }
            let metrics = try await resizeReadingMetrics(f.web)
            XCTAssertEqual(metrics["samePage"] as? Bool, true)
            XCTAssertEqual(metrics["visible"] as? Bool, true,
                           "The passage being read must stay visible after moving between narrow and wide windows")
            XCTAssertLessThanOrEqual(try XCTUnwrap(metrics["overflow"] as? Double), 1)
        }
        XCTAssertTrue(webView(in: f.host.view) === f.web)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    #if MARGINED_NATIVE_RESIZE_FEEDBACK_FIXTURE
    func testResizePreservesPassageAfterEmulatedStaleDOMFeedback() async throws {
        let paragraphs = (0..<100).map { "Paragraph \($0) has enough words to reflow between native reading-pane widths while retaining its semantic passage." }.joined(separator: "\n\n")
        let f = try await fixture(tail: "\n\n" + paragraphs)
        let observing = await pollAsync {
            try await f.web.callAsyncJavaScript("return typeof window.marginedReadingResize?.stop==='function';",
                arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld) as? Bool == true
        }
        XCTAssertTrue(observing)
        guard observing else { return }
        _ = try await f.web.callAsyncJavaScript("""
        await document.fonts.ready;
        window.mobileResizePage=document;
        const passage=Array.from(document.querySelectorAll('main p')).find(p=>p.textContent.startsWith('Paragraph 35 '));
        passage.id='resize-reading-passage';
        passage.scrollIntoView({block:'start',behavior:'instant'});
        await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
        return true;
        """, arguments: [:], in: nil, contentWorld: .defaultClient)
        var seed: [String: Any] = [:], evidence: [String: Any] = [:]
        let seeded = await pollAsync { try await self.resizeSeedHasCommitted(f, metrics: &seed, evidence: &evidence) }
        XCTAssertTrue(seeded, "Establish native P35 before emulating feedback: \(evidence)")
        guard seeded else { return }
        let native = f.web.scrollView.contentOffset
        XCTAssertGreaterThan(native.y, 300)
        addTeardownBlock { @MainActor in
            _ = try? await f.web.callAsyncJavaScript("window.__nativeFeedbackFixture?.restore();return true;",
                arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld)
        }
        let emulation = try await f.web.callAsyncJavaScript("""
        // Replay the captured relationship only in the app's isolated world.
        // Native scrolling and default-world outcome measurements stay real.
        const root=document.documentElement,main=document.getElementById('document');
        const width=root.clientWidth,height=root.clientHeight;
        const scrollDescriptor=Object.getOwnPropertyDescriptor(window,'scrollY');
        if(scrollDescriptor && !scrollDescriptor.configurable)return {supported:false};
        const rect=Element.prototype.getBoundingClientRect;
        const point=document.elementFromPoint;
        const pointDescriptor=Object.getOwnPropertyDescriptor(document,'elementFromPoint');
        const active=()=>root.clientWidth===width && root.clientHeight===height;
        const restore=()=>{
            if(scrollDescriptor)Object.defineProperty(window,'scrollY',scrollDescriptor);else delete window.scrollY;
            Element.prototype.getBoundingClientRect=rect;
            if(pointDescriptor)Object.defineProperty(document,'elementFromPoint',pointDescriptor);else delete document.elementFromPoint;
            delete window.__nativeFeedbackFixture;
        };
        window.__nativeFeedbackFixture={restore};
        Object.defineProperty(window,'scrollY',{configurable:true,get:()=>active()?fakeY:window.pageYOffset});
        Element.prototype.getBoundingClientRect=function(){
            const r=rect.call(this);
            return active() && main.contains(this) ? new DOMRect(r.x,r.y+window.pageYOffset-fakeY,r.width,r.height) : r;
        };
        document.elementFromPoint=function(x,y){
            if(!active())return point.call(this,x,y);
            return Array.from(main.querySelectorAll('h1,h2,h3,h4,h5,h6,p,li,pre,tr,dt,dd,figure')).find(node=>{
                const r=node.getBoundingClientRect();return r.left<=x && x<r.right && r.top<=y && y<r.bottom;
            })??null;
        };
        window.dispatchEvent(new Event('resize'));
        window.dispatchEvent(new Event('scroll'));
        await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
        const p=document.getElementById('resize-reading-passage').getBoundingClientRect();
        return {supported:true,domY:scrollY,nativeY,markedVisible:p.bottom>0&&p.top<height,width,height};
        """, arguments: ["fakeY": Double(native.y) / 2, "nativeY": Double(native.y)],
            in: nil, contentWorld: MobileWebView.Coordinator.contentWorld) as? [String: Any]
        XCTAssertEqual(emulation?["supported"] as? Bool, true, "The fixture must actually replace isolated-world feedback")
        guard emulation?["supported"] as? Bool == true else { return }
        XCTAssertEqual(f.web.scrollView.contentOffset.y, native.y, accuracy: 1, "Feedback emulation must not move the native viewport")
        XCTAssertEqual(emulation?["markedVisible"] as? Bool, false, "The emulated DOM viewport must describe a different passage")
        print("EMULATED-NATIVE-FEEDBACK \(emulation ?? [:])")
        print("EMULATED-NATIVE-FEEDBACK-PROCESS \(ProcessInfo.processInfo.processIdentifier)")
        f.window.frame.size = CGSize(width: 890, height: 626)
        f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
        let reflowed = await pollAsync {
            guard abs(Double(f.web.bounds.width) - (seed["width"] as? Double ?? 0)) > 100 else { return false }
            return try await self.readingWidthHasCommitted(f)
        }
        XCTAssertTrue(reflowed, "The test must commit a genuinely different native reading width")
        guard reflowed else { return }
        var after: [String: Any] = [:], finalEvidence: [String: Any] = [:]
        let retained = await pollAsync { try await self.resizeSeedHasCommitted(f, metrics: &after, evidence: &finalEvidence) }
        XCTAssertTrue(retained, "Emulated stale DOM feedback must not replace native P35 during reflow: \(finalEvidence)")
        XCTAssertEqual(after["samePage"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }
    #endif

    func testOldResizeObserverCannotScrollANewerDocumentVersion() async throws {
        let paragraphs = (0..<100).map { "Paragraph \($0) has enough words to wrap onto several lines when the native window changes width." }.joined(separator: "\n\n")
        let f = try await fixture(tail: "\n\n" + paragraphs)
        _ = try await f.web.callAsyncJavaScript("""
        await document.fonts.ready;
        const passage=Array.from(document.querySelectorAll('main p')).find(p=>p.textContent.startsWith('Paragraph 35 '));
        passage.scrollIntoView({block:'start',behavior:'instant'});
        await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
        return true;
        """, arguments: [:], in: nil, contentWorld: .defaultClient)
        let observer = try await f.web.callAsyncJavaScript("return typeof window.marginedReadingResize?.stop==='function';",
            arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld) as? Bool
        XCTAssertEqual(observer, true, "The actual app observer must be installed before testing stale work")
        // Observe app-issued scrolling in its actual isolated world. First prove
        // the observer acts while current, then require silence after supersession.
        _ = try await f.web.callAsyncJavaScript("""
        window.resizeScrollCalls=0;
        window.resizeScrollTokens=[];
        const original=window.scrollTo;
        window.scrollTo=function(...args) {
            window.resizeScrollCalls++;
            window.resizeScrollTokens.push(document.documentElement.getAttribute('data-margined-mobile-token'));
            return Reflect.apply(original,this,args);
        };
        return true;
        """, arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld)
        f.window.frame.size = CGSize(width: 520, height: 780)
        f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
        _ = try await f.web.callAsyncJavaScript("await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));return true;",
            arguments: [:], in: nil, contentWorld: .defaultClient)
        _ = await pollAsync {
            try await f.web.callAsyncJavaScript("return window.resizeScrollCalls>0;",
                arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld) as? Bool == true
        }
        let active = try await f.web.callAsyncJavaScript("return window.resizeScrollCalls;",
            arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld) as? Int
        XCTAssertGreaterThan(try XCTUnwrap(active), 0, "The native resize must exercise a live observer, not a vacuous spy")
        guard let active, active > 0 else { return }
        // Establish one JS-task boundary. An authorized restore between a
        // separate counter reset and token mutation would be miscounted as stale.
        _ = try await f.web.callAsyncJavaScript("""
        window.resizeScrollCalls=0;
        window.resizeScrollTokens=[];
        document.documentElement.setAttribute('data-margined-mobile-token','superseded-page-version');
        return true;
        """, arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld)
        f.window.frame.size = CGSize(width: 890, height: 626)
        f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
        let committed = await pollAsync {
            let width = try await f.web.evaluateJavaScript("innerWidth") as? Double
            return width.map { abs($0 - f.web.bounds.width) < 1 } == true
        }
        XCTAssertTrue(committed)
        let callsValue = try await f.web.callAsyncJavaScript("""
        await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
        return window.resizeScrollCalls;
        """, arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld)
        XCTAssertEqual(try XCTUnwrap(callsValue as? Int), 0,
                       "A superseded observer must leave scrolling to the new document version")
        if (callsValue as? Int) != 0 {
            let tokens = try? await f.web.callAsyncJavaScript("return window.resizeScrollTokens;",
                arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld)
            print("STALE-RESIZE-WRITE-TOKENS \(String(describing: tokens))")
        }
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testChangeReviewUsesAvailableSpaceRatherThanRegularWidthAlone() async throws {
        let f = try await fixture()
        f.host.traitOverrides.horizontalSizeClass = .regular
        f.window.frame.size = CGSize(width: 626, height: 890)
        f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
        let narrow = await poll { !f.reader.discussionUsesMargin }
        XCTAssertTrue(narrow)
        f.reader.inspector = .changes
        let sheet = await poll { f.host.presentedViewController != nil }
        XCTAssertTrue(sheet, "A tall regular-width window must not lose 340 points of reading width to an inspector")
        guard sheet else { return }
        var sawInlineReview = false
        for size in [CGSize(width: 890, height: 626), CGSize(width: 1_000, height: 780),
                     CGSize(width: 1_120, height: 780), CGSize(width: 466, height: 678)] {
            f.window.frame.size = size
            f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
            _ = try await f.web.callAsyncJavaScript("await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));return true;",
                arguments: [:], in: nil, contentWorld: .defaultClient)
            let settled = await poll {
                guard let sheet = f.host.presentedViewController else { return true }
                return !sheet.isBeingDismissed && !sheet.isBeingPresented
            }
            XCTAssertTrue(settled)
            XCTAssertEqual(f.reader.inspector, .changes, "Changing presentation must keep review open")
            if f.host.presentedViewController == nil {
                sawInlineReview = true
                XCTAssertLessThanOrEqual(f.web.bounds.width, size.width - 340 + 1,
                                         "An inline review must actually occupy space beside the document")
                let minimum = DiscussionMarginLayout.minimumDocumentWidth(
                    bodyFont: f.reader.discussionMargin?.bodyFont ?? 16 * f.reader.zoom,
                    horizontalInsets: f.reader.discussionMargin?.horizontalInsets ?? 48, outlineWidth: 0)
                XCTAssertGreaterThanOrEqual(f.web.bounds.width, minimum - 1,
                                            "A docked inspector must leave the actual document a readable column after system bars")
            }
        }
        XCTAssertTrue(sawInlineReview, "The test must actually move review from its sheet into a sufficiently wide margin")
        XCTAssertNotNil(f.host.presentedViewController, "A narrow window must offer review in its sheet")
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        f.reader.inspector = nil
        _ = await poll { f.host.presentedViewController == nil }
    }

    func testDiscussionMarginLeavesReadableDocumentWidthAfterNavigationChrome() async throws {
        let f = try await fixture(withThread: true)
        f.reader.inspector = .discussions
        var sawMargin = false
        for size in [CGSize(width: 1_000, height: 780), CGSize(width: 1_120, height: 780),
                     CGSize(width: 626, height: 890)] {
            f.window.frame.size = size
            f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
            let settled = await settledNavigation(f)
            XCTAssertTrue(settled)
            if f.reader.discussionUsesMargin {
                sawMargin = true
                let minimum = DiscussionMarginLayout.minimumDocumentWidth(
                    bodyFont: f.reader.discussionMargin?.bodyFont ?? 16 * f.reader.zoom,
                    horizontalInsets: f.reader.discussionMargin?.horizontalInsets ?? 48, outlineWidth: 0)
                XCTAssertGreaterThanOrEqual(f.web.bounds.width, minimum - 1,
                    "A discussion margin must leave a readable document after the system's vertical bars")
            }
        }
        XCTAssertTrue(sawMargin, "The test must exercise a real wide discussion margin")
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    private func settledNavigation(_ fixture: Fixture) async -> Bool {
        func navigation(in controller: UIViewController) -> UINavigationController? {
            if let value = controller as? UINavigationController { return value }
            return controller.children.lazy.compactMap { navigation(in: $0) }.first
        }
        let result = await poll {
            guard let navigation = navigation(in: fixture.host),
                  let top = navigation.topViewController?.viewIfLoaded,
                  navigation.transitionCoordinator == nil,
                  top.bounds.size == fixture.window.bounds.size else { return false }
            // Native navigation may settle before SwiftUI publishes its new
            // measured width. Wait for the layout decision to agree with the
            // actual top controller's usable area, including vertical bars.
            let minimum = DiscussionMarginLayout.minimumDocumentWidth(
                bodyFont: fixture.reader.discussionMargin?.bodyFont ?? 16 * fixture.reader.zoom,
                horizontalInsets: max(88, fixture.reader.discussionMargin?.horizontalInsets ?? 88), outlineWidth: 0)
            let canDock = !top.traitCollection.preferredContentSizeCategory.isAccessibilityCategory &&
                top.safeAreaLayoutGuide.layoutFrame.width >= minimum + 341
            guard fixture.reader.discussionUsesMargin == canDock else { return false }
            return fixture.web.isDescendant(of: top)
        }
        if !result { recordFailedNavigation(fixture) }
        return result
    }

    // Failure-only diagnostics: the original success predicate and poll are unchanged.
    private func recordFailedNavigation(_ fixture: Fixture) {
        func navigation(in controller: UIViewController) -> UINavigationController? {
            if let value = controller as? UINavigationController { return value }
            return controller.children.lazy.compactMap { navigation(in: $0) }.first
        }
        let nav = navigation(in: fixture.host)
        let top = nav?.topViewController?.viewIfLoaded
        let minimum = DiscussionMarginLayout.minimumDocumentWidth(
            bodyFont: fixture.reader.discussionMargin?.bodyFont ?? 16 * fixture.reader.zoom,
            horizontalInsets: max(88, fixture.reader.discussionMargin?.horizontalInsets ?? 88), outlineWidth: 0)
        let modelMargin = fixture.reader.discussionUsesMargin
        let showsReading = true
        let nativeCanDock = top.map { !$0.traitCollection.preferredContentSizeCategory.isAccessibilityCategory &&
            $0.safeAreaLayoutGuide.layoutFrame.width >= minimum + 341 }
        let stack: [[String: Any]] = (nav?.viewControllers ?? []).map { controller in
            var record: [String: Any] = ["class": String(describing: type(of: controller)),
                "holdsDocument": fixture.web.isDescendant(of: controller.viewIfLoaded ?? UIView())]
            if let view = controller.viewIfLoaded {
                record["bounds"] = String(describing: view.bounds)
                record["safeFrame"] = String(describing: view.safeAreaLayoutGuide.layoutFrame)
                record["accessibilitySize"] = view.traitCollection.preferredContentSizeCategory.isAccessibilityCategory
            }
            return record
        }
        let report: [String: Any] = [
            "afterFailedOriginalPoll": true, "navigationExists": nav != nil, "topLoaded": top != nil,
            "transitionActive": nav?.transitionCoordinator != nil,
            "topMatchesWindow": top.map { $0.bounds.size == fixture.window.bounds.size } ?? false,
            "modelMatchesTopCanDock": nativeCanDock.map { $0 == modelMargin } ?? false,
            "webAncestryMatches": top.map { fixture.web.isDescendant(of: $0) == showsReading } ?? false,
            "windowFrame": String(describing: fixture.window.frame), "windowBounds": String(describing: fixture.window.bounds),
            "windowIsKey": fixture.window.isKeyWindow, "windowHidden": fixture.window.isHidden,
            "sceneState": fixture.window.windowScene?.activationState.rawValue ?? -1,
            "modelMargin": modelMargin, "minimumProse": String(describing: minimum),
            "bodyFont": String(describing: fixture.reader.discussionMargin?.bodyFont ?? 16 * fixture.reader.zoom),
            "horizontalInsets": String(describing: fixture.reader.discussionMargin?.horizontalInsets ?? 48),
            "pathCount": fixture.reader.discussionNavigationPath.count,
            "unpostedDraft": fixture.reader.discussions.hasUnpostedDrafts,
            "threadState": String(describing: fixture.reader.rendered?.discussions?.threads.first?.state),
            "webBounds": String(describing: fixture.web.bounds), "navigationStack": stack]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print("MARGINED-NAV-FAIL " + text) }
    }

    private func settleMobileResizeObserver(_ web: WKWebView) async throws {
        // Wait for the app observer's own frame barrier in addition to the
        // page's committed layout and width-policy checks.
        _ = try await web.callAsyncJavaScript("await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));return true;",
            arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld)
    }

    /// Evidence only: retain model/presentation and clipping geometry at the
    /// first mismatch and convergence. This helper never lays out or scrolls.
    private func nativeReadingGeometry(_ fixture: Fixture) -> [String: Any] {
        let scroll = fixture.web.scrollView
        var ancestors: [[String: Any]] = [], current: UIView? = fixture.web
        while let view = current {
            var item: [String: Any] = ["bounds": String(describing: view.bounds),
                "frameInWindow": String(describing: view.convert(view.bounds, to: fixture.window)),
                "clips": view.clipsToBounds, "hidden": view.isHidden, "alpha": view.alpha]
            if let shown = view.layer.presentation(), let window = fixture.window.layer.presentation() {
                item["presentationInWindow"] = String(describing: shown.convert(shown.bounds, to: window))
            }
            ancestors.append(item)
            current = view.superview
        }
        let content = scroll.subviews.filter {
            !$0.isHidden && $0.alpha > 0.01 && abs($0.bounds.width-scroll.contentSize.width)<=1 &&
                abs($0.bounds.height-scroll.contentSize.height)<=1
        }.map { view -> [String: Any] in
            var item: [String: Any] = ["bounds": String(describing: view.bounds),
                "modelIdentity": NativeReadingLayerMapping.isIdentity(view.layer, to: scroll.layer)]
            if let shown = view.layer.presentation(), let parent = scroll.layer.presentation() {
                item["presentationBounds"] = String(describing: shown.bounds)
                item["presentationIdentity"] = NativeReadingLayerMapping.isIdentity(shown, to: parent)
            }
            return item
        }
        return ["time": CACurrentMediaTime(), "offset": String(describing: scroll.contentOffset),
            "scrollBounds": String(describing: scroll.bounds),
            "scrollPresentation": String(describing: scroll.layer.presentation()?.bounds),
            "contentSize": String(describing: scroll.contentSize), "content": content, "ancestors": ancestors]
    }

    private func recordReadingReadiness(_ evidence: [String: Any], name: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]) else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func requestedReadingWidth(_ fixture: Fixture) -> Double? {
        func navigation(_ controller: UIViewController) -> UINavigationController? {
            if let value = controller as? UINavigationController { return value }
            return controller.children.lazy.compactMap { navigation($0) }.first
        }
        guard let top = navigation(fixture.host)?.topViewController?.viewIfLoaded,
              top.bounds.size == fixture.window.bounds.size else { return nil }
        let panel = fixture.reader.inspector == .discussions && fixture.reader.discussionUsesMargin
            ? Double(MobileReaderPanelLayout.inspectorWidth) + 1 / Double(fixture.window.screen.scale) : 0
        return Double(top.safeAreaLayoutGuide.layoutFrame.width) - panel
    }

    private func readingWidthMatchesRequested(_ fixture: Fixture, cssWidth: Double? = nil) -> Bool {
        guard let expected = requestedReadingWidth(fixture), expected > 0 else { return false }
        let native = Double(fixture.web.bounds.width), pixel = 1 / Double(fixture.window.screen.scale)
        return abs(native - expected) <= pixel + expected.ulp * 8 &&
            (cssWidth.map { abs($0 - native) < 1 } ?? true)
    }

    private func readingWidthHasCommitted(_ fixture: Fixture) async throws -> Bool {
        guard readingWidthMatchesRequested(fixture) else { return false }
        let width = try await fixture.web.evaluateJavaScript("innerWidth") as? Double
        return width.map { readingWidthMatchesRequested(fixture, cssWidth: $0) } == true
    }

    private func resizeReadingMetrics(_ web: WKWebView) async throws -> [String: Any] {
        let value = try await web.callAsyncJavaScript("""
        await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
        const box=document.getElementById('resize-reading-passage').getBoundingClientRect();
        const visible=box.bottom>0&&box.top<innerHeight;
        return {samePage:window.mobileResizePage===document,scroll:scrollY,x:scrollX,y:scrollY,
            top:box.top,bottom:box.bottom,width:innerWidth,height:innerHeight,
            visible,semanticVisible:visible,
            contentWidth:document.documentElement.scrollWidth,
            contentHeight:document.documentElement.scrollHeight,
            overflow:document.documentElement.scrollWidth-document.documentElement.clientWidth};
        """, arguments: [:], in: nil, contentWorld: .defaultClient)
        return try XCTUnwrap(value as? [String: Any])
    }

    private func resizeSeedHasCommitted(_ fixture: Fixture, metrics: inout [String: Any],
        evidence: inout [String: Any]) async throws -> Bool {
        // This reads the result of the original single jump. It never scrolls
        // again or changes the cadence of the later live-resize sequence.
        metrics = [:]
        evidence = ["reason": "awaiting initial resize DOM metrics"]
        do { metrics = try await resizeReadingMetrics(fixture.web) }
        catch {
            evidence = ["reason": "initial resize DOM evaluation failed", "error": String(describing: error)]
            throw error
        }
        return NativeReadingPositionReadiness.matches(metrics, web: fixture.web,
            window: fixture.window, evidence: &evidence)
    }

    func testFirstPostKeepsTheSavedConversationOpenAndCanReply() async throws {
        let f = try await fixture()
        _ = try await f.web.callAsyncJavaScript("""
        const paragraph=Array.from(document.querySelectorAll('main p')).find(p=>p.textContent.includes('bold'));
        const range=document.createRange();range.selectNodeContents(paragraph);
        getSelection().removeAllRanges();getSelection().addRange(range);return true;
        """, arguments: [:], in: nil, contentWorld: .defaultClient)
        f.reader.requestAddDiscussion()
        let selected = await poll { f.reader.discussions.selection != nil }
        XCTAssertTrue(selected)
        let draft = try XCTUnwrap(f.reader.discussions.selection)
        f.reader.discussions.displayName = "Test Author"
        f.reader.discussions.setDraft("The first saved note.", for: draft)
        f.reader.postDiscussion()
        let saved = await poll { !f.reader.fileSaving && !f.reader.isRendering && f.reader.rendered?.discussions?.threads.count == 1 }
        XCTAssertTrue(saved, "The first post must finish its real coordinated file save")
        let thread = try XCTUnwrap(try DiscussionCodec.parse(MarkdownSource.read(f.file)).threads.first)
        XCTAssertEqual(thread.messages.first?.body, "The first saved note.")
        XCTAssertEqual(f.reader.discussionRoute, .thread(thread.id), "The saved conversation must replace its now-empty new-draft route")
        XCTAssertEqual(f.reader.discussions.selection, .thread(thread.id))
        var mountedReply: UITextView?
        let mounted = await poll {
            guard let candidate = self.visibleEditor(in: f.host.view), candidate.window === f.window,
                  let coordinator = candidate.delegate as? MobileDiscussionDraftEditor.Coordinator,
                  coordinator.owner.reader === f.reader,
                  coordinator.owner.document == f.reader.documentGeneration,
                  coordinator.owner.key == .thread(thread.id) else { return false }
            mountedReply = candidate
            return true
        }
        XCTAssertTrue(mounted)
        let reply = try XCTUnwrap(mountedReply)
        reply.text = "A reply from the mounted composer."
        reply.delegate?.textViewDidChange?(reply)
        XCTAssertEqual(f.reader.discussions.drafts[.thread(thread.id)]?.body, "A reply from the mounted composer.")
        XCTAssertNil(f.reader.discussions.drafts[draft], "Typing the reply must not recreate the old new-thread composer")
        f.reader.postDiscussion()
        let replied = await poll { !f.reader.fileSaving && !f.reader.isRendering && f.reader.rendered?.discussions?.threads.first?.messages.count == 2 }
        XCTAssertTrue(replied)
        XCTAssertEqual(try DiscussionCodec.parse(MarkdownSource.read(f.file)).threads.count, 1)
        XCTAssertTrue(try MarkdownSource.read(f.file).hasPrefix(try MarkdownSource.decode(f.original)))
    }

    func testChangingTheComposerNameOnlyAffectsFutureSavedMessages() async throws {
        let f = try await fixture(withThread: true)
        f.reader.discussions.displayName = "Original Author"
        f.reader.openDiscussion("t-mobile")
        let available = await poll { self.nameField(in: f.host.view) != nil }
        XCTAssertTrue(available, "A remembered author name must remain editable while composing")
        guard available, let name = nameField(in: f.host.view) else { return }
        XCTAssertEqual(name.text, "Original Author")
        name.text = "Updated Author"; name.sendActions(for: .editingChanged)
        let changed = await poll { f.reader.discussions.displayName == "Updated Author" }
        XCTAssertTrue(changed)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original, "Editing the future author name must not rewrite saved comments")
        let editor = try XCTUnwrap(self.editor(in: f.host.view))
        editor.text = "A reply under the updated name."; editor.delegate?.textViewDidChange?(editor)
        f.reader.postDiscussion()
        let saved = await poll { !f.reader.fileSaving && !f.reader.isRendering && f.reader.rendered?.discussions?.threads.first?.messages.count == 2 }
        XCTAssertTrue(saved)
        let thread = try XCTUnwrap(try DiscussionCodec.parse(MarkdownSource.read(f.file)).threads.first)
        XCTAssertEqual(thread.messages.map(\.author), ["Reviewer", "Updated Author"])
        XCTAssertEqual(thread.messages.map(\.body), ["A portable note.", "A reply under the updated name."])
    }

    func testDiscardedNameFieldsLateEditCannotRenameTheNextDocumentsAuthor() async throws {
        let f = try await fixture(withThread: true)
        f.reader.discussions.displayName = "Original Author"; f.reader.openDiscussion("t-mobile")
        let available = await poll { self.nameField(in: f.host.view) != nil }
        XCTAssertTrue(available, "The native composer must expose its remembered author name")
        guard available, let oldField = nameField(in: f.host.view) else { return }
        let second = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        try f.original.write(to: second); defer { try? FileManager.default.removeItem(at: second) }
        await f.reader.open(url: second); await f.reader.waitForRendering()
        f.reader.discussions.displayName = "Next Author"; f.reader.openDiscussion("t-mobile")
        let mounted = await poll { self.nameField(in: f.host.view)?.text == "Next Author" }
        XCTAssertTrue(mounted)
        let current = try XCTUnwrap(nameField(in: f.host.view))
        XCTAssertFalse(current === oldField)
        oldField.text = "Stale Author"; oldField.sendActions(for: .editingChanged)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(f.reader.discussions.displayName, "Next Author")
        XCTAssertEqual(current.text, "Next Author")
        XCTAssertEqual(try Data(contentsOf: second), f.original)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testExternalResolveKeepsTheUnpostedReplyReachableInTheRegularMargin() async throws {
        try await assertExternalResolvePreservesReply(width: 1_120, requiresMargin: true)
    }

    func testExternalResolveKeepsTheUnpostedReplyReachableAtTheOriginalWindowWidth() async throws {
        try await assertExternalResolvePreservesReply(width: 1_024, requiresMargin: false)
    }

    private func assertExternalResolvePreservesReply(width: CGFloat, requiresMargin: Bool) async throws {
        let f = try await fixture(withThread: true)
        f.window.frame.size = CGSize(width: width, height: 780)
        f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
        let settled = await settledNavigation(f)
        XCTAssertTrue(settled, "The layout must agree with its actual native usable width and rendered font")
        f.reader.openDiscussion("t-mobile")
        f.reader.discussions.setDraft("Keep this reply while another author resolves.", for: .thread("t-mobile"))
        let before = await poll { self.editor(in: f.host.view)?.text == "Keep this reply while another author resolves." }
        XCTAssertTrue(before)
        await assertVisibleDiscussionMargin(f, required: requiresMargin)
        let parsed = try DiscussionCodec.parse(MarkdownSource.read(f.file))
        let replacement = try MarkdownSourceEdits.apply(DiscussionEdits.splices(for:
            .resolve(threadID: "t-mobile", author: "Other Author", created: "2026-10-24T10:00:00Z"), in: parsed),
            to: Data(contentsOf: f.file), expectedSource: parsed.source)
        try replacement.write(to: f.file, options: .atomic)
        await f.reader.refresh(); await f.reader.waitForRendering()
        XCTAssertEqual(f.reader.discussions.filter, .open)
        XCTAssertEqual(f.reader.rendered?.discussions?.threads.first?.state, .resolved)
        let retained = await poll { self.editor(in: f.host.view)?.text == "Keep this reply while another author resolves." }
        XCTAssertTrue(retained, "A filter-changing refresh must not remove the only visible route to an unposted reply")
        await assertVisibleDiscussionMargin(f, required: requiresMargin)
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "Keep this reply while another author resolves.")
        XCTAssertEqual(try Data(contentsOf: f.file), replacement, "Refresh and retained draft presentation must not write")
    }

    private func assertVisibleDiscussionMargin(_ f: Fixture, required: Bool) async {
        let settled = await settledNavigation(f)
        XCTAssertTrue(settled, "Opening and refreshing the conversation must preserve a settled native layout")
        if required {
            XCTAssertTrue(f.reader.discussionUsesMargin, "The wide positive control must exercise the discussion margin")
        }
        if f.reader.discussionUsesMargin {
            let minimum = DiscussionMarginLayout.minimumDocumentWidth(
                bodyFont: f.reader.discussionMargin?.bodyFont ?? 16 * f.reader.zoom,
                horizontalInsets: f.reader.discussionMargin?.horizontalInsets ?? 48, outlineWidth: 0)
            XCTAssertGreaterThanOrEqual(f.web.bounds.width, minimum - 1,
                "The margin must leave readable prose after native navigation chrome")
        }
    }

    func testNoSelectionOffersNativePassagesAndStartsAnUnpostedComment() async throws {
        let f = try await fixture()
        _ = try await f.web.evaluateJavaScript("getSelection().removeAllRanges();true")
        f.reader.requestAddDiscussion()
        let offered = await poll { f.reader.discussionPassagePicker != nil }
        XCTAssertTrue(offered, "Add without a text selection must offer accessible semantic passages")
        guard let picker = f.reader.discussionPassagePicker else { return }
        let presented = await poll { f.host.presentedViewController != nil }
        XCTAssertTrue(presented, "The passage chooser must be a mounted native sheet")
        let unit = try XCTUnwrap(picker.projection.units.first { $0.text == "Café bold passage." })
        XCTAssertNil(f.reader.discussions.selection)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        f.reader.confirmDiscussionPassage(unit.id, pickerID: picker.id)
        XCTAssertNil(f.reader.discussionPassagePicker)
        let key = try XCTUnwrap(f.reader.discussions.selection)
        XCTAssertEqual(f.reader.discussions.drafts[key]?.target?.exact, "Café bold passage.")
        let composer = await poll { self.editor(in: f.host.view) != nil }
        XCTAssertTrue(composer)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original, "Choosing a passage only starts a draft")
    }

    func testPassageChooserRefusesConfirmationAfterTheFileChanges() async throws {
        let f = try await fixture()
        f.reader.requestAddDiscussion()
        let offered = await poll { f.reader.discussionPassagePicker != nil }
        XCTAssertTrue(offered)
        guard let picker = f.reader.discussionPassagePicker else { return }
        let unit = try XCTUnwrap(picker.projection.units.first { $0.text == "Café bold passage." })
        let replacement = Data(try MarkdownSource.decode(f.original).replacingOccurrences(of: "Before.", with: "Before updated externally.").utf8)
        try replacement.write(to: f.file, options: .atomic)
        await f.reader.refresh(); await f.reader.waitForRendering()
        f.reader.confirmDiscussionPassage(unit.id, pickerID: picker.id)
        XCTAssertNil(f.reader.discussions.selection)
        XCTAssertTrue(f.reader.discussions.drafts.isEmpty)
        XCTAssertNotNil(f.reader.discussionError)
        XCTAssertEqual(try Data(contentsOf: f.file), replacement)
        f.reader.cancelDiscussionPassage(pickerID: picker.id)
        XCTAssertNil(f.reader.discussionPassagePicker)
    }

    func testOldPassageConfirmationCannotStartADraftInAnotherDocument() async throws {
        try await checkOldPickerAction(confirm: true)
    }

    func testOldPassageCancellationCannotDismissAnotherDocumentsPicker() async throws {
        try await checkOldPickerAction(confirm: false)
    }

    private func checkOldPickerAction(confirm: Bool) async throws {
        let f = try await fixture()
        f.reader.requestAddDiscussion()
        let offered = await poll { f.reader.discussionPassagePicker != nil }
        XCTAssertTrue(offered)
        let old = try XCTUnwrap(f.reader.discussionPassagePicker)
        let oldUnit = try XCTUnwrap(old.projection.units.first { $0.text == "Café bold passage." })
        // Capture exactly the request identity held by the old native sheet.
        let oldAction = {
            if confirm { f.reader.confirmDiscussionPassage(oldUnit.id, pickerID: old.id) }
            else { f.reader.cancelDiscussionPassage(pickerID: old.id) }
        }
        f.reader.cancelDiscussionPassage(pickerID: old.id)
        let dismissed = await poll { f.host.presentedViewController == nil }
        XCTAssertTrue(dismissed, "The original native picker must finish dismissal before replacing the file")
        guard dismissed else { return }
        let second = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        let data = Data("# Other\n\nDifferent nearby text.\n\nAn unrelated new passage.\n\nAfter.\n".utf8)
        try data.write(to: second)
        defer { try? FileManager.default.removeItem(at: second) }
        await f.reader.open(url: second); await f.reader.waitForRendering()
        let loaded = await pollAsync {
            try await f.web.evaluateJavaScript("document.querySelector('main')?.textContent.includes('An unrelated new passage.')===true") as? Bool == true
        }
        XCTAssertTrue(loaded)
        f.reader.requestAddDiscussion()
        let currentOffered = await poll { f.reader.discussionPassagePicker != nil }
        XCTAssertTrue(currentOffered)
        let current = try XCTUnwrap(f.reader.discussionPassagePicker)
        let currentUnit = try XCTUnwrap(current.projection.units.first { $0.text == "An unrelated new passage." })
        XCTAssertEqual(oldUnit.id, currentUnit.id, "The case must reuse semantic unit IDs across two distinct documents")
        oldAction()
        XCTAssertEqual(f.reader.discussionPassagePicker?.id, current.id, "A delayed action from another sheet must leave the current picker open")
        XCTAssertNil(f.reader.discussions.selection)
        XCTAssertTrue(f.reader.discussions.drafts.isEmpty, "An old native action must never select text in a new file")
        XCTAssertEqual(try Data(contentsOf: second), data)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        if f.reader.discussionPassagePicker?.id == current.id {
            f.reader.confirmDiscussionPassage(currentUnit.id, pickerID: current.id)
            let key = try XCTUnwrap(f.reader.discussions.selection)
            XCTAssertEqual(f.reader.discussions.drafts[key]?.target?.exact, "An unrelated new passage.")
        }
        f.reader.discussions.discardDrafts(); await f.reader.close()
    }

    func testAnOutgoingComposerCannotOverwriteTheSameDraftAfterAWidthChange() async throws {
        let f = try await fixture(withThread: true)
        f.reader.openDiscussion("t-mobile")
        f.reader.discussions.setDraft("Original reply before resizing.", for: .thread("t-mobile"))
        let mounted = await poll { self.editor(in: f.host.view)?.text == "Original reply before resizing." }
        XCTAssertTrue(mounted); guard mounted else { return }
        let oldEditor = try XCTUnwrap(self.editor(in: f.host.view)), delegate = try XCTUnwrap(oldEditor.delegate)
        f.window.frame.size = CGSize(width: 1120, height: 780)
        f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
        let moved = await poll { f.reader.discussionUsesMargin && self.editor(in: f.host.view).map { $0 !== oldEditor } == true }
        XCTAssertTrue(moved); guard moved else { return }
        f.reader.discussions.setDraft("Newer typing in the inspector.", for: .thread("t-mobile"))
        oldEditor.text = "Queued old editor text."
        delegate.textViewDidChange?(oldEditor)
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "Newer typing in the inspector.")
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testDiscardedComposersLateEditCannotChangeAnotherDocumentsReply() async throws {
        let f = try await fixture(withThread: true)
        f.reader.openDiscussion("t-mobile")
        f.reader.discussions.setDraft("Original document draft.", for: .thread("t-mobile"))
        let mounted = await poll { self.editor(in: f.host.view)?.text == "Original document draft." }
        XCTAssertTrue(mounted)
        let oldEditor = try XCTUnwrap(self.editor(in: f.host.view))
        let oldDelegate = try XCTUnwrap(oldEditor.delegate)
        let second = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        try f.original.write(to: second)
        defer { try? FileManager.default.removeItem(at: second) }
        await f.reader.open(url: second)
        XCTAssertTrue(f.reader.showDraftDiscardConfirmation)
        await f.reader.confirmDiscardDrafts(); await f.reader.waitForRendering()
        XCTAssertEqual(f.reader.fileURL, second)
        let popped = await poll { self.editor(in: f.host.view) == nil }
        XCTAssertTrue(popped, "Finish the old native destination before opening another file's same-ID thread")
        guard popped else { return }
        f.reader.openDiscussion("t-mobile")
        f.reader.discussions.setDraft("Only the new document reply.", for: .thread("t-mobile"))
        let remounted = await poll { self.editor(in: f.host.view)?.text == "Only the new document reply." }
        XCTAssertTrue(remounted)
        let newEditor = try XCTUnwrap(self.editor(in: f.host.view))
        XCTAssertFalse(oldEditor === newEditor)
        guard oldEditor !== newEditor else { return }
        oldEditor.text = "Delayed text from the discarded document."
        oldDelegate.textViewDidChange?(oldEditor)
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "Only the new document reply.", "A queued callback still holds the old editor's binding, not permission to alter the new file's draft")
        f.reader.discussions.displayName = "Test Author"
        f.reader.postDiscussion()
        let saved = await poll { !f.reader.fileSaving && !f.reader.isRendering && f.reader.rendered?.discussions?.threads.first?.messages.count == 2 }
        XCTAssertTrue(saved)
        XCTAssertEqual(try DiscussionCodec.parse(MarkdownSource.read(second)).threads.first?.messages.last?.body, "Only the new document reply.")
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        f.reader.discussions.discardDrafts(); await f.reader.close()
    }

    func testResolveOffersDraftChoicesAndReopenPreservesTheConversation() async throws {
        let f = try await fixture(withThread: true)
        f.reader.openDiscussion("t-mobile")
        f.reader.discussions.displayName = "Test Author"
        f.reader.discussions.setDraft("Post this reply before resolving.", for: .thread("t-mobile"))
        f.reader.requestResolveDiscussion("t-mobile")
        XCTAssertNotNil(f.reader.discussionDecision, "Resolve must ask what to do with the unposted reply")
        guard let first = f.reader.discussionDecision else { return }
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        f.reader.confirmDiscussionResolution(first.id, choice: .keepOpen)
        XCTAssertNil(f.reader.discussionDecision)
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "Post this reply before resolving.")
        f.reader.requestResolveDiscussion("t-mobile")
        let decision = try XCTUnwrap(f.reader.discussionDecision)
        f.reader.confirmDiscussionResolution(decision.id, choice: .postDraft)
        let resolved = await poll { !f.reader.fileSaving && !f.reader.isRendering && f.reader.rendered?.discussions?.threads.first?.state == .resolved }
        XCTAssertTrue(resolved)
        let saved = try XCTUnwrap(try DiscussionCodec.parse(MarkdownSource.read(f.file)).threads.first)
        XCTAssertEqual(saved.messages.map(\.body), ["A portable note.", "Post this reply before resolving."])
        XCTAssertEqual(saved.resolvedBy, "Test Author")
        XCTAssertNil(f.reader.discussionDecision)
        XCTAssertFalse(f.reader.discussions.hasUnpostedDrafts)
        f.reader.reopenDiscussion("t-mobile")
        let reopened = await poll { !f.reader.fileSaving && !f.reader.isRendering && f.reader.rendered?.discussions?.threads.first?.state == .open }
        XCTAssertTrue(reopened)
        XCTAssertEqual(try DiscussionCodec.parse(MarkdownSource.read(f.file)).threads.first?.messages, saved.messages)
    }

    func testResolvedReplyConfirmationRejectsNewTypingAndOldDecisionCallbacks() async throws {
        let f = try await fixture(withThread: true)
        f.reader.openDiscussion("t-mobile"); f.reader.discussions.displayName = "Test Author"
        f.reader.resolveDiscussion("t-mobile", choice: .discardDraft)
        let resolved = await poll { !f.reader.fileSaving && !f.reader.isRendering && f.reader.rendered?.discussions?.threads.first?.state == .resolved }
        XCTAssertTrue(resolved)
        let before = try Data(contentsOf: f.file)
        f.reader.discussions.setDraft("First version of the reply.", for: .thread("t-mobile"))
        f.reader.postDiscussion()
        XCTAssertNotNil(f.reader.discussionDecision, "Posting to a resolved thread needs explicit reopening confirmation")
        guard let first = f.reader.discussionDecision else { return }
        f.reader.discussions.setDraft("New typing must be reviewed first.", for: .thread("t-mobile"))
        f.reader.confirmDiscussionReopenReply(first.id)
        XCTAssertEqual(try Data(contentsOf: f.file), before)
        XCTAssertNotNil(f.reader.discussionError)
        f.reader.cancelDiscussionDecision(first.id)
        f.reader.postDiscussion()
        let current = try XCTUnwrap(f.reader.discussionDecision)
        XCTAssertNotEqual(current.id, first.id)
        f.reader.confirmDiscussionReopenReply(first.id)
        f.reader.cancelDiscussionDecision(first.id)
        XCTAssertEqual(f.reader.discussionDecision?.id, current.id)
        XCTAssertEqual(try Data(contentsOf: f.file), before)
        f.reader.confirmDiscussionReopenReply(current.id)
        let saved = await poll { !f.reader.fileSaving && !f.reader.isRendering && f.reader.rendered?.discussions?.threads.first?.messages.count == 2 }
        XCTAssertTrue(saved)
        let thread = try XCTUnwrap(try DiscussionCodec.parse(MarkdownSource.read(f.file)).threads.first)
        XCTAssertEqual(thread.state, .open)
        XCTAssertEqual(thread.messages.last?.body, "New typing must be reviewed first.")
        XCTAssertNil(f.reader.discussionDecision)
        XCTAssertFalse(f.reader.discussions.hasUnpostedDrafts)
    }

    func testResolveConfirmationRejectsAnIdenticalExternalReplacement() async throws {
        let f = try await fixture(withThread: true)
        f.reader.openDiscussion("t-mobile"); f.reader.discussions.displayName = "Test Author"
        f.reader.discussions.setDraft("Keep this unposted reply.", for: .thread("t-mobile"))
        f.reader.requestResolveDiscussion("t-mobile")
        XCTAssertNotNil(f.reader.discussionDecision)
        guard let decision = f.reader.discussionDecision else { return }
        try f.original.write(to: f.file, options: .atomic)
        await f.reader.refresh(); await f.reader.waitForRendering()
        f.reader.confirmDiscussionResolution(decision.id, choice: .discardDraft)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "Keep this unposted reply.")
        XCTAssertEqual(f.reader.rendered?.discussions?.threads.first?.state, .open)
        XCTAssertNotNil(f.reader.discussionError)
    }

    func testActualSelectionReattachmentRequiresConfirmationAndPreservesDraftAndHistory() async throws {
        let f = try await fixture(withThread: true)
        f.reader.openDiscussion("t-mobile"); f.reader.discussions.displayName = "Test Author"
        f.reader.discussions.setDraft("Keep my unsent reply.", for: .thread("t-mobile"))
        _ = try await f.web.callAsyncJavaScript("""
        const paragraph=Array.from(document.querySelectorAll('main p')).find(p=>p.textContent==='Before.');
        const range=document.createRange();range.selectNodeContents(paragraph);
        getSelection().removeAllRanges();getSelection().addRange(range);return true;
        """, arguments: [:], in: nil, contentWorld: .defaultClient)
        f.reader.requestReattachDiscussion("t-mobile")
        let offered = await poll { f.reader.discussionDecision != nil }
        XCTAssertTrue(offered, "Reattachment needs an old/new quote comparison before writing")
        guard let decision = f.reader.discussionDecision else { return }
        if case let .reattach(id, old, selected) = decision.kind {
            XCTAssertEqual(id, "t-mobile"); XCTAssertEqual(old.exact, "Café bold passage.")
            XCTAssertEqual(selected.target.exact, "Before.")
        } else { XCTFail("Expected reattachment comparison") }
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        f.reader.confirmDiscussionReattachment(decision.id)
        let saved = await poll { !f.reader.fileSaving && !f.reader.isRendering && f.reader.rendered?.discussions?.threads.first?.target.exact == "Before." }
        XCTAssertTrue(saved)
        let thread = try XCTUnwrap(try DiscussionCodec.parse(MarkdownSource.read(f.file)).threads.first)
        XCTAssertEqual(thread.messages.map(\.body), ["A portable note."])
        XCTAssertEqual(thread.attachmentHistory.first?.target.exact, "Café bold passage.")
        XCTAssertEqual(thread.attachmentHistory.first?.author, "Test Author")
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "Keep my unsent reply.")
        XCTAssertNil(f.reader.discussionDecision)
        f.reader.undoDiscussion()
        _ = await poll { !f.reader.fileSaving && !f.reader.isRendering }
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "Keep my unsent reply.")
    }

    func testReattachmentWithoutSelectionUsesTheNativePassagePicker() async throws {
        let f = try await fixture(withThread: true)
        f.reader.openDiscussion("t-mobile"); f.reader.discussions.displayName = "Test Author"
        _ = try await f.web.evaluateJavaScript("getSelection().removeAllRanges();true")
        f.reader.requestReattachDiscussion("t-mobile")
        let offered = await poll { f.reader.discussionPassagePicker != nil }
        XCTAssertTrue(offered, "Reattach must offer accessible semantic passages when nothing is selected")
        guard let picker = f.reader.discussionPassagePicker else { return }
        let unit = try XCTUnwrap(picker.projection.units.first { $0.text == "Before." })
        f.reader.confirmDiscussionPassage(unit.id, pickerID: picker.id)
        let decision = try XCTUnwrap(f.reader.discussionDecision)
        if case let .reattach(_, old, selected) = decision.kind {
            XCTAssertEqual(old.exact, "Café bold passage."); XCTAssertEqual(selected.target.exact, "Before.")
        } else { XCTFail("Choosing a replacement must compare the quotes, not start a new discussion") }
        XCTAssertTrue(f.reader.discussions.drafts.isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        f.reader.cancelDiscussionDecision(decision.id)
        XCTAssertNil(f.reader.discussionDecision)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testReattachmentRejectsStaleSourceAndOldDecisionsButKeepsNewTyping() async throws {
        let f = try await fixture(withThread: true)
        f.reader.openDiscussion("t-mobile"); f.reader.discussions.displayName = "Test Author"
        f.reader.discussions.setDraft("My original draft.", for: .thread("t-mobile"))
        _ = try await f.web.evaluateJavaScript("getSelection().removeAllRanges();true")
        f.reader.requestReattachDiscussion("t-mobile")
        let offered = await poll { f.reader.discussionPassagePicker != nil }
        XCTAssertTrue(offered)
        guard let picker = f.reader.discussionPassagePicker else { return }
        let unit = try XCTUnwrap(picker.projection.units.first { $0.text == "Before." })
        f.reader.confirmDiscussionPassage(unit.id, pickerID: picker.id)
        let old = try XCTUnwrap(f.reader.discussionDecision)
        try f.original.write(to: f.file, options: .atomic)
        await f.reader.refresh(); await f.reader.waitForRendering()
        f.reader.confirmDiscussionReattachment(old.id)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        XCTAssertNotNil(f.reader.discussionError)
        f.reader.cancelDiscussionDecision(old.id)
        f.reader.requestReattachDiscussion("t-mobile")
        let currentOffered = await poll { f.reader.discussionPassagePicker != nil }
        XCTAssertTrue(currentOffered)
        let currentPicker = try XCTUnwrap(f.reader.discussionPassagePicker)
        let currentUnit = try XCTUnwrap(currentPicker.projection.units.first { $0.text == "Before." })
        f.reader.confirmDiscussionPassage(currentUnit.id, pickerID: currentPicker.id)
        let current = try XCTUnwrap(f.reader.discussionDecision)
        f.reader.confirmDiscussionReattachment(old.id); f.reader.cancelDiscussionDecision(old.id)
        XCTAssertEqual(f.reader.discussionDecision?.id, current.id)
        f.reader.discussions.setDraft("New typing stays with my reply.", for: .thread("t-mobile"))
        f.reader.confirmDiscussionReattachment(current.id)
        let saved = await poll { !f.reader.fileSaving && !f.reader.isRendering && f.reader.rendered?.discussions?.threads.first?.target.exact == "Before." }
        XCTAssertTrue(saved)
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "New typing stays with my reply.")
        XCTAssertEqual(try DiscussionCodec.parse(MarkdownSource.read(f.file)).threads.first?.attachmentHistory.count, 1)
    }

    func testNativeCopyPickerShowsAReadOnlyPreviewBeforeExplicitImport() async throws {
        let f = try await fixture(withThread: true)
        f.reader.openDiscussion("t-mobile")
        f.reader.discussions.setDraft("Keep my local reply.", for: .thread("t-mobile"))
        let other = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        let incoming = try incomingCopy(f.original, conflict: false); try incoming.write(to: other)
        defer { try? FileManager.default.removeItem(at: other) }
        f.reader.requestReviewAnotherCopy()
        XCTAssertNotNil(f.reader.discussionCopyRequest, "Review Another Copy must start a version-fenced native file choice")
        guard f.reader.discussionCopyRequest != nil else { return }
        let mounted = await poll { self.documentPicker(in: f.host) != nil }
        XCTAssertTrue(mounted)
        let picker = try XCTUnwrap(documentPicker(in: f.host))
        XCTAssertFalse(picker.allowsMultipleSelection)
        picker.delegate?.documentPicker?(picker, didPickDocumentsAt: [other])
        let reviewed = await poll { f.reader.discussionImportReview != nil }
        XCTAssertTrue(reviewed)
        let review = try XCTUnwrap(f.reader.discussionImportReview)
        XCTAssertEqual(review.preview.items.first?.kind, .replies)
        XCTAssertEqual(f.reader.fileURL, f.file)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        XCTAssertEqual(try Data(contentsOf: other), incoming)
        f.reader.confirmDiscussionImport(review.id)
        let saved = await poll { !f.reader.fileSaving && !f.reader.isRendering && f.reader.rendered?.discussions?.threads.first?.messages.count == 2 }
        XCTAssertTrue(saved)
        XCTAssertTrue(f.reader.source.hasPrefix("# Plan\n"))
        XCTAssertFalse(f.reader.source.contains("# Other copy prose"))
        XCTAssertEqual(try Data(contentsOf: other), incoming)
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "Keep my local reply.")
        XCTAssertNil(f.reader.discussionImportReview)
        f.reader.undoDiscussion(); _ = await poll { !f.reader.fileSaving && !f.reader.isRendering }
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testOldFilePickerSelectionCannotReviewIntoAnotherDocument() async throws {
        let f = try await fixture(withThread: true)
        let other = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        try incomingCopy(f.original, conflict: false).write(to: other)
        defer { try? FileManager.default.removeItem(at: other) }
        f.reader.requestReviewAnotherCopy()
        XCTAssertNotNil(f.reader.discussionCopyRequest)
        guard let request = f.reader.discussionCopyRequest else { return }
        let second = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        try f.original.write(to: second); defer { try? FileManager.default.removeItem(at: second) }
        await f.reader.open(url: second); await f.reader.waitForRendering()
        await f.reader.completeDiscussionCopyPicker(other, request: request)
        XCTAssertEqual(f.reader.fileURL, second)
        XCTAssertNil(f.reader.discussionImportPreview)
        XCTAssertNil(f.reader.discussionImportReview)
        XCTAssertEqual(try Data(contentsOf: second), f.original)
        f.reader.discussions.discardDrafts(); await f.reader.close()
    }

    func testConflictingCopyRequiresAChoiceAndCanRemainSeparate() async throws {
        let f = try await fixture(withThread: true)
        let other = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        let incoming = try incomingCopy(f.original, conflict: true); try incoming.write(to: other)
        defer { try? FileManager.default.removeItem(at: other) }
        f.reader.requestReviewAnotherCopy()
        XCTAssertNotNil(f.reader.discussionCopyRequest)
        guard f.reader.discussionCopyRequest != nil else { return }
        let mounted = await poll { self.documentPicker(in: f.host) != nil }; XCTAssertTrue(mounted)
        let picker = try XCTUnwrap(documentPicker(in: f.host))
        picker.delegate?.documentPicker?(picker, didPickDocumentsAt: [other])
        let reviewed = await poll { f.reader.discussionImportReview != nil }; XCTAssertTrue(reviewed)
        let review = try XCTUnwrap(f.reader.discussionImportReview)
        XCTAssertEqual(review.preview.items.first?.kind, .conflict)
        XCTAssertEqual(review.preview.current.threads.first?.messages.first?.body, "A portable note.")
        XCTAssertEqual(review.preview.incoming.threads.first?.messages.first?.body, "Incoming conflicting comment.")
        f.reader.confirmDiscussionImport(review.id)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        XCTAssertNotNil(f.reader.discussionError)
        f.reader.confirmDiscussionImport(review.id, choices: ["t-mobile": .keepSeparate])
        let saved = await poll { !f.reader.fileSaving && !f.reader.isRendering && f.reader.rendered?.discussions?.threads.count == 2 }; XCTAssertTrue(saved)
        let threads = try DiscussionCodec.parse(MarkdownSource.read(f.file)).threads
        XCTAssertEqual(Set(threads.flatMap(\.messages).map(\.body)), ["A portable note.", "Incoming conflicting comment."])
        XCTAssertEqual(Set(threads.flatMap(\.messages).map(\.id)).count, 2)
        XCTAssertEqual(try Data(contentsOf: other), incoming)
    }

    func testImportReviewRejectsOldCallbacksAndReplacedCurrentFile() async throws {
        let f = try await fixture(withThread: true)
        let other = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        try incomingCopy(f.original, conflict: false).write(to: other)
        defer { try? FileManager.default.removeItem(at: other) }
        f.reader.requestReviewAnotherCopy()
        XCTAssertNotNil(f.reader.discussionCopyRequest)
        guard let request = f.reader.discussionCopyRequest else { return }
        await f.reader.completeDiscussionCopyPicker(other, request: request)
        let old = try XCTUnwrap(f.reader.discussionImportReview)
        f.reader.cancelDiscussionImportReview(old.id)
        _ = await poll { f.host.presentedViewController == nil }
        f.reader.requestReviewAnotherCopy()
        let currentRequest = try XCTUnwrap(f.reader.discussionCopyRequest)
        await f.reader.completeDiscussionCopyPicker(other, request: currentRequest)
        let current = try XCTUnwrap(f.reader.discussionImportReview)
        f.reader.cancelDiscussionImportReview(old.id); f.reader.confirmDiscussionImport(old.id)
        XCTAssertEqual(f.reader.discussionImportReview?.id, current.id)
        try f.original.write(to: f.file, options: .atomic)
        await f.reader.refresh(); await f.reader.waitForRendering()
        f.reader.confirmDiscussionImport(current.id)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        XCTAssertNotNil(f.reader.discussionError)
    }

    func testSnapshotCopyMovesLatestDraftOnlyWhenExplicitlyOpened() async throws {
        let f = try await fixture()
        var previewURL = URLComponents(string: "margined://preview")!
        previewURL.queryItems = [.init(name: "text", value: try MarkdownSource.decode(f.original)), .init(name: "title", value: "Snapshot")]
        await f.reader.openPreview(url: try XCTUnwrap(previewURL.url))
        await f.reader.waitForRendering()
        let projection = try XCTUnwrap(f.reader.rendered?.discussionText)
        let unit = try XCTUnwrap(projection.units.first { $0.text.contains("bold passage") })
        let selection = try XCTUnwrap(projection.selection(unit.range, renderID: "copy-test"))
        let key = try f.reader.discussions.beginDraft(selection, in: projection)
        f.reader.discussions.displayName = "Copy Author"
        f.reader.discussions.setDraft("Unposted before saving.", for: key)
        f.reader.requestDiscussionExport(.savedCopy)
        XCTAssertNotNil(f.reader.discussionExport, "A read-only snapshot must offer a native new-copy flow")
        guard let export = f.reader.discussionExport else { return }
        let target = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: target) }
        f.reader.createDiscussionExport(export.id, at: target)
        XCTAssertTrue(f.reader.fileSaving, "Save must be accepted synchronously before close or navigation")
        await f.reader.waitForSaving()
        let result = try XCTUnwrap(f.reader.discussionExportResult)
        XCTAssertEqual(try Data(contentsOf: target), f.original)
        XCTAssertNil(f.reader.fileURL)
        XCTAssertEqual(f.reader.discussions.drafts[key]?.body, "Unposted before saving.")
        f.reader.discussions.setDraft("A newer reply before moving.", for: key)
        let copy = try XCTUnwrap(f.reader.takeDiscussionCopyToOpen(result.id))
        defer { Task { @MainActor in copy.discussions.discardDrafts(); await copy.close() } }
        XCTAssertEqual(copy.fileURL, target)
        XCTAssertEqual(copy.discussions.drafts[key]?.body, "A newer reply before moving.")
        XCTAssertFalse(f.reader.discussions.hasUnpostedDrafts)
        XCTAssertEqual(copy.discussions.draftAnchor(for: key)?.status, .attached)
        copy.postDiscussion(); await copy.waitForSaving(); await copy.waitForRendering()
        XCTAssertEqual(try DiscussionCodec.parse(MarkdownSource.read(target)).threads.first?.messages.first?.body, "A newer reply before moving.")
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testNativeExportModesPreserveSourceEncodingAndDrafts() async throws {
        let f = try await fixture(withThread: true)
        let encoded = Data([0xff, 0xfe]) + (try MarkdownSource.decode(f.original)).data(using: .utf16LittleEndian)!
        try encoded.write(to: f.file, options: .atomic)
        await f.reader.refresh(); await f.reader.waitForRendering()
        f.reader.discussions.setDraft("Never export this unsaved reply.", for: .thread("t-mobile"))
        for kind in [MobileDiscussionExport.Kind.markdown, .clean, .conversation] {
            f.reader.requestDiscussionExport(kind)
            XCTAssertNotNil(f.reader.discussionExport, "Each labeled export must prepare its real document payload")
            guard let export = f.reader.discussionExport else { return }
            let target = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
            defer { try? FileManager.default.removeItem(at: target) }
            if kind == .clean { XCTAssertEqual(export.removedBlocks, 1) }
            f.reader.createDiscussionExport(export.id, at: target); await f.reader.waitForSaving()
            let written = try Data(contentsOf: target), text = try MarkdownSource.decode(written)
            switch kind {
            case .markdown: XCTAssertEqual(written, encoded)
            case .clean:
                XCTAssertTrue(written.starts(with: [0xff, 0xfe]))
                XCTAssertTrue(try DiscussionCodec.parse(text).blocks.isEmpty)
                XCTAssertTrue(text.contains("Cafe\u{301} **bold** passage."))
            case .conversation:
                XCTAssertTrue(text.contains("A portable note."))
                XCTAssertTrue(text.contains("Reviewer"))
                XCTAssertFalse(text.contains("<!-- margined:thread"))
            case .savedCopy: XCTFail("This case tests exported files, not reader handoff")
            }
            XCTAssertFalse(text.contains("Never export this unsaved reply."))
            XCTAssertEqual(try Data(contentsOf: f.file), encoded)
            XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "Never export this unsaved reply.")
            f.reader.cancelDiscussionExport(export.id)
        }
    }

    func testExportNeverOverwritesAnExistingDestination() async throws {
        let f = try await fixture(withThread: true)
        f.reader.discussions.setDraft("Keep my reply after failure.", for: .thread("t-mobile"))
        f.reader.requestDiscussionExport(.savedCopy)
        XCTAssertNotNil(f.reader.discussionExport)
        guard let export = f.reader.discussionExport else { return }
        let target = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        let other = Data("A different existing file.\n".utf8); try other.write(to: target)
        defer { try? FileManager.default.removeItem(at: target) }
        f.reader.createDiscussionExport(export.id, at: target); await f.reader.waitForSaving()
        XCTAssertEqual(try Data(contentsOf: target), other)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        XCTAssertNotNil(f.reader.discussionError)
        XCTAssertNil(f.reader.discussionExportResult)
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "Keep my reply after failure.")
        XCTAssertEqual(f.reader.discussionExport?.id, export.id)
    }

    func testOldExportCallbackCannotSaveOrDismissAnotherDocument() async throws {
        let f = try await fixture(withThread: true)
        f.reader.requestDiscussionExport(.clean)
        XCTAssertNotNil(f.reader.discussionExport)
        guard let old = f.reader.discussionExport else { return }
        let second = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        let target = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        try f.original.write(to: second)
        defer { try? FileManager.default.removeItem(at: second); try? FileManager.default.removeItem(at: target) }
        await f.reader.open(url: second); await f.reader.waitForRendering()
        f.reader.requestDiscussionExport(.markdown)
        let current = try XCTUnwrap(f.reader.discussionExport)
        f.reader.cancelDiscussionExport(old.id)
        f.reader.createDiscussionExport(old.id, at: target); await f.reader.waitForSaving()
        XCTAssertEqual(f.reader.discussionExport?.id, current.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try Data(contentsOf: second), f.original)
        f.reader.cancelDiscussionExport(current.id)
        f.reader.requestDiscussionExport(.clean)
        let review = try XCTUnwrap(f.reader.discussionExport)
        try f.original.write(to: second, options: .atomic)
        await f.reader.refresh(); await f.reader.waitForRendering()
        f.reader.createDiscussionExport(review.id, at: target); await f.reader.waitForSaving()
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertNotNil(f.reader.discussionError)
    }

    func testCloseDrainsAnAcceptedNewCopySave() async throws {
        let f = try await fixture(withThread: true)
        f.reader.requestDiscussionExport(.savedCopy)
        XCTAssertNotNil(f.reader.discussionExport)
        guard let export = f.reader.discussionExport else { return }
        let target = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: target) }
        f.reader.createDiscussionExport(export.id, at: target)
        XCTAssertTrue(f.reader.fileSaving)
        await f.reader.close()
        XCTAssertEqual(try Data(contentsOf: target), f.original)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        XCTAssertFalse(f.reader.hasDocument)
        XCTAssertFalse(f.reader.fileSaving)
        XCTAssertNil(f.reader.discussionExportResult)
    }

    func testNativeMarkdownShareProvidesTheFrozenEncodedFileWithoutDrafts() async throws {
        let f = try await fixture(withThread: true)
        let encoded = Data([0xff, 0xfe]) + (try MarkdownSource.decode(f.original)).data(using: .utf16LittleEndian)!
        try encoded.write(to: f.file, options: .atomic)
        await f.reader.refresh(); await f.reader.waitForRendering()
        f.reader.discussions.setDraft("Private unposted reply.", for: .thread("t-mobile"))
        f.reader.requestMarkdownShare(); await f.reader.waitForSaving()
        XCTAssertNotNil(f.reader.discussionShare, "Share must stage a Markdown file without asking for an export folder")
        guard let share = f.reader.discussionShare else { return }
        let metadata = share.configuration.perItemMetadataProvider?(0, .linkPresentationMetadata) as? LPLinkMetadata
        XCTAssertNotNil(metadata, "The system share header must identify the Markdown file being shared")
        guard let metadata else { return }
        XCTAssertEqual(metadata.title, f.file.lastPathComponent)
        let presented = await poll { self.activityController(in: f.host) != nil }; XCTAssertTrue(presented)
        let activity = try XCTUnwrap(activityController(in: f.host))
        // The inherited responder configuration is independent of the input to
        // UIActivityViewController's initializer, including on plain UIKit controls.
        let provider = try XCTUnwrap(share.configuration.itemProvidersForActivityItemsConfiguration.first)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier("net.daringfireball.markdown"))
        let newer = Data("# A newer original\n\nKeep this agent update.\n".utf8)
        try newer.write(to: f.file, options: .atomic)
        await f.reader.refresh(); await f.reader.waitForRendering()
        let bytes = try await sharedData(from: provider)
        XCTAssertEqual(bytes, encoded, "The real native activity provider must keep the version chosen for sharing")
        XCTAssertTrue(try MarkdownSource.decode(bytes).contains("A portable note."))
        XCTAssertFalse(try MarkdownSource.decode(bytes).contains("Private unposted reply."))
        XCTAssertEqual(try Data(contentsOf: f.file), newer)
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "Private unposted reply.")
        activity.completionWithItemsHandler?(nil, false, nil, nil)
        let finished = await poll { f.reader.discussionShare == nil }; XCTAssertTrue(finished)
        XCTAssertTrue(FileManager.default.fileExists(atPath: share.url.path), "An activity provider still holding the file must keep it readable")
    }

    func testSharedTemporaryFileLivesUntilTheLastProviderReleasesIt() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let data = Data("# Share safely\n\nThe original stays unchanged.\n".utf8); try data.write(to: file)
        let reader = MobileReaderState(defaults: UserDefaults(suiteName: "MobileShare-\(UUID().uuidString)")!)
        addTeardownBlock { @MainActor in await reader.close(); try? FileManager.default.removeItem(at: file) }
        await reader.open(url: file); await reader.waitForRendering()
        reader.requestMarkdownShare(); await reader.waitForSaving()
        XCTAssertNotNil(reader.discussionShare)
        var share: MobileDiscussionShare? = reader.discussionShare
        guard share != nil else { return }
        let url = try XCTUnwrap(share?.url), id = try XCTUnwrap(share?.id)
        var provider = share?.configuration.itemProvidersForActivityItemsConfiguration.first
        reader.finishDiscussionShare(id); share = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let bytes = try await sharedData(from: XCTUnwrap(provider)); XCTAssertEqual(bytes, data)
        provider = nil
        let cleaned = await poll { !FileManager.default.fileExists(atPath: url.path) }; XCTAssertTrue(cleaned)
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testOldActivityCompletionCannotDismissTheNextDocumentsShare() async throws {
        let f = try await fixture(withThread: true)
        f.reader.requestMarkdownShare(); await f.reader.waitForSaving()
        XCTAssertNotNil(f.reader.discussionShare)
        guard let first = f.reader.discussionShare else { return }
        let mounted = await poll { self.activityController(in: f.host) != nil }; XCTAssertTrue(mounted)
        let activity = try XCTUnwrap(activityController(in: f.host))
        let completion = try XCTUnwrap(activity.completionWithItemsHandler)
        let second = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        try f.original.write(to: second); defer { try? FileManager.default.removeItem(at: second) }
        await f.reader.open(url: second); await f.reader.waitForRendering()
        let dismissed = await poll { f.host.presentedViewController == nil }; XCTAssertTrue(dismissed)
        f.reader.requestMarkdownShare(); await f.reader.waitForSaving()
        let current = try XCTUnwrap(f.reader.discussionShare)
        completion(nil, false, nil, nil)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        f.reader.finishDiscussionShare(first.id)
        let stillCurrent = await poll { f.reader.discussionShare?.id == current.id }; XCTAssertTrue(stillCurrent)
        XCTAssertEqual(f.reader.discussionShare?.id, current.id)
        XCTAssertEqual(try Data(contentsOf: current.url), f.original)
        XCTAssertEqual(try Data(contentsOf: second), f.original)
        f.reader.finishDiscussionShare(current.id)
    }


    func testNativeHistoryRendersFormattedBodiesAndLocalImagesWithReadOnlyTasks() async throws {
        let f = try await fixture(withThread: true)
        let image = f.file.deletingPathExtension().appendingPathExtension("png")
        try historyPixel.write(to: image); defer { try? FileManager.default.removeItem(at: image) }
        let body = "**Formatted history.**\n\n| Item | State |\n| --- | --- |\n| Reader | Ready |\n\n- [ ] Comment task\n\n![History](\(image.lastPathComponent))\n\n![Remote](https://127.0.0.1:9/history.png)"
        let bytes = try appendHistoryReply(body, id: "m-rich", file: f.file, threadID: "t-mobile")
        await f.reader.refresh(); await f.reader.waitForRendering(); f.reader.openDiscussion("t-mobile")
        let mounted = await poll { self.history(in: f.host.view, excluding: f.web) != nil }
        XCTAssertTrue(mounted, "Saved discussion bodies must use a native rendered history, separate from the composer")
        guard mounted, let history = history(in: f.host.view, excluding: f.web) else { return }
        try await waitForInitialHistory(f)
        let ready = await pollAsync {
            try await history.evaluateJavaScript("document.querySelector('article[data-message-id=m-rich] strong')?.textContent==='Formatted history.' && document.querySelector('img[alt=History]')?.naturalWidth===1") as? Bool == true
        }; XCTAssertTrue(ready)
        let duplicateQuoteCount = try await history.evaluateJavaScript("document.querySelectorAll('main > blockquote').length") as? Int
        XCTAssertEqual(duplicateQuoteCount, 0, "The surrounding native thread already displays its quoted context")
        let historyValue0 = try await history.evaluateJavaScript("document.querySelector('td')?.textContent") as? String
        XCTAssertEqual(historyValue0, "Reader")
        let historyValue1 = try await history.evaluateJavaScript("document.querySelector('input').disabled") as? Bool
        XCTAssertEqual(historyValue1, true)
        let historyValue2 = try await history.evaluateJavaScript("document.querySelector('img[alt=Remote]').getAttribute('src')") as? String
        XCTAssertEqual(historyValue2, nil)
        let historyValue3 = try await history.evaluateJavaScript("document.querySelectorAll('article header time').length") as? Int
        XCTAssertEqual(historyValue3, 2)
        let historyValue4 = try await history.evaluateJavaScript("document.querySelector('article[data-message-id=m-rich] header a')?.textContent") as? String
        XCTAssertEqual(historyValue4, "Reviewer")
        f.reader.loadRemoteImages = true
        let optedIn = await pollAsync {
            try await history.evaluateJavaScript("document.querySelector('img[alt=Remote]')?.getAttribute('src')==='https://127.0.0.1:9/history.png'") as? Bool == true
        }; XCTAssertTrue(optedIn, "The history must follow this document's remote-image choice")
        XCTAssertEqual(try Data(contentsOf: f.file), bytes)
        XCTAssertFalse(f.reader.fileSaving)
    }

    func testNativeHistoryRefreshKeepsItsPageReadingPositionAndFocusedDraft() async throws {
        let f = try await fixture(withThread: true, useNativeSceneBounds: true)
        let paragraphs = (0..<45).map { "History paragraph \($0) stays readable." }.joined(separator: "\n\n")
        _ = try appendHistoryReply(paragraphs, id: "m-long", file: f.file, threadID: "t-mobile")
        await f.reader.refresh(); await f.reader.waitForRendering(); f.reader.openDiscussion("t-mobile")
        f.reader.discussions.setDraft("Keep this focused reply.", for: .thread("t-mobile"))
        let mounted = await poll { self.history(in: f.host.view, excluding: f.web) != nil && self.editor(in: f.host.view)?.text == "Keep this focused reply." }
        XCTAssertTrue(mounted, "The rendered history and native reply editor must coexist")
        guard mounted, let history = history(in: f.host.view, excluding: f.web), let editor = editor(in: f.host.view) else { return }
        try await waitForInitialHistory(f)
        let ready = await pollAsync {
            guard !history.isLoading else { return false }
            return try await history.evaluateJavaScript("document.querySelectorAll('article').length===2 && document.documentElement.scrollHeight>innerHeight && document.body.style.fontSize!==''") as? Bool == true
        }
        XCTAssertTrue(ready)
        let keyboard = MobileKeyboardFrameObservation(window: f.window)
        XCTAssertTrue(editor.becomeFirstResponder())
        let typingSettled = await poll { keyboard.frame.height > 100 && editor.isFirstResponder }
        XCTAssertTrue(typingSettled, "Seed the history after the actual keyboard has completed its frame transition")
        guard typingSettled else { return }
        _ = try await history.callAsyncJavaScript("""
        await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame);
        window.scrollTo({top:160,behavior:'instant'});
        await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame);
        return true;
        """, arguments: [:], in: nil, contentWorld: .defaultClient)
        let scrolled = await pollAsync { try await history.evaluateJavaScript("scrollY>=159 && scrollY<=161") as? Bool == true }
        if !scrolled { try await recordDuoGeometry(f, keyboard: keyboard, phase: "refresh-scroll") }
        XCTAssertTrue(scrolled, "Establish an actual scrolled history with its native editor focused before refreshing")
        guard scrolled else { return }
        _ = try await history.evaluateJavaScript("window.historyPage=document;true")
        let before = try await history.evaluateJavaScript("scrollY") as? Double ?? 0
        XCTAssertGreaterThan(before, 0)
        let bytes = try appendHistoryReply("A newly saved reply.", id: "m-new", file: f.file, threadID: "t-mobile")
        await f.reader.refresh(); await f.reader.waitForRendering()
        let updated = await pollAsync { try await history.evaluateJavaScript("document.querySelectorAll('article').length===3") as? Bool == true }
        XCTAssertTrue(updated)
        XCTAssertTrue(self.history(in: f.host.view, excluding: f.web) === history)
        let historyValue5 = try await history.evaluateJavaScript("window.historyPage===document") as? Bool
        XCTAssertEqual(historyValue5, true)
        let historyValue6 = try await history.evaluateJavaScript("scrollY") as? Double ?? 0
        XCTAssertEqual(historyValue6, before, accuracy: 1)
        XCTAssertTrue(self.editor(in: f.host.view) === editor)
        XCTAssertTrue(editor.isFirstResponder)
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "Keep this focused reply.")
        XCTAssertEqual(try Data(contentsOf: f.file), bytes)
        editor.resignFirstResponder()
    }

    func testOldHistoryImageRequestCannotReadOrReportIntoTheNextDocument() async throws {
        let f = try await fixture(withThread: true)
        let image = f.file.deletingPathExtension().appendingPathExtension("png")
        try historyPixel.write(to: image); defer { try? FileManager.default.removeItem(at: image) }
        let bytes = try appendHistoryReply("![History](\(image.lastPathComponent))", id: "m-image", file: f.file, threadID: "t-mobile")
        await f.reader.refresh(); await f.reader.waitForRendering(); f.reader.openDiscussion("t-mobile")
        let mounted = await poll { self.history(in: f.host.view, excluding: f.web) != nil }
        XCTAssertTrue(mounted, "The current conversation must own a native history image context")
        guard mounted, let old = history(in: f.host.view, excluding: f.web) else { return }
        try await waitForInitialHistory(f)
        let ready = await pollAsync { try await old.evaluateJavaScript("document.querySelector('img[alt=History]')?.naturalWidth===1") as? Bool == true }; XCTAssertTrue(ready)
        let oldAddress = try await old.evaluateJavaScript("document.querySelector('img[alt=History]').src") as? String
        let address = try XCTUnwrap(oldAddress)
        let handler = try XCTUnwrap(old.configuration.urlSchemeHandler(forURLScheme: "margined-resource"))
        let folder = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let next = folder.appendingPathComponent("Identical.md")
        try bytes.write(to: next); try historyPixel.write(to: folder.appendingPathComponent(image.lastPathComponent))
        await f.reader.open(url: next); await f.reader.waitForRendering(); f.reader.openDiscussion("t-mobile")
        let replaced = await poll { self.history(in: f.host.view, excluding: f.web).map { $0 !== old } == true }; XCTAssertTrue(replaced)
        let request = MobileHistoryImageRequest(URLRequest(url: try XCTUnwrap(URL(string: address))))
        handler.webView(old, start: request)
        let finished = await poll { request.failure != nil || !request.data.isEmpty }; XCTAssertTrue(finished)
        XCTAssertEqual((request.failure as? URLError)?.code, .cancelled)
        XCTAssertTrue(request.data.isEmpty)
        XCTAssertNil(f.reader.localImageError)
        XCTAssertEqual(try Data(contentsOf: next), bytes)
        XCTAssertEqual(try Data(contentsOf: f.file), bytes)
    }

    private var historyPixel: Data { Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=")! }
    private func appendHistoryReply(_ body: String, id: String, file: URL, threadID: String) throws -> Data {
        let data = try Data(contentsOf: file), source = try MarkdownSource.decode(data)
        let message = DiscussionMessage(id: id, author: "Guest", created: "2026-10-24T10:00:00Z", body: body,
                                        inReplyTo: threadID == "t-mobile" ? "m-mobile" : "m-t1")
        let bytes = try MarkdownSourceEdits.apply(DiscussionEdits.splices(for:
            .reply(threadID: threadID, message: message, reopenResolved: false), in: DiscussionCodec.parse(source)),
            to: data, expectedSource: source)
        try bytes.write(to: file, options: .atomic); return bytes
    }
    private func history(in view: UIView, excluding document: WKWebView) -> WKWebView? {
        if let web = view as? WKWebView { return web !== document ? web : nil }
        return view.subviews.lazy.compactMap { self.history(in: $0, excluding: document) }.first
    }

    private func activityController(in controller: UIViewController) -> UIActivityViewController? {
        if let activity = controller as? UIActivityViewController { return activity }
        if let presented = controller.presentedViewController, let activity = activityController(in: presented) { return activity }
        return controller.children.lazy.compactMap { self.activityController(in: $0) }.first
    }
    private func sharedData(from provider: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: "net.daringfireball.markdown") { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw CocoaError(.fileReadNoSuchFile) }
                    continuation.resume(returning: try Data(contentsOf: url))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func incomingCopy(_ data: Data, conflict: Bool) throws -> Data {
        let source = try MarkdownSource.decode(data).replacingOccurrences(of: "# Plan\n", with: "# Other copy prose\n")
        if conflict { return Data(source.replacingOccurrences(of: "A portable note.", with: "Incoming conflicting comment.").utf8) }
        let document = try DiscussionCodec.parse(source)
        let message = DiscussionMessage(id: "m-incoming", author: "Guest", created: "2026-10-24T10:00:00Z", body: "A reply from another copy.", inReplyTo: "m-mobile")
        return try MarkdownSourceEdits.apply(DiscussionEdits.splices(for: .reply(threadID: "t-mobile", message: message, reopenResolved: false), in: document), to: Data(source.utf8), expectedSource: source)
    }
    private func documentPicker(in controller: UIViewController) -> UIDocumentPickerViewController? {
        if let picker = controller as? UIDocumentPickerViewController { return picker }
        if let presented = controller.presentedViewController, let picker = documentPicker(in: presented) { return picker }
        return controller.children.lazy.compactMap { self.documentPicker(in: $0) }.first
    }

    private enum FixtureFailure: Error { case documentDidNotLoad }
    private struct Fixture {
        let reader: MobileReaderState
        let file: URL
        let original: Data
        let window: UIWindow
        let host: UIHostingController<MobileDocumentWorkspace>
        let web: WKWebView
    }
    private func historyReadingPositionHasCommitted(_ history: WKWebView, in fixture: Fixture,
        initial: Bool, evidence: inout [String: Any]) async throws -> Bool {
        let condition = initial ? "y>300 && Math.abs(r.top)<2" : "r.top>=-2 && r.top<90"
        evidence = ["reason": "awaiting history DOM metrics", "initial": initial]
        let value: [String: Any]?
        do {
            value = try await history.evaluateJavaScript("""
        (()=>{
            const p=Array.from(document.querySelectorAll('p')).find(p=>p.textContent.startsWith('History paragraph 18 '));
            if(!p)return null;
            const r=p.getBoundingClientRect(),y=scrollY,height=innerHeight;
            return {semanticVisible:(\(condition))&&r.bottom>0&&r.top<height,
                x:scrollX,y,top:r.top,bottom:r.bottom,width:innerWidth,height,
                contentWidth:document.documentElement.scrollWidth,
                contentHeight:document.documentElement.scrollHeight};
        })()
        """) as? [String: Any]
        } catch {
            evidence = ["reason": "history DOM evaluation failed", "error": String(describing: error), "initial": initial]
            throw error
        }
        guard let value else { evidence = ["reason": "missing history DOM metrics"]; return false }
        return NativeReadingPositionReadiness.matches(value, web: history, window: fixture.window, evidence: &evidence)
    }

    private func waitForInitialHistory(_ fixture: Fixture) async throws {
        let committed = await WebKitTestReadiness.navigation({ self.history(in: fixture.host.view, excluding: fixture.web) },
            expectedURL: fixture.file.deletingLastPathComponent())
        _ = try XCTUnwrap(committed, "Finish initial native history navigation before checking its content")
    }

    private func fixture(withThread: Bool = false, useNativeSceneBounds: Bool = false, tail: String = "") async throws -> Fixture {
        var source = "# Plan\n\nBefore.\n\nCafe\u{301} **bold** passage.\n\nAfter.\n" + tail
        if withThread {
            let thread = DiscussionThread(id: "t-mobile", state: .open,
                target: .init(type: "TextQuoteSelector", exact: "Café bold passage.", prefix: "Before.", suffix: "After.", section: "Plan"),
                messages: [.init(id: "m-mobile", author: "Reviewer", created: "2026-10-23T10:00:00Z", body: "A portable note.", inReplyTo: nil)],
                resolvedBy: nil, resolved: nil, attachmentHistory: [])
            let parsed = try DiscussionCodec.parse(source)
            source = try MarkdownSource.decode(MarkdownSourceEdits.apply(DiscussionEdits.splices(for: .newThread(thread), in: parsed),
                to: Data(source.utf8), expectedSource: source))
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let original = Data(source.utf8); try original.write(to: file)
        let reader = MobileReaderState(defaults: UserDefaults(suiteName: "MobileDiscussionFixture-\(UUID().uuidString)")!)
        await reader.open(url: file); await reader.waitForRendering()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: MobileDocumentWorkspace(reader: reader, openFolder: {}, closeFile: {}))
        let window = UIWindow(windowScene: scene)
        window.frame = useNativeSceneBounds ? scene.coordinateSpace.bounds : CGRect(x: 0, y: 0, width: 390, height: 780)
        window.rootViewController = host; window.makeKeyAndVisible(); host.loadViewIfNeeded(); host.view.layoutIfNeeded()
        addTeardownBlock { @MainActor in
            reader.discussions.discardDrafts(); await reader.close()
            window.isHidden = true; window.rootViewController = nil
            try? FileManager.default.removeItem(at: file)
        }
        let committed = await WebKitTestReadiness.navigation({ self.webView(in: host.view) },
            expectedURL: file.deletingLastPathComponent())
        let mounted = committed != nil
        if !mounted {
            // Observe only after the original wait fails; never issue pre-commit JavaScript.
            let web = webView(in: host.view)
            let report: [String: Any] = [
                "afterOriginalMountWaitFailed": true,
                "applicationState": UIApplication.shared.applicationState.rawValue,
                "sceneState": scene.activationState.rawValue,
                "windowIsKey": window.isKeyWindow, "windowHidden": window.isHidden,
                "windowBounds": String(describing: window.bounds),
                "hostAttached": host.view.window === window,
                "webExists": web != nil, "webProgress": web?.estimatedProgress ?? -1,
                "webLoading": web?.isLoading ?? false, "webURLScheme": web?.url?.scheme ?? "none",
                "webBounds": web.map { String(describing: $0.bounds) } ?? "none",
                "webAttached": web?.window === window, "webHidden": web?.isHidden ?? true,
                "renderedExists": reader.rendered != nil, "rendering": reader.isRendering,
                "sourceBytes": reader.source.utf8.count,
                "otherSceneCount": UIApplication.shared.connectedScenes.count - 1]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print("MARGINED-MOUNT-FAIL " + text) }
        }
        XCTAssertTrue(mounted, "Wait for a committed navigation before querying WebKit")
        guard mounted else { throw FixtureFailure.documentDidNotLoad }
        let web = try XCTUnwrap(committed)
        let ready = await pollAsync { try await web.evaluateJavaScript("document.querySelector('main')?.textContent.normalize('NFC').includes('Café bold passage.')===true") as? Bool == true }
        XCTAssertTrue(ready, "The actual formatted fixture must be loaded before exercising discussion actions")
        guard ready else { throw FixtureFailure.documentDidNotLoad }
        return .init(reader: reader, file: file, original: original, window: window, host: host, web: web)
    }
    private func poll(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<500 { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
        return false
    }
    private func pollAsync(_ predicate: () async throws -> Bool) async -> Bool {
        for _ in 0..<500 { if (try? await predicate()) == true { return true }; try? await Task.sleep(for: .milliseconds(20)) }
        return false
    }
    private func webView(in view: UIView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.webView(in: $0) }.first
    }
    private func nameField(in view: UIView) -> UITextField? {
        if view is WKWebView { return nil }
        if let field = view as? UITextField, field.placeholder == "Your name" { return field }
        return view.subviews.lazy.compactMap { self.nameField(in: $0) }.first
    }
    private func visibleEditor(in view: UIView) -> UITextView? {
        guard !view.isHidden, view.alpha > 0.01, let window = view.window,
              view.convert(view.bounds, to: window).intersects(window.bounds) else { return nil }
        if view is WKWebView { return nil }
        if let text = view as? UITextView, text.isEditable { return text }
        return view.subviews.lazy.compactMap { self.visibleEditor(in: $0) }.first
    }
    private func editor(in view: UIView) -> UITextView? {
        if view is WKWebView { return nil }
        if let text = view as? UITextView, text.isEditable { return text }
        return view.subviews.lazy.compactMap { self.editor(in: $0) }.first
    }
}

private final class MobileHistoryImageRequest: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var data = Data()
    var failure: (any Error)?
    init(_ request: URLRequest) { self.request = request }
    func didReceive(_ response: URLResponse) {}
    func didReceive(_ data: Data) { self.data.append(data) }
    func didFinish() {}
    func didFailWithError(_ error: any Error) { failure = error }
}

@MainActor
private final class MobileKeyboardFrameObservation: NSObject {
    let window: UIWindow
    private(set) var frame = CGRect.zero
    private(set) var lastScreenFrame: CGRect?
    private(set) var diagnostics: [[String:Any]] = []
    init(window: UIWindow) {
        self.window = window
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)),
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willChange(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }
    @objc private func willChange(_ notification: Notification) { record(notification) }
    private func record(_ notification:Notification) {
        let info=notification.userInfo ?? [:]
        func responders(_ view:UIView)->[String] { (view.isFirstResponder ? ["\(type(of:view)):\(ObjectIdentifier(view))"] : [])+view.subviews.flatMap(responders) }
        diagnostics.append(["responders":responders(window),"name":notification.name.rawValue,"begin":String(describing:info[UIResponder.keyboardFrameBeginUserInfoKey]),
            "end":String(describing:info[UIResponder.keyboardFrameEndUserInfoKey]),"local":String(describing:info[UIResponder.keyboardIsLocalUserInfoKey]),
            "object":String(describing:notification.object.map{type(of:$0)}),"key":window.isKeyWindow,"scene":window.windowScene?.session.persistentIdentifier ?? "none"])
        if diagnostics.count>12 {diagnostics.removeFirst()}
    }
    @objc private func changed(_ notification: Notification) {
        guard let screen = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        lastScreenFrame=screen;record(notification)
        frame = window.convert(screen, from: window.screen.coordinateSpace).intersection(window.bounds)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}

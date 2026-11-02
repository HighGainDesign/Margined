import XCTest
import WebKit
#if os(iOS)
import UIKit
@testable import MarginediOS
#else
import AppKit
@testable import Margined
#endif

@MainActor
final class DiscussionHistoryLifecycleTests: XCTestCase {
    func testTemporarilyHiddenHistoryCanResumeWithTheLatestSavedMessages() async throws {
        var visible = true
        let scope = DiscussionHistoryScope(fileURL: nil, isCurrent: { visible },
            imageFailed: { _ in XCTFail("No image requests in this fixture") }, openFile: { _ in XCTFail("No navigation in this fixture") })
        let coordinator = DiscussionHistoryCoordinator(scope: scope)
        let web = coordinator.makeWebView()
        defer { coordinator.invalidate() }
        try mount(web)
        let first = "<html><body><main id='document'><p>First saved message.</p></main></body></html>"
        coordinator.update(html: first, fontSize: 16, imageGeneration: 0)
        try await waitForNavigation(web)
        let loaded = await contains("First saved message.", in: web)
        XCTAssertTrue(loaded, "Establish a committed history before changing its presentation")
        guard loaded else { return }

        visible = false
        coordinator.update(html: first, fontSize: 16, imageGeneration: 0)
        visible = true
        let latest = first.replacingOccurrences(of: "</main>", with: "<p>Second saved message.</p></main>")
        coordinator.update(html: latest, fontSize: 20, imageGeneration: 0)
        let resumed = await contains("Second saved message.", in: web)
        XCTAssertTrue(resumed, "A temporary compact/docked transition must not permanently invalidate a retained history")
        let firstStillPresent = await contains("First saved message.", in: web)
        XCTAssertTrue(firstStillPresent)
        XCTAssertNotNil(web.window)
    }

    func testExplicitlyRetiredHistoryNeverResumes() async throws {
        let scope = DiscussionHistoryScope(fileURL: nil, isCurrent: { true }, imageFailed: { _ in }, openFile: { _ in })
        let coordinator = DiscussionHistoryCoordinator(scope: scope)
        let web = coordinator.makeWebView()
        try mount(web)
        coordinator.update(html: "<html><body><main id='document'>Original message.</main></body></html>", fontSize: 16, imageGeneration: 0)
        try await waitForNavigation(web)
        let loaded = await contains("Original message.", in: web)
        XCTAssertTrue(loaded)
        coordinator.invalidate()
        coordinator.update(html: "<html><body>Must not load.</body></html>", fontSize: 16, imageGeneration: 0)
        for _ in 0..<5 { await Task.yield() }
        let text = try await web.evaluateJavaScript("document.body.textContent") as? String
        XCTAssertFalse(text?.contains("Must not load.") == true)
    }

    func testInPlaceRefreshRetiresAnInterruptedRestoreAndCapturesSubsequentScrolling() async throws {
        let state = DiscussionHistoryPresentationState(), gate = HistoryCaptureGate()
        let seedOwner = UUID()
        state.activate(seedOwner)
        state.capture(owner: seedOwner) {
            await gate.wait()
            return ["x": 0, "y": 0, "top": 0, "candidates": []]
        }
        let scope = DiscussionHistoryScope(fileURL: nil, isCurrent: { true }, imageFailed: { _ in },
            openFile: { _ in }, presentationState: state)
        let first = historyHTML()
        let latest = first.replacingOccurrences(of: "</main>", with: "<p id='new-message'>Appended saved message.</p></main>")
        let coordinator = DiscussionHistoryCoordinator(scope: scope), web = coordinator.makeWebView()
        defer { gate.release(); coordinator.invalidate() }
        let navigation = HistoryNavigationProbe(coordinator: coordinator)
        web.navigationDelegate = navigation
        try mount(web)
        coordinator.update(html: first, fontSize: 16, imageGeneration: 0)
        try await waitForNavigation(web)
        let initial = await poll { navigation.completions == 1 }
        XCTAssertTrue(initial); guard initial else { gate.release(); return }
        _ = try await web.evaluateJavaScript("window.originalHistoryDocument=document;true")
        // The native didFinish callback has marked this page ready. Its restore
        // waits on the held outgoing capture while this same-head update runs.
        coordinator.update(html: latest, fontSize: 16, imageGeneration: 0)
        let reconciled = await poll {
            try await web.evaluateJavaScript("window.originalHistoryDocument===document && !!document.getElementById('new-message')") as? Bool == true
        }
        XCTAssertTrue(reconciled)
        XCTAssertEqual(navigation.completions, 1, "Exercise in-place reconciliation, not replacement navigation")
        gate.release()
        _ = await state.restorePosition()
        try await reveal("history-p23", in: web)
        coordinator.invalidate()

        let successor = DiscussionHistoryCoordinator(scope: scope), restored = successor.makeWebView()
        defer { successor.invalidate() }
        try mount(restored)
        successor.update(html: latest, fontSize: 16, imageGeneration: 0)
        try await waitForNavigation(restored)
        let retained = await poll {
            try await restored.evaluateJavaScript("document.body.style.fontSize==='16px' && Math.abs(document.getElementById('history-p23').getBoundingClientRect().top-24)<2") as? Bool == true
        }
        if !retained {
            let dom = try? await restored.evaluateJavaScript("JSON.stringify({ready:document.readyState,font:document.body?.style.fontSize,anchor:document.getElementById('history-p23')?.getBoundingClientRect().top,y:scrollY})")
            let cached = await state.restorePosition()
            let candidate = (cached?["candidates"] as? [[String: Any]])?.first?["id"]
            let cachedTop = cached?["top"]
            print("INTERRUPTED-RESTORE-FAIL progress=\(restored.estimatedProgress) loading=\(restored.isLoading) dom=\(String(describing:dom)) cachedID=\(String(describing:candidate)) top=\(String(describing:cachedTop))")
        }
        XCTAssertTrue(retained, "A superseded restore must not prevent capturing the later paragraph being read")
    }

    func testSameMountedHistoryRetainsItsPassageAcrossResizeAndInPlaceTokenRenewal() async throws {
        let scope = DiscussionHistoryScope(fileURL: nil, isCurrent: { true }, imageFailed: { _ in }, openFile: { _ in })
        let coordinator = DiscussionHistoryCoordinator(scope: scope), web = coordinator.makeWebView()
        let navigation = HistoryNavigationProbe(coordinator: coordinator)
        web.navigationDelegate = navigation
        defer { coordinator.invalidate() }
        try mount(web)
        let first = historyHTML()
        coordinator.update(html: first, fontSize: 16, imageGeneration: 0)
        try await waitForNavigation(web)
        let ready = await poll {
            try await web.evaluateJavaScript("document.body.style.fontSize==='16px'") as? Bool == true
        }
        XCTAssertTrue(ready); guard ready else { return }
        _ = try await web.evaluateJavaScript("window.resizingHistoryDocument=document;true")
        try await reveal("history-p22", in: web)
        resize(web, to: CGSize(width: 500, height: 400))
        let firstResize = await poll {
            guard web.bounds.width == 500 else { return false }
            return try await web.callAsyncJavaScript("return Math.abs(innerWidth-expectedWidth)<1 && window.resizingHistoryDocument===document && Math.abs(document.getElementById('history-p22').getBoundingClientRect().top-24)<2", arguments: ["expectedWidth": self.layoutViewportWidth(web)], in: nil, contentWorld: .page) as? Bool == true
        }
        if !firstResize { try await recordDuoHistoryGeometry(web, coordinator: coordinator, phase: "first500", navigations: navigation.completions) }
        XCTAssertTrue(firstResize, "The history token must authorize its own same-mounted resize observer after scrolling")

        let latest = first.replacingOccurrences(of: "</main>", with: "<p id='new-message'>Appended saved message.</p></main>")
        coordinator.update(html: latest, fontSize: 16, imageGeneration: 0)
        let reconciled = await poll {
            try await web.evaluateJavaScript("window.resizingHistoryDocument===document && !!document.getElementById('new-message')") as? Bool == true
        }
        XCTAssertTrue(reconciled)
        try await reveal("history-p32", in: web)
        let established = await poll {
            guard web.bounds.width == 500 else { return false }
            return try await web.callAsyncJavaScript("""
            const target=document.getElementById('history-p32');
            const visible=()=>Math.abs(innerWidth-expectedWidth)<1 && document.documentElement.clientWidth>0 && Math.abs(document.getElementById('document').getBoundingClientRect().width-document.documentElement.clientWidth)<1 &&
                Math.abs(target.getBoundingClientRect().top-24)<2 && document.elementFromPoint(document.documentElement.clientWidth/2,24)?.closest('p')===target;
            if(!visible())return false;
            await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
            return visible();
            """, arguments: ["expectedWidth": self.layoutViewportWidth(web)], in: nil, contentWorld: .world(name: "MarginedDiscussionHistory")) as? Bool == true
        }
        if !established { try await recordDuoHistoryGeometry(web, coordinator: coordinator, phase: "establish500", navigations: navigation.completions) }
        XCTAssertTrue(established, "Establish the actual visible paragraph and native 500-point layout before resizing it")
        resize(web, to: CGSize(width: 390, height: 400))
        let renewed = await poll {
            guard web.bounds.width == 390 else { return false }
            return try await web.callAsyncJavaScript("return Math.abs(innerWidth-expectedWidth)<1 && window.resizingHistoryDocument===document && Math.abs(document.getElementById('history-p32').getBoundingClientRect().top-24)<2", arguments: ["expectedWidth": self.layoutViewportWidth(web)], in: nil, contentWorld: .page) as? Bool == true
        }
        if !renewed { try await recordDuoHistoryGeometry(web, coordinator: coordinator, phase: "renew390", navigations: navigation.completions) }
        XCTAssertTrue(renewed, "In-place history-token updates must renew the resize lease before later scrolling/reflow")
        XCTAssertEqual(navigation.completions, 1, "The renewal must retain its original native navigation")
    }

    func testLongOlderMessagesCollapseInlineWhileLatestAndLinkTargetsStayExpanded() async throws {
        let scope = DiscussionHistoryScope(fileURL: nil, isCurrent: { true }, imageFailed: { _ in }, openFile: { _ in })
        let coordinator = DiscussionHistoryCoordinator(scope: scope), web = coordinator.makeWebView()
        defer { coordinator.invalidate() }
        try mount(web)
        let html = disclosureHTML()
        coordinator.update(html: html, fontSize: 16, imageGeneration: 0)
        try await waitForNavigation(web)
        let ready = await poll {
            try await web.evaluateJavaScript("document.querySelector('[data-message-id=older] button')?.getAttribute('aria-expanded')==='false'") as? Bool == true
        }
        XCTAssertTrue(ready, "An older body exceeding eight rendered lines needs a compact disclosure")
        guard ready else { return }
        let initial = try await web.evaluateJavaScript("""
        (()=>{const a=document.querySelector('[data-message-id=older]'),b=a.querySelector('.discussion-message-body'),c=a.querySelector('button');return [b.clientHeight,parseFloat(getComputedStyle(b).lineHeight),c.getAttribute('aria-label'),c.textContent,document.querySelector('[data-message-id=latest] button')===null,b.textContent.includes('Tail preserved'),getComputedStyle(b).overflowY]})()
        """) as? [Any]
        XCTAssertEqual((initial?[0] as? Double ?? 0) / (initial?[1] as? Double ?? 1), 4, accuracy: 0.1)
        XCTAssertEqual(initial?[2] as? String, "Show full comment")
        XCTAssertEqual(initial?[3] as? String, "", "Use a compact chevron, without a full label row")
        XCTAssertEqual(initial?[4] as? Bool, true)
        XCTAssertEqual(initial?[5] as? Bool, true)
        XCTAssertEqual(initial?[6] as? String, "hidden", "The message must not introduce another scroller")
        let hiddenControl = try await web.evaluateJavaScript("(()=>{const a=document.getElementById('hidden-link');a.focus();return [a.inert,a.tabIndex,document.activeElement===a]})()") as? [Any]
        XCTAssertEqual(hiddenControl?[0] as? Bool, true, "Wholly clipped controls are excluded from keyboard and accessibility navigation")
        XCTAssertEqual(hiddenControl?[1] as? Int, -1)
        XCTAssertEqual(hiddenControl?[2] as? Bool, false)
        let control = try await web.evaluateJavaScript("(()=>{const b=document.querySelector('[data-message-id=older] button'),r=b.getBoundingClientRect();return {width:r.width,height:r.height,controls:b.getAttribute('aria-controls'),type:b.type}})()") as? [String: Any]
        #if os(iOS)
        XCTAssertGreaterThanOrEqual(control?["width"] as? Double ?? 0, 44)
        XCTAssertGreaterThanOrEqual(control?["height"] as? Double ?? 0, 44)
        #else
        XCTAssertGreaterThanOrEqual(control?["width"] as? Double ?? 0, 24)
        XCTAssertGreaterThanOrEqual(control?["height"] as? Double ?? 0, 24)
        #endif
        XCTAssertEqual(control?["type"] as? String, "button")
        XCTAssertFalse((control?["controls"] as? String ?? "").isEmpty, "The native WebKit button exposes an expanded state for its associated body")
        let boundaryCollapsed = try await web.evaluateJavaScript("!!document.querySelector('[data-message-id=boundary] button')") as? Bool
        XCTAssertEqual(boundaryCollapsed, false, "Exactly eight rendered body lines remain fully visible")
        coordinator.update(html: html, fontSize: 16, imageGeneration: 0, previewLines: 3)
        let shortTyping = await poll {
            try await web.evaluateJavaScript("document.querySelector('[data-message-id=older] .discussion-message-body').clientHeight===72") as? Bool == true
        }
        XCTAssertTrue(shortTyping, "Short typing uses three lines without rebuilding the history")
        _ = try await web.evaluateJavaScript("document.querySelector('[data-message-id=older] button').click()")
        let expanded = try await web.evaluateJavaScript("document.querySelector('[data-message-id=older] button').getAttribute('aria-expanded')") as? String
        XCTAssertEqual(expanded, "true")
        let expandedLabel = try await web.evaluateJavaScript("document.querySelector('[data-message-id=older] button').getAttribute('aria-label')") as? String
        XCTAssertEqual(expandedLabel, "Show less")
        let expandedControl = try await web.evaluateJavaScript("(()=>{const a=document.getElementById('hidden-link');return [a.inert,a.tabIndex]})()") as? [Any]
        XCTAssertEqual(expandedControl?[0] as? Bool, false)
        XCTAssertEqual(expandedControl?[1] as? Int, 0, "Expanding restores the original native link behavior")
        _ = try await web.evaluateJavaScript("document.querySelector('[data-message-id=older] button').click();document.querySelector('[data-message-id=latest] a').click()")
        let targeted = await poll {
            try await web.evaluateJavaScript("document.querySelector('[data-message-id=older] button').getAttribute('aria-expanded')==='true'") as? Bool == true
        }
        XCTAssertTrue(targeted, "Reply and body fragment links must expand their target before navigation")
        _ = try await web.evaluateJavaScript("document.querySelector('[data-message-id=older] button').click()")
        coordinator.update(html: html, fontSize: 16, imageGeneration: 0,
            speech: .init(elementID: "saved-body", follow: false))
        let speechTarget = await poll {
            try await web.evaluateJavaScript("document.querySelector('[data-message-id=older] button')?.getAttribute('aria-expanded')==='true'") as? Bool == true
        }
        XCTAssertTrue(speechTarget, "The full current speech message is visible even when following is paused")
        _ = try await web.evaluateJavaScript("document.querySelector('[data-message-id=older] button').click()")
        coordinator.update(html: html, fontSize: 16, imageGeneration: 0, targetedMessageID: "older")
        let explicitTarget = await poll {
            try await web.evaluateJavaScript("document.querySelector('[data-message-id=older] button')===null && document.querySelector('[data-message-id=older] .discussion-message-body').style.maxHeight===''") as? Bool == true
        }
        XCTAssertTrue(explicitTarget, "An explicitly targeted message remains fully expanded")
    }

    func testDisclosureSurvivesReconciliationAndRestoresSessionWithoutMovingTheReadingAnchor() async throws {
        let state = DiscussionHistoryPresentationState()
        let scope = DiscussionHistoryScope(fileURL: nil, isCurrent: { true }, imageFailed: { _ in }, openFile: { _ in }, presentationState: state)
        let coordinator = DiscussionHistoryCoordinator(scope: scope), web = coordinator.makeWebView()
        defer { coordinator.invalidate() }
        try mount(web)
        coordinator.update(html: disclosureHTML(), fontSize: 16, imageGeneration: 0)
        try await waitForNavigation(web)
        let ready = await poll { try await web.evaluateJavaScript("!!document.querySelector('[data-message-id=older] button')") as? Bool == true }
        XCTAssertTrue(ready); guard ready else { return }
        _ = try await web.evaluateJavaScript("document.querySelector('[data-message-id=older] button').click()")
        try await reveal("tail-anchor", in: web)
        _ = try await web.evaluateJavaScript("document.querySelector('[data-message-id=older] button').click()")
        try await present(web)
        let collapsedAnchor = try await web.evaluateJavaScript("document.getElementById('tail-anchor').getBoundingClientRect().top") as? Double
        XCTAssertEqual(collapsedAnchor ?? 0, 24, accuracy: 2, "Collapsing an earlier body keeps the paragraph being read in place")
        if abs((collapsedAnchor ?? 0) - 24) > 2 { await recordDisclosureFailure(web, phase: "collapsed") }
        _ = try await web.evaluateJavaScript("document.querySelector('[data-message-id=older] button').click()")
        try await present(web)
        let expandedAnchor = try await web.evaluateJavaScript("document.getElementById('tail-anchor').getBoundingClientRect().top") as? Double
        XCTAssertEqual(expandedAnchor ?? 0, 24, accuracy: 2, "Expanding inline preserves the shared history scroll anchor")
        let captured = try await web.callAsyncJavaScript("""
        const saved=window.marginedHistoryDisclosure.capture();
        const rect=id=>{const r=document.getElementById(id).getBoundingClientRect();return {top:r.top,bottom:r.bottom}};
        return {id:saved.candidates?.[0]?.id,top:saved.top,anchor:rect('tail-anchor'),previous:rect('tail-29')};
        """, arguments: [:], in: nil, contentWorld: .world(name: "MarginedDiscussionHistory")) as? [String: Any]
        print("DISCLOSURE-ANCHOR-CAPTURE \(String(describing: captured))")
        XCTAssertEqual(captured?["id"] as? String, "tail-anchor", "The fixture must identify the paragraph whose position it asserts")
        _ = try await web.evaluateJavaScript("window.disclosureDocument=document;true")
        coordinator.update(html: disclosureHTML().replacingOccurrences(of: "Latest text", with: "Updated latest text"), fontSize: 18, imageGeneration: 0)
        let retained = await poll {
            try await self.present(web)
            return try await web.evaluateJavaScript("window.disclosureDocument===document && document.body.textContent.includes('Updated latest text') && document.body.style.fontSize==='18px' && document.querySelector('[data-message-id=older] button')?.getAttribute('aria-expanded')==='true' && Math.abs(document.getElementById('tail-anchor').getBoundingClientRect().top-24)<2") as? Bool == true
        }
        XCTAssertTrue(retained, "Reconciliation retains stable message disclosure and semantic scroll position")
        if !retained { await recordDisclosureFailure(web, phase: "reconciled") }
        let lease = Mirror(reflecting: coordinator).children.filter { ["ready", "generation", "presentationRestore", "navigation"].contains($0.label ?? "") }.map { "\($0.label ?? "")=\($0.value)" }.joined(separator: ", ")
        coordinator.invalidate()
        let cached = await state.restorePosition()
        XCTAssertEqual((cached?["disclosure"] as? [String: Bool])?["older"], true, "Outgoing history must capture its expansion map; \(lease); cached=\(String(describing: cached))")
        let successor = DiscussionHistoryCoordinator(scope: scope), restored = successor.makeWebView()
        defer { successor.invalidate() }
        try mount(restored)
        successor.update(html: disclosureHTML(), fontSize: 16, imageGeneration: 0)
        try await waitForNavigation(restored)
        let restoredExpansion = await poll {
            try await restored.evaluateJavaScript("document.querySelector('[data-message-id=older] button')?.getAttribute('aria-expanded')==='true'") as? Bool == true
        }
        XCTAssertTrue(restoredExpansion, "Hide/show must preserve the session's expanded messages")
    }

    func testAppendedReplyKeepsThePreviouslyLatestMessageVisibleAndImmediateHideCapturesDisclosure() async throws {
        let state = DiscussionHistoryPresentationState()
        let scope = DiscussionHistoryScope(fileURL: nil, isCurrent: { true }, imageFailed: { _ in }, openFile: { _ in }, presentationState: state)
        let coordinator = DiscussionHistoryCoordinator(scope: scope), web = coordinator.makeWebView()
        defer { coordinator.invalidate() }
        try mount(web)
        let first = disclosureHTML()
        coordinator.update(html: first, fontSize: 16, imageGeneration: 0)
        try await waitForNavigation(web)
        let ready = await poll { try await web.evaluateJavaScript("!!document.querySelector('[data-message-id=older] button')") as? Bool == true }
        XCTAssertTrue(ready); guard ready else { return }
        _ = try await web.evaluateJavaScript("document.querySelector('[data-message-id=older] button').click();window.appendHistoryDocument=document;true")
        let latest = first.replacingOccurrences(of: "</main>", with: "<article id='appended' data-message-id='appended'><div class='discussion-message-body'>New saved reply.</div></article></main>")
        coordinator.update(html: latest, fontSize: 16, imageGeneration: 0)
        let reconciled = await poll {
            try await web.evaluateJavaScript("window.appendHistoryDocument===document && !!document.getElementById('appended')") as? Bool == true
        }
        XCTAssertTrue(reconciled)
        let visible = try await web.evaluateJavaScript("document.querySelector('[data-message-id=latest] .discussion-message-body').style.maxHeight===''") as? Bool
        XCTAssertEqual(visible, true, "A new reply must not collapse the latest message the reader already had expanded")
        let lease = Mirror(reflecting: coordinator).children.filter { ["ready", "generation", "presentationRestore", "navigation"].contains($0.label ?? "") }.map { "\($0.label ?? "")=\($0.value)" }.joined(separator: ", ")
        coordinator.invalidate()
        let cached = await state.restorePosition()
        XCTAssertEqual((cached?["disclosure"] as? [String: Bool])?["older"], true, "Immediate reconciled hide must capture expansion; \(lease); cached=\(String(describing: cached))")
    }

    func testRealSingleParagraphDisclosureShowsCompleteLinesAndAnUnobstructedEnding() async throws {
        let body = (0..<16).map { "Saved line \($0) has **formatted** text." }.joined(separator: "  \n") +
            "  \n[Final saved link " + String(repeating: "with a readable ending ", count: 15) + "](https://example.invalid/ending)"
        try await verifyRealMarkdownDisclosure(body, paragraphs: 1)
    }

    func testRealMultipleParagraphDisclosureShowsCompleteLinesAndAnUnobstructedEnding() async throws {
        let body = (0..<10).map { "Paragraph \($0) has **formatted** text.  \nIts second line has *inline emphasis*." }.joined(separator: "\n\n") +
            "\n\n[Final saved link " + String(repeating: "with a readable ending ", count: 15) + "](https://example.invalid/ending)"
        try await verifyRealMarkdownDisclosure(body, paragraphs: 11)
    }

    private func verifyRealMarkdownDisclosure(_ body: String, paragraphs: Int) async throws {
        let thread = DiscussionThread(id: "t-real-preview", state: .open,
            target: .init(type: "TextQuoteSelector", exact: "A saved passage.", prefix: "", suffix: "", section: nil),
            messages: [.init(id: "m-real-older", author: "Earlier author", created: "2026-10-30T10:00:00Z", body: body, inReplyTo: nil),
                       .init(id: "m-real-latest", author: "Latest author", created: "2026-10-30T11:00:00Z", body: "Latest saved reply.", inReplyTo: "m-real-older")],
            resolvedBy: nil, resolved: nil, attachmentHistory: [])
        let rendered = try await MarkdownRenderer.shared.renderDiscussion(thread, prepareSpeech: true, includeContext: false)
        XCTAssertTrue(rendered.speech?.segments.map(\.text).joined(separator: " ").contains("Final saved link") == true)
        let scope = DiscussionHistoryScope(fileURL: nil, isCurrent: { true }, imageFailed: { _ in }, openFile: { _ in })
        let coordinator = DiscussionHistoryCoordinator(scope: scope), web = coordinator.makeWebView()
        defer { coordinator.invalidate() }
        try mount(web)
        coordinator.update(html: rendered.html, fontSize: 16, imageGeneration: 0)
        try await waitForNavigation(web)
        let ready = await poll {
            try await web.evaluateJavaScript("document.querySelector('[data-message-id=m-real-older] button')?.getAttribute('aria-expanded')==='false'") as? Bool == true
        }
        XCTAssertTrue(ready); guard ready else { return }
        for lines in [4, 3] {
            if lines == 3 {
                let previous = try await web.evaluateJavaScript("document.querySelector('[data-message-id=m-real-older] .discussion-message-body').style.maxHeight") as? String
                coordinator.update(html: rendered.html, fontSize: 16, imageGeneration: 0, previewLines: lines)
                let changed = await poll {
                    try await web.evaluateJavaScript("document.querySelector('[data-message-id=m-real-older] .discussion-message-body').style.maxHeight") as? String != previous
                }
                XCTAssertTrue(changed, "Commit the actual short-typing configuration before measuring it")
            }
            let metrics = try await realMarkdownGeometry(in: web)
            XCTAssertEqual(metrics["paragraphCount"] as? Int, paragraphs, "Measure the actual intended single-/multi-paragraph renderer output")
            XCTAssertGreaterThan(metrics["paragraphMargin"] as? Double ?? 0, 0, "Use the production reader.css paragraph margins")
            XCTAssertGreaterThan(metrics["totalLines"] as? Int ?? 0, 8, "The real rendered saved comment must require disclosure")
            XCTAssertEqual(metrics["completeLines"] as? Int, lines, "Preview must show \(lines) complete rendered text lines: \(metrics)")
            XCTAssertEqual(metrics["partialLines"] as? Int, 0, "No next text line may be partially clipped: \(metrics)")
            XCTAssertEqual(metrics["controlOverlapsBody"] as? Bool, false, "The compact control reserves its own layout space: \(metrics)")
            XCTAssertEqual(metrics["controlObstructsVisibleText"] as? Bool, false)
            #if os(iOS)
            XCTAssertGreaterThanOrEqual(metrics["controlWidth"] as? Double ?? 0, 44)
            XCTAssertGreaterThanOrEqual(metrics["controlHeight"] as? Double ?? 0, 44)
            #else
            XCTAssertGreaterThanOrEqual(metrics["controlWidth"] as? Double ?? 0, 24)
            XCTAssertGreaterThanOrEqual(metrics["controlHeight"] as? Double ?? 0, 24)
            #endif
        }
        _ = try await web.evaluateJavaScript("document.querySelector('[data-message-id=m-real-older] button').click()")
        let expanded = try await realMarkdownGeometry(in: web)
        XCTAssertEqual(expanded["expanded"] as? String, "true")
        XCTAssertEqual(expanded["controlOverlapsBody"] as? Bool, false, "Show less must not cover the fully expanded ending: \(expanded)")
        XCTAssertEqual(expanded["controlObstructsVisibleText"] as? Bool, false)
        XCTAssertEqual(expanded["completeLines"] as? Int, expanded["totalLines"] as? Int)
        _ = try await web.callAsyncJavaScript("""
        document.querySelector('[data-message-id=m-real-older] .discussion-message-body a').scrollIntoView({block:'end',behavior:'instant'});
        await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
        return true;
        """, arguments: [:], in: nil, contentWorld: .world(name: "MarginedDiscussionHistory"))
        let ending = try await realMarkdownGeometry(in: web)
        XCTAssertGreaterThan(ending["visibleEndingRects"] as? Int ?? 0, 0, "The actual trailing link must be visible for native hit testing")
        XCTAssertEqual(ending["endingHitsLink"] as? Bool, true, "The visible ending must hit its link rather than the disclosure: \(ending)")
        XCTAssertEqual(thread.messages.first?.body, body)
    }

    private func realMarkdownGeometry(in web: WKWebView) async throws -> [String: Any] {
        let value = try await web.callAsyncJavaScript("""
        const article=document.querySelector('[data-message-id=m-real-older]'),body=article.querySelector('.discussion-message-body'),button=article.querySelector('button[data-history-disclosure]');
        const clip=body.getBoundingClientRect(),control=button.getBoundingClientRect();
        const rects=[],walker=document.createTreeWalker(body,NodeFilter.SHOW_TEXT);
        while(walker.nextNode()){
            const node=walker.currentNode;if(!node.textContent.trim())continue;
            const range=document.createRange();range.selectNodeContents(node);
            rects.push(...Array.from(range.getClientRects()).filter(r=>r.width>0&&r.height>0));
        }
        const bands=[];
        for(const rect of rects.slice().sort((a,b)=>a.top-b.top||a.bottom-b.bottom)){
            const last=bands.at(-1);
            if(last&&rect.top<last.bottom-1){last.top=Math.min(last.top,rect.top);last.bottom=Math.max(last.bottom,rect.bottom)}
            else bands.push({top:rect.top,bottom:rect.bottom});
        }
        const intersects=(a,b)=>a.right>b.left&&a.left<b.right&&a.bottom>b.top&&a.top<b.bottom;
        const visible=bands.filter(r=>r.bottom>clip.top+0.5&&r.top<clip.bottom-0.5);
        const complete=visible.filter(r=>r.top>=clip.top-0.5&&r.bottom<=clip.bottom+0.5);
        const ending=body.querySelector('a'),endingRects=[];
        const endingRange=document.createRange();endingRange.selectNodeContents(ending);
        for(const rect of endingRange.getClientRects())if(rect.width>0&&rect.height>0&&rect.top>=0&&rect.bottom<=innerHeight)endingRects.push(rect);
        return {paragraphCount:body.querySelectorAll('p').length,paragraphMargin:parseFloat(getComputedStyle(body.querySelector('p')).marginTop),totalLines:bands.length,
            completeLines:complete.length,partialLines:visible.length-complete.length,controlOverlapsBody:intersects(control,clip),
            controlObstructsVisibleText:rects.some(r=>intersects(r,clip)&&intersects(r,control)),
            controlWidth:control.width,controlHeight:control.height,expanded:button.getAttribute('aria-expanded'),
            visibleEndingRects:endingRects.length,endingHitsLink:endingRects.every(r=>document.elementFromPoint((r.left+r.right)/2,(r.top+r.bottom)/2)?.closest('a')===ending)};
        """, arguments: [:], in: nil, contentWorld: .world(name: "MarginedDiscussionHistory"))
        return try XCTUnwrap(value as? [String: Any])
    }

    private func disclosureHTML() -> String {
        let long = (0..<16).map { "Saved line \($0).<br>" }.joined() + "Tail preserved <a id='hidden-link' href='#latest'>Offscreen saved link</a>"
        return "<html><head><meta name='viewport' content='width=device-width, initial-scale=1'><style>html{overflow-anchor:none}body{margin:0;font-size:16px;line-height:24px}main{padding:16px}article{margin-bottom:24px}#tail-anchor{margin-top:32px}.discussion-message-body{line-height:24px}</style></head><body><main id='document'><article id='older' data-message-id='older'><header>Earlier author</header><div class='discussion-message-body' data-margined-speech='saved-body'>" + long + "</div></article><article id='boundary' data-message-id='boundary'><div class='discussion-message-body'>One<br>Two<br>Three<br>Four<br>Five<br>Six<br>Seven<br>Eight</div></article><article id='latest' data-message-id='latest'><header>Latest author</header><div class='discussion-message-body'><a href='#older'>Earlier comment</a><p>Latest text</p>" + long + "</div></article>" + (0..<30).map { "<p id='tail-\($0)'>Following paragraph \($0).</p>" }.joined() + "<p id='tail-anchor'>Retained reading anchor.</p><div style='height:800px'></div></main></body></html>"
    }

    private func recordDisclosureFailure(_ web: WKWebView, phase: String) async {
        func native() -> [String: String] {
            var value = ["bounds": String(describing: web.bounds)]
            #if os(iOS)
            value["offset"] = String(describing: web.scrollView.contentOffset)
            value["contentSize"] = String(describing: web.scrollView.contentSize)
            value["adjustedInset"] = String(describing: web.scrollView.adjustedContentInset)
            value["presentationOrigin"] = String(describing: web.scrollView.layer.presentation()?.bounds.origin)
            #endif
            return value
        }
        let before = native()
        do {
            let configuration = WKSnapshotConfiguration(); configuration.afterScreenUpdates = true
            let image = try await web.takeSnapshot(configuration: configuration)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Disclosure \(phase) after screen updates"; attachment.lifetime = .keepAlways
            add(attachment)
        } catch { print("DISCLOSURE-SNAPSHOT-ERROR phase=\(phase) code=\((error as NSError).code)") }
        let after = native()
        let dom = try? await web.callAsyncJavaScript("""
        const target=document.getElementById('tail-anchor');
        return JSON.stringify({sameDocument:window.disclosureDocument===document,
            updatedText:document.body.textContent.includes('Updated latest text'),font:document.body.style.fontSize,
            expanded:document.querySelector('[data-message-id=older] button')?.getAttribute('aria-expanded'),
            anchor:target?.getBoundingClientRect().top,anchorDocumentTop:target?.getBoundingClientRect().top+scrollY,y:scrollY,width:innerWidth,height:innerHeight,
            scrollHeight:document.documentElement.scrollHeight,
            visual:visualViewport?{top:visualViewport.offsetTop,pageTop:visualViewport.pageTop,height:visualViewport.height,scale:visualViewport.scale}:null,
            hit24:document.elementFromPoint(document.documentElement.clientWidth/2,24)?.closest('p')?.id,
            olderHeight:document.getElementById('older')?.getBoundingClientRect().height});
        """, arguments: [:], in: nil, contentWorld: .page)
        print("DISCLOSURE-PRESENTATION phase=\(phase) before=\(before) after=\(after) dom=\(String(describing: dom))")
    }

    private func layoutViewportWidth(_ web: WKWebView) -> CGFloat {
        #if os(iOS)
        // The public native safe-area insets predict CSS layout independently;
        // Duo's sidebar can consume part of the requested native window width.
        return web.scrollView.bounds.width - web.scrollView.adjustedContentInset.left - web.scrollView.adjustedContentInset.right
        #else
        return web.bounds.width
        #endif
    }

    private func recordDuoHistoryGeometry(_ web: WKWebView, coordinator: DiscussionHistoryCoordinator, phase: String, navigations: Int) async throws {
        #if os(iOS)
        let window = try XCTUnwrap(web.window), screen = window.screen
        var data: [String: Any] = ["phase":phase,"navigationCompletions":navigations,
            "windowFrame":String(describing:window.frame),"windowBounds":String(describing:window.bounds),"windowTransform":String(describing:window.transform),
            "windowSafe":String(describing:window.safeAreaInsets),"key":window.isKeyWindow,
            "sceneBounds":String(describing:window.windowScene?.coordinateSpace.bounds),"orientation":window.windowScene?.interfaceOrientation.rawValue ?? -1,
            "screenBounds":String(describing:screen.bounds),"screenCoordinate":String(describing:screen.coordinateSpace.bounds),"screenFixed":String(describing:screen.fixedCoordinateSpace.bounds),
            "webFrame":String(describing:web.frame),"webBounds":String(describing:web.bounds),"webSafe":String(describing:web.safeAreaInsets),
            "scrollFrame":String(describing:web.scrollView.frame),"scrollBounds":String(describing:web.scrollView.bounds),"scrollInset":String(describing:web.scrollView.contentInset),
            "scrollAdjusted":String(describing:web.scrollView.adjustedContentInset),"scrollOffset":String(describing:web.scrollView.contentOffset),"scrollContent":String(describing:web.scrollView.contentSize),
            "scrollZoom":web.scrollView.zoomScale,"pageZoom":web.pageZoom]
        data["pageIdentity"] = try await web.evaluateJavaScript("window.resizingHistoryDocument===document")
        data["coordinator"] = Mirror(reflecting:coordinator).children.filter{["ready","generation","reconciliationGeneration","presentationRestore","token"].contains($0.label ?? "")}.map{"\($0.label ?? "")=\($0.value)"}.joined(separator:",")
        data["dom"] = try await web.callAsyncJavaScript("""
        const rect=id=>{const r=document.getElementById(id)?.getBoundingClientRect();return r?{top:r.top,bottom:r.bottom,width:r.width,height:r.height}:null};
        return {innerWidth,innerHeight,x:scrollX,y:scrollY,clientWidth:document.documentElement.clientWidth,clientHeight:document.documentElement.clientHeight,
            visual:visualViewport?{width:visualViewport.width,height:visualViewport.height,scale:visualViewport.scale,top:visualViewport.offsetTop}:null,
            main:rect('document'),p22:rect('history-p22'),p32:rect('history-p32'),font:document.body.style.fontSize,
            token:document.documentElement.getAttribute('data-margined-history-token'),observing:typeof window.marginedReadingResize?.stop==='function',
            hit24:document.elementFromPoint(document.documentElement.clientWidth/2,24)?.closest('p')?.id??null};
        """, arguments:[:],in:nil,contentWorld:.world(name:"MarginedDiscussionHistory"))
        let encoded=try JSONSerialization.data(withJSONObject:data,options:[.sortedKeys]);print("DUO-HISTORY "+String(decoding:encoded,as:UTF8.self))
        #endif
    }

    private func historyHTML() -> String {
        let paragraphs = (0..<50).map { index in
            "<p id='history-p\(index)'>History paragraph \(index). " + String(repeating: "A retained conversation keeps the actual passage readable while its viewport reflows. ", count: 5) + "</p>"
        }.joined()
        return "<html><head><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><style>html{overflow-anchor:none}body{margin:0;font-size:16px;line-height:1.5}main{padding:16px}p{margin:0 0 20px}</style></head><body><main id='document'>" + paragraphs + "</main></body></html>"
    }
    private func reveal(_ id: String, in web: WKWebView) async throws {
        _ = try await web.callAsyncJavaScript("""
        await document.fonts.ready;
        const paragraph=document.getElementById(id);
        scrollTo({top:scrollY+paragraph.getBoundingClientRect().top-24,behavior:'instant'});
        await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
        return true;
        """, arguments: ["id": id], in: nil, contentWorld: .world(name: "MarginedDiscussionHistory"))
        try await present(web)
    }

    // A completed JavaScript call/rAF can precede iOS's native scroll commit.
    // Establish the painted passage before measuring it or hiding the page.
    private func present(_ web: WKWebView) async throws {
        let configuration = WKSnapshotConfiguration(); configuration.afterScreenUpdates = true
        let image = try await web.takeSnapshot(configuration: configuration)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }
    private func resize(_ web: WKWebView, to size: CGSize) {
        #if os(iOS)
        web.window?.frame.size = size
        web.window?.rootViewController?.view.frame = CGRect(origin: .zero, size: size)
        web.window?.rootViewController?.view.layoutIfNeeded()
        #else
        web.window?.setContentSize(size)
        web.frame.size = size; web.layoutSubtreeIfNeeded()
        #endif
    }
    private func poll(_ predicate: () async throws -> Bool) async -> Bool {
        for _ in 0..<150 {
            if (try? await predicate()) == true { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func waitForNavigation(_ web: WKWebView) async throws {
        let committed = await WebKitTestReadiness.navigation { web }
        XCTAssertNotNil(committed, "Finish native history navigation before inspecting its content or restore")
        guard committed != nil else { throw URLError(.timedOut) }
    }

    private func mount(_ web: WKWebView) throws {
        web.frame = CGRect(x: 0, y: 0, width: 360, height: 400)
        #if os(iOS)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = UIViewController(); controller.view = web
        let window = UIWindow(windowScene: scene); window.frame = web.frame
        window.rootViewController = controller; window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true; window.rootViewController = nil }
        #else
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = web; window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
        #endif
    }

    private func contains(_ text: String, in web: WKWebView) async -> Bool {
        for _ in 0..<150 {
            if !web.isLoading, (try? await web.evaluateJavaScript("document.querySelector('main')?.textContent")) as? String != nil,
               let body = try? await web.evaluateJavaScript("document.body.textContent") as? String, body.contains(text) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

@MainActor
private final class HistoryCaptureGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor
private final class HistoryNavigationProbe: NSObject, WKNavigationDelegate {
    let coordinator: DiscussionHistoryCoordinator
    private(set) var completions = 0
    init(coordinator: DiscussionHistoryCoordinator) { self.coordinator = coordinator }
    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        coordinator.webView(view, didFinish: navigation)
        completions += 1
    }
    func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        await coordinator.webView(view, decidePolicyFor: action)
    }
}

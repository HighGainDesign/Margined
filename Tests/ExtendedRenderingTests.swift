import SwiftSoup
import WebKit
import XCTest
@testable import Margined

final class ExtendedRenderingTests: XCTestCase {
    func testAllFiveGitHubAlertsKeepTypeAndNestedContent() async throws {
        for type in ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"] {
            let result = try await MarkdownRenderer.shared.render("> [!\(type)]\n> Keep **this** and [the link](https://example.com).\n>\n> - Nested list")
            let body = try SwiftSoup.parse(result.html)
            let alert = try XCTUnwrap(body.select("blockquote.margined-alert-\(type.lowercased())").first())
            XCTAssertFalse(try alert.text().contains("[!"))
            XCTAssertEqual(try alert.select("strong").text(), "this")
            XCTAssertEqual(try alert.select("li").text(), "Nested list")
            XCTAssertEqual(try alert.select("a[href=https://example.com]").size(), 1)
            XCTAssertNotEqual(try alert.attr("role"), "alert")
        }
    }

    func testMathFormsBecomeStaticMathMLAndCodeCurrencyStayLiteral() async throws {
        let result = try await MarkdownRenderer.shared.render(#"""
        Inline $x^2$ and $2+2$ and $`\sqrt{a_b}`$.

        $$\frac{1}{2} < x$$

        ```math
        \sum_{i=1}^n i
        ```

        `literal $a$` and \$escaped and prices $5 and $10.

        ```swift
        let price = "$x$"
        ```
        """#)
        let doc = try SwiftSoup.parse(result.html)
        XCTAssertEqual(try doc.select("math").size(), 5)
        XCTAssertTrue(try doc.select("math[display=block]").size() >= 2)
        XCTAssertTrue(try doc.select("mfrac").size() > 0)
        XCTAssertTrue(try doc.text().contains("literal $a$"))
        XCTAssertTrue(try doc.text().contains("prices $5 and $10"))
        XCTAssertTrue(try doc.select("pre code.language-swift").text().contains("$x$"))
        XCTAssertEqual(try doc.select("script, iframe, math a, math img").size(), 0)
    }

    func testDisplayMathAcrossBlankLinesAndReviewTargetsSurviveArtwork() async throws {
        let math = try await MarkdownRenderer.shared.render("$$\nx + y\n\n+ z\n$$\n\nAfter display")
        let mathDoc = try SwiftSoup.parse(math.html)
        XCTAssertEqual(try mathDoc.select("math[display=block]").size(), 1)
        XCTAssertTrue(try mathDoc.text().contains("After display"))
        let old = "```mermaid\nflowchart LR\nA-->B\n```"
        let result = try await MarkdownRenderer.shared.render(old.replacingOccurrences(of: "A-->B", with: "A-->C"), baseline: old, prepareSpeech: true)
        let doc = try SwiftSoup.parse(result.html)
        for change in result.changes.navigable {
            XCTAssertEqual(try doc.select("[id=\(try XCTUnwrap(change.targetID))]").size(), 1)
        }
        for segment in try XCTUnwrap(result.speech).segments {
            XCTAssertEqual(try doc.select("[data-margined-speech=\(segment.elementID)]").size(), 1)
        }
    }

    func testInvalidMathAndDiagramsStayReadableWithoutFailingDocument() async throws {
        let result = try await MarkdownRenderer.shared.render(#"""
        Before $\notARealCommand{1}$ after.

        ```mermaid
        this is not a diagram
        ```

        Last paragraph.
        """#)
        let doc = try SwiftSoup.parse(result.html)
        XCTAssertTrue(try doc.text().contains("notARealCommand"))
        XCTAssertTrue(try doc.text().contains("this is not a diagram"))
        XCTAssertTrue(try doc.text().contains("Last paragraph."))
    }

    func testMermaidRendersOfflineStaticImagesWithAccessibleDescription() async throws {
        let source = """
        ```mermaid
        flowchart LR
          accTitle: Build pipeline
          accDescr: Source is tested before release.
          A[Source] --> B[Tests] --> C[Release]
        ```
        """
        let result = try await MarkdownRenderer.shared.render(source)
        let doc = try SwiftSoup.parse(result.html)
        let image = try XCTUnwrap(doc.select("figure.margined-diagram img").first())
        XCTAssertTrue(try image.attr("src").hasPrefix("data:image/svg+xml;base64,"))
        XCTAssertTrue(try image.attr("alt").contains("Build pipeline"))
        let svgData = try XCTUnwrap(Data(base64Encoded: try image.attr("src").components(separatedBy: ",").last!))
        let svg = String(decoding: svgData, as: UTF8.self)
        XCTAssertTrue(svg.contains("#ECECFF") || svg.contains("rgb(236, 236, 255)"), "Static diagrams retain the node palette")
        XCTAssertFalse(svg.contains("@keyframes"))
        XCTAssertTrue(svg.contains("role=\"img\""))
        XCTAssertTrue(try doc.text().contains("A[Source]"))
        XCTAssertEqual(try doc.select("script, iframe").size(), 0)
        XCTAssertTrue(result.html.contains("default-src 'none'"))
    }

    func testUnmatchedCurrencyDollarsHaveBoundedParsingWork() async throws {
        let source = String(repeating: "$1", count: 50_000)
        let start = ContinuousClock.now
        let result = try await MarkdownRenderer.shared.render(source)
        XCTAssertLessThan(start.duration(to: .now), .seconds(5))
        XCTAssertEqual(try SwiftSoup.parse(result.html).select("math").size(), 0)
        XCTAssertTrue(result.html.contains(source))
    }

    func testRepresentativeDocumentLatencyAndArtworkBudgets() async throws {
        let prose = (0..<2_000).map { "Paragraph \($0). Read and review a large document with ordinary Markdown.\n\n" }.joined()
        let start = ContinuousClock.now
        let ordinary = try await MarkdownRenderer.shared.render(prose)
        let ordinaryTime = start.duration(to: .now)
        XCTAssertTrue(ordinary.html.contains("Paragraph 1999"))
        let math = (0..<201).map { "$x_{\($0)}$" }.joined(separator: " ")
        let diagrams = String(repeating: "```mermaid\nflowchart LR\nA[Budget]-->B[Ready]\n```\n\n", count: 21)
        let diagramStart = ContinuousClock.now
        let artwork = try await MarkdownRenderer.shared.render(math + "\n\n" + diagrams)
        let doc = try SwiftSoup.parse(artwork.html)
        XCTAssertEqual(try doc.select("math").size(), 200)
        XCTAssertEqual(try doc.select("figure.margined-diagram > img").size(), 20)
        XCTAssertEqual(try doc.select("figure.margined-diagram > pre").size(), 1)
        XCTAssertTrue(try doc.text().contains("x_{200}"))
        let evidence = XCTAttachment(string: "Ordinary 2,000 paragraphs: \(ordinaryTime). Artwork 201 equations/21 diagrams: \(diagramStart.duration(to: .now)).")
        evidence.name = "Representative rendering latency"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testCancelledDiagramWorkReleasesCapacityForLatestDocument() async throws {
        let renderer = DiagramRenderer()
        let graph = "flowchart LR\n" + (0..<150).map { "A\($0)-->A\($0 + 1)" }.joined(separator: "\n")
        let obsolete = (0..<2).map { index in
            Task { await renderer.render(graph + "\n%% obsolete \(index)") }
        }
        try await Task.sleep(for: .milliseconds(30))
        for task in obsolete { task.cancel() }
        for task in obsolete { let result = await task.value; XCTAssertNil(result) }
        let latest = await renderer.render("flowchart LR\nA[Latest]-->B[Ready]")
        XCTAssertNotNil(latest)
    }

    func testMermaidClassNamesPreserveSafePalette() async throws {
        let source = "flowchart LR\nA:::curl --> B:::expression\nclassDef curl fill:#ff0000\nclassDef expression fill:#00ff00"
        let result = try await MarkdownRenderer.shared.render("```mermaid\n" + source + "\n```")
        let image = try XCTUnwrap(SwiftSoup.parse(result.html).select("figure.margined-diagram img").first())
        let svg = String(decoding: try XCTUnwrap(Data(base64Encoded: try image.attr("src").components(separatedBy: ",").last!)), as: UTF8.self)
        XCTAssertTrue(svg.contains(".curl"))
        XCTAssertTrue(svg.contains(".expression"))
        XCTAssertTrue(svg.contains("#ECECFF") || svg.contains("rgb(236, 236, 255)"))
    }

    func testCommonMermaidDiagramTypesRender() async throws {
        let sources = [
            "sequenceDiagram\nAlice->>Bob: Hello",
            "classDiagram\nAnimal <|-- Duck",
            "stateDiagram-v2\n[*] --> Ready\nReady --> [*]",
            "erDiagram\nCUSTOMER ||--o{ ORDER : places",
            "pie title Languages\n\"Swift\" : 80\n\"Other\" : 20",
            "gantt\ndateFormat YYYY-MM-DD\nsection Work\nTask :2026-10-22, 1d"
        ]
        for source in sources {
            let result = try await MarkdownRenderer.shared.render("```mermaid\n" + source + "\n```")
            XCTAssertEqual(try SwiftSoup.parse(result.html).select("figure.margined-diagram > img").size(), 1, source)
        }
    }

    func testUntrustedMathAndMermaidCannotAddActiveContent() async throws {
        let result = try await MarkdownRenderer.shared.render(#"""
        $x <img src="https://tracker.example/x" onerror="alert(1)"> + 1$

        $\htmlClass{evil}{x}$

        ```mermaid
        %%{init: {"securityLevel":"loose","htmlLabels":true,"themeCSS":"@import url(https://tracker.example/style);"}}%%
        flowchart LR
          A["<img src='https://tracker.example/x' onerror='alert(1)'>"] --> B[Safe]
          click B "javascript:alert(1)"
        ```
        """#)
        let doc = try SwiftSoup.parse(result.html)
        XCTAssertEqual(try doc.select("script, iframe, [onerror], img[src^=https]").size(), 0)
        if let image = try doc.select("figure.margined-diagram img").first() {
            let encoded = try image.attr("src").split(separator: ",", maxSplits: 1).last.map(String.init) ?? ""
            let data = try XCTUnwrap(Data(base64Encoded: encoded))
            let svg = try SwiftSoup.parse(String(decoding: data, as: UTF8.self), "", Parser.xmlParser())
            XCTAssertEqual(try svg.select("script, foreignObject, image, a, [onload], [onerror], [href]").size(), 0)
            XCTAssertFalse(try svg.select("style").html().contains("tracker.example"))
        }
        let large = try await MarkdownRenderer.shared.render("```mermaid\n" + String(repeating: "A-->B\n", count: 4_000) + "```")
        let fallback = try SwiftSoup.parse(large.html)
        XCTAssertEqual(try fallback.select("figure.margined-diagram > img").size(), 0)
        XCTAssertTrue(try fallback.select("code.language-mermaid").text().contains("A-->B"))
    }

    @MainActor
    func testStaticMathAndSVGDisplayWithDocumentScriptsDisabled() async throws {
        let result = try await MarkdownRenderer.shared.render("Fraction $\\frac{1}{2}$.\n\n```mermaid\nflowchart LR\nA[Start]-->B[Finish]\n```")
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        web.loadHTMLString(result.html, baseURL: nil)
        var ready = false
        for _ in 0..<200 {
            ready = (try? await web.evaluateJavaScript("document.querySelector('math mfrac')?.getBoundingClientRect().height > 12 && document.querySelector('figure img')?.naturalWidth > 10")) as? Bool == true
            if ready { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(ready, "Static artifacts must work in the reader and data-based Quick Look")
    }

    @MainActor
    func testReadAloudSelectionAfterMathUsesOriginalSourceOffsets() async throws {
        let result = try await MarkdownRenderer.shared.render("Read $\\frac{x}{2}$ then ending.", prepareSpeech: true)
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        web.loadHTMLString(result.html, baseURL: nil)
        for _ in 0..<200 {
            if !web.isLoading, (try? await web.evaluateJavaScript("!!document.querySelector('math')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        _ = try await web.evaluateJavaScript("""
        (() => {
          const p = document.querySelector('p');
          const node = p.lastChild;
          const range = document.createRange();
          range.setStart(node, node.data.indexOf('ending.')); range.setEnd(node, node.data.length);
          getSelection().removeAllRanges(); getSelection().addRange(range);
          return true;
        })()
        """)
        let url = try XCTUnwrap(Bundle(for: MarkdownDocument.self).url(forResource: "reader-speech", withExtension: "js"))
        let script = try String(contentsOf: url, encoding: .utf8)
        let value = try await web.callAsyncJavaScript(script, arguments: ["operation":"locate", "mode":"selection"], in: nil, contentWorld: .world(name:"MathSelectionTest")) as? [String:Any]
        let speech = try XCTUnwrap(result.speech)
        let position = try XCTUnwrap(speech.position(elementID: try XCTUnwrap(value?["elementID"] as? String), sourceOffset: try XCTUnwrap(value?["offset"] as? Int)))
        XCTAssertEqual((speech.segments[position.index].text as NSString).substring(from: position.offset), "ending.")
    }

    func testMathPreservesCommentsBlockReviewSpeechAndTaskProvenance() async throws {
        let original = "$$\nx % comment\n+y\n$$"
        let result = try await MarkdownRenderer.shared.render(original, prepareSpeech: true)
        let doc = try SwiftSoup.parse(result.html)
        XCTAssertEqual(try doc.select("math mi").text(), "x y")
        XCTAssertFalse(try XCTUnwrap(result.speech).segments.isEmpty)
        let changed = try await MarkdownRenderer.shared.render(original.replacingOccurrences(of: "+y", with: "+z"), baseline: original)
        XCTAssertEqual(changed.changes.count, 1)
        let source = "- [ ] Solve $x^2$\n- [x] Another task\n\n$$\n- [ ] Not a task\n$$"
        let tasks = try await MarkdownRenderer.shared.render(source, mapTasks: true)
        XCTAssertEqual(tasks.tasks.count, 2)
        if let task = tasks.tasks.first {
            let patched = try MarkdownTasks.patch(Data(source.utf8), expectedSource: source, task: task, checked: true)
            XCTAssertEqual(String(decoding: patched, as: UTF8.self), source.replacingOccurrences(of: "- [ ] Solve", with: "- [x] Solve"))
        }
    }

    func testRenderingDoesNotInventReviewChangesOrLoseMathAndDiagramEdits() async throws {
        let original = "Equation $x^2$.\n\n```mermaid\nflowchart LR\nA-->B\n```"
        let unchanged = try await MarkdownRenderer.shared.render(original, baseline: original, prepareSpeech: true)
        XCTAssertEqual(unchanged.changes.count, 0)
        let edited = try await MarkdownRenderer.shared.render(original.replacingOccurrences(of: "x^2", with: "x^3").replacingOccurrences(of: "A-->B", with: "A-->C"), baseline: original, prepareSpeech: true)
        XCTAssertTrue(edited.changes.entries.contains { $0.before.contains("x^2") && $0.after.contains("x^3") })
        XCTAssertTrue(edited.changes.entries.contains { $0.before.contains("A-->B") && $0.after.contains("A-->C") })
        XCTAssertFalse(edited.speech?.segments.contains { $0.text.contains("<svg") } ?? true)
    }
}

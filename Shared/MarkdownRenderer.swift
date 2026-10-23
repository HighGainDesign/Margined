import ApexC
import CcmarkGFM
import Foundation
import SwiftSoup

struct MarkdownHeading: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let level: Int
}

struct RenderedMarkdown: Sendable {
    let html: String
    let headings: [MarkdownHeading]
    let wordCount: Int
    var changes = ChangeSummary()
    var comparisonBaseline: [ReadingUnit]?
    var tasks: [MarkdownTask] = []
    var taskSource = ""
    var checkboxCount = 0
    var documentLanguage: String? = nil
    var speech: SpeechDocument? = nil
}

/// Serializes native Apex conversions off the UI actor. App and Quick Look use
/// the same options, HTML adaptation, and bundled CSS. No AppKit dependency.
actor MarkdownRenderer {
    static let shared = MarkdownRenderer()
    private var stylesheet: String?
    private let mathTypesetter = MathTypesetter()

    func render(_ source: String, title: String = "Markdown", wide: Bool = false, baseline: String? = nil, reviewedUnits: [ReadingUnit]? = nil, loadRemoteImages: Bool = false, appearance: DocumentAppearance = .system, mapTasks: Bool = false, documentLanguage: String? = nil, prepareSpeech: Bool = false, speechOptions: SpeechOptions = SpeechOptions()) async throws -> RenderedMarkdown {
        try Task.checkCancellation()
        guard source.utf8.count <= MarkdownSource.maximumBytes else { throw ReaderError.tooLarge }
        if stylesheet == nil {
            guard let cssURL = Bundle(for: RendererBundleMarker.self).url(forResource: "reader", withExtension: "css") else {
                throw ReaderError.rendererUnavailable
            }
            stylesheet = try String(contentsOf: cssURL, encoding: .utf8)
        }
        let document = try parse(source, loadRemoteImages: loadRemoteImages)
        let headings = try document.select("h1, h2, h3, h4, h5, h6").array().map { heading in
            MarkdownHeading(id: try heading.attr("id"), title: try heading.text(),
                            level: Int(heading.tagName().dropFirst()) ?? 1)
        }
        let language = DocumentLanguage.resolve(selected: documentLanguage, text: try document.body()?.text() ?? "")
        let speech = prepareSpeech ? try SpeechDocumentBuilder.prepare(document, source: source, language: language, options: speechOptions) : nil
        var changes = ChangeSummary()
        let comparisonBaseline: [ReadingUnit]?
        if let reviewedUnits {
            comparisonBaseline = reviewedUnits
        } else if let baseline {
            comparisonBaseline = try DocumentChanges.snapshot(in: parse(baseline, loadRemoteImages: loadRemoteImages))
        } else {
            comparisonBaseline = nil
        }
        if let comparisonBaseline {
            changes = try DocumentChanges.annotate(current: document, baseline: comparisonBaseline)
        }
        let checkboxCount = try document.select("input[type=checkbox]").size()
        let tasks = mapTasks ? try MarkdownTasks.attach(to: document, source: source) : []
        // Typeset after semantic review/speech, so generated artwork never changes
        // comparison identity or duplicates MathML tokens in Read Aloud.
        for (index, expression) in try document.select("span.margined-math").array().enumerated() {
            let tex = try expression.text(trimAndNormaliseWhitespace: false)
            try expression.attr("data-margined-math-source", tex)
            if index < 200, let math = mathTypesetter.render(tex, display: expression.hasClass("margined-math-display")) {
                try expression.html(math)
            }
        }
        let diagramDeadline = ContinuousClock.now.advanced(by: .seconds(6))
        for (index, figure) in try document.select("figure.margined-diagram").array().enumerated() {
            try Task.checkCancellation()
            guard index < 20, ContinuousClock.now < diagramDeadline, let code = try figure.select("pre > code.language-mermaid").first(),
                  let pre = code.parent(), let artifact = await DiagramRenderer.shared.render(try code.text(trimAndNormaliseWhitespace: false)) else { continue }
            let image = Element(try Tag.valueOf("img"), "")
            try image.attr("src", artifact.image)
            try image.attr("alt", artifact.description)
            try figure.prependChild(image)
            let details = try figure.appendElement("details")
            try details.appendElement("summary").text(String(localized: "Diagram source"))
            try pre.remove()
            try details.appendChild(pre)
        }
        // Serialize the sanitized DOM itself, including newly attached task metadata.
        // Source reuse can retain an input tag without its new attributes.
        let body = String(decoding: try document.body()?.htmlUTF8WithoutSourceReuse() ?? [], as: UTF8.self)
        let count = source.split(whereSeparator: \.isWhitespace).count
        let languageAttribute = language.map { " lang=\"\($0)\"" } ?? ""
        let html = """
        <!doctype html><html\(languageAttribute) data-appearance="\(appearance.rawValue)"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="referrer" content="no-referrer">
        <meta name="color-scheme" content="\(appearance.colorScheme)">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src margined-resource: data:\(loadRemoteImages ? " https:" : ""); base-uri 'none'; form-action 'none'">
        <title>\(Self.escapeHTML(title))</title><style>\(stylesheet ?? "")</style></head>
        <body class="\(wide ? "wide" : "")"><main id="document" dir="auto" aria-label="\(Self.escapeHTML(String(localized: "Markdown document")))">\(body)</main></body></html>
        """
        return RenderedMarkdown(html: html, headings: headings, wordCount: count, changes: changes, comparisonBaseline: comparisonBaseline, tasks: tasks, taskSource: source, checkboxCount: checkboxCount, documentLanguage: language, speech: speech)
    }

    private func parse(_ source: String, loadRemoteImages: Bool) throws -> Document {
        try Task.checkCancellation()
        guard source.utf8.count <= MarkdownSource.maximumBytes else { throw ReaderError.tooLarge }
        var options = apex_options_for_mode(APEX_MODE_UNIFIED)
        // The C API makes false values explicit; the Swift wrapper only forwards
        // Let Apex emit author HTML, then apply our allowlist in HTMLAdapter.
        // This enables GitHub-style passive formatting, never executable content.
        options.unsafe = true
        options.enable_plugins = false
        options.allow_external_plugin_detection = false
        options.enable_file_includes = false
        options.enable_metadata_transforms = false
        options.enable_attributes = false
        options.enable_markdown_in_html = false
        options.enable_smart_typography = false
        options.enable_math = false
        options.enable_citations = false
        // Apex's styled callouts use internal raw HTML, which safe mode omits.
        // Preserve their source as readable blockquotes instead.
        options.enable_callouts = false
        options.embed_images = false
        options.enable_autolink = true
        options.enable_aria = true
        options.id_format = 0
        options.github_pre_lang = false
        options.generate_header_ids = true
        // Normalize parsed image destinations and exclude author-supplied inputs
        // before they can be mistaken for renderer-generated Markdown task controls.
        guard let imageExtension = cmark_syntax_extension_new("margined-local-images") else {
            throw ReaderError.rendererUnavailable
        }
        defer { cmark_syntax_extension_free(cmark_get_default_mem_allocator(), imageExtension) }
        MathSyntax.install(on: imageExtension, sourceBytes: source.utf8.count)
        cmark_syntax_extension_set_postprocess_func(imageExtension) { _, _, root in
            guard let root, let iterator = cmark_iter_new(root) else { return root }
            defer { cmark_iter_free(iterator) }
            while cmark_iter_next(iterator) != CMARK_EVENT_DONE {
                guard cmark_iter_get_event_type(iterator) == CMARK_EVENT_ENTER,
                      let node = cmark_iter_get_node(iterator) else { continue }
                let type = cmark_node_get_type(node)
                if type == CMARK_NODE_CODE_BLOCK,
                   let info = cmark_node_get_fence_info(node), String(cString: info) == "math",
                   let literal = cmark_node_get_literal(node) {
                    let html = MathSyntax.placeholder(String(cString: literal), display: true, block: true)
                    if cmark_node_set_type(node, CMARK_NODE_HTML_BLOCK) != 0 {
                        _ = html.withCString { cmark_node_set_literal(node, $0) }
                    }
                    continue
                }
                if type == CMARK_NODE_HTML_INLINE || type == CMARK_NODE_HTML_BLOCK {
                    if let literal = cmark_node_get_literal(node) {
                        let html = String(cString: literal)
                        if html.range(of: "<input", options: .caseInsensitive) != nil {
                            // Remove controls before task mapping without discarding
                            // surrounding author text, images or passive formatting.
                            let filtered: String
                            do {
                                let fragment = try SwiftSoup.parseBodyFragment(html)
                                fragment.outputSettings().prettyPrint(pretty: false)
                                let controls = try fragment.select("input")
                                if controls.isEmpty() { filtered = html }
                                else {
                                    try controls.remove()
                                    filtered = try fragment.body()?.html() ?? ""
                                }
                            } catch { filtered = "" }
                            _ = filtered.withCString { cmark_node_set_literal(node, $0) }
                        }
                    }
                    continue
                }
                guard type == CMARK_NODE_IMAGE,
                      let destination = cmark_node_get_url(node) else { continue }
                let source = String(cString: destination)
                if URLComponents(string: source)?.scheme?.lowercased() == "file",
                   let path = LocalImage.pathReference(source) {
                    _ = path.withCString { cmark_node_set_url(node, $0) }
                }
            }
            return root
        }
        options.cmark_user_data = UnsafeMutableRawPointer(imageExtension)
        options.cmark_init = { parser, _, _, data in
            if let data { _ = cmark_parser_attach_syntax_extension(parser, data.assumingMemoryBound(to: cmark_syntax_extension.self)) }
        }
        let fragment = try source.withCString { markdown in
            guard let output = apex_markdown_to_html(markdown, source.utf8.count, &options) else {
                throw ReaderError.rendererUnavailable
            }
            defer { apex_free_string(output) }
            return String(cString: output)
        }
        let document = try SwiftSoup.parseBodyFragment(fragment)
        document.outputSettings().prettyPrint(pretty: false)
        try HTMLAdapter.prepare(document, loadRemoteImages: loadRemoteImages)
        try GitHubAlerts.prepare(document)
        for code in try document.select("pre > code.language-mermaid").array() {
            guard let pre = code.parent() else { continue }
            let figure = Element(try Tag.valueOf("figure"), "")
            try figure.addClass("margined-diagram")
            if pre.hasAttr("id") { try figure.attr("id", pre.attr("id")); try pre.removeAttr("id") }
            try pre.before(figure)
            try pre.remove()
            try figure.appendChild(pre)
        }
        return document
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private final class RendererBundleMarker: NSObject {}

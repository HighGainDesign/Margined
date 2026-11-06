import ApexC
import CcmarkGFM
import Foundation
import SwiftSoup

struct MarkdownChoiceGroup: Equatable, Sendable {
    let id: Int
    let label: String
    let tasks: [MarkdownTask]
    var hasConflict: Bool { tasks.filter(\.checked).count > 1 }
}

struct MarkdownTextResponse: Equatable, Sendable {
    let id: Int
    let label: String
    let range: Range<Int>
    let sourceValue: String
    let plainValue: String
}

struct MarkdownResponseMap: Sendable {
    var choices: [MarkdownChoiceGroup] = []
    var answers: [MarkdownTextResponse] = []
}

struct MarkdownResponseEdit: Equatable, Sendable {
    let source: String
    let splices: [MarkdownSourceSplice]

    func apply(to data: Data) throws -> Data {
        try MarkdownSourceEdits.apply(splices, to: data, expectedSource: source)
    }

    func inverse() throws -> MarkdownResponseEdit {
        let updated = try MarkdownSource.decode(apply(to: Data(source.utf8)))
        let original = Array(source.utf8)
        var delta = 0
        let inverse = splices.sorted { $0.range.lowerBound < $1.range.lowerBound }.map { splice in
            let start = splice.range.lowerBound + delta
            let end = start + splice.replacement.utf8.count
            delta += splice.replacement.utf8.count - splice.range.count
            return MarkdownSourceSplice(range: start..<end, replacement: String(decoding: original[splice.range], as: UTF8.self))
        }
        return .init(source: updated, splices: inverse)
    }
}

/// Source positions prove that labels are real top-level paragraphs. A separate
/// DOM match proves that each descriptor belongs to the sanitized displayed text.
enum MarkdownResponses {
    static let maximumAnswerLength = 1000

    enum Failure: LocalizedError {
        case changed, tooLong, lineBreak, controlCharacter
        var errorDescription: String? {
            switch self {
            case .changed: SourceFileEdit.Failure.changed.localizedDescription
            case .tooLong: String(localized: "Keep this answer to 1,000 characters or fewer.")
            case .lineBreak: String(localized: "Use one paragraph without line breaks for this answer.")
            case .controlCharacter: String(localized: "Remove control characters from this answer.")
            }
        }
    }

    static func choiceEdit(source: String, group: MarkdownChoiceGroup, taskID: Int, checked: Bool) throws -> MarkdownResponseEdit {
        guard group.tasks.count >= 2, group.tasks.contains(where: { $0.id == taskID }),
              Set(group.tasks.map(\.utf8Offset)).count == group.tasks.count else { throw Failure.changed }
        let bytes = Array(source.utf8)
        let selecting = group.hasConflict || checked
        var edits: [MarkdownSourceSplice] = []
        for task in group.tasks {
            guard task.utf8Offset > 0, task.utf8Offset + 1 < bytes.count,
                  bytes[task.utf8Offset - 1] == 91, bytes[task.utf8Offset + 1] == 93,
                  bytes[task.utf8Offset] == task.marker, [32, 88, 120].contains(task.marker) else { throw Failure.changed }
            let marker: UInt8 = task.id == taskID && selecting ? (task.checked ? task.marker : 120) : 32
            if marker != task.marker {
                edits.append(.init(range: task.utf8Offset..<(task.utf8Offset + 1), replacement: String(UnicodeScalar(UInt32(marker))!)))
            }
        }
        return .init(source: source, splices: edits)
    }

    static func answerEdit(source: String, field: MarkdownTextResponse, text: String) throws -> MarkdownResponseEdit {
        let bytes = Array(source.utf8)
        guard field.range.lowerBound >= 0, field.range.upperBound <= bytes.count,
              bytes[field.range].elementsEqual(field.sourceValue.utf8) else { throw Failure.changed }
        // A no-op retains all externally authored inline formatting, even for an
        // imported answer above today's editing limit. It never truncates it.
        if text.utf8.elementsEqual(field.plainValue.utf8) { return .init(source: source, splices: []) }
        let value = try normalizedAnswer(text)
        if value.utf8.elementsEqual(field.plainValue.utf8) { return .init(source: source, splices: []) }
        let replacement = value.isEmpty ? "_Not answered_" : value.unicodeScalars.reduce(into: "") { result, scalar in
            // Apex's preprocessing can interpret backslash-escaped brackets,
            // URLs and tildes before cmark sees their escapes. Ordinary Markdown
            // character references keep those literal throughout both stages.
            if "\\*_`[]<>!&$|{}~:@+=^".unicodeScalars.contains(scalar) {
                result += "&#\(scalar.value);"
            } else { result.unicodeScalars.append(scalar) }
        }
        return .init(source: source, splices: [.init(range: field.range, replacement: replacement)])
    }

    static func normalizedAnswer(_ text: String) throws -> String {
        guard !text.contains(where: \.isNewline) else { throw Failure.lineBreak }
        guard !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && $0.value != 9 }) else { throw Failure.controlCharacter }
        let value = text.trimmingCharacters(in: .whitespaces)
        guard value.count <= maximumAnswerLength else { throw Failure.tooLong }
        return value == "_Not answered_" ? "" : value
    }

    static func attach(to document: Document, source: String, tasks: [MarkdownTask], answerOrigins: [Int: Element] = [:]) throws -> MarkdownResponseMap {
        guard source.contains(" (choose one):**") || source.contains(" (short answer):** ") else { return .init() }
        return try withSourceTree(source) { root, bytes, starts in
            guard let body = document.body() else { return .init() }
            let elements = body.children().array()
            var choiceElements: [Int: (paragraph: Element, list: Element, inputs: [Element], ids: [Int])] = [:]
            if !tasks.isEmpty {
                for index in elements.indices.dropLast() {
                    let p = elements[index], ul = elements[index + 1]
                    guard p.tagName() == "p", ul.tagName() == "ul" else { continue }
                    let inputs = try ul.select("input[data-margined-task]").array()
                    let ids = try inputs.compactMap { Int(try $0.attr("data-margined-task")) }
                    guard let first = ids.first, ids.count == inputs.count else { continue }
                    choiceElements[first] = (p, ul, inputs, ids)
                }
            }
            var result = MarkdownResponseMap()
            var tasksByLine: [Int: [MarkdownTask]] = [:]
            for task in tasks {
                var lo = 0, hi = starts.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if starts[mid] <= task.utf8Offset { lo = mid + 1 } else { hi = mid }
                }
                tasksByLine[lo - 1, default: []].append(task)
            }
            struct AnswerCandidate {
                let label: String
                let range: Range<Int>
                let value: String
                let plain: String
                let key: String
            }
            var answers: [AnswerCandidate] = []
            func hasNestedList(_ node: UnsafeMutablePointer<cmark_node>) -> Bool {
                var child = cmark_node_first_child(node)
                while let current = child {
                    if cmark_node_get_type(current) == CMARK_NODE_LIST || hasNestedList(current) { return true }
                    child = cmark_node_next(current)
                }
                return false
            }
            var node = cmark_node_first_child(root)
            while let paragraph = node {
                node = cmark_node_next(paragraph)
                let line = Int(cmark_node_get_start_line(paragraph)) - 1
                guard cmark_node_get_type(paragraph) == CMARK_NODE_PARAGRAPH,
                      cmark_node_get_start_column(paragraph) == 1,
                      cmark_node_get_end_line(paragraph) == cmark_node_get_start_line(paragraph),
                      starts.indices.contains(line) else { continue }
                var end = line + 1 < starts.count ? starts[line + 1] : bytes.count
                while end > starts[line], [10, 13].contains(bytes[end - 1]) { end -= 1 }
                let raw = String(decoding: bytes[starts[line]..<end], as: UTF8.self)
                if let label = label(in: raw, suffix: "(choose one):", answer: false)?.label,
                   plainLabel(paragraph, equals: label + " (choose one):"),
                   let list = node, cmark_node_get_type(list) == CMARK_NODE_LIST,
                   cmark_node_get_list_type(list) == CMARK_BULLET_LIST, !hasNestedList(list) {
                    var members: [MarkdownTask] = [], valid = true
                    var item = cmark_node_first_child(list)
                    while let current = item {
                        let mapped = tasksByLine[Int(cmark_node_get_start_line(current)) - 1] ?? []
                        guard mapped.count == 1 else { valid = false; break }
                        members.append(mapped[0]); item = cmark_node_next(current)
                    }
                    guard valid, members.count >= 2, let match = choiceElements[members[0].id] else { continue }
                    // Task IDs already have exact source mappings. They disambiguate
                    // identical labels and prevent author-HTML lookalikes stealing a group.
                    let p = match.paragraph, ul = match.list, inputs = match.inputs
                    guard matchingText(p) == normalizedMatchingText(label + " (choose one):"),
                          p.children().size() == 1, p.children().first()?.tagName() == "strong" else { continue }
                    guard match.ids == members.map(\.id),
                          ul.children().size() == members.count,
                          try ul.select("li ul, li ol").isEmpty() else { continue }
                    let group = MarkdownChoiceGroup(id: result.choices.count, label: label, tasks: members)
                    try ul.attr("data-margined-choice", String(group.id)).attr("role", "group")
                        .attr("aria-label", label + " (choose one)")
                    if group.hasConflict { try ul.attr("aria-invalid", "true") }
                    for input in inputs { try input.attr("data-margined-choice", String(group.id)) }
                    result.choices.append(group)
                } else if let match = label(in: raw, suffix: "(short answer):", answer: true),
                          plainLabel(paragraph, equals: match.label + " (short answer):"),
                          let html = cmark_render_html(paragraph, Int32(CMARK_OPT_UNSAFE), nil) {
                    defer { free(html) }
                    let fragment = try SwiftSoup.parseBodyFragment(String(cString: html))
                    let text = matchingText(fragment)
                    let prefix = match.label + " (short answer):"
                    let uncollapsed = try fragment.select("p").first().map(textPreservingWhitespace) ?? text
                    guard uncollapsed.hasPrefix(prefix) else { continue }
                    let plain = String(uncollapsed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    answers.append(.init(label: match.label, range: (starts[line] + match.valueOffset)..<end,
                        value: match.value, plain: match.value == "_Not answered_" ? "" : plain,
                        key: text))
                }
            }
            let sourceCounts = Dictionary(grouping: answers, by: \.key).mapValues(\.count)
            var displayedCounts: [String: Int] = [:]
            for element in elements where element.tagName() == "p" {
                guard element.children().first()?.tagName() == "strong" else { continue }
                displayedCounts[matchingText(element), default: 0] += 1
            }
            for candidate in answers {
                // Equal text/counts cannot prove identity when authored HTML
                // nests, drops or duplicates paragraphs. The rendering copy
                // carries a unique source-owned token to this exact DOM node.
                guard displayedCounts[candidate.key] == sourceCounts[candidate.key],
                      let paragraph = answerOrigins[candidate.range.lowerBound],
                      paragraph.parent() === body, paragraph.tagName() == "p",
                      paragraph.children().first()?.tagName() == "strong",
                      matchingText(paragraph) == candidate.key else { continue }
                let field = MarkdownTextResponse(id: result.answers.count, label: candidate.label,
                    range: candidate.range, sourceValue: candidate.value, plainValue: candidate.plain)
                try paragraph.attr("data-margined-answer", String(field.id))
                result.answers.append(field)
            }
            return result
        }
    }

    struct LiteralAnswerMask: Sendable {
        let source: String
        let values: [String: String]
        var positions: [String: Int] = [:]
        var anchors: [String: Int] = [:]
        var prefix = ""

        func restore(in document: Document) throws -> [Int: Element] {
            guard !values.isEmpty || !anchors.isEmpty, let body = document.body() else { return [:] }
            var stack: [Node] = [body], origins: [Int: Element] = [:]
            while let node = stack.popLast() {
                if let text = node as? TextNode {
                    let raw = text.getWholeText()
                    guard raw.hasPrefix(" ") else { continue }
                    let token = String(raw.dropFirst())
                    if let value = values[token] {
                        try text.text(" " + value)
                        if let position = positions[token], let parent = text.parent() as? Element {
                            origins[position] = parent
                        }
                    }
                } else { stack.append(contentsOf: node.getChildNodes()) }
            }
            for marker in try document.select("span[class]").array() {
                guard let position = anchors[try marker.attr("class")] else { continue }
                if let parent = marker.parent() { origins[position] = parent }
                try marker.remove()
            }
            // Sanitization may remove a source-owned node entirely. It then has
            // no editable counterpart. Any surviving unrecognized token must
            // fail closed rather than reach semantic snapshots or final HTML.
            if !prefix.isEmpty, try document.outerHtml().contains(prefix) { throw ReaderError.rendererUnavailable }
            return origins
        }
    }

    /// Render-only tokens bind source-proven answers to their exact DOM nodes.
    /// Plain values also bypass Apex's autolink/emoji rewriting; formatted values
    /// follow normal rendering with an empty provenance marker. All tokens and
    /// markers disappear before semantic snapshots or HTML leave the renderer.
    static func maskLiteralAnswers(in source: String) throws -> LiteralAnswerMask {
        guard source.contains(" (short answer):** ") else { return .init(source: source, values: [:]) }
        var prefix = "marginedA" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        while source.contains(prefix) { prefix += "x" }
        struct Candidate { let start: Int; let range: Range<Int>; let plain: String? }
        let candidates: [Candidate] = try withSourceTree(source) { root, bytes, starts in
            var result: [Candidate] = []
            var node = cmark_node_first_child(root)
            while let paragraph = node {
                node = cmark_node_next(paragraph)
                let line = Int(cmark_node_get_start_line(paragraph)) - 1
                guard cmark_node_get_type(paragraph) == CMARK_NODE_PARAGRAPH,
                      cmark_node_get_start_column(paragraph) == 1,
                      cmark_node_get_end_line(paragraph) == cmark_node_get_start_line(paragraph), starts.indices.contains(line) else { continue }
                var end = line + 1 < starts.count ? starts[line + 1] : bytes.count
                while end > starts[line], [10, 13].contains(bytes[end - 1]) { end -= 1 }
                let raw = String(decoding: bytes[starts[line]..<end], as: UTF8.self)
                guard let match = label(in: raw, suffix: "(short answer):", answer: true),
                      plainLabel(paragraph, equals: match.label + " (short answer):"),
                      let strong = cmark_node_first_child(paragraph),
                      let html = cmark_render_html(paragraph, Int32(CMARK_OPT_UNSAFE), nil) else { continue }
                defer { free(html) }
                var literal = true, value = cmark_node_next(strong)
                while let current = value {
                    if cmark_node_get_type(current) != CMARK_NODE_TEXT { literal = false }
                    value = cmark_node_next(current)
                }
                let fragment = try SwiftSoup.parseBodyFragment(String(cString: html))
                guard let p = try fragment.select("p").first() else { continue }
                let labelText = match.label + " (short answer): "
                let rawText = textPreservingWhitespace(p)
                guard rawText.hasPrefix(labelText) else { continue }
                result.append(.init(start: starts[line], range: (starts[line] + match.valueOffset)..<end,
                    plain: literal ? String(rawText.dropFirst(labelText.count)) : nil))
            }
            return result
        }
        guard !candidates.isEmpty else { return .init(source: source, values: [:]) }
        let bytes = Array(source.utf8)
        var result = Data(), previous = 0, values: [String: String] = [:]
        var positions: [String: Int] = [:], anchors: [String: Int] = [:]
        for (index, candidate) in candidates.enumerated() {
            let token = prefix + String(index)
            if let plain = candidate.plain {
                result.append(contentsOf: bytes[previous..<candidate.range.lowerBound])
                result.append(contentsOf: token.utf8)
                values[token] = plain
                positions[token] = candidate.range.lowerBound
                previous = candidate.range.upperBound
            } else {
                result.append(contentsOf: bytes[previous..<candidate.start])
                result.append(contentsOf: "<span class=\"\(token)\"></span>".utf8)
                anchors[token] = candidate.range.lowerBound
                previous = candidate.start
            }
        }
        result.append(contentsOf: bytes[previous...])
        // This is an internal, bounded rendering copy; it never changes the
        // file's 8 MB limit or goes through the source-write API.
        guard result.count <= MarkdownSource.maximumBytes * 4 else { throw ReaderError.tooLarge }
        return .init(source: String(decoding: result, as: UTF8.self), values: values,
            positions: positions, anchors: anchors, prefix: prefix)
    }

    private static func textPreservingWhitespace(_ node: Node) -> String {
        var stack = [node], result = ""
        while let current = stack.popLast() {
            if let text = current as? TextNode { result += text.getWholeText() }
            else if let element = current as? Element, element.tagName() == "br" { result += "\n" }
            else { stack.append(contentsOf: current.getChildNodes().reversed()) }
        }
        return result
    }

    private static func normalizedMatchingText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func matchingText(_ node: Node) -> String {
        // SwiftSoup's text() can remove spaces next to CJK text when review
        // marks split a single text node. Compare the actual text-node stream.
        normalizedMatchingText(textPreservingWhitespace(node))
    }

    private static func withSourceTree<Result>(_ source: String, _ action: (UnsafeMutablePointer<cmark_node>, [UInt8], [Int]) throws -> Result) throws -> Result {
        let bytes = Array(source.utf8)
        guard bytes.count <= MarkdownSource.maximumBytes else { throw ReaderError.tooLarge }
        var starts = [0], offset = 0
        while offset < bytes.count {
            if bytes[offset] == 13 {
                if offset + 1 < bytes.count, bytes[offset + 1] == 10 { offset += 1 }
                starts.append(offset + 1)
            } else if bytes[offset] == 10 { starts.append(offset + 1) }
            offset += 1
        }
        guard let parser = cmark_parser_new(0), let ext = cmark_syntax_extension_new("margined-response-math") else { throw ReaderError.rendererUnavailable }
        defer {
            cmark_parser_free(parser)
            cmark_syntax_extension_free(cmark_get_default_mem_allocator(), ext)
        }
        MathSyntax.install(on: ext, sourceBytes: bytes.count)
        _ = cmark_parser_attach_syntax_extension(parser, ext)
        source.withCString { cmark_parser_feed(parser, $0, bytes.count) }
        guard let root = cmark_parser_finish(parser) else { throw ReaderError.rendererUnavailable }
        defer { cmark_node_free(root) }
        return try action(root, bytes, starts)
    }

    private static func label(in raw: String, suffix: String, answer: Bool) -> (label: String, valueOffset: Int, value: String)? {
        guard raw.hasPrefix("**"), let boundary = raw.range(of: " " + suffix + "**") else { return nil }
        let label = String(raw[raw.index(raw.startIndex, offsetBy: 2)..<boundary.lowerBound])
        guard !label.isEmpty, label == label.trimmingCharacters(in: .whitespaces) else { return nil }
        let rest = raw[boundary.upperBound...]
        if !answer { return rest.isEmpty ? (label, raw.utf8.count, "") : nil }
        guard rest.hasPrefix(" "), rest.count > 1 else { return nil }
        let prefix = raw[..<boundary.upperBound] + " "
        return (label, prefix.utf8.count, String(rest.dropFirst()))
    }

    private static func plainLabel(_ paragraph: UnsafeMutablePointer<cmark_node>, equals expected: String) -> Bool {
        guard let strong = cmark_node_first_child(paragraph), cmark_node_get_type(strong) == CMARK_NODE_STRONG else { return false }
        var text = "", node = cmark_node_first_child(strong)
        while let current = node {
            guard cmark_node_get_type(current) == CMARK_NODE_TEXT, let literal = cmark_node_get_literal(current) else { return false }
            text += String(cString: literal)
            node = cmark_node_next(current)
        }
        return text.utf8.elementsEqual(expected.utf8)
    }
}

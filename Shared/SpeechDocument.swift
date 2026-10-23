import Foundation
import CryptoKit
import NaturalLanguage
import SwiftSoup

struct SpeechOptions: Codable, Equatable, Sendable {
    var includeCode = false
    var includeLinkDestinations = false
}

struct SpeechSegment: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case heading, paragraph, listItem, tableRow, code, image }
    let id: String
    let elementID: String
    let text: String
    let sectionID: String?
    let kind: Kind
    var elementOffset = 0
}

struct SpeechSection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let firstSegment: Int
}

struct SpeechDocument: Equatable, Sendable {
    let segments: [SpeechSegment]
    let sections: [SpeechSection]
    let language: String?
    let fingerprint: String
    var elements: [String: SpeechElementMap] = [:]
    var options = SpeechOptions()

    func section(at segment: Int) -> SpeechSection? {
        sections.last { $0.firstSegment <= segment }
    }
}

/// Walk the already parsed, sanitized DOM once. Never re-parse Markdown or
/// derive spoken text from review decorations. QL does not request this work.
enum SpeechDocumentBuilder {
    static func prepare(_ document: Document, source: String, language: String?, options: SpeechOptions) throws -> SpeechDocument {
        try Builder(language: language, options: options).build(document, source: source)
    }

    private final class Builder {
        let language: String?
        let options: SpeechOptions
        var segments: [SpeechSegment] = []
        var sections: [SpeechSection] = []
        var elementMaps: [String: SpeechElementMap] = [:]
        private struct Part { let text: String; var origin: TextNode? = nil }
        var nextElement = 0
        var sectionID: String?

        init(language: String?, options: SpeechOptions) { self.language = language; self.options = options }

        func build(_ document: Document, source: String) throws -> SpeechDocument {
            for child in document.body()?.children().array() ?? [] { try walk(child) }
            let fingerprint = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
            return SpeechDocument(segments: segments, sections: sections, language: language, fingerprint: fingerprint, elements: elementMaps, options: options)
        }

        func walk(_ element: Element) throws {
            guard try element.attr("aria-hidden") != "true", !element.hasAttr("hidden") else { return }
            let tag = element.tagName()
            if tag == "figure", element.hasClass("margined-diagram") {
                try append([Part(text: label("diagram"))], element: element, kind: .image)
            } else if ["h1", "h2", "h3", "h4", "h5", "h6"].contains(tag) {
                let title = try inline(element)
                let id = try element.attr("id")
                sectionID = id.isEmpty ? "section-\(sections.count)" : id
                sections.append(SpeechSection(id: sectionID!, title: title, firstSegment: segments.count))
                try append(parts(element), element: element, kind: .heading)
            } else if tag == "table" {
                try table(element)
            } else if tag == "pre" {
                let text = options.includeCode ? try parts(element) : [Part(text: label("code"))]
                try append(text, element: element, kind: .code)
            } else if tag == "li" {
                try listItem(element)
            } else if ["p", "dt", "dd", "figcaption", "summary"].contains(tag) {
                try append(parts(element), element: element, kind: .paragraph)
            } else if tag == "img" {
                try append(parts(element), element: element, kind: .image)
            } else {
                for child in element.children().array() { try walk(child) }
            }
        }

        private func listItem(_ element: Element) throws {
            let task = try element.select("input[type=checkbox]").array().first { input in
                var parent = input.parent()
                while let current = parent {
                    if current.tagName() == "li" { return current === element }
                    parent = current.parent()
                }
                return false
            }
            var prefix = task.map { Part(text: label($0.hasAttr("checked") ? "checked" : "unchecked") + ": ") }
            var pending: [Part] = []
            func emit(_ value: [Part], on target: Element) throws {
                var value = value
                if let first = prefix { value.insert(first, at: 0); prefix = nil }
                try append(value, element: target, kind: .listItem)
            }
            func flush() throws {
                guard prefix != nil || !pending.isEmpty else { return }
                try emit(pending, on: element); pending = []
            }
            let blocks: Set<String> = ["p", "ul", "ol", "pre", "table", "blockquote", "div", "section", "figure", "dl", "h1", "h2", "h3", "h4", "h5", "h6"]
            for child in element.getChildNodes() {
                if let block = child as? Element, blocks.contains(block.tagName()) {
                    // Loose-list paragraphs own their inline text and task cue.
                    // Other blocks retain the same semantic handlers as the body.
                    if block.tagName() == "p" {
                        if pending.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { try flush() }
                        else { pending.removeAll() }
                        try emit(parts(block), on: block)
                    } else {
                        try flush()
                        try walk(block)
                    }
                } else { pending += try parts(child) }
            }
            try flush()
        }

        func table(_ table: Element) throws {
            let rows = try table.select("tr").array().filter { row in
                var parent = row.parent()
                while let current = parent { if current.tagName() == "table" { return current === table }; parent = current.parent() }
                return false
            }
            let firstCells = rows.first?.children().array() ?? []
            let hasHeaders = !firstCells.isEmpty && firstCells.allSatisfy { $0.tagName() == "th" }
            let headers = hasHeaders ? try firstCells.map { try inline($0) } : []
            for (index, row) in rows.enumerated() {
                if index == 0 && hasHeaders && rows.count > 1 { continue }
                var spoken: [Part] = []
                for (column, cell) in row.children().array().enumerated() {
                    if column > 0 { spoken.append(Part(text: "; ")) }
                    if !headers.isEmpty && index > 0 && column < headers.count && !headers[column].isEmpty {
                        spoken.append(Part(text: headers[column] + ": "))
                    }
                    spoken += try parts(cell)
                }
                try append(spoken, element: row, kind: .tableRow)
            }
        }

        func inline(_ node: Node) throws -> String {
            try parts(node).map(\.text).joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        private func parts(_ node: Node, skipLists: Bool = false) throws -> [Part] {
            if let text = node as? TextNode { return [Part(text: text.getWholeText(), origin: text)] }
            guard let element = node as? Element else { return [] }
            let tag = element.tagName()
            if try element.attr("aria-hidden") == "true" || element.hasAttr("hidden") { return [] }
            if skipLists && ["ul", "ol"].contains(tag) { return [] }
            if tag == "input" { return [] }
            if tag == "img" { return [Part(text: try element.attr("alt"))] }
            if tag == "br" { return [Part(text: " ")] }
            let role = try element.attr("role"), classes = try element.attr("class").split(separator: " ")
            if role == "doc-backlink" || role == "doc-noteref" ||
                classes.contains(where: { ["footnote-backref", "reversefootnote", "footnote-ref"].contains(String($0)) }) { return [] }
            var result = try element.getChildNodes().flatMap { try parts($0, skipLists: skipLists) }
            if tag == "a" && options.includeLinkDestinations {
                let href = try element.attr("href")
                if !href.isEmpty && !href.hasPrefix("#"), result.map(\.text).joined() != href {
                    result.append(Part(text: " (" + href + ")"))
                }
            }
            return result
        }

        private func append(_ parts: [Part], element: Element, kind: SpeechSegment.Kind) throws {
            let literal = kind == .code && options.includeCode
            var sourceRanges: [ObjectIdentifier: NSRange] = [:], sourceLength = 0
            func index(_ node: Node) {
                if let text = node as? TextNode {
                    let length = text.getWholeText().utf16.count
                    sourceRanges[ObjectIdentifier(text)] = NSRange(location: sourceLength, length: length)
                    sourceLength += length
                } else { for child in node.getChildNodes() { index(child) } }
            }
            index(element)
            var text = "", pendingSpace = false, anchors: [SpeechAnchor] = []
            for part in parts {
                let content = literal ? part.text : part.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if !literal && !content.isEmpty && !text.isEmpty && (pendingSpace || part.text.first?.isWhitespace == true) { text += " " }
                if let origin = part.origin, let range = sourceRanges[ObjectIdentifier(origin)] {
                    anchors.append(SpeechAnchor(sourceRange: range, sourceText: part.text, spokenOffset: text.utf16.count, literal: literal))
                }
                text += content
                pendingSpace = part.text.last?.isWhitespace == true
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let existingID = try element.attr("data-margined-speech")
            let elementID: String
            if existingID.isEmpty { elementID = "speech-\(nextElement)"; nextElement += 1 }
            else { elementID = existingID }
            try element.attr("data-margined-speech", elementID)
            let previous = existingID.isEmpty ? [] : segments.filter { $0.elementID == elementID }
            var offset = previous.reduce(0) { $0 + $1.text.utf16.count }
            anchors = anchors.map { SpeechAnchor(sourceRange: $0.sourceRange, sourceText: $0.sourceText,
                                                  spokenOffset: $0.spokenOffset + offset, literal: $0.literal) }
            elementMaps[elementID] = SpeechElementMap(sourceLength: sourceLength,
                anchors: (elementMaps[elementID]?.anchors ?? []) + anchors)
            for (index, chunk) in Self.chunks(text).enumerated() {
                segments.append(SpeechSegment(id: "\(elementID)-\(previous.count + index)", elementID: elementID,
                    text: chunk, sectionID: sectionID, kind: kind, elementOffset: offset))
                offset += chunk.utf16.count
            }
        }

        static func chunks(_ text: String) -> [String] {
            var chunks: [String] = [], current = "", count = 0
            let tokenizer = NLTokenizer(unit: .sentence); tokenizer.string = text
            var cursor = text.startIndex
            func consume(_ unit: Substring) {
                if count + unit.utf16.count > 1200 && !current.isEmpty {
                    chunks.append(current); current = ""; count = 0
                }
                for character in unit {
                    let value = String(character), size = value.utf16.count
                    if count + size > 1200 && !current.isEmpty {
                        chunks.append(current); current = ""; count = 0
                    }
                    current += value; count += size
                }
            }
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                // Carry whitespace between sentence tokens, preserving exact
                // Unicode text while preferring a natural utterance boundary.
                consume(text[cursor..<range.upperBound]); cursor = range.upperBound
                return true
            }
            if cursor < text.endIndex { consume(text[cursor..<text.endIndex]) }
            if !current.isEmpty { chunks.append(current) }
            return chunks
        }

        func label(_ key: String) -> String {
            // These short semantic cues follow document language, not UI locale.
            let base = language?.split(separator: "-").first.map(String.init) ?? "en"
            if base == "zh", let language, Locale(identifier: language).language.script?.identifier == "Hant" {
                return ["checked": "已完成", "unchecked": "未完成", "code": "略過程式碼區塊", "diagram": "Mermaid 圖表"][key]!
            }
            let labels = [
                "en": ["checked": "Checked", "unchecked": "Unchecked", "code": "Code block omitted", "diagram": "Mermaid diagram"],
                "es": ["checked": "Completado", "unchecked": "Pendiente", "code": "Bloque de código omitido", "diagram": "Diagrama Mermaid"],
                "zh": ["checked": "已完成", "unchecked": "未完成", "code": "略过代码块", "diagram": "Mermaid 图表"],
                "ja": ["checked": "完了", "unchecked": "未完了", "code": "コードブロックを省略", "diagram": "Mermaid 図"],
                "fr": ["checked": "Terminé", "unchecked": "À faire", "code": "Bloc de code omis", "diagram": "Diagramme Mermaid"],
                "de": ["checked": "Erledigt", "unchecked": "Offen", "code": "Codeblock ausgelassen", "diagram": "Mermaid-Diagramm"]
            ]
            return labels[base]?[key] ?? labels["en"]![key]!
        }
    }
}

import CryptoKit
import Foundation
import SwiftSoup

struct DiscussionDOMPart: Equatable, Sendable {
    enum Kind: String, Sendable { case text, image, separator }
    let kind: Kind
    let path: [Int]
    /// UTF-16 in this semantic unit's raw source-DOM stream, including image alt.
    let range: NSRange
}
struct DiscussionTextUnit: Equatable, Sendable {
    let id: Int
    let kind: String
    let text: String
    let range: NSRange
    let section: String?
    let rawText: String
    let parts: [DiscussionDOMPart]
}
struct DiscussionDOMBoundary: Equatable, Sendable { let unit: Int; let offset: Int }
struct DiscussionDOMRange: Equatable, Sendable { let start: DiscussionDOMBoundary; let end: DiscussionDOMBoundary }
struct DiscussionSelection: Equatable, Sendable {
    let target: DiscussionTarget
    let range: NSRange
    let sourceID: String
    let renderID: String
    let domRange: DiscussionDOMRange
}
struct DiscussionTextProjection: Equatable, Sendable {
    let text: String
    let sourceID: String
    let units: [DiscussionTextUnit]
    let barriers: [Int]
    let targets: [String: DiscussionTarget]
    var anchorResults: [String: DiscussionAnchorResult] = [:]
    var attachmentVersions: [String: Int] = [:]

    func selection(_ proposed: NSRange, renderID: String) -> DiscussionSelection? {
        let literal = text as NSString
        guard proposed.location >= 0, proposed.length > 0, proposed.location <= literal.length,
              proposed.length <= literal.length - proposed.location,
              literal.rangeOfComposedCharacterSequences(for: proposed) == proposed else { return nil }
        let value = literal.substring(with: proposed)
        let leading = String(value.prefix { $0.isWhitespace }).utf16.count
        let trailing = String(value.reversed().prefix { $0.isWhitespace }).utf16.count
        guard leading + trailing < proposed.length else { return nil }
        let range = NSRange(location: proposed.location + leading, length: proposed.length - leading - trailing)
        let end = range.location + range.length
        guard !barriers.contains(where: { range.location < $0 && $0 < end }),
              let first = units.first(where: { $0.range.location <= range.location && range.location < NSMaxRange($0.range) }),
              let last = units.last(where: { $0.range.location < end && end <= NSMaxRange($0.range) }),
              let rawStart = DiscussionText.rawOffset(range.location - first.range.location, in: first.rawText),
              let rawEnd = DiscussionText.rawOffset(end - last.range.location, in: last.rawText) else { return nil }
        let before = literal.substring(to: range.location), after = literal.substring(from: end)
        let prefix = String(String.UnicodeScalarView(before.unicodeScalars.suffix(32)))
        let suffix = String(String.UnicodeScalarView(after.unicodeScalars.prefix(32)))
        let target = DiscussionTarget(type: "TextQuoteSelector", exact: literal.substring(with: range), prefix: prefix, suffix: suffix, section: first.section)
        return DiscussionSelection(target: target, range: range, sourceID: sourceID, renderID: renderID,
            domRange: .init(start: .init(unit: first.id, offset: rawStart), end: .init(unit: last.id, offset: rawEnd)))
    }
}

/// The source here is the sanitized semantic DOM, not Markdown-file offsets.
/// No marker wrappers or attributes are added to reading/review/speech HTML.
enum DiscussionText {
    struct NormalizationRun {
        let canonical: NSRange
        let raw: NSRange
        let identity: Bool
    }
    static func normalized(_ text: String) -> String { normalize(text).text }

    static func normalize(_ raw: String) -> (text: String, runs: [NormalizationRun]) {
        let leading = raw.prefix { $0.isWhitespace }
        let tail = raw.dropFirst(leading.count)
        let trailing = tail.reversed().prefix { $0.isWhitespace }
        let middle = String(tail.dropLast(trailing.count))
        guard !middle.isEmpty else { return ("", []) }
        let direct = middle.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if direct.utf8.elementsEqual(middle.utf8) {
            let length = direct.utf16.count
            return (direct, [.init(canonical: .init(location: 0, length: length), raw: .init(location: String(leading).utf16.count, length: length), identity: true)])
        }
        var text = "", runs: [NormalizationRun] = [], rawOffset = 0, canonicalOffset = 0
        var whitespace: NSRange?
        func append(_ value: String, raw range: NSRange, identity: Bool) {
            let canonical = NSRange(location: canonicalOffset, length: value.utf16.count)
            if identity, let last = runs.last, last.identity, NSMaxRange(last.canonical) == canonical.location, NSMaxRange(last.raw) == range.location {
                runs[runs.count - 1] = .init(canonical: .init(location: last.canonical.location, length: last.canonical.length + canonical.length), raw: .init(location: last.raw.location, length: last.raw.length + range.length), identity: true)
            } else { runs.append(.init(canonical: canonical, raw: range, identity: identity)) }
            text += value; canonicalOffset += canonical.length
        }
        for character in raw {
            let original = String(character), length = original.utf16.count
            defer { rawOffset += length }
            if character.isWhitespace {
                if let start = whitespace?.location { whitespace = .init(location: start, length: rawOffset + length - start) }
                else { whitespace = .init(location: rawOffset, length: length) }
                continue
            }
            if let pending = whitespace, !text.isEmpty { append(" ", raw: pending, identity: pending.length == 1 && (raw as NSString).substring(with: pending) == " ") }
            whitespace = nil
            let value = original.utf8.count == 1 ? original : original.precomposedStringWithCanonicalMapping
            append(value, raw: .init(location: rawOffset, length: length), identity: value.utf8.elementsEqual(original.utf8))
        }
        return (text, runs)
    }
    static func rawOffset(_ offset: Int, in raw: String) -> Int? {
        let result = normalize(raw), length = result.text.utf16.count
        guard offset >= 0 && offset <= length else { return nil }
        for run in result.runs {
            if run.canonical.location <= offset && offset <= NSMaxRange(run.canonical) {
                if offset == run.canonical.location { return run.raw.location }
                if offset == NSMaxRange(run.canonical) { return NSMaxRange(run.raw) }
                if run.identity { return run.raw.location + offset - run.canonical.location }
                return nil
            }
        }
        return nil
    }

    static func project(html: String, source: String, targets: [String: DiscussionTarget] = [:]) throws -> DiscussionTextProjection {
        // HTML input preprocessing happens before character references decode.
        // A literal CRLF becomes LF; &#13; remains a real CR in the DOM.
        let input = html.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return try Builder().build(SwiftSoup.parseBodyFragment(input), source: source, targets: targets)
    }
    static func project(_ document: Document, source: String, targets: [String: DiscussionTarget] = [:]) throws -> DiscussionTextProjection {
        if let bytes = try document.body()?.htmlUTF8WithoutSourceReuse(), bytes.contains(13) {
            // This DOM will be serialized for WebKit. Reapply the browser's
            // preprocessing only when serialization contains a literal CR.
            return try project(html: String(decoding: bytes, as: UTF8.self), source: source, targets: targets)
        }
        return try Builder().build(document, source: source, targets: targets)
    }

    private final class Builder {
        private static let blocks: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6", "p", "li", "pre", "th", "td", "dt", "dd", "caption", "summary", "figcaption"]
        private static let containers: Set<String> = ["body", "div", "section", "blockquote", "ul", "ol", "dl", "table", "thead", "tbody", "tfoot", "tr", "figure", "details"]
        private struct Owner: Equatable { let kind: String; let path: [Int] }
        private var units: [DiscussionTextUnit] = [], barriers: [Int] = [], text = ""
        private var owner: Owner?, raw = "", parts: [DiscussionDOMPart] = []
        private var headings: [(Int, String)] = []
        private var textLength = 0

        func build(_ document: Document, source: String, targets: [String: DiscussionTarget]) throws -> DiscussionTextProjection {
            if let body = document.body() { try walk(body, path: [], inherited: .init(kind: "p", path: [])) }
            flush()
            let fingerprint = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
            return DiscussionTextProjection(text: text, sourceID: fingerprint, units: units, barriers: barriers, targets: targets)
        }
        private func flush() {
            guard let owner else { return }
            let value = DiscussionText.normalized(raw)
            if !value.isEmpty {
                if !text.isEmpty { text += " "; textLength += 1 }
                let range = NSRange(location: textLength, length: value.utf16.count)
                units.append(.init(id: units.count, kind: owner.kind, text: value, range: range,
                    section: headings.isEmpty ? nil : headings.map(\.1).joined(separator: " › "), rawText: raw, parts: parts))
                text += value; textLength += range.length
            }
            self.owner = nil; raw = ""; parts = []
        }
        private func append(_ value: String, kind: DiscussionDOMPart.Kind, path: [Int], owner: Owner) {
            if self.owner != owner { flush(); self.owner = owner }
            let offset = raw.utf16.count
            raw += value
            if !value.isEmpty { parts.append(.init(kind: kind, path: path, range: .init(location: offset, length: value.utf16.count))) }
        }
        private func ignored(_ element: Element) throws -> Bool {
            try element.hasAttr("hidden") || element.attr("aria-hidden") == "true" || ["script", "style", "input", "button", "noscript"].contains(element.tagName()) || element.hasClass("margined-discussion-decoration")
        }
        private func unsupported(_ element: Element) -> Bool {
            element.hasClass("margined-math") || element.hasClass("margined-diagram") || ["math", "svg"].contains(element.tagName())
        }
        private func headingText(_ node: Node) throws -> String {
            if let text = node as? TextNode { return text.getWholeText() }
            guard let element = node as? Element, try !ignored(element), !unsupported(element) else { return "" }
            if element.tagName() == "img" { return try element.attr("alt") }
            return try element.getChildNodes().map(headingText).joined()
        }
        private func walk(_ node: Node, path: [Int], inherited: Owner) throws {
            if let text = node as? TextNode { append(text.getWholeText(), kind: .text, path: path, owner: inherited); return }
            guard let element = node as? Element, try !ignored(element) else { return }
            if unsupported(element) { flush(); if barriers.last != textLength { barriers.append(textLength) }; return }
            let tag = element.tagName(), isBlock = Self.blocks.contains(tag), isContainer = Self.containers.contains(tag)
            let current = isBlock ? Owner(kind: tag, path: path) : inherited
            if isBlock || isContainer { flush() }
            if ["h1", "h2", "h3", "h4", "h5", "h6"].contains(tag) {
                let level = Int(tag.dropFirst())!
                headings.removeAll { $0.0 >= level }
                headings.append((level, DiscussionText.normalized(try headingText(element))))
            }
            if tag == "img" { append(try element.attr("alt"), kind: .image, path: path, owner: current) }
            else if tag == "br" { append(" ", kind: .separator, path: path, owner: current) }
            else {
                for (index, child) in element.getChildNodes().enumerated() { try walk(child, path: path + [index], inherited: current) }
            }
            if isBlock || isContainer { flush() }
        }
    }
}

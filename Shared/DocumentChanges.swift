import Foundation
import SwiftSoup

struct DocumentChange: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case added = "Added", edited = "Edited", removed = "Removed"
        var localizedTitle: String {
            switch self {
            case .added: String(localized: "Added")
            case .edited: String(localized: "Edited")
            case .removed: String(localized: "Removed")
            }
        }
    }
    let id: Int
    let kind: Kind
    let targetID: String?
    let before: String
    let after: String
    /// Offset in this render's in-memory baseline, never in the source file.
    let baselineOffset: Int
    let replacement: ReadingUnit?
    var beforeDescription: String? = nil
    var afterDescription: String? = nil
    var beforeAccessibleText: String { beforeDescription ?? before }
    var afterAccessibleText: String { afterDescription ?? after }
}

/// Rendered blocks let review advance without serializing or editing Markdown.
struct ReadingUnit: Hashable, Sendable {
    let tag: String
    let alignment: String
    let html: String
    private let comparisonHTML: String

    init(_ element: Element) throws {
        tag = element.tagName()
        alignment = try element.attr("align")
        html = try element.html()
        guard html.contains("data-margined-image-source") || html.contains("data-margined-speech") else {
            comparisonHTML = html
            return
        }
        let comparisonDocument = Document.createShell("")
        comparisonDocument.outputSettings().prettyPrint(pretty: false)
        let comparison = try comparisonDocument.body()!.appendElement(tag)
        try comparison.html(html)
        for marker in try comparison.select("[data-margined-speech]").array() {
            try marker.removeAttr("data-margined-speech")
        }
        for image in try comparison.select("img").array() {
            if image.hasAttr("data-margined-image-source") {
                try image.attr("src", image.attr("data-margined-image-source"))
                try image.removeAttr("data-margined-image-source")
                try image.removeAttr("referrerpolicy")
                let attributes = (image.getAttributes()?.asList() ?? []).map { ($0.getKey(), $0.getValue()) }
                for (key, _) in attributes { try image.removeAttr(key) }
                for (key, value) in attributes.sorted(by: { $0.0 < $1.0 }) { try image.attr(key, value) }
            }
        }
        comparisonHTML = try comparison.html()
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tag == rhs.tag && lhs.alignment == rhs.alignment && lhs.comparisonHTML == rhs.comparisonHTML
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(tag)
        hasher.combine(alignment)
        hasher.combine(comparisonHTML)
    }

    func element() throws -> Element {
        let element = Element(try Tag.valueOf(tag), "")
        try element.attr("align", alignment)
        try element.html(html)
        return element
    }
}

struct ChangeSummary: Sendable {
    var entries: [DocumentChange] = []
    var usesSectionComparison = false
    var count: Int { entries.count }
    var navigable: [DocumentChange] { entries.filter { $0.targetID != nil } }
}

/// Compares rendered reading units, so Markdown formatting and links remain
/// intact. Swift's CollectionDifference aligns unchanged blocks and words.
/// Deleted text belongs in the review summary rather than in the current file.
enum DocumentChanges {
    private static let selector = "h1, h2, h3, h4, h5, h6, p, li, pre, th, td, dt, dd, figure"
    private static let unitTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6", "p", "li", "pre", "th", "td", "dt", "dd", "figure"]

    static func annotate(current: Document, baseline: Document) throws -> ChangeSummary {
        try annotate(current: current, baseline: snapshot(in: baseline))
    }

    static func snapshot(in document: Document) throws -> [ReadingUnit] {
        try units(in: document).map { try ReadingUnit($0) }
    }

    static func annotate(current: Document, baseline: [ReadingUnit]) throws -> ChangeSummary {
        let old = try baseline.map { try $0.element() }
        let new = try units(in: current)
        let oldKeys = baseline
        let newKeys = try new.map { try ReadingUnit($0) }
        guard oldKeys != newKeys else { return ChangeSummary() }
        // Bound worst-case sequence work for huge generated documents. The
        // fallback is explicit in the review panel and preserves every block.
        let coarse = max(old.count, new.count) > 2_500
        var removed: Set<Int> = [], inserted: Set<Int> = []
        if coarse {
            for i in 0..<max(old.count, new.count) {
                if i < old.count, i < new.count, oldKeys[i] == newKeys[i] { continue }
                if i < old.count { removed.insert(i) }
                if i < new.count { inserted.insert(i) }
            }
        } else {
            for change in newKeys.difference(from: oldKeys) {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): inserted.insert(offset)
                }
            }
        }
        var summary = ChangeSummary(usesSectionComparison: coarse)
        var oldIndex = 0, newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            let oldStart = oldIndex
            var oldRun: [Element] = [], newRun: [Element] = []
            while oldIndex < old.count, removed.contains(oldIndex) { oldRun.append(old[oldIndex]); oldIndex += 1 }
            while newIndex < new.count, inserted.contains(newIndex) { newRun.append(new[newIndex]); newIndex += 1 }
            if !oldRun.isEmpty || !newRun.isEmpty {
                for i in 0..<max(oldRun.count, newRun.count) {
                    let previous = i < oldRun.count ? oldRun[i] : nil
                    let updated = i < newRun.count ? newRun[i] : nil
                    let before = try previous?.text() ?? ""
                    let after = try updated?.text() ?? ""
                    let kind: DocumentChange.Kind = previous == nil ? .added : (updated == nil ? .removed : .edited)
                    let replacement = try updated.map { try ReadingUnit($0) }
                    let index = summary.entries.count
                    var target: String?
                    if let updated {
                        try updated.addClass("margined-change")
                        try updated.addClass(kind == .added ? "margined-added" : "margined-edited")
                        target = try updated.attr("id")
                        if target?.isEmpty != false {
                            target = "margined-change-\(index)"
                            try updated.attr("id", target!)
                        }
                        try updated.attr("aria-description", String(localized: "\(kind.localizedTitle) since last review"))
                        if let previous { try highlightWords(in: updated, comparedWith: previous) }
                    }
                    summary.entries.append(DocumentChange(id: index, kind: kind, targetID: target,
                        before: before, after: after, baselineOffset: oldStart + min(i, oldRun.count),
                        replacement: replacement, beforeDescription: try accessibleDescription(previous),
                        afterDescription: try accessibleDescription(updated)))
                }
            } else {
                oldIndex += 1
                newIndex += 1
            }
        }
        return summary
    }

    /// Text alone loses checked state, image alternatives and link destinations.
    /// Describe the sanitized DOM already used for review, without reparsing Markdown.
    private static func accessibleDescription(_ element: Element?) throws -> String? {
        guard let element else { return nil }
        let fullText = try element.text()
        let text = fullText.count > 1_200 ? String(fullText.prefix(1_200)) + "…" : fullText
        var details: [String] = []
        let checkboxes = try element.select("input[type=checkbox]").array()
        for checkbox in checkboxes {
            let label = try checkbox.attr("aria-label")
            let state = checkbox.hasAttr("checked") ? String(localized: "Checked checkbox") : String(localized: "Unchecked checkbox")
            details.append(label.isEmpty ? state : String(localized: "\(label): \(state)"))
        }
        for link in try element.select("a[href]").array() {
            let label = try link.text(), destination = try link.attr("href")
            details.append(String(localized: "Link \(label): \(destination)"))
        }
        for image in try element.select("img").array() {
            let label = try image.attr("alt")
            let source = try image.attr("data-margined-image-source")
            details.append(String(localized: "Image \(label): \(source)"))
        }
        if checkboxes.count == 1, details.count == 1, text == (try checkboxes[0].attr("aria-label")) {
            return details[0]
        }
        return ([text] + details).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func units(in document: Document) throws -> [Element] {
        try document.select(selector).array().filter { element in
            var ancestor = element.parent()
            while let parent = ancestor {
                if unitTags.contains(parent.tagName()) { return false }
                ancestor = parent.parent()
            }
            return true
        }
    }

    private static func textNodes(in node: Node) -> [TextNode] {
        if let text = node as? TextNode { return [text] }
        if let element = node as? Element, element.hasClass("margined-math") { return [] }
        return node.getChildNodes().flatMap { textNodes(in: $0) }
    }

    private static func highlightWords(in element: Element, comparedWith previous: Element) throws {
        let nodes = textNodes(in: element)
        let newText = nodes.map { $0.getWholeText() }.joined()
        let oldText = textNodes(in: previous).map { $0.getWholeText() }.joined()
        let expression = try NSRegularExpression(pattern: "\\s+|[^\\s]+")
        let newMatches = expression.matches(in: newText, range: NSRange(newText.startIndex..., in: newText))
        let oldMatches = expression.matches(in: oldText, range: NSRange(oldText.startIndex..., in: oldText))
        guard max(newMatches.count, oldMatches.count) <= 2_000 else { return }
        let newWords = newMatches.map { (newText as NSString).substring(with: $0.range) }
        let oldWords = oldMatches.map { (oldText as NSString).substring(with: $0.range) }
        let ranges = newWords.difference(from: oldWords).compactMap { change -> NSRange? in
            if case .insert(let offset, _, _) = change, !newWords[offset].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return newMatches[offset].range
            }
            return nil
        }.sorted { $0.location < $1.location }
        var location = 0
        for node in nodes {
            let text = node.getWholeText() as NSString
            let nodeRange = NSRange(location: location, length: text.length)
            let intersections = ranges.map { NSIntersectionRange(nodeRange, $0) }.filter { $0.length > 0 }
            location += text.length
            guard !intersections.isEmpty else { continue }
            var cursor = 0
            for range in intersections {
                let local = NSRange(location: range.location - nodeRange.location, length: range.length)
                if local.location > cursor {
                    try node.before(TextNode(text.substring(with: NSRange(location: cursor, length: local.location - cursor)), ""))
                }
                let mark = Element(try Tag.valueOf("mark"), "")
                try mark.addClass("margined-word-change")
                try mark.text(text.substring(with: local))
                try node.before(mark)
                cursor = local.location + local.length
            }
            if cursor < text.length { try node.before(TextNode(text.substring(from: cursor), "")) }
            try node.remove()
        }
    }
}

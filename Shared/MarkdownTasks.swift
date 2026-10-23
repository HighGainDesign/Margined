import ApexC
import CcmarkGFM
import Foundation
import SwiftSoup

struct MarkdownTask: Equatable, Sendable {
    let id: Int
    let utf8Offset: Int
    let marker: UInt8
    let label: String
    var checked: Bool { marker != 32 }
}

/// cmark's source positions identify real list items, excluding code and prose.
/// The small marker matcher verifies the exact edit; it does not parse Markdown.
enum MarkdownTasks {
    static func attach(to document: Document, source: String) throws -> [MarkdownTask] {
        let inputs = try document.select("input[type=checkbox]").array()
        guard !inputs.isEmpty else { return [] }
        let bytes = Array(source.utf8)
        let starts = [0] + bytes.indices.filter { bytes[$0] == 10 }.map { $0 + 1 }
        // Use the same cmark math grammar as display rendering. Exact source
        // positions and marker-byte checks still gate every checklist write.
        guard let parser = cmark_parser_new(0), let ext = cmark_syntax_extension_new("margined-task-math") else { return [] }
        defer {
            cmark_parser_free(parser)
            cmark_syntax_extension_free(cmark_get_default_mem_allocator(), ext)
        }
        MathSyntax.install(on: ext, sourceBytes: source.utf8.count)
        _ = cmark_parser_attach_syntax_extension(parser, ext)
        source.withCString { cmark_parser_feed(parser, $0, bytes.count) }
        guard let root = cmark_parser_finish(parser) else { return [] }
        defer { cmark_node_free(root) }
        var candidates: [(Int, UInt8, String)] = []
        func visit(_ node: UnsafeMutablePointer<cmark_node>) throws {
            if cmark_node_get_type(node) == CMARK_NODE_ITEM {
                let line = Int(cmark_node_get_start_line(node)) - 1
                let column = Int(cmark_node_get_start_column(node)) - 1
                if starts.indices.contains(line) {
                    let end = line + 1 < starts.count ? starts[line + 1] : bytes.count
                    var offset = starts[line], visual = 0
                    while offset < end && visual < column {
                        visual += bytes[offset] == 9 ? 4 - visual % 4 : 1
                        offset += 1
                    }
                    let text = String(decoding: bytes[offset..<end], as: UTF8.self)
                    let pattern = #"^(?:[-+*]|[0-9]{1,9}[.)])[ \t]+\[([ xX])\](?=[ \t\r\n]|$)"#
                    if visual == column, let match = text.range(of: pattern, options: .regularExpression) {
                        let prefix = String(text[match])
                        let state = prefix.utf8.count - 2
                        // The match ends at ], so the state is the penultimate byte.
                        let markerOffset = offset + state
                        if bytes.indices.contains(markerOffset), let paragraph = cmark_node_first_child(node),
                           let html = cmark_render_html(paragraph, Int32(CMARK_OPT_UNSAFE), nil) {
                            defer { free(html) }
                            let label = try SwiftSoup.parseBodyFragment(String(cString: html)).text()
                            let cleaned = label.hasPrefix("[") && label.dropFirst(2).hasPrefix("]") ? String(label.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines) : ""
                            candidates.append((markerOffset, bytes[markerOffset], cleaned))
                        }
                    }
                }
            }
            var child = cmark_node_first_child(node)
            while let current = child { try visit(current); child = cmark_node_next(current) }
        }
        try visit(root)
        guard candidates.count == inputs.count else { return [] }
        var tasks: [MarkdownTask] = []
        for (index, input) in inputs.enumerated() {
            guard let parent = input.parent() else { return [] }
            guard let copy = try SwiftSoup.parseBodyFragment(parent.html()).body() else { return [] }
            try copy.select("ul, ol").remove()
            let label = try copy.text()
            let candidate = candidates[index]
            guard candidate.2.filter({ !$0.isWhitespace }) == label.filter({ !$0.isWhitespace }), input.hasAttr("checked") == (candidate.1 != 32) else { return [] }
            tasks.append(MarkdownTask(id: index, utf8Offset: candidate.0, marker: candidate.1, label: label))
        }
        // Attach only after every mapping has been validated.
        for (index, input) in inputs.enumerated() {
            try input.attr("data-margined-task", String(index))
            try input.attr("title", String(localized: "Click to save checkmarks in this file"))
        }
        return tasks
    }

    /// Changes only the marker bytes, preserving BOM, line endings and all text.
    static func patch(_ data: Data, expectedSource: String, task: MarkdownTask, checked: Bool) throws -> Data {
        try patch(data, expectedSource: expectedSource, task: task, marker: checked ? 120 : 32)
    }

    static func patch(_ data: Data, expectedSource: String, task: MarkdownTask, marker: UInt8) throws -> Data {
        guard [32, 88, 120].contains(marker) else { throw ChecklistError.changed }
        guard try MarkdownSource.decode(data) == expectedSource else { throw ChecklistError.changed }
        let bytes = Array(expectedSource.utf8)
        guard task.utf8Offset > 0, task.utf8Offset + 1 < bytes.count,
              bytes[task.utf8Offset - 1] == 91, bytes[task.utf8Offset + 1] == 93,
              bytes[task.utf8Offset] == task.marker,
              [32, 88, 120].contains(task.marker) else { throw ChecklistError.changed }
        let state = marker
        var updated = data
        if data.starts(with: [255, 254]) || data.starts(with: [254, 255]) {
            let prefix = String(decoding: bytes[..<task.utf8Offset], as: UTF8.self)
            let offset = 2 + prefix.utf16.count * 2
            guard offset + 1 < data.count else { throw ChecklistError.changed }
            if data.starts(with: [255, 254]) { updated[offset] = state; updated[offset + 1] = 0 }
            else { updated[offset] = 0; updated[offset + 1] = state }
        } else {
            let offset = task.utf8Offset + (data.starts(with: [239, 187, 191]) ? 3 : 0)
            guard updated.indices.contains(offset) else { throw ChecklistError.changed }
            updated[offset] = state
        }
        return updated
    }
}

enum ChecklistError: LocalizedError {
    case changed
    var errorDescription: String? {
        switch self {
        case .changed: String(localized: "The file changed before the checkbox could be saved. Margined refreshed it; please try again.")
        }
    }
}

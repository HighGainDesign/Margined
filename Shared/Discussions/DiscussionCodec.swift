import CcmarkGFM
import Foundation

/// cmark decides where comments exist. libyaml decides the payload grammar.
/// Neither an invalid payload nor a future version is discarded or repaired.
enum DiscussionCodec {
    static func parse(_ source: String) throws -> DiscussionDocument {
        guard source.utf8.count <= MarkdownSource.maximumBytes else { throw ReaderError.tooLarge }
        try Task.checkCancellation()
        guard source.contains("<!-- margined:thread") else { return DiscussionDocument(source: source, blocks: [], diagnostics: []) }
        let lines = DiscussionSourceLines(source)
        var input = lines.bytes
        // Frontmatter is not a Markdown discussion, even when its sample text
        // looks like a comment. Mask bytes, retaining all source line positions.
        if lines.text(0) == "---", let end = lines.ranges.indices.dropFirst().first(where: { ["---", "..."].contains(lines.text($0)) }) {
            for index in 0..<lines.ranges[end].upperBound where input[index] != 10 && input[index] != 13 { input[index] = 32 }
        }
        guard let parser = cmark_parser_new(0), let ext = cmark_syntax_extension_new("margined-discussions-math") else { throw ReaderError.rendererUnavailable }
        defer { cmark_parser_free(parser); cmark_syntax_extension_free(cmark_get_default_mem_allocator(), ext) }
        MathSyntax.install(on: ext, sourceBytes: input.count)
        _ = cmark_parser_attach_syntax_extension(parser, ext)
        String(decoding: input, as: UTF8.self).withCString { cmark_parser_feed(parser, $0, input.count) }
        guard let root = cmark_parser_finish(parser) else { throw ReaderError.rendererUnavailable }
        defer { cmark_node_free(root) }
        var blocks: [DiscussionBlock] = [], diagnostics: [DiscussionDiagnostic] = []
        var eventBudget = 200_000
        var child = cmark_node_first_child(root)
        while let node = child {
            defer { child = cmark_node_next(node) }
            guard cmark_node_get_type(node) == CMARK_NODE_HTML_BLOCK, cmark_node_get_start_column(node) == 1 else { continue }
            let line = Int(cmark_node_get_start_line(node)) - 1
            guard lines.ranges.indices.contains(line) else { continue }
            let opening = lines.text(line), marker = "<!-- margined:thread"
            guard opening == marker || opening.hasPrefix(marker + " ") else { continue }
            let version = String(opening.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            let start = lines.ranges[line].lowerBound
            // This pinned cmark finalizes a terminated HTML block with end_line
            // one line before its final literal line. Its parsed literal retains
            // that line; use its line count while retaining ORIGINAL source bytes.
            guard let literal = cmark_node_get_literal(node) else { continue }
            let parsedLiteral = String(cString: literal)
            let literalLines = parsedLiteral.split(separator: "\n", omittingEmptySubsequences: false).count - (parsedLiteral.hasSuffix("\n") ? 1 : 0)
            let lastLine = min(line + max(1, literalLines) - 1, lines.ranges.count - 1)
            let fragmentEnd = lines.ranges[lastLine].upperBound
            let raw = String(decoding: lines.bytes[start..<fragmentEnd], as: UTF8.self)
            let close = raw.range(of: "-->")
            let closeOffset = close.map { start + raw[..<$0.lowerBound].utf8.count }
            let upper = closeOffset.map { $0 + 3 } ?? fragmentEnd
            let closeLine = closeOffset.flatMap { offset in lines.index(containing: offset) }
            let bodyStart = lines.ranges[line].upperBound
            let bodyEnd = closeLine.map { lines.ranges[$0].lowerBound } ?? upper
            let body = bodyStart <= bodyEnd ? String(decoding: lines.bytes[bodyStart..<bodyEnd], as: UTF8.self) : ""
            let certain = closeLine.map { $0 > line && lines.text($0) == "-->" } == true && !body.contains("<!--") && !body.contains("--!>")
            var syntax: RestrictedYAML.Node?, thread: DiscussionThread?
            do {
                guard certain else { throw RestrictedYAML.Failure(line: 0, column: 1, message: "The discussion wrapper is incomplete or ambiguous. Inspect its source.") }
                guard opening == marker + " v1" else { throw RestrictedYAML.Failure(line: 0, column: 1, message: "Unsupported discussion format version.") }
                syntax = try RestrictedYAML.parse(body, eventBudget: &eventBudget)
                thread = try decodeThread(syntax!)
            } catch let error as RestrictedYAML.Failure {
                diagnostics.append(DiscussionDiagnostic(line: line + 1 + error.line, column: error.column, message: error.message))
            }
            blocks.append(DiscussionBlock(range: start..<upper, line: line + 1, version: version, hasCertainExtent: certain, thread: thread, syntax: syntax, yamlOffset: bodyStart))
        }
        // Even a syntactically readable but invalid thread can make an ID
        // ambiguous. Invalidate all affected blocks, leaving independent ones usable.
        var threadIDs: [String: Int] = [:], messageIDs: [String: Int] = [:]
        for block in blocks {
            if let id = block.syntax?["id"]?.string { threadIDs[id, default: 0] += 1 }
            for message in block.syntax?["messages"]?.items ?? [] {
                if let id = message["id"]?.string { messageIDs[id, default: 0] += 1 }
            }
        }
        blocks = blocks.map { block in
            let root = block.syntax
            let duplicateThread = root?["id"]?.string.map { threadIDs[$0, default: 0] > 1 } ?? false
            let duplicateMessage = (root?["messages"]?.items ?? []).contains { node in node["id"]?.string.map { messageIDs[$0, default: 0] > 1 } ?? false }
            guard duplicateThread || duplicateMessage else { return block }
            diagnostics.append(DiscussionDiagnostic(line: block.line, column: 1, message: "Duplicate discussion or message ID; this thread cannot be edited."))
            return DiscussionBlock(range: block.range, line: block.line, version: block.version, hasCertainExtent: block.hasCertainExtent, thread: nil, syntax: root, yamlOffset: block.yamlOffset)
        }
        return DiscussionDocument(source: source, blocks: blocks, diagnostics: diagnostics)
    }

    private static func invalid(_ node: RestrictedYAML.Node, _ message: String) -> RestrictedYAML.Failure {
        .init(line: node.line, column: node.column, message: message)
    }
    private static func field(_ key: String, in node: RestrictedYAML.Node, nonempty: Bool = false) throws -> String {
        guard let value = node[key], let string = value.string, !nonempty || !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw invalid(node, "Missing or invalid discussion field: \(key).")
        }
        return string
    }
    private static func id(_ node: RestrictedYAML.Node) throws -> String {
        let string = try field("id", in: node)
        guard validID(string) else { throw invalid(node["id"] ?? node, "Invalid discussion or message ID.") }
        return string
    }
    static func validID(_ string: String) -> Bool {
        (1...128).contains(string.utf8.count) && string.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [46, 95, 58, 45].contains($0) }
    }
    private static func date(_ key: String, in node: RestrictedYAML.Node) throws -> String {
        let string = try field(key, in: node)
        guard let value = node[key], case let .scalar(_, style) = value.value,
              style == .singleQuoted || style == .doubleQuoted, validDate(string) else {
            throw invalid(node[key] ?? node, "Discussion dates must be quoted RFC 3339 timestamps.")
        }
        return string
    }
    static func validDate(_ string: String) -> Bool {
        guard string.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:[Zz]|[+-][0-9]{2}:[0-9]{2})$"#, options: .regularExpression) != nil else { return false }
        // ISO8601DateFormatter normalizes invalid days and offsets. Validate
        // RFC3339's calendar/ranges before accepting the original literal.
        let bytes = Array(string.utf8)
        func number(_ start: Int, _ count: Int = 2) -> Int { bytes[start..<(start + count)].reduce(0) { $0 * 10 + Int($1 - 48) } }
        let year = number(0, 4), month = number(5), day = number(8)
        guard (1...12).contains(month), number(11) <= 23, number(14) <= 59, number(17) <= 60 else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...days[month - 1]).contains(day) else { return false }
        if bytes.last != 90 && bytes.last != 122 {
            guard number(bytes.count - 5) <= 23, number(bytes.count - 2) <= 59 else { return false }
        }
        return true
    }
    private static func target(_ node: RestrictedYAML.Node) throws -> DiscussionTarget {
        guard node.entries != nil, try field("type", in: node) == "TextQuoteSelector" else { throw invalid(node, "Expected a TextQuoteSelector target.") }
        return try DiscussionTarget(type: "TextQuoteSelector", exact: field("exact", in: node, nonempty: true), prefix: field("prefix", in: node), suffix: field("suffix", in: node), section: node["section"].map { _ in try field("section", in: node) })
    }
    private static func decodeThread(_ root: RestrictedYAML.Node) throws -> DiscussionThread {
        guard root.entries != nil, let state = try DiscussionThread.State(rawValue: field("state", in: root)),
              let targetNode = root["target"], let messages = root["messages"]?.items, !messages.isEmpty else { throw invalid(root, "Expected discussion state, target and a nonempty messages sequence.") }
        var seen = Set<String>(), result: [DiscussionMessage] = []
        for message in messages {
            let messageID = try id(message)
            let reply = try message["in-reply-to"].map { _ in try field("in-reply-to", in: message) }
            guard reply.map({ seen.contains($0) }) ?? true, seen.insert(messageID).inserted else { throw invalid(message, "Replies must refer to an earlier message in this thread; message IDs must be unique.") }
            result.append(try DiscussionMessage(id: messageID, author: field("author", in: message, nonempty: true), created: date("created", in: message), body: field("body", in: message), inReplyTo: reply))
        }
        let resolvedBy = try root["resolved-by"].map { _ in try field("resolved-by", in: root, nonempty: true) }
        let resolved = try root["resolved"].map { _ in try date("resolved", in: root) }
        guard state != .resolved || (resolvedBy != nil && resolved != nil) else { throw invalid(root, "A resolved discussion must include its author and date.") }
        var history: [DiscussionAttachment] = []
        if let value = root["attachment-history"] {
            guard let entries = value.items else { throw invalid(value, "Attachment history must be a sequence.") }
            for entry in entries {
                guard let oldTarget = entry["target"] else { throw invalid(entry, "An attachment history entry needs its old target.") }
                history.append(try DiscussionAttachment(target: target(oldTarget), author: field("author", in: entry, nonempty: true), created: date("created", in: entry)))
            }
        }
        return try DiscussionThread(id: id(root), state: state, target: target(targetNode), messages: result, resolvedBy: resolvedBy, resolved: resolved, attachmentHistory: history)
    }
}

/// Lines retain the original bytes, including CRLF and standalone CR separators.
struct DiscussionSourceLines {
    let bytes: [UInt8]
    let ranges: [Range<Int>]
    init(_ source: String) {
        bytes = Array(source.utf8)
        var lines: [Range<Int>] = [], start = 0, offset = 0
        while offset < bytes.count {
            if bytes[offset] == 10 || bytes[offset] == 13 {
                let crlf = bytes[offset] == 13 && offset + 1 < bytes.count && bytes[offset + 1] == 10
                offset += crlf ? 2 : 1; lines.append(start..<offset); start = offset
            } else { offset += 1 }
        }
        lines.append(start..<bytes.count); ranges = lines
    }
    func index(containing offset: Int) -> Int? {
        var lower = 0, upper = ranges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if ranges[middle].lowerBound <= offset { lower = middle + 1 } else { upper = middle }
        }
        return lower > 0 && ranges[lower - 1].contains(offset) ? lower - 1 : nil
    }
    func text(_ index: Int) -> String {
        guard ranges.indices.contains(index) else { return "" }
        var end = ranges[index].upperBound
        while end > ranges[index].lowerBound && [10, 13].contains(bytes[end - 1]) { end -= 1 }
        return String(decoding: bytes[ranges[index].lowerBound..<end], as: UTF8.self)
    }
}

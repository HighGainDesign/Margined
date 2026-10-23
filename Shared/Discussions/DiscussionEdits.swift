import Foundation

/// Produces edits against one exact decoded snapshot. The platform write gate
/// separately validates encoded bytes/identity before applying these splices.
enum DiscussionEdits {
    enum Failure: Error { case unavailableThread, invalidOperation, invalidResult, overlappingEdits }

    static func splices(for operation: DiscussionOperation, in document: DiscussionDocument) throws -> [MarkdownSourceSplice] {
        let source = document.source, bytes = Array(source.utf8)
        let newline = source.contains("\r\n") ? "\r\n" : source.contains("\r") && !source.contains("\n") ? "\r" : "\n"
        var edits: [MarkdownSourceSplice] = []
        var expectedIDs = Set(document.threads.map(\.id))
        switch operation {
        case let .newThread(thread):
            guard !document.blocks.contains(where: { !$0.hasCertainExtent }), !expectedIDs.contains(thread.id) else { throw Failure.invalidOperation }
            let separator = source.isEmpty ? "" : source.hasSuffix(newline + newline) ? "" : source.hasSuffix(newline) ? newline : newline + newline
            let content = "<!-- margined:thread v1" + newline + render(thread, newline: newline) + "-->" + newline
            edits.append(.init(range: bytes.count..<bytes.count, replacement: separator + content))
            expectedIDs.insert(thread.id)
        default:
            let threadID: String
            switch operation {
            case let .reply(id, _, _), let .resolve(id, _, _), let .reopen(id), let .reattach(id, _, _, _): threadID = id
            case .newThread: throw Failure.invalidOperation
            }
            guard let block = document.blocks.first(where: { $0.thread?.id == threadID }), let thread = block.thread, let root = block.syntax else { throw Failure.unavailableThread }
            let editor = Editor(source: source, offset: block.yamlOffset, newline: newline)
            switch operation {
            case let .reply(_, message, reopen):
                guard !thread.messages.contains(where: { $0.id == message.id }), message.inReplyTo.map({ id in thread.messages.contains { $0.id == id } }) ?? true,
                      thread.state != .resolved || reopen, let messages = root["messages"] else { throw Failure.invalidOperation }
                edits += try editor.append(to: messages, block: { indent in renderMessage(message, indent: indent, newline: newline) }, flow: renderMessageFlow(message))
                if thread.state == .resolved {
                    edits += try editor.set("state", in: root, scalar: "open")
                    edits += try editor.remove(["resolved-by", "resolved"], from: root)
                }
            case let .resolve(_, author, created):
                guard !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, DiscussionCodec.validDate(created) else { throw Failure.invalidOperation }
                edits += try editor.set("state", in: root, scalar: "resolved")
                edits += try editor.set("resolved-by", in: root, scalar: author)
                edits += try editor.set("resolved", in: root, scalar: created)
            case .reopen:
                edits += try editor.set("state", in: root, scalar: "open")
                edits += try editor.remove(["resolved-by", "resolved"], from: root)
            case let .reattach(_, target, author, created):
                guard target.type == "TextQuoteSelector", !target.exact.isEmpty,
                      !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, DiscussionCodec.validDate(created), let old = root["target"] else { throw Failure.invalidOperation }
                for (key, value) in [("type", target.type), ("exact", target.exact), ("prefix", target.prefix), ("suffix", target.suffix)] { edits += try editor.set(key, in: old, scalar: value) }
                if let section = target.section { edits += try editor.set("section", in: old, scalar: section) }
                else { edits += try editor.remove(["section"], from: old) }
                let oldTarget = flow(old)
                let historyFlow = "{target: \(oldTarget), author: \(quote(author)), created: \(quote(created))}"
                func history(_ indent: Int) -> String {
                    let spaces = String(repeating: " ", count: indent)
                    return spaces + "- target: " + oldTarget + newline + spaces + "  author: " + quote(author) + newline + spaces + "  created: " + quote(created) + newline
                }
                if let entries = root["attachment-history"] { edits += try editor.append(to: entries, block: history, flow: historyFlow) }
                else { edits += try editor.insert("attachment-history", into: root, blockValue: newline + history(2), flowValue: "[" + historyFlow + "]") }
            case .newThread: throw Failure.invalidOperation
            }
        }
        // Combine equal insertion points in operation order and reject any
        // overlap before exposing edits. Reparse the result through the SAME
        // format boundary; a duplicate ID can invalidate an existing thread too.
        var combined = edits.filter { !$0.range.isEmpty }
        var insertions: [(Int, String)] = []
        for edit in edits where edit.range.isEmpty {
            if let index = insertions.firstIndex(where: { $0.0 == edit.range.lowerBound }) {
                insertions[index].1 += edit.replacement
            } else { insertions.append((edit.range.lowerBound, edit.replacement)) }
        }
        // An insertion at the start of a removed resolution field MUST be one
        // splice with that removal. Otherwise equally valid sort orders can
        // remove part of the new reply instead of the original field.
        for (point, text) in insertions {
            if let index = combined.firstIndex(where: { $0.range.lowerBound == point }) {
                combined[index] = .init(range: combined[index].range, replacement: text + combined[index].replacement)
            } else if let index = combined.firstIndex(where: { $0.range.upperBound == point }) {
                combined[index] = .init(range: combined[index].range, replacement: combined[index].replacement + text)
            } else { combined.append(.init(range: point..<point, replacement: text)) }
        }
        combined.sort { $0.range.lowerBound < $1.range.lowerBound }
        var lastEnd = 0, updated = bytes
        for edit in combined {
            guard edit.range.lowerBound >= lastEnd, edit.range.upperBound <= bytes.count else { throw Failure.overlappingEdits }
            lastEnd = edit.range.upperBound
        }
        for edit in combined.reversed() { updated.replaceSubrange(edit.range, with: edit.replacement.utf8) }
        guard let candidateSource = String(bytes: updated, encoding: .utf8) else { throw Failure.invalidResult }
        let candidate = try DiscussionCodec.parse(candidateSource)
        guard Set(candidate.threads.map(\.id)) == expectedIDs, candidate.diagnostics.count <= document.diagnostics.count else { throw Failure.invalidResult }
        return combined
    }

    /// JSON-compatible quoted scalars are also YAML strings. Escape Unicode
    /// line separators and all angle brackets when a comment delimiter occurs.
    static func quote(_ string: String) -> String {
        let protect = ["<!--", "-->", "--!>"].contains { string.contains($0) }
        var value = "\""
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 34: value += "\\\""
            case 92: value += "\\\\"
            case 10: value += "\\n"
            case 13: value += "\\r"
            case 9: value += "\\t"
            case 0...31, 127, 133, 0x2028, 0x2029: value += String(format: "\\u%04x", scalar.value)
            case 60 where protect: value += "\\u003c"
            case 62 where protect: value += "\\u003e"
            default: value.unicodeScalars.append(scalar)
            }
        }
        return value + "\""
    }
    private static func flow(_ node: RestrictedYAML.Node) -> String {
        switch node.value {
        case let .scalar(string, _): quote(string)
        case let .sequence(items, _): "[" + items.map(flow).joined(separator: ", ") + "]"
        case let .mapping(entries, _): "{" + entries.map { quote($0.key.string!) + ": " + flow($0.value) }.joined(separator: ", ") + "}"
        }
    }
    private static func renderTarget(_ target: DiscussionTarget) -> String {
        let fields = [("type", target.type), ("exact", target.exact), ("prefix", target.prefix), ("suffix", target.suffix)] + (target.section.map { [("section", $0)] } ?? [])
        return "{" + fields.map { $0.0 + ": " + quote($0.1) }.joined(separator: ", ") + "}"
    }
    private static func renderMessageFlow(_ message: DiscussionMessage) -> String {
        var fields = [("id", message.id), ("author", message.author), ("created", message.created), ("body", message.body)]
        if let reply = message.inReplyTo { fields.append(("in-reply-to", reply)) }
        return "{" + fields.map { $0.0 + ": " + quote($0.1) }.joined(separator: ", ") + "}"
    }
    private static func renderMessage(_ message: DiscussionMessage, indent: Int, newline: String) -> String {
        let spaces = String(repeating: " ", count: indent)
        var result = spaces + "- id: " + quote(message.id) + newline + spaces + "  author: " + quote(message.author) + newline + spaces + "  created: " + quote(message.created) + newline
        if let reply = message.inReplyTo { result += spaces + "  in-reply-to: " + quote(reply) + newline }
        let body = message.body
        if body.isEmpty || body.contains("\r") || body.trimmingCharacters(in: .newlines).isEmpty || ["<!--", "-->", "--!>"].contains(where: body.contains) || body.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 10 && $0.value != 9 || [133, 0x2028, 0x2029].contains($0.value) }) {
            result += spaces + "  body: " + quote(body) + newline
        } else {
            let trailing = body.reversed().prefix { $0 == "\n" }.count
            var lines = body.components(separatedBy: "\n")
            if trailing > 0 { lines.removeLast() }
            let explicitIndent = lines.first(where: { !$0.isEmpty })?.first?.isWhitespace == true ? "2" : ""
            let chomp = trailing == 0 ? "-" : trailing == 1 ? "" : "+"
            result += spaces + "  body: |" + explicitIndent + chomp + newline
            result += lines.map { spaces + "    " + $0 + newline }.joined()
        }
        return result
    }
    private static func render(_ thread: DiscussionThread, newline: String) -> String {
        var result = "id: " + quote(thread.id) + newline + "state: " + thread.state.rawValue + newline
        if let author = thread.resolvedBy { result += "resolved-by: " + quote(author) + newline }
        if let date = thread.resolved { result += "resolved: " + quote(date) + newline }
        result += "target: " + renderTarget(thread.target) + newline + "messages:" + newline
        result += thread.messages.map { renderMessage($0, indent: 2, newline: newline) }.joined()
        if !thread.attachmentHistory.isEmpty {
            result += "attachment-history:" + newline
            for entry in thread.attachmentHistory {
                result += "  - target: " + renderTarget(entry.target) + newline + "    author: " + quote(entry.author) + newline + "    created: " + quote(entry.created) + newline
            }
        }
        return result
    }

    private final class Editor {
        let bytes: [UInt8]
        let offset: Int
        let newline: String
        private var flowInsertionPoints = Set<Int>()
        init(source: String, offset: Int, newline: String) {
            self.bytes = Array(source.utf8); self.offset = offset; self.newline = newline
        }
        func absolute(_ range: Range<Int>) -> Range<Int> { (offset + range.lowerBound)..<(offset + range.upperBound) }
        func set(_ key: String, in node: RestrictedYAML.Node, scalar: String) throws -> [MarkdownSourceSplice] {
            if let value = node[key] {
                var replacement = quote(scalar)
                if case let .scalar(_, style) = value.value {
                    if style == .plain && ["open", "resolved"].contains(scalar) { replacement = scalar }
                    if style == .literal || style == .folded { replacement += newline }
                }
                return [.init(range: absolute(value.range), replacement: replacement)]
            }
            return try insert(key, into: node, blockValue: quote(scalar) + newline, flowValue: quote(scalar))
        }
        func insert(_ key: String, into node: RestrictedYAML.Node, blockValue: String, flowValue: String) throws -> [MarkdownSourceSplice] {
            guard case let .mapping(entries, isFlow) = node.value else { throw Failure.invalidOperation }
            let point = offset + node.range.upperBound - (isFlow ? 1 : 0)
            let value: String
            if isFlow { value = try separator(after: entries.last?.value, before: point) + quote(key) + ": " + flowValue }
            else {
                let prefix = point > 0 && ![10, 13].contains(bytes[point - 1]) ? newline : ""
                value = prefix + String(repeating: " ", count: node.column - 1) + key + ": " + blockValue
            }
            return [.init(range: point..<point, replacement: value)]
        }
        func append(to node: RestrictedYAML.Node, block: (Int) -> String, flow: String) throws -> [MarkdownSourceSplice] {
            guard case let .sequence(items, isFlow) = node.value else { throw Failure.invalidOperation }
            let point = offset + node.range.upperBound - (isFlow ? 1 : 0)
            let value = isFlow ? try separator(after: items.last, before: point) + flow : (point > 0 && ![10, 13].contains(bytes[point - 1]) ? newline : "") + block(node.column - 1)
            return [.init(range: point..<point, replacement: value)]
        }
        private func separator(after last: RestrictedYAML.Node?, before point: Int) throws -> String {
            if !flowInsertionPoints.insert(point).inserted { return ", " }
            guard let last else { return "" }
            var comment = false, comma = false
            for byte in bytes[(offset + last.range.upperBound)..<point] {
                if byte == 10 || byte == 13 { comment = false; continue }
                if comment { continue }
                if byte == 35 { comment = true; continue }
                if byte == 44 { guard !comma else { throw Failure.invalidOperation }; comma = true; continue }
                guard byte == 32 || byte == 9 else { throw Failure.invalidOperation }
            }
            return comma ? " " : ", "
        }
        func remove(_ keys: Set<String>, from node: RestrictedYAML.Node) throws -> [MarkdownSourceSplice] {
            guard case let .mapping(entries, isFlow) = node.value else { throw Failure.invalidOperation }
            var result: [MarkdownSourceSplice] = [], index = 0
            while index < entries.count {
                guard keys.contains(entries[index].key.string!) else { index += 1; continue }
                let first = index
                while index + 1 < entries.count && keys.contains(entries[index + 1].key.string!) { index += 1 }
                let last = index
                var start = offset + entries[first].key.range.lowerBound
                var end = offset + entries[last].value.range.upperBound
                if isFlow {
                    if last + 1 < entries.count { end = offset + entries[last + 1].key.range.lowerBound }
                    else if first > 0 { start = offset + entries[first - 1].value.range.upperBound }
                } else {
                    while start > 0 && ![10, 13].contains(bytes[start - 1]) { start -= 1 }
                    if end > 0 && ![10, 13].contains(bytes[end - 1]) {
                        while end < bytes.count && ![10, 13].contains(bytes[end]) { end += 1 }
                        if end < bytes.count && bytes[end] == 13 { end += 1 }
                        if end < bytes.count && bytes[end] == 10 { end += 1 }
                    }
                }
                result.append(.init(range: start..<end, replacement: "")); index += 1
            }
            return result
        }
    }
}

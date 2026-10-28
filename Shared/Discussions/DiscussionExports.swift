import Foundation

enum DiscussionExports {
    struct CleanCopy: Sendable { let data: Data; let removedBlocks: Int }
    enum Failure: LocalizedError {
        case uncertainWrapper
        var errorDescription: String? { String(localized: "A discussion block has an uncertain boundary. Inspect its source before exporting a clean copy.") }
    }
    static func cleanCopy(_ data: Data) throws -> CleanCopy {
        let source = try MarkdownSource.decode(data), document = try DiscussionCodec.parse(source)
        guard document.blocks.allSatisfy(\.hasCertainExtent) else { throw Failure.uncertainWrapper }
        let edits = document.blocks.map { MarkdownSourceSplice(range: $0.range, replacement: "") }
        return CleanCopy(data: try MarkdownSourceEdits.apply(edits, to: data, expectedSource: source), removedBlocks: edits.count)
    }
    static func conversation(_ document: DiscussionDocument) -> String {
        var result = "# Discussions\n"
        for (index, block) in document.blocks.enumerated() {
            result += "\n## Discussion \(index + 1)\n\n"
            guard let thread = block.thread else {
                result += "Unavailable discussion at source line \(block.line). Inspect the original source.\n\n"
                let raw = String(decoding: Array(document.source.utf8)[block.range], as: UTF8.self)
                result += quoted(raw) + "\n"
                continue
            }
            result += "ID: " + literal(thread.id) + " · " + (thread.state == .open ? "Open" : "Resolved") + "\n\n" + quoted(thread.target.exact) + "\n"
            if let author = thread.resolvedBy, let date = thread.resolved { result += "Resolved by " + literal(author) + " · " + literal(date) + "\n\n" }
            for message in thread.messages {
                result += "### " + literal(message.author) + " · " + literal(message.created) + "\n\n"
                result += "Message: " + literal(message.id)
                if let reply = message.inReplyTo { result += " · Reply to " + literal(reply) }
                result += "\n\n" + literal(message.body) + "\n\n"
            }
        }
        return result
    }
    private static func quoted(_ text: String) -> String {
        literal(text).components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n") + "\n"
    }
    private static func literal(_ text: String) -> String {
        let punctuation: Set<Character> = ["\\", "`", "*", "_", "{", "}", "[", "]", "(", ")", "#", "+", "!", "|", "~"]
        var result = ""
        for character in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            default:
                if punctuation.contains(character) { result += "\\" }
                result.append(character)
            }
        }
        return result
    }
}

import Foundation

struct DiscussionDiagnostic: Equatable, Sendable {
    let line: Int
    let column: Int
    let message: String
}

struct DiscussionTarget: Equatable, Sendable {
    let type: String
    let exact: String
    let prefix: String
    let suffix: String
    let section: String?
}

struct DiscussionMessage: Equatable, Sendable {
    let id: String
    let author: String
    let created: String
    let body: String
    let inReplyTo: String?
}

struct DiscussionAttachment: Equatable, Sendable {
    let target: DiscussionTarget
    let author: String
    let created: String
}

struct DiscussionThread: Equatable, Sendable {
    enum State: String, Sendable { case open, resolved }
    let id: String
    let state: State
    let target: DiscussionTarget
    let messages: [DiscussionMessage]
    let resolvedBy: String?
    let resolved: String?
    let attachmentHistory: [DiscussionAttachment]
}

struct DiscussionBlock: Sendable {
    /// UTF-8 offsets in the original decoded source, never encoded-file offsets.
    let range: Range<Int>
    let line: Int
    let version: String
    /// Independent of YAML validity. False prevents a purported clean export.
    let hasCertainExtent: Bool
    let thread: DiscussionThread?
    let syntax: RestrictedYAML.Node?
    let yamlOffset: Int
}

struct DiscussionDocument: Sendable {
    let source: String
    let blocks: [DiscussionBlock]
    let diagnostics: [DiscussionDiagnostic]
    var threads: [DiscussionThread] { blocks.compactMap(\.thread) }

    /// Mask parsed comment bytes only for reading. Original ranges/data remain
    /// available for diagnostics and edits; uncertain wrappers still block a
    /// Clean Copy. Keeping byte/line positions preserves checklist provenance.
    var readingSource: String { maskedSource(includeUncertain: false) }
    var wordCountSource: String { maskedSource(includeUncertain: true) }

    private func maskedSource(includeUncertain: Bool) -> String {
        let masked = blocks.filter { includeUncertain || $0.hasCertainExtent }
        guard !masked.isEmpty else { return source }
        var bytes = Array(source.utf8)
        for block in masked {
            for index in block.range where bytes[index] != 10 && bytes[index] != 13 { bytes[index] = 32 }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

struct MarkdownSourceSplice: Equatable, Sendable {
    let range: Range<Int>
    let replacement: String
}

enum DiscussionOperation: Sendable {
    case newThread(DiscussionThread)
    case reply(threadID: String, message: DiscussionMessage, reopenResolved: Bool)
    case resolve(threadID: String, author: String, created: String)
    case reopen(threadID: String)
    case reattach(threadID: String, target: DiscussionTarget, author: String, created: String)
}

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

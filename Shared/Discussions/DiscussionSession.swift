import Foundation
import CryptoKit
import Observation

/// Unsaved discussion text belongs to the open document, not its current inspector.
@MainActor @Observable
final class DiscussionSession {
    enum DraftKey: Hashable, Sendable { case new(UUID), thread(String) }
    enum ResolveChoice: Equatable { case keepOpen, discardDraft, postDraft }
    enum Filter: String, Sendable { case all, open, resolved, unattached }
    struct Draft: Sendable {
        var body: String
        let target: DiscussionTarget?
        let inReplyTo: String?
        let revision: UUID
    }
    struct Pending: Sendable {
        enum Kind: Sendable { case post, state, importDiscussions, undo, redo }
        let kind: Kind
        let id: UUID
        let key: DraftKey
        let revision: UUID
        let expected: SourceFileEdit.Snapshot
        let replacement: Data
        let threadID: String
        let messageID: String?
    }
    enum Failure: LocalizedError, Equatable {
        case unavailable, passageChanged, alreadySaved, displayNameRequired, savedCopyRequired, reopenRequired, busy, staleSource, emptyDraft
        var errorDescription: String? {
            switch self {
            case .passageChanged: String(localized: "The selected passage changed. Choose its location again before posting.")
            case .unavailable: String(localized: "This discussion can’t be edited in the current file.")
            case .alreadySaved: String(localized: "This reply is already in the reloaded file. Keep the saved reply or edit your draft to post another.")
            case .displayNameRequired: String(localized: "Choose a name to store with your comments and replies.")
            case .savedCopyRequired: String(localized: "Save a Markdown copy to add discussions to this document.")
            case .reopenRequired: String(localized: "Posting this reply will reopen the resolved discussion. Confirm to continue.")
            case .busy: String(localized: "A save is in progress. Wait for it to finish.")
            case .staleSource: String(localized: "The file changed. Reload it, then review your draft and post again.")
            case .emptyDraft: String(localized: "Write a comment or reply before posting.")
            }
        }
    }

    @ObservationIgnored private let historyByteLimit: Int
    init(historyByteLimit: Int = 32 * 1_024 * 1_024) {
        self.historyByteLimit = max(1, historyByteLimit)
    }

    var displayName = ""
    var visible = false
    var filter: Filter = .open
    var selection: DraftKey?
    private(set) var drafts: [DraftKey: Draft] = [:]
    private(set) var pending: Pending?
    private(set) var saveError: String?
    private struct DraftOrigin {
        let trackingID: String
        var projection: DiscussionTextProjection
    }
    private var origins: [DraftKey: DraftOrigin] = [:]
    private var postedThreads: [DraftKey: String] = [:]
    private struct FailedAttempt { let threadID: String; let messageID: String }
    private var failedAttempts: [DraftKey: FailedAttempt] = [:]
    private struct History { let before: Data; let after: Data; let threadID: String }
    private var undo: [History] = []
    private var redo: [History] = []
    private var historySnapshot: SourceFileEdit.Snapshot?
    var hasUnpostedDrafts: Bool { drafts.values.contains { !$0.body.isEmpty } }

    func beginDraft(_ selected: DiscussionSelection, in projection: DiscussionTextProjection) throws -> DraftKey {
        guard selected.sourceID == projection.sourceID,
              projection.selection(selected.range, renderID: selected.renderID) == selected else { throw Failure.unavailable }
        let uuid = UUID(), key = DraftKey.new(uuid), trackingID = "draft-" + uuid.uuidString
        var tracked = Self.projection(projection, target: selected.target, trackingID: trackingID)
        tracked.anchorResults[trackingID] = .init(status: .attached, range: selected.range,
            candidates: [selected.range], originSourceID: projection.sourceID)
        origins[key] = DraftOrigin(trackingID: trackingID, projection: tracked)
        setDraft("", for: key, target: selected.target)
        selection = key; visible = true
        return key
    }

    /// Keep deletion/ambiguity evidence even across several refreshes while the
    /// composer is hidden. A new equal quotation never proves the old origin.
    func acceptProjection(_ projection: DiscussionTextProjection) {
        for (key, origin) in origins {
            guard let target = drafts[key]?.target else { continue }
            let id = origin.trackingID
            let thread = DiscussionThread(id: id, state: .open, target: target, messages: [],
                resolvedBy: nil, resolved: nil, attachmentHistory: [])
            let document = DiscussionDocument(source: "", blocks: [.init(range: 0..<0, line: 1,
                version: "v1", hasCertainExtent: true, thread: thread, syntax: nil, yamlOffset: 0)], diagnostics: [])
            var current = Self.projection(projection, target: target, trackingID: id)
            current.anchorResults = DiscussionAnchors.resolve(document: document, current: current, previous: origin.projection)
            origins[key] = DraftOrigin(trackingID: id, projection: current)
        }
    }
    func draftAnchor(for key: DraftKey) -> DiscussionAnchorResult? {
        guard let origin = origins[key] else { return nil }
        return origin.projection.anchorResults[origin.trackingID]
    }
    private static func projection(_ value: DiscussionTextProjection, target: DiscussionTarget, trackingID: String) -> DiscussionTextProjection {
        DiscussionTextProjection(text: value.text, sourceID: value.sourceID, units: value.units,
            barriers: value.barriers, targets: [trackingID: target])
    }
    private func currentTarget(for key: DraftKey, draft: Draft, source: String) throws -> DiscussionTarget {
        guard let target = draft.target else { throw Failure.unavailable }
        guard let origin = origins[key] else { return target }
        let sourceID = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        guard sourceID == origin.projection.sourceID else { throw Failure.staleSource }
        guard let anchor = origin.projection.anchorResults[origin.trackingID], anchor.status == .attached,
              let range = anchor.range, let selected = origin.projection.selection(range, renderID: "draft") else {
            throw Failure.passageChanged
        }
        return selected.target
    }

    func setDraft(_ body: String, for key: DraftKey, target: DiscussionTarget? = nil, inReplyTo: String? = nil) {
        drafts[key] = Draft(body: body, target: target ?? drafts[key]?.target, inReplyTo: inReplyTo ?? drafts[key]?.inReplyTo, revision: UUID())
    }
    func preparePost(in document: DiscussionDocument, snapshot: SourceFileEdit.Snapshot?, reopenResolved: Bool = false) throws -> Pending {
        guard pending == nil else { throw Failure.busy }
        let author = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !author.isEmpty else { throw Failure.displayNameRequired }
        guard let snapshot else { throw Failure.savedCopyRequired }
        guard try snapshot.source.utf8.elementsEqual(document.source.utf8) else { throw Failure.staleSource }
        guard let key = selection, let draft = drafts[key], !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.emptyDraft }
        if let attempted = failedAttempts[key],
           let thread = document.threads.first(where: { $0.id == attempted.threadID }),
           let message = thread.messages.first(where: { $0.id == attempted.messageID }) {
            postedThreads[key] = thread.id
            guard !message.body.utf8.elementsEqual(draft.body.utf8) else { throw Failure.alreadySaved }
        }
        let date = ISO8601DateFormatter().string(from: Date())
        let message = DiscussionMessage(id: "m-" + UUID().uuidString.lowercased(), author: author, created: date, body: draft.body, inReplyTo: draft.inReplyTo)
        let operation: DiscussionOperation
        let threadID: String
        switch key {
        case .new where postedThreads[key] == nil:
            let target = try currentTarget(for: key, draft: draft, source: document.source)
            threadID = "t-" + UUID().uuidString.lowercased()
            operation = .newThread(DiscussionThread(id: threadID, state: .open, target: target, messages: [message], resolvedBy: nil, resolved: nil, attachmentHistory: []))
        default:
            if case let .thread(id) = key { threadID = id }
            else if let id = postedThreads[key] { threadID = id }
            else { throw Failure.unavailable }
            guard let thread = document.threads.first(where: { $0.id == threadID }) else { throw Failure.unavailable }
            guard thread.state != .resolved || reopenResolved else { throw Failure.reopenRequired }
            operation = .reply(threadID: threadID, message: message, reopenResolved: reopenResolved)
        }
        let splices = try DiscussionEdits.splices(for: operation, in: document)
        let replacement = try MarkdownSourceEdits.apply(splices, to: snapshot.data, expectedSource: document.source)
        let value = Pending(kind: .post, id: UUID(), key: key, revision: draft.revision, expected: snapshot, replacement: replacement, threadID: threadID, messageID: message.id)
        pending = value; saveError = nil
        return value
    }
    func saved(_ operation: Pending, as snapshot: SourceFileEdit.Snapshot) throws {
        guard pending?.id == operation.id, snapshot.url == operation.expected.url,
              snapshot.data == operation.replacement else { throw Failure.staleSource }
        switch operation.kind {
        case .post, .state, .importDiscussions:
            if let historySnapshot, historySnapshot != operation.expected { undo.removeAll() }
            undo.append(History(before: operation.expected.data, after: snapshot.data, threadID: operation.threadID))
            // Keep at least the latest edit; one record is bounded by the
            // source-size limit. Older snapshots share a finite memory budget.
            while undo.count > 1 && (undo.count > 100 || undo.reduce(0, { $0 + $1.before.count + $1.after.count }) > historyByteLimit) {
                undo.removeFirst()
            }
            redo.removeAll()
            if operation.kind != .importDiscussions {
                postedThreads[operation.key] = operation.threadID
                failedAttempts[operation.key] = nil
                origins[operation.key] = nil
                if drafts[operation.key]?.revision == operation.revision { drafts[operation.key] = nil }
            }
        case .undo:
            guard let item = undo.popLast() else { throw Failure.staleSource }; redo.append(item)
        case .redo:
            guard let item = redo.popLast() else { throw Failure.staleSource }; undo.append(item)
        }
        historySnapshot = snapshot
        pending = nil; saveError = nil
    }
    func failed(_ operation: Pending, error: Error) {
        guard pending?.id == operation.id else { return }
        if let messageID = operation.messageID { failedAttempts[operation.key] = FailedAttempt(threadID: operation.threadID, messageID: messageID) }
        pending = nil; saveError = error.localizedDescription
    }
    func discardDrafts() {
        guard pending == nil else { return }
        drafts.removeAll(); origins.removeAll(); failedAttempts.removeAll(); postedThreads.removeAll()
    }
    func discardDraft(for key: DraftKey) {
        guard pending?.key != key else { return }
        drafts[key] = nil; origins[key] = nil; failedAttempts[key] = nil
    }
    func resetDocument() {
        drafts.removeAll(); origins.removeAll(); failedAttempts.removeAll(); postedThreads.removeAll()
        undo.removeAll(); redo.removeAll(); historySnapshot = nil
        pending = nil; saveError = nil; selection = nil; visible = false
    }
    func canUndo(snapshot: SourceFileEdit.Snapshot?) -> Bool {
        guard pending == nil, let snapshot, historySnapshot == snapshot, let item = undo.last else { return false }
        return item.after == snapshot.data
    }
    func canRedo(snapshot: SourceFileEdit.Snapshot?) -> Bool {
        guard pending == nil, let snapshot, historySnapshot == snapshot, let item = redo.last else { return false }
        return item.before == snapshot.data
    }
    func prepareResolve(threadID: String, in document: DiscussionDocument, snapshot: SourceFileEdit.Snapshot?, choice: ResolveChoice) throws -> Pending? {
        guard pending == nil else { throw Failure.busy }
        if choice == .keepOpen { return nil }
        let author = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !author.isEmpty else { throw Failure.displayNameRequired }
        guard let snapshot else { throw Failure.savedCopyRequired }
        guard try snapshot.source.utf8.elementsEqual(document.source.utf8) else { throw Failure.staleSource }
        let key = DraftKey.thread(threadID), draft = drafts[key]
        if choice == .postDraft, let draft, !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let priorSelection = selection
            selection = key
            defer { selection = priorSelection }
            let post = try preparePost(in: document, snapshot: snapshot)
            do {
                let postedSource = try MarkdownSource.decode(post.replacement), posted = try DiscussionCodec.parse(postedSource)
                let resolve = DiscussionOperation.resolve(threadID: threadID, author: author, created: ISO8601DateFormatter().string(from: Date()))
                let edits = try DiscussionEdits.splices(for: resolve, in: posted)
                let replacement = try MarkdownSourceEdits.apply(edits, to: post.replacement, expectedSource: postedSource)
                let value = Pending(kind: .state, id: post.id, key: key, revision: post.revision, expected: snapshot, replacement: replacement, threadID: threadID, messageID: post.messageID)
                pending = value
                return value
            } catch { pending = nil; throw error }
        }
        let operation = DiscussionOperation.resolve(threadID: threadID, author: author, created: ISO8601DateFormatter().string(from: Date()))
        let replacement = try MarkdownSourceEdits.apply(DiscussionEdits.splices(for: operation, in: document), to: snapshot.data, expectedSource: document.source)
        let value = Pending(kind: .state, id: UUID(), key: key, revision: draft?.revision ?? UUID(), expected: snapshot, replacement: replacement, threadID: threadID, messageID: nil)
        pending = value; saveError = nil
        return value
    }
    func prepareImport(_ preview: DiscussionImportPreview, snapshot: SourceFileEdit.Snapshot?,
                       choices: [String: DiscussionReconciliation.Choice] = [:]) throws -> Pending? {
        guard pending == nil else { throw Failure.busy }
        guard let snapshot else { throw Failure.savedCopyRequired }
        guard try snapshot.source.utf8.elementsEqual(preview.current.source.utf8) else { throw Failure.staleSource }
        let edits = try DiscussionReconciliation.splices(for: preview, in: preview.current, choices: choices)
        guard !edits.isEmpty else { saveError = nil; return nil }
        let replacement = try MarkdownSourceEdits.apply(edits, to: snapshot.data, expectedSource: preview.current.source)
        let threadID = preview.items.first { $0.kind != .duplicate && choices[$0.id] != .keepCurrent }?.id ?? "import"
        let value = Pending(kind: .importDiscussions, id: UUID(), key: .new(UUID()), revision: UUID(), expected: snapshot,
                            replacement: replacement, threadID: threadID, messageID: nil)
        pending = value; saveError = nil
        return value
    }
    func prepareUndo(snapshot: SourceFileEdit.Snapshot) throws -> Pending {
        guard pending == nil else { throw Failure.busy }
        guard historySnapshot == snapshot, let item = undo.last, item.after == snapshot.data else { throw Failure.staleSource }
        let value = Pending(kind: .undo, id: UUID(), key: .thread(item.threadID), revision: UUID(), expected: snapshot, replacement: item.before, threadID: item.threadID, messageID: nil)
        pending = value; saveError = nil
        return value
    }
    func prepareRedo(snapshot: SourceFileEdit.Snapshot) throws -> Pending {
        guard pending == nil else { throw Failure.busy }
        guard historySnapshot == snapshot, let item = redo.last, item.before == snapshot.data else { throw Failure.staleSource }
        let value = Pending(kind: .redo, id: UUID(), key: .thread(item.threadID), revision: UUID(), expected: snapshot, replacement: item.after, threadID: item.threadID, messageID: nil)
        pending = value; saveError = nil
        return value
    }
}

import Foundation

struct DiscussionImportPreview: Sendable {
    struct Item: Identifiable, Sendable {
        enum Kind: Equatable, Sendable { case newThread, replies, duplicate, conflict }
        enum Reason: Equatable, Sendable { case rootChanged, messageChanged, idCollision, unavailableCurrent }
        let id: String
        let kind: Kind
        let addedMessageIDs: [String]
        let reasons: [Reason]
    }
    let current: DiscussionDocument
    let incoming: DiscussionDocument
    let items: [Item]
}

enum DiscussionReconciliation {
    enum Choice: Equatable, Sendable { case keepCurrent, useIncoming, keepSeparate }
    enum Failure: LocalizedError, Equatable {
        case conflictNeedsChoice, staleSource, invalidImport, idExhausted
        var errorDescription: String? {
            switch self {
            case .conflictNeedsChoice: String(localized: "Choose how to handle each conflicting discussion before importing.")
            case .staleSource: String(localized: "The document changed. Review the other copy again before importing.")
            case .invalidImport: String(localized: "These discussions can’t be combined safely. Keep the current version or keep a separate discussion.")
            case .idExhausted: String(localized: "Unique discussion identifiers could not be created. Try again.")
            }
        }
    }
    private struct Record {
        let block: DiscussionBlock
        let root: DiscussionYAML.Value
        let id: String
        let messages: [DiscussionYAML.Value]
        var messageIDs: [String] { messages.compactMap { $0["id"]?.string } }
        var indexed: [String: DiscussionYAML.Value] { Dictionary(uniqueKeysWithValues: zip(messageIDs, messages)) }
        init?(_ block: DiscussionBlock, bytes: [UInt8]) {
            guard let thread = block.thread, let syntax = block.syntax else { return nil }
            let root = DiscussionYAML.value(syntax, source: bytes, offset: block.yamlOffset)
            guard let messages = root["messages"]?.items else { return nil }
            self.block = block; self.root = root; id = thread.id; self.messages = messages
        }
    }
    private static func records(_ document: DiscussionDocument) -> [Record] {
        let bytes = Array(document.source.utf8)
        return document.blocks.compactMap { Record($0, bytes: bytes) }
    }
    private static func reserved(_ document: DiscussionDocument) -> (threads: Set<String>, messages: Set<String>) {
        (Set(document.blocks.compactMap { $0.syntax?["id"]?.string }),
         Set(document.blocks.flatMap { ($0.syntax?["messages"]?.items ?? []).compactMap { $0["id"]?.string } }))
    }
    static func preview(current: DiscussionDocument, incoming: DiscussionDocument) -> DiscussionImportPreview {
        let currentRecords = Dictionary(uniqueKeysWithValues: records(current).map { ($0.id, $0) })
        let ids = reserved(current)
        let items: [DiscussionImportPreview.Item] = records(incoming).map { other in
            let existing = currentRecords[other.id]
            let existingMessages = existing?.indexed ?? [:]
            let added = other.messageIDs.filter { existingMessages[$0] == nil }
            var reasons: [DiscussionImportPreview.Item.Reason] = []
            if let existing {
                if existing.root.removing("messages").signature() != other.root.removing("messages").signature() { reasons.append(.rootChanged) }
                let otherMessages = other.indexed
                if existing.messageIDs.contains(where: { id in otherMessages[id].map { $0.signature() != existingMessages[id]!.signature() } ?? false }) { reasons.append(.messageChanged) }
            } else if ids.threads.contains(other.id) { reasons.append(.unavailableCurrent) }
            let unrelated = ids.messages.subtracting(existing?.messageIDs ?? [])
            if !unrelated.isDisjoint(with: other.messageIDs) { reasons.append(.idCollision) }
            let kind: DiscussionImportPreview.Item.Kind = !reasons.isEmpty ? .conflict : existing == nil ? .newThread : added.isEmpty ? .duplicate : .replies
            return .init(id: other.id, kind: kind, addedMessageIDs: added, reasons: reasons)
        }
        return .init(current: current, incoming: incoming, items: items)
    }
    static func splices(for preview: DiscussionImportPreview, in current: DiscussionDocument,
                        choices: [String: Choice] = [:], newID: () -> String = { UUID().uuidString.lowercased() }) throws -> [MarkdownSourceSplice] {
        guard current.source.utf8.elementsEqual(preview.current.source.utf8) else { throw Failure.staleSource }
        let fresh = self.preview(current: current, incoming: preview.incoming)
        guard Set(choices.keys).isSubset(of: Set(fresh.items.map(\.id))) else { throw Failure.invalidImport }
        let currentRecords = Dictionary(uniqueKeysWithValues: records(current).map { ($0.id, $0) })
        let incomingRecords = Dictionary(uniqueKeysWithValues: records(preview.incoming).map { ($0.id, $0) })
        let ids = reserved(current)
        let incomingIDs = reserved(preview.incoming)
        var used = ids.threads.union(ids.messages).union(incomingIDs.threads).union(incomingIDs.messages)
        func allocate() throws -> String {
            for _ in 0..<64 {
                let value = newID()
                if DiscussionCodec.validID(value), used.insert(value).inserted { return value }
            }
            throw Failure.idExhausted
        }
        let newline = current.source.contains("\r\n") ? "\r\n" : current.source.contains("\r") && !current.source.contains("\n") ? "\r" : "\n"
        func wrapper(_ root: DiscussionYAML.Value) throws -> String { "<!-- margined:thread v1" + newline + (try DiscussionYAML.render(root, newline: newline)) + "-->" }
        var edits: [MarkdownSourceSplice] = [], append: [String] = []
        var expected = currentRecords.mapValues(\.root)
        for item in fresh.items {
            let choice = choices[item.id]
            if item.kind == .conflict && choice == nil { throw Failure.conflictNeedsChoice }
            if choice == .keepCurrent { continue }
            guard let other = incomingRecords[item.id] else { throw Failure.invalidImport }
            if choice == .keepSeparate {
                let threadID = try allocate()
                var mapping: [String: String] = [:]
                for id in other.messageIDs { mapping[id] = try allocate() }
                let messages = other.messages.map { message in
                    var value = message.replacing("id", with: .scalar(mapping[message["id"]!.string!]!, .string))
                    if let reply = message["in-reply-to"]?.string { value = value.replacing("in-reply-to", with: .scalar(mapping[reply]!, .string)) }
                    return value
                }
                let root = other.root.replacing("id", with: .scalar(threadID, .string)).replacing("messages", with: .sequence(messages))
                append.append(try wrapper(root)); expected[threadID] = root
            } else if let existing = currentRecords[item.id] {
                guard !item.reasons.contains(.idCollision) else { throw Failure.invalidImport }
                if item.kind == .duplicate { continue }
                let incomingMessages = other.indexed, useIncoming = item.kind == .conflict && choice == .useIncoming
                var messages = existing.messages.map { value in useIncoming ? incomingMessages[value["id"]!.string!] ?? value : value }
                let existingIDs = Set(existing.messageIDs)
                messages += other.messages.filter { !existingIDs.contains($0["id"]!.string!) }
                let root = (useIncoming ? other.root : existing.root).replacing("messages", with: .sequence(messages))
                edits.append(.init(range: existing.block.range, replacement: try wrapper(root)))
                expected[item.id] = root
                used.formUnion(other.messageIDs)
            } else {
                guard item.kind == .newThread else { throw Failure.invalidImport }
                let bytes = Array(preview.incoming.source.utf8)
                append.append(String(decoding: bytes[other.block.range], as: UTF8.self))
                expected[item.id] = other.root; used.insert(item.id); used.formUnion(other.messageIDs)
            }
        }
        if !append.isEmpty {
            guard current.blocks.allSatisfy(\.hasCertainExtent) else { throw Failure.invalidImport }
            let source = current.source
            let separator = source.isEmpty || source.hasSuffix(newline + newline) ? "" : source.hasSuffix(newline) ? newline : newline + newline
            let point = source.utf8.count
            edits.append(.init(range: point..<point, replacement: separator + append.joined(separator: newline + newline) + newline))
        }
        guard !edits.isEmpty else { return [] }
        let data = try MarkdownSourceEdits.apply(edits, to: Data(current.source.utf8), expectedSource: current.source)
        let candidate = try DiscussionCodec.parse(MarkdownSource.decode(data))
        let actual = Dictionary(uniqueKeysWithValues: records(candidate).map { ($0.id, $0.root) })
        guard candidate.diagnostics.count <= current.diagnostics.count, Set(actual.keys) == Set(expected.keys),
              expected.allSatisfy({ actual[$0.key]?.signature() == $0.value.signature() }) else { throw Failure.invalidImport }
        return edits
    }
}

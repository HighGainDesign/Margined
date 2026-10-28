import Foundation
import CYaml

/// A semantic tree for reconciliation. Schema strings compare independently of
/// quoting; unknown plain scalars retain their meaning for other YAML readers.
enum DiscussionYAML {
    enum Context { case root, target, messages, message, attachments, attachment, unknown, string }
    enum ScalarKind: Sendable { case plain, string }
    struct Entry: Sendable { let key: Value; let value: Value }
    indirect enum Value: Sendable {
        case scalar(String, ScalarKind)
        case sequence([Value])
        case mapping([Entry])

        var string: String? { if case let .scalar(text, _) = self { text } else { nil } }
        var items: [Value]? { if case let .sequence(items) = self { items } else { nil } }
        subscript(_ key: String) -> Value? {
            guard case let .mapping(entries) = self else { return nil }
            return entries.first { $0.key.string?.utf8.elementsEqual(key.utf8) == true }?.value
        }
        func replacing(_ key: String, with value: Value) -> Value {
            guard case let .mapping(entries) = self else { return self }
            return .mapping(entries.map { $0.key.string == key ? .init(key: $0.key, value: value) : $0 })
        }
        func removing(_ key: String) -> Value {
            guard case let .mapping(entries) = self else { return self }
            return .mapping(entries.filter { $0.key.string != key })
        }
        /// Length framing and byte equality avoid Swift String's canonical
        /// equivalence changing an imported author's original text.
        func signature() -> Data {
            func frame(_ type: UInt8, _ bytes: Data) -> Data {
                Data([type]) + Data(String(bytes.count).utf8) + Data([58]) + bytes
            }
            switch self {
            case let .scalar(text, kind): return frame(kind == .plain ? 112 : 115, Data(text.utf8))
            case let .sequence(items): return frame(113, items.reduce(into: Data()) { $0.append($1.signature()) })
            case let .mapping(entries):
                let pairs = entries.map { ($0.key.signature(), $0.value.signature()) }.sorted { $0.0.lexicographicallyPrecedes($1.0) }
                return frame(109, pairs.reduce(into: Data()) { $0.append($1.0); $0.append($1.1) })
            }
        }
    }
    static func value(_ node: RestrictedYAML.Node, source: [UInt8], offset: Int, context: Context = .root) -> Value {
        switch node.value {
        case let .scalar(text, style):
            let start = offset + node.range.lowerBound
            let explicitString = source.indices.contains(start) && source[start] == 33
            return .scalar(text, context == .string || style != .plain || explicitString ? .string : .plain)
        case let .sequence(items, _):
            let child: Context = context == .messages ? .message : context == .attachments ? .attachment : .unknown
            return .sequence(items.map { value($0, source: source, offset: offset, context: child) })
        case let .mapping(entries, _):
            return .mapping(entries.map { entry in
                let key = entry.key.string ?? ""
                let child: Context
                switch (context, key) {
                case (.root, "target"), (.attachment, "target"): child = .target
                case (.root, "messages"): child = .messages
                case (.root, "attachment-history"): child = .attachments
                case (.root, "id"), (.root, "state"), (.root, "resolved-by"), (.root, "resolved"),
                     (.target, "type"), (.target, "exact"), (.target, "prefix"), (.target, "suffix"), (.target, "section"),
                     (.message, "id"), (.message, "author"), (.message, "created"), (.message, "body"), (.message, "in-reply-to"),
                     (.attachment, "author"), (.attachment, "created"): child = .string
                default: child = .unknown
                }
                let keyValue = context == .unknown ? value(entry.key, source: source, offset: offset, context: .unknown) : .scalar(key, .string)
                return Entry(key: keyValue, value: value(entry.value, source: source, offset: offset, context: child))
            })
        }
    }

    private final class Output {
        var data = Data()
        func append(_ buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int32 {
            guard count <= MarkdownSource.maximumBytes - data.count else { return 0 }
            data.append(buffer, count: count); return 1
        }
    }
    static func render(_ value: Value, newline: String, flow: Bool = false) throws -> String {
        var emitter = yaml_emitter_t()
        guard yaml_emitter_initialize(&emitter) != 0 else { throw DiscussionReconciliation.Failure.invalidImport }
        defer { yaml_emitter_delete(&emitter) }
        let output = Output()
        yaml_emitter_set_output(&emitter, { context, bytes, count in
            guard let context, let bytes else { return 0 }
            return Unmanaged<Output>.fromOpaque(context).takeUnretainedValue().append(bytes, count: count)
        }, Unmanaged.passUnretained(output).toOpaque())
        yaml_emitter_set_unicode(&emitter, 1)
        yaml_emitter_set_width(&emitter, -1)
        func send(_ initialize: (UnsafeMutablePointer<yaml_event_t>) -> Int32) throws {
            var event = yaml_event_t()
            guard initialize(&event) != 0 else { throw DiscussionReconciliation.Failure.invalidImport }
            // libyaml owns and deletes the event on either emit result.
            guard yaml_emitter_emit(&emitter, &event) != 0 else { throw DiscussionReconciliation.Failure.invalidImport }
        }
        func emit(_ value: Value) throws {
            switch value {
            case let .scalar(text, kind):
                // A flow collection cannot represent an empty plain scalar. The
                // equivalent explicit null retains its YAML type in history.
                let scalar = flow && kind == .plain && text.isEmpty ? "null" : text
                let bytes = Array(scalar.utf8) + [0]
                try bytes.withUnsafeBufferPointer { buffer in
                    try send { yaml_scalar_event_initialize($0, nil, nil, buffer.baseAddress, Int32(bytes.count - 1), kind == .plain ? 1 : 0, kind == .string ? 1 : 0, kind == .plain ? YAML_PLAIN_SCALAR_STYLE : YAML_DOUBLE_QUOTED_SCALAR_STYLE) }
                }
            case let .sequence(items):
                try send { yaml_sequence_start_event_initialize($0, nil, nil, 1, flow ? YAML_FLOW_SEQUENCE_STYLE : YAML_BLOCK_SEQUENCE_STYLE) }
                for item in items { try emit(item) }
                try send { yaml_sequence_end_event_initialize($0) }
            case let .mapping(entries):
                try send { yaml_mapping_start_event_initialize($0, nil, nil, 1, flow ? YAML_FLOW_MAPPING_STYLE : YAML_BLOCK_MAPPING_STYLE) }
                for entry in entries { try emit(entry.key); try emit(entry.value) }
                try send { yaml_mapping_end_event_initialize($0) }
            }
        }
        try send { yaml_stream_start_event_initialize($0, YAML_UTF8_ENCODING) }
        try send { yaml_document_start_event_initialize($0, nil, nil, nil, 1) }
        try emit(value)
        try send { yaml_document_end_event_initialize($0, 1) }
        try send { yaml_stream_end_event_initialize($0) }
        guard let raw = String(data: output.data, encoding: .utf8) else { throw DiscussionReconciliation.Failure.invalidImport }
        // YAML quoting alone doesn't protect the enclosing HTML comment. Use
        // parsed scalar ranges to escape delimiters without touching syntax or
        // reinterpreting unknown plain values.
        var budget = 200_000
        let parsed = try RestrictedYAML.parse(raw, eventBudget: &budget)
        var protections: [MarkdownSourceSplice] = []
        func protect(_ node: RestrictedYAML.Node) {
            switch node.value {
            case let .scalar(text, _):
                if ["<!--", "-->", "--!>"].contains(where: text.contains) { protections.append(.init(range: node.range, replacement: DiscussionEdits.quote(text))) }
            case let .sequence(items, _): items.forEach(protect)
            case let .mapping(entries, _): entries.forEach { protect($0.key); protect($0.value) }
            }
        }
        protect(parsed)
        let safe = try MarkdownSource.decode(MarkdownSourceEdits.apply(protections, to: output.data, expectedSource: raw))
        return newline == "\n" ? safe : safe.replacingOccurrences(of: "\n", with: newline)
    }
}

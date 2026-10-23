import CYaml
import Foundation

/// An event reader over the bundled libyaml, never YAML object construction.
/// Marks stay attached to every value so edits can leave other source untouched.
enum RestrictedYAML {
    enum Style: Sendable { case plain, singleQuoted, doubleQuoted, literal, folded }
    struct Entry: Sendable { let key: Node; let value: Node }
    struct Node: Sendable {
        indirect enum Value: Sendable {
            case scalar(String, Style)
            case sequence([Node], flow: Bool)
            case mapping([Entry], flow: Bool)
        }
        let value: Value
        let range: Range<Int>
        let line: Int
        let column: Int
        var string: String? { if case let .scalar(value, _) = value { value } else { nil } }
        var entries: [Entry]? { if case let .mapping(entries, _) = value { entries } else { nil } }
        var items: [Node]? { if case let .sequence(items, _) = value { items } else { nil } }
        subscript(key: String) -> Node? { entries?.first { $0.key.string == key }?.value }
    }
    struct Failure: Error {
        let line: Int
        let column: Int
        let message: String
    }
    private struct Event {
        enum Kind {
            case streamStart, streamEnd, documentStart, documentEnd
            case scalar(String, Style), sequenceStart(Bool), sequenceEnd, mappingStart(Bool), mappingEnd
        }
        let kind: Kind
        let range: Range<Int>
        let line: Int
        let column: Int
    }

    /// libyaml counts Unicode scalars, not UTF-8 bytes. Checkpoints avoid both
    /// quadratic rescanning on one long flow line and an Int per ASCII byte.
    private struct Marks {
        let bytes: [UInt8]
        let checkpoints: [Int]
        init(_ text: String) {
            bytes = Array(text.utf8)
            var offsets = [0], byte = 0, scalar = 0
            while byte < bytes.count {
                byte += Self.width(bytes[byte]); scalar += 1
                if scalar % 256 == 0 { offsets.append(byte) }
            }
            checkpoints = offsets
        }
        private static func width(_ lead: UInt8) -> Int {
            lead < 0x80 ? 1 : lead < 0xe0 ? 2 : lead < 0xf0 ? 3 : 4
        }
        func byte(_ scalar: Int) -> Int {
            let index = scalar / 256
            guard checkpoints.indices.contains(index) else { return bytes.count }
            var byte = checkpoints[index], remaining = scalar % 256
            while remaining > 0 && byte < bytes.count { byte += Self.width(bytes[byte]); remaining -= 1 }
            return min(byte, bytes.count)
        }
    }

    static func parse(_ text: String, eventBudget: inout Int) throws -> Node {
        guard eventBudget > 0 else { throw Failure(line: 1, column: 1, message: "Discussion YAML exceeds the event limit.") }
        var parser = yaml_parser_t()
        guard yaml_parser_initialize(&parser) != 0 else {
            throw Failure(line: 1, column: 1, message: "The YAML parser could not start.")
        }
        defer { yaml_parser_delete(&parser) }
        let marks = Marks(text)
        var terminated = marks.bytes
        terminated.append(0) // libyaml requires a nonnull pointer even for empty input.
        return try terminated.withUnsafeBufferPointer { bytes in
            yaml_parser_set_input_string(&parser, bytes.baseAddress, marks.bytes.count)
            var events = 0
            func next() throws -> Event {
                events += 1
                guard eventBudget > 0 else {
                    throw Failure(line: Int(parser.mark.line) + 1, column: Int(parser.mark.column) + 1, message: "Discussion YAML exceeds the event limit.")
                }
                eventBudget -= 1
                if events % 256 == 0 { try Task.checkCancellation() }
                var event = yaml_event_t()
                guard yaml_parser_parse(&parser, &event) != 0 else {
                    throw Failure(line: Int(parser.problem_mark.line) + 1, column: Int(parser.problem_mark.column) + 1, message: "Malformed discussion YAML.")
                }
                defer { yaml_event_delete(&event) }
                let line = Int(event.start_mark.line) + 1, column = Int(event.start_mark.column) + 1
                func fail(_ message: String) throws -> Never { throw Failure(line: line, column: column, message: message) }
                func permitted(_ anchor: UnsafeMutablePointer<yaml_char_t>?, _ tag: UnsafeMutablePointer<yaml_char_t>?, standard: String) throws {
                    guard anchor == nil else { try fail("YAML anchors are not allowed in discussions.") }
                    if let tag, String(cString: tag) != "tag:yaml.org,2002:" + standard { try fail("This YAML tag is not allowed in discussions.") }
                }
                let kind: Event.Kind
                switch event.type {
                case YAML_STREAM_START_EVENT: kind = .streamStart
                case YAML_STREAM_END_EVENT: kind = .streamEnd
                case YAML_DOCUMENT_START_EVENT:
                    guard event.data.document_start.version_directive == nil,
                          event.data.document_start.tag_directives.start == event.data.document_start.tag_directives.end else {
                        try fail("YAML directives are not allowed in discussions.")
                    }
                    kind = .documentStart
                case YAML_DOCUMENT_END_EVENT: kind = .documentEnd
                case YAML_ALIAS_EVENT: try fail("YAML aliases are not allowed in discussions.")
                case YAML_SCALAR_EVENT:
                    let scalar = event.data.scalar
                    try permitted(scalar.anchor, scalar.tag, standard: "str")
                    let string = String(decoding: UnsafeBufferPointer(start: scalar.value, count: scalar.length), as: UTF8.self)
                    let style: Style
                    switch scalar.style {
                    case YAML_SINGLE_QUOTED_SCALAR_STYLE: style = .singleQuoted
                    case YAML_DOUBLE_QUOTED_SCALAR_STYLE: style = .doubleQuoted
                    case YAML_LITERAL_SCALAR_STYLE: style = .literal
                    case YAML_FOLDED_SCALAR_STYLE: style = .folded
                    default: style = .plain
                    }
                    kind = .scalar(string, style)
                case YAML_SEQUENCE_START_EVENT:
                    try permitted(event.data.sequence_start.anchor, event.data.sequence_start.tag, standard: "seq")
                    kind = .sequenceStart(event.data.sequence_start.style == YAML_FLOW_SEQUENCE_STYLE)
                case YAML_SEQUENCE_END_EVENT: kind = .sequenceEnd
                case YAML_MAPPING_START_EVENT:
                    try permitted(event.data.mapping_start.anchor, event.data.mapping_start.tag, standard: "map")
                    kind = .mappingStart(event.data.mapping_start.style == YAML_FLOW_MAPPING_STYLE)
                case YAML_MAPPING_END_EVENT: kind = .mappingEnd
                default: try fail("Unsupported discussion YAML event.")
                }
                return Event(kind: kind, range: marks.byte(Int(event.start_mark.index))..<marks.byte(Int(event.end_mark.index)), line: line, column: column)
            }
            func value(_ event: Event, depth: Int) throws -> Node {
                guard depth <= 64 else { throw Failure(line: event.line, column: event.column, message: "Discussion YAML exceeds the nesting limit.") }
                let content: Node.Value
                var end = event.range.upperBound
                switch event.kind {
                case let .scalar(string, style): content = .scalar(string, style)
                case let .sequenceStart(flow):
                    var items: [Node] = []
                    while true {
                        let child = try next()
                        if case .sequenceEnd = child.kind { end = child.range.upperBound; break }
                        items.append(try value(child, depth: depth + 1))
                    }
                    content = .sequence(items, flow: flow)
                case let .mappingStart(flow):
                    var entries: [Entry] = [], keys = Set<String>()
                    while true {
                        let child = try next()
                        if case .mappingEnd = child.kind { end = child.range.upperBound; break }
                        let key = try value(child, depth: depth + 1)
                        guard let string = key.string, string != "<<", keys.insert(string).inserted else {
                            throw Failure(line: key.line, column: key.column, message: "Discussion keys must be unique strings; YAML merges are not allowed.")
                        }
                        entries.append(Entry(key: key, value: try value(next(), depth: depth + 1)))
                    }
                    content = .mapping(entries, flow: flow)
                default: throw Failure(line: event.line, column: event.column, message: "Expected a discussion YAML value.")
                }
                return Node(value: content, range: event.range.lowerBound..<end, line: event.line, column: event.column)
            }
            guard case .streamStart = try next().kind, case .documentStart = try next().kind else {
                throw Failure(line: 1, column: 1, message: "Expected one YAML document.")
            }
            let root = try value(next(), depth: 1)
            guard case .documentEnd = try next().kind, case .streamEnd = try next().kind else {
                throw Failure(line: root.line, column: root.column, message: "Only one YAML document is allowed per discussion.")
            }
            return root
        }
    }
}

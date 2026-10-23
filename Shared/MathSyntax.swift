import CcmarkGFM
import Foundation

/// A cmark inline extension, not a second Markdown parser. cmark owns code,
/// escapes, containers and UTF-8 chunks; KaTeX owns the TeX grammar.
enum MathSyntax {
    private final class ScanBudget {
        var remaining: Int
        init(sourceBytes: Int) { remaining = sourceBytes * 4 + 16_384 }
    }

    static func install(on ext: UnsafeMutablePointer<cmark_syntax_extension>, sourceBytes: Int) {
        // cmark may retry each unmatched dollar. Bound total lookahead work to
        // source size; exhausted candidates remain ordinary readable Markdown.
        let budget = Unmanaged.passRetained(ScanBudget(sourceBytes: sourceBytes))
        cmark_syntax_extension_set_private(ext, budget.toOpaque()) { _, pointer in
            if let pointer { Unmanaged<ScanBudget>.fromOpaque(pointer).release() }
        }
        // cmark supplies complete lines and container indentation. A standalone
        // $$ pair is a code-like block, so blank lines and TeX stay untouched.
        cmark_syntax_extension_set_open_block_func(ext) { ext, indented, parser, parent, input, length in
            guard indented == 0, let ext, let parser, let input else { return nil }
            let offset = Int(cmark_parser_get_first_nonspace(parser))
            guard offset >= 0, offset < Int(length) else { return nil }
            let line = String(decoding: UnsafeBufferPointer(start: input + offset, count: Int(length) - offset), as: UTF8.self)
            guard line.trimmingCharacters(in: .whitespacesAndNewlines) == "$$",
                  let node = cmark_parser_add_child(parser, parent, CMARK_NODE_CODE_BLOCK, Int32(offset + 1)) else { return nil }
            _ = cmark_node_set_syntax_extension(node, ext)
            _ = "math".withCString { cmark_node_set_fence_info(node, $0) }
            cmark_parser_advance_offset(parser, UnsafeRawPointer(input).assumingMemoryBound(to: CChar.self), length - cmark_parser_get_offset(parser), 0)
            return node
        }
        cmark_syntax_extension_set_match_block_func(ext) { _, parser, input, length, _ in
            guard let parser, let input else { return 0 }
            let offset = Int(cmark_parser_get_first_nonspace(parser))
            guard offset >= 0, offset < Int(length) else { return 1 }
            let line = String(decoding: UnsafeBufferPointer(start: input + offset, count: Int(length) - offset), as: UTF8.self)
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "$$" {
                cmark_parser_advance_offset(parser, UnsafeRawPointer(input).assumingMemoryBound(to: CChar.self), length - cmark_parser_get_offset(parser), 0)
                return 0
            }
            return 1
        }
        let chars = cmark_llist_append(cmark_get_default_mem_allocator(), nil, UnsafeMutableRawPointer(bitPattern: 36))
        cmark_syntax_extension_set_special_inline_chars(ext, chars)
        cmark_syntax_extension_set_match_inline_func(ext) { ext, _, _, character, parser in
            guard let ext, let pointer = cmark_syntax_extension_get_private(ext) else { return nil }
            let budget = Unmanaged<ScanBudget>.fromOpaque(pointer).takeUnretainedValue()
            guard budget.remaining > 0, character == 36, let parser, let chunk = cmark_inline_parser_get_chunk(parser),
                  let data = chunk.pointee.data else { return nil }
            let start = Int(cmark_inline_parser_get_offset(parser)), length = Int(chunk.pointee.len)
            guard start >= 0, start + 1 < length else { return nil }
            let display = data[start + 1] == 36
            let quoted = data[start + 1] == 96
            let size = display || quoted ? 2 : 1
            let content = start + size
            guard content < length, display || ![9, 10, 13, 32, 36].contains(data[content]) else { return nil }
            var end = content
            let limit = min(length, start + 16_384)
            while end < limit {
                guard budget.remaining > 0 else { return nil }
                budget.remaining -= 1
                if data[end] == 92 { end += 2; continue }
                let closes = display ? (end + 1 < limit && data[end] == 36 && data[end + 1] == 36) :
                    quoted ? (end + 1 < limit && data[end] == 96 && data[end + 1] == 36) : data[end] == 36
                if closes {
                    guard end > content else { return nil }
                    if !display && !quoted {
                        if [9, 10, 13, 32].contains(data[end - 1]) { return nil }
                        if end + 1 < length, (48...57).contains(data[end + 1]) { return nil }
                    }
                    let tex = String(decoding: UnsafeBufferPointer(start: data + content, count: end - content), as: UTF8.self)
                    guard let node = cmark_node_new(CMARK_NODE_HTML_INLINE) else { return nil }
                    let html = MathSyntax.placeholder(tex, display: display)
                    _ = html.withCString { cmark_node_set_literal(node, $0) }
                    cmark_inline_parser_set_offset(parser, Int32(end + size))
                    return node
                }
                end += 1
            }
            return nil
        }
    }

    static func placeholder(_ tex: String, display: Bool, block: Bool = false) -> String {
        let escaped = tex.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let span = "<span class=\"margined-math \(display ? "margined-math-display" : "margined-math-inline")\">\(escaped)</span>"
        return block ? "<p class=\"margined-math-block\">\(span)</p>" : span
    }
}

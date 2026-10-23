import Foundation

struct MarkdownSourceSplice: Equatable, Sendable {
    let range: Range<Int>
    let replacement: String
}

/// Splice offsets address UTF-8 in the decoded source, not encoded file bytes.
enum MarkdownSourceEdits {
    enum Failure: Error { case staleSource, invalidEdit, invalidEncoding }
    static func apply(_ edits: [MarkdownSourceSplice], to data: Data, expectedSource: String) throws -> Data {
        let decoded = try MarkdownSource.decode(data)
        guard decoded.utf8.elementsEqual(expectedSource.utf8) else { throw Failure.staleSource }
        let encoding: String.Encoding
        let bom: Data
        if data.starts(with: [255, 254]) { encoding = .utf16LittleEndian; bom = Data([255,254]) }
        else if data.starts(with: [254, 255]) { encoding = .utf16BigEndian; bom = Data([254,255]) }
        else { encoding = .utf8; bom = data.starts(with: [239,187,191]) ? Data([239,187,191]) : Data() }
        guard let roundTrip = decoded.data(using: encoding), bom + roundTrip == data else { throw Failure.invalidEncoding }
        let bytes = Array(expectedSource.utf8)
        let ordered = edits.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var end = 0, previousStart: Int?, result = Data()
        func isBoundary(_ offset: Int) -> Bool {
            offset == bytes.count || (offset >= 0 && offset < bytes.count && bytes[offset] & 0xc0 != 0x80)
        }
        for edit in ordered {
            let start = edit.range.lowerBound, upper = edit.range.upperBound
            guard start >= end, upper <= bytes.count, start != previousStart,
                  isBoundary(start), isBoundary(upper) else { throw Failure.invalidEdit }
            result.append(contentsOf: bytes[end..<start])
            result.append(contentsOf: edit.replacement.utf8)
            guard result.count <= MarkdownSource.maximumBytes * 3 else { throw ReaderError.tooLarge }
            end = upper; previousStart = start
        }
        result.append(contentsOf: bytes[end...])
        let source = String(decoding: result, as: UTF8.self)
        guard source.utf8.elementsEqual(result), let encoded = source.data(using: encoding) else { throw Failure.invalidEncoding }
        let output = bom + encoded
        guard output.count <= MarkdownSource.maximumBytes else { throw ReaderError.tooLarge }
        return output
    }
}

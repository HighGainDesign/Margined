import Foundation

enum MarkdownSource {
    static let maximumBytes = 8 * 1_024 * 1_024

    static func decode(_ data: Data) throws -> String {
        guard data.count <= maximumBytes else { throw ReaderError.tooLarge }
        let body = data.starts(with: [239, 187, 191]) ? data.dropFirst(3) : data[...]
        let utf8 = String(decoding: body, as: UTF8.self)
        if utf8.utf8.elementsEqual(body) { return utf8 }
        // Decode exactly one file BOM. Foundation's data initializer also strips
        // a leading U+FEFF, which can otherwise consume actual document text.
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]), data.count % 2 == 0 {
            let bytes = Array(data.dropFirst(2)), little = data.first == 0xff
            let units = stride(from: 0, to: bytes.count, by: 2).map { index in
                little ? UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8 : UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
            }
            let string = String(decoding: units, as: UTF16.self)
            if string.utf16.elementsEqual(units) { return string }
        }
        throw ReaderError.invalidEncoding
    }

    static func read(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try decode(file.read(upToCount: maximumBytes + 1) ?? Data())
    }

    @concurrent
    static func readInBackground(_ url: URL) async throws -> String {
        try read(url)
    }
}

enum ReaderError: LocalizedError {
    case tooLarge, invalidEncoding, rendererUnavailable, invalidPreviewURL

    var errorDescription: String? {
        switch self {
        case .tooLarge: String(localized: "This document exceeds Margined’s 8 MB preview limit.")
        case .invalidEncoding: String(localized: "This file is not UTF-8 or BOM-marked UTF-16 text.")
        case .rendererUnavailable: String(localized: "The bundled Markdown renderer could not be loaded.")
        case .invalidPreviewURL: String(localized: "Use margined://preview?text=…&title=… to preview Markdown.")
        }
    }
}

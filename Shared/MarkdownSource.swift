import Foundation

enum MarkdownSource {
    static let maximumBytes = 8 * 1_024 * 1_024

    static func decode(_ data: Data) throws -> String {
        guard data.count <= maximumBytes else { throw ReaderError.tooLarge }
        if let string = String(data: data, encoding: .utf8) {
            return string.hasPrefix("\u{feff}") ? String(string.dropFirst()) : string
        }
        // Only interpret UTF-16 when a BOM is present, rather than guessing binary data.
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]),
           let string = String(data: data, encoding: .utf16) { return string }
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

import Foundation

enum ResponseControlScript {
    static let script: String = {
        guard let url = Bundle(for: ResponseScriptBundle.self).url(forResource: "reader-responses", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return "return false;" }
        return source
    }()

    static func labels(_ fields: [MarkdownTextResponse]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: fields.map { (String($0.id), String(localized: "Edit answer for \($0.label)")) })
    }
    static func identities(_ fields: [MarkdownTextResponse]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: fields.map { (String($0.id), "\($0.range.lowerBound):\($0.label)") })
    }
}

private final class ResponseScriptBundle: NSObject {}

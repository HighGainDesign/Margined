import Foundation
import SwiftSoup

enum GitHubAlerts {
    static func prepare(_ document: Document) throws {
        let names = ["NOTE": String(localized: "Note"), "TIP": String(localized: "Tip"),
                     "IMPORTANT": String(localized: "Important"), "WARNING": String(localized: "Warning"), "CAUTION": String(localized: "Caution")]
        for quote in try document.select("blockquote").array() {
            guard let paragraph = quote.children().first(), paragraph.tagName() == "p",
                  let first = paragraph.getChildNodes().first as? TextNode else { continue }
            let raw = first.getWholeText()
            guard let type = names.keys.first(where: { raw == "[!\($0)]" || raw.hasPrefix("[!\($0)]\n") }),
                  let label = names[type] else { continue }
            first.text(String(raw.dropFirst(type.count + 3)).trimmingCharacters(in: .newlines))
            if try paragraph.text().isEmpty { try paragraph.remove() }
            try quote.addClass("margined-alert")
            try quote.addClass("margined-alert-" + type.lowercased())
            let title = Element(try Tag.valueOf("p"), "")
            try title.addClass("margined-alert-title")
            try title.text(label)
            try quote.prependChild(title)
            try quote.attr("role", "note")
        }
    }
}

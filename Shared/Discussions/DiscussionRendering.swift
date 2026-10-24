import Foundation
import SwiftSoup

/// App-owned metadata surrounds separately sanitized Markdown fragments.
/// Author labels and identifiers are inserted as DOM data, never as markup.
enum DiscussionRendering {
    static func document(_ thread: DiscussionThread, bodies: [Document],
                         locale: Locale, timeZone: TimeZone, includeContext: Bool = true) throws -> Document {
        let document = try SwiftSoup.parseBodyFragment("")
        document.outputSettings().prettyPrint(pretty: false)
        guard let root = document.body() else { throw ReaderError.rendererUnavailable }
        if includeContext {
            try root.appendElement("h1").attr("id", "discussion-title-" + thread.id).text(String(localized: "Discussion"))
            try root.appendElement("blockquote").appendElement("p").attr("dir", "auto").text(thread.target.exact)
            try root.appendElement("p").addClass("discussion-state")
                .text(thread.state == .open ? String(localized: "Open") : String(localized: "Resolved"))
        }
        let parser = ISO8601DateFormatter()
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.timeZone = timeZone
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        var earlier: [String: (author: String, id: String)] = [:]
        for (index, message) in thread.messages.enumerated() {
            guard index < bodies.count else { throw ReaderError.rendererUnavailable }
            let id = "discussion-message-" + thread.id + "-" + String(index)
            let article = try root.appendElement("article").attr("id", id)
                .attr("data-message-id", message.id).attr("aria-labelledby", id + "-author")
            let header = try article.appendElement("header")
            try header.appendElement("h3").attr("id", id + "-author").attr("dir", "auto").text(message.author)
            try header.appendElement("p").appendElement("time").attr("datetime", message.created)
                .text(dateLabel(message.created, parser: parser, formatter: formatter))
            if let reply = message.inReplyTo {
                let relationship = try header.appendElement("p")
                if let parent = earlier[reply] {
                    try relationship.appendText(String(localized: "Reply to") + " ")
                    try relationship.appendElement("a").attr("href", "#" + parent.id).text(parent.author)
                } else {
                    try relationship.text(String(localized: "Reply target unavailable"))
                }
            }
            let body = bodies[index]
            try rebaseIDs(in: body, prefix: "discussion-body-" + thread.id + "-" + String(index) + "-")
            let content = try article.appendElement("div").addClass("discussion-message-body").attr("dir", "auto")
            for child in body.body()?.getChildNodes() ?? [] { try content.appendChild(child) }
            earlier[message.id] = (message.author, id)
        }
        return document
    }

    private static func dateLabel(_ value: String, parser: ISO8601DateFormatter, formatter: DateFormatter) -> String {
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = parser.date(from: value)
        if date == nil { parser.formatOptions = [.withInternetDateTime]; date = parser.date(from: value) }
        guard let date else { return value }
        return formatter.string(from: date)
    }

    private static func rebaseIDs(in body: Document, prefix: String) throws {
        var ids: [String: String] = [:]
        for element in try body.select("[id]").array() {
            let original = try element.attr("id"), replacement = prefix + original
            ids[original] = replacement
            try element.attr("id", replacement)
        }
        for link in try body.select("a[href]").array() {
            let href = try link.attr("href")
            guard href.hasPrefix("#"), let id = ids[String(href.dropFirst()).removingPercentEncoding ?? String(href.dropFirst())] else { continue }
            try link.attr("href", "#" + id)
        }
    }
}

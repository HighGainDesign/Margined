import Foundation
import SwiftSoup

enum HTMLAdapter {
    private static let tags: Set<String> = [
        "html", "head", "body", "p", "h1", "h2", "h3", "h4", "h5", "h6", "a", "blockquote",
        "ul", "ol", "li", "dl", "dt", "dd", "pre", "code", "hr", "br", "table", "thead", "tbody",
        "tfoot", "tr", "th", "td", "caption", "details", "summary", "del", "ins", "sup", "sub",
        "strong", "em", "b", "i", "kbd", "samp", "s", "mark", "figure", "figcaption", "span", "div", "section", "input", "img", "abbr"
    ]
    private static let attributes: Set<String> = [
        "href", "src", "alt", "title", "id", "class", "rowspan", "colspan", "align", "aria-label",
        "aria-hidden", "role", "type", "disabled", "checked", "start", "reversed", "scope", "style", "width", "height", "open"
    ]

    static func prepare(_ document: Document, loadRemoteImages: Bool = false) throws {
        var ids: Set<String> = []
        var nextSuffix: [String: Int] = [:]
        var htmlHeadingIndex = 0
        for element in try document.getAllElements().array() {
            let tag = element.tagName()
            if tag == "#root" { continue }
            if ["script", "style", "iframe", "object", "embed", "link", "meta"].contains(tag) {
                try element.remove()
                continue
            }
            guard tags.contains(tag) else { try element.unwrap(); continue }
            for attribute in element.getAttributes()?.asList() ?? [] {
                if !attributes.contains(attribute.getKey()) { try element.removeAttr(attribute.getKey()) }
            }
            if tag != "details" { try element.removeAttr("open") }
            for dimension in ["width", "height"] where element.hasAttr(dimension) {
                let value = try element.attr(dimension).trimmingCharacters(in: .whitespacesAndNewlines)
                let percent = value.hasSuffix("%")
                let digits = percent ? String(value.dropLast()) : value
                if tag == "img", !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
                   let number = Int32(digits), number > 0, !percent || number <= 100 {
                    try element.attr(dimension, String(number) + (percent ? "%" : ""))
                } else { try element.removeAttr(dimension) }
            }
            if element.hasAttr("style") {
                let style = try element.attr("style").replacingOccurrences(of: " ", with: "").lowercased()
                if !["text-align:left", "text-align:right", "text-align:center", "text-align:left;", "text-align:right;", "text-align:center;"].contains(style) {
                    try element.removeAttr("style")
                }
            }
            if ["h1", "h2", "h3", "h4", "h5", "h6"].contains(tag), !element.hasAttr("id") {
                // Apex assigns IDs to Markdown headings; author HTML also needs
                // stable targets for the outline and accessible navigation.
                try element.attr("id", "html-heading-\(htmlHeadingIndex)")
                htmlHeadingIndex += 1
            }
            if element.hasAttr("id") {
                let original = try element.attr("id")
                let base = "margined-" + original
                var candidate = base
                var suffix = nextSuffix[base, default: 1]
                while ids.contains(candidate) {
                    candidate = base + "-\(suffix)"
                    suffix += 1
                }
                ids.insert(candidate)
                nextSuffix[base] = suffix
                try element.attr("id", candidate)
            }
            if element.hasAttr("href") {
                let href = try element.attr("href")
                if href.hasPrefix("#") { try element.attr("href", "#margined-" + String(href.dropFirst())) }
                else {
                    // Browsers discard control characters in URL schemes.
                    // Validate the same normalized form so encoded tabs/newlines
                    // cannot disguise a script URL in author HTML.
                    let normalized = String(String.UnicodeScalarView(href.unicodeScalars.filter {
                        !CharacterSet.controlCharacters.contains($0)
                    })).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let url = URLComponents(string: normalized) {
                        if let scheme = url.scheme, !["http", "https", "mailto"].contains(scheme.lowercased()) {
                            try element.removeAttr("href")
                        }
                    } else { try element.removeAttr("href") }
                }
            }
            if tag == "input" {
                guard try element.attr("type") == "checkbox" else { try element.remove(); continue }
                try element.attr("disabled", "")
                // Name the task; the native checkbox role/value announces its state.
                if let parent = element.parent(), let copy = try SwiftSoup.parseBodyFragment(parent.html()).body() {
                    try copy.select("ul, ol").remove()
                    let label = try copy.text()
                    try element.attr("aria-label", label.isEmpty ? String(localized: "Task") : label)
                }
            }
            if tag == "img" {
                // Preserve authored proportions when max-width shrinks an image.
                // Only sanitizer-validated pixel dimensions generate this CSS.
                if let width = Int32(try element.attr("width")), width > 0,
                   let height = Int32(try element.attr("height")), height > 0 {
                    let alignment = try element.attr("style")
                    try element.attr("style", (alignment.isEmpty ? "" : alignment + ";") + "aspect-ratio: \(width) / \(height); height: auto")
                }
                let src = try element.attr("src")
                // Private comparison metadata preserves the Markdown image URL
                // without loading it when remote resources are disabled.
                try element.attr("data-margined-image-source", src)
                if LocalImage.isLocalReference(src),
                   let encoded = src.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                    try element.attr("src", "margined-resource://local/" + encoded)
                } else if loadRemoteImages, let remote = URLComponents(string: src),
                          remote.scheme?.lowercased() == "https", remote.host?.isEmpty == false,
                          remote.user == nil, remote.password == nil {
                    try element.attr("referrerpolicy", "no-referrer")
                } else if !src.lowercased().hasPrefix("data:image/png;base64,") &&
                            !src.lowercased().hasPrefix("data:image/jpeg;base64,") &&
                            !src.lowercased().hasPrefix("data:image/gif;base64,") &&
                            !src.lowercased().hasPrefix("data:image/webp;base64,") {
                    try element.removeAttr("src")
                }
            }
        }
        // Apex 1.1.34 can mistake a following Markdown link for a table
        // caption while also emitting the real link paragraph. Keep that
        // paragraph and remove only its duplicated, generated caption.
        for figure in try document.select("figure.table-figure").array() {
            guard let next = try figure.nextElementSibling(), next.tagName() == "p",
                  try next.select("a").size() == 1 else { continue }
            for caption in try figure.select("figcaption").array() {
                if try caption.text() == next.text() {
                    try caption.remove()
                }
            }
        }
        for table in try document.select("table").array() {
            try table.wrap("<div class=\"table-scroll\"></div>")
        }
    }
}

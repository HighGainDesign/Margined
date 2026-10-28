import CoreFoundation
import Foundation

struct DiscussionMarginSnapshot: Equatable, Sendable {
    struct Anchor: Equatable, Sendable { let id: String; let top: Double; let height: Double }
    let sourceID: String
    let bodyFont: Double
    let horizontalInsets: Double
    let viewportHeight: Double
    let anchors: [Anchor]

    static func read(_ body: Any, context: DiscussionBridge.Context) -> DiscussionMarginSnapshot? {
        guard context.enabled, let value = body as? [String: Any], value["kind"] as? String == "geometry",
              value["token"] as? String == context.token, value["sourceID"] as? String == context.sourceID,
              let font = number(value["bodyFont"], in: 4...1_024),
              let insets = number(value["horizontalInsets"], in: 0...10_000),
              let viewport = number(value["viewportHeight"], in: 1...100_000),
              let rows = value["anchors"] as? [[String: Any]], rows.count <= context.allowedThreadIDs.count else { return nil }
        var seen = Set<String>(), anchors: [Anchor] = []
        for row in rows {
            guard let id = row["id"] as? String, context.allowedThreadIDs.contains(id), seen.insert(id).inserted,
                  let top = number(row["top"], in: -100_000_000...100_000_000),
                  let height = number(row["height"], in: 0...100_000_000) else { return nil }
            anchors.append(.init(id: id, top: top, height: height))
        }
        return .init(sourceID: context.sourceID, bodyFont: font, horizontalInsets: insets, viewportHeight: viewport, anchors: anchors)
    }
    private static func number(_ value: Any?, in range: ClosedRange<Double>) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, range.contains(number.doubleValue) else { return nil }
        return number.doubleValue
    }
}

enum DiscussionMarginLayout {
    struct Card: Equatable, Sendable { let id: String; let top: Double }
    static func minimumDocumentWidth(bodyFont: Double, horizontalInsets: Double, outlineWidth: Double) -> Double {
        max(420, 28 * bodyFont) + horizontalInsets + outlineWidth
    }
    static func canShowMargin(width: Double, bodyFont: Double, horizontalInsets: Double, outlineWidth: Double) -> Bool {
        guard [width, bodyFont, horizontalInsets, outlineWidth].allSatisfy(\.isFinite),
              width > 0, bodyFont > 0, horizontalInsets >= 0, outlineWidth >= 0 else { return false }
        return width >= minimumDocumentWidth(bodyFont: bodyFont, horizontalInsets: horizontalInsets, outlineWidth: outlineWidth) + 340
    }
    static func cards(ids: [String], anchorTops: [String: Double], heights: [String: Double], topInset: Double) -> [Card] {
        let ordered = ids.enumerated().sorted { left, right in
            let a = anchorTops[left.element].flatMap { $0.isFinite ? $0 : nil } ?? .infinity
            let b = anchorTops[right.element].flatMap { $0.isFinite ? $0 : nil } ?? .infinity
            return a == b ? left.offset < right.offset : a < b
        }
        let inset = topInset.isFinite ? max(0, topInset) : 0
        var bottom = 0.0
        return ordered.map { _, id in
            let desired = anchorTops[id].flatMap { $0.isFinite ? max(0, $0 - inset) : nil } ?? bottom
            let top = max(bottom, desired)
            let height = heights[id].flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 100
            bottom = top + height + 12
            return .init(id: id, top: top)
        }
    }
}

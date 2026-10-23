import CoreFoundation
import Foundation

/// Installed/executed exclusively in the app's isolated WKContentWorld.
enum DiscussionWebScripts {
    static let script: String = {
        guard let url = Bundle(for: DiscussionScriptBundle.self).url(forResource: "reader-discussions", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return "return null;" }
        return source
    }()
}

enum DiscussionBridge {
    struct Context: Sendable {
        let token: String
        let sourceID: String
        let enabled: Bool
        let allowedThreadIDs: Set<String>
    }
    enum Request: Equatable, Sendable {
        case openThread(String)
        case selection(DiscussionSelection)
    }
    static func request(_ body: Any, isMainFrame: Bool, context: Context, projection: DiscussionTextProjection) -> Request? {
        guard isMainFrame, context.enabled, context.sourceID == projection.sourceID,
              let values = body as? [String: Any], values["token"] as? String == context.token,
              values["sourceID"] as? String == context.sourceID else { return nil }
        if values["kind"] as? String == "openThread" {
            guard let id = values["id"] as? String, context.allowedThreadIDs.contains(id) else { return nil }
            return .openThread(id)
        }
        guard values["kind"] as? String == "selection", let location = integer(values["location"]), let length = integer(values["length"]),
              let selection = projection.selection(NSRange(location: location, length: length), renderID: context.token),
              values["quote"] as? String == selection.target.exact,
              integer(values["startUnit"]) == selection.domRange.start.unit, integer(values["startOffset"]) == selection.domRange.start.offset,
              integer(values["endUnit"]) == selection.domRange.end.unit, integer(values["endOffset"]) == selection.domRange.end.offset else { return nil }
        return .selection(selection)
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= Double(Int32.max),
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.intValue
    }
}

private final class DiscussionScriptBundle: NSObject {}

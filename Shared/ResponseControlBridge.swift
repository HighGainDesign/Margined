import CoreFoundation
import Foundation

enum ResponseControlBridge {
    static func answerID(_ body: Any, isMainFrame: Bool, enabled: Bool, token: String, allowed: Set<Int>) -> Int? {
        guard isMainFrame, enabled, !token.isEmpty,
              let values = body as? [String: Any], values["kind"] as? String == "answer",
              values["token"] as? String == token, let number = values["id"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue >= 0, number.doubleValue <= Double(Int32.max),
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              allowed.contains(number.intValue) else { return nil }
        return number.intValue
    }
}

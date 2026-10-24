import Foundation

struct ReaderNavigation: Equatable {
    enum Destination: Equatable {
        case element(String)
        case uncheckedTask(backwards: Bool)
        case readingPosition
    }
    enum ReturnTarget: Equatable {
        case outline(String)
        case discussion(String)
        case review
        case find
    }
    let destination: Destination
    let focus: Bool
    let focusIntent: Int
}

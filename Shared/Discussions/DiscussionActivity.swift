import Foundation

/// A transient refresh summary, not unread/seen state or prose review status.
struct DiscussionActivity: Equatable, Sendable {
    var addedThreads = 0
    var updatedThreads = 0
    var removedThreads = 0
    var hasChanges: Bool { addedThreads + updatedThreads + removedThreads > 0 }
    static func compare(current: DiscussionDocument, previous: DiscussionDocument?) -> DiscussionActivity {
        guard let previous else { return .init() }
        let old = Dictionary(uniqueKeysWithValues: previous.threads.map { ($0.id, $0) })
        let new = Dictionary(uniqueKeysWithValues: current.threads.map { ($0.id, $0) })
        let oldIDs = Set(old.keys), newIDs = Set(new.keys)
        return .init(addedThreads: newIDs.subtracting(oldIDs).count,
            updatedThreads: oldIDs.intersection(newIDs).filter { old[$0] != new[$0] }.count,
            removedThreads: oldIDs.subtracting(newIDs).count)
    }
}

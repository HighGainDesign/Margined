import Foundation

struct DiscussionAnchorResult: Equatable, Sendable {
    enum Status: Sendable { case attached, ambiguous, missing, needsConfirmation }
    enum Reason: Sendable { case contextChanged, originUncertain, knownDeletion, unsupportedContent, resourceLimit }
    let status: Status
    let range: NSRange?
    var candidates: [NSRange] = []
    var reason: Reason? = nil
    /// Session-only evidence for an exact source-version restoration, never saved.
    var originSourceID: String? = nil
}

/// Quotes supply evidence, not authenticated passage identity. In particular,
/// an LCS's arbitrary choice between equal paragraphs is not an origin proof.
enum DiscussionAnchors {
    private struct UnitKey: Hashable { let kind: String; let text: String }
    private struct Candidates { let ranges: [NSRange]; let truncated: Bool }
    private enum Tracking { case mapped(NSRange), deleted, uncertain, constrained([NSRange]), unavailable }
    private struct UnitIndex {
        let oldKeys: [UnitKey]
        let newKeys: [UnitKey]
        let unique: [Int: Int]
        init(previous: DiscussionTextProjection, current: DiscussionTextProjection) {
            let old = previous.units.map { UnitKey(kind: $0.kind, text: $0.text) }
            let new = current.units.map { UnitKey(kind: $0.kind, text: $0.text) }
            oldKeys = old; newKeys = new
            let oldGroups = Dictionary(grouping: old.indices, by: { old[$0] })
            let newGroups = Dictionary(grouping: new.indices, by: { new[$0] })
            var matches: [Int: Int] = [:]
            for (key, indices) in oldGroups where indices.count == 1 {
                if let updated = newGroups[key], updated.count == 1 { matches[indices[0]] = updated[0] }
            }
            unique = matches
        }
    }

    static func resolve(document: DiscussionDocument, current: DiscussionTextProjection, previous: DiscussionTextProjection? = nil) -> [String: DiscussionAnchorResult] {
        let threads = document.threads
        guard !threads.isEmpty else { return [:] }
        let literal = current.text as NSString
        let unitIndex = previous.map { UnitIndex(previous: $0, current: current) }
        var previousCache: [String: Candidates] = [:]
        var cache: [String: Candidates] = [:], comparisonBudget = 32 * 1_024 * 1_024
        var results: [String: DiscussionAnchorResult] = [:]
        for thread in threads {
            let target = thread.target, exact = DiscussionText.normalized(target.exact)
            let found: Candidates
            if let saved = cache[exact] { found = saved }
            else { found = occurrences(of: exact, in: literal); cache[exact] = found }
            var result = direct(target, in: current, candidates: found, comparisonBudget: &comparisonBudget)
            if let previous, previous.targets[thread.id].map({ sameSelector($0, target) }) == true,
               previous.attachmentVersions[thread.id, default: 0] == current.attachmentVersions[thread.id, default: 0] {
                let previousCandidates: Candidates
                if let saved = previousCache[exact] { previousCandidates = saved }
                else { previousCandidates = occurrences(of: exact, in: previous.text as NSString); previousCache[exact] = previousCandidates }
                let prior = previous.anchorResults[thread.id] ?? direct(target, in: previous,
                    candidates: previousCandidates, comparisonBudget: &comparisonBudget)
                let origin = prior.originSourceID ?? previous.sourceID
                if [.knownDeletion, .originUncertain].contains(prior.reason), current.sourceID != origin {
                    result = .init(status: prior.reason == .knownDeletion ? .missing : .needsConfirmation, range: nil, candidates: found.ranges, reason: prior.reason, originSourceID: origin)
                } else if !found.truncated, prior.status == .attached, let oldRange = prior.range {
                    switch track(oldRange, exact: exact, previous: previous, current: current, candidates: found.ranges, index: unitIndex!) {
                    case let .mapped(range): result = .init(status: .attached, range: range, candidates: [range])
                    case .deleted: result = .init(status: .missing, range: nil, candidates: found.ranges, reason: .knownDeletion, originSourceID: origin)
                    case .uncertain: result = .init(status: .needsConfirmation, range: nil, candidates: found.ranges, reason: .originUncertain, originSourceID: origin)
                    case let .constrained(ranges): result = direct(target, in: current, candidates: .init(ranges: ranges, truncated: false), comparisonBudget: &comparisonBudget)
                    case .unavailable: break
                    }
                } else if prior.status == .ambiguous, prior.candidates.count > found.ranges.count, !found.ranges.isEmpty {
                    result = .init(status: .needsConfirmation, range: nil, candidates: found.ranges, reason: .originUncertain, originSourceID: origin)
                }
            }
            if result.status == .attached { result.originSourceID = current.sourceID }
            results[thread.id] = result
        }
        return results
    }

    private static func sameSelector(_ left: DiscussionTarget, _ right: DiscussionTarget) -> Bool {
        left.type == right.type && DiscussionText.normalized(left.exact) == DiscussionText.normalized(right.exact) &&
            DiscussionText.normalized(left.prefix) == DiscussionText.normalized(right.prefix) &&
            DiscussionText.normalized(left.suffix) == DiscussionText.normalized(right.suffix)
    }

    private static func occurrences(of exact: String, in text: NSString) -> Candidates {
        guard !exact.isEmpty else { return .init(ranges: [], truncated: false) }
        var ranges: [NSRange] = [], offset = 0
        while offset < text.length {
            let found = text.range(of: exact, options: .literal, range: NSRange(location: offset, length: text.length - offset))
            guard found.location != NSNotFound else { break }
            if ranges.count == 1_024 { return .init(ranges: ranges, truncated: true) }
            ranges.append(found); offset = found.location + 1
        }
        return .init(ranges: ranges, truncated: false)
    }

    private static func selectable(_ range: NSRange, in projection: DiscussionTextProjection) -> Bool {
        let text = projection.text as NSString
        guard range.location >= 0, range.length > 0, range.location <= text.length,
              range.length <= text.length - range.location,
              text.rangeOfComposedCharacterSequences(for: range) == range else { return false }
        return !projection.barriers.contains { range.location < $0 && $0 < NSMaxRange(range) }
    }

    private static func direct(_ target: DiscussionTarget, in projection: DiscussionTextProjection, candidates: Candidates, comparisonBudget: inout Int) -> DiscussionAnchorResult {
        guard !candidates.truncated else { return .init(status: .needsConfirmation, range: nil, candidates: candidates.ranges, reason: .resourceLimit) }
        guard !candidates.ranges.isEmpty else { return .init(status: .missing, range: nil) }
        let ranges = candidates.ranges.filter { selectable($0, in: projection) }
        guard !ranges.isEmpty else { return .init(status: .needsConfirmation, range: nil, candidates: candidates.ranges, reason: .unsupportedContent) }
        let prefix = DiscussionText.normalized(target.prefix), suffix = DiscussionText.normalized(target.suffix)
        let text = projection.text as NSString
        if prefix.isEmpty && suffix.isEmpty {
            if ranges.count == 1, ranges[0] == NSRange(location: 0, length: text.length) { return .init(status: .attached, range: ranges[0], candidates: ranges) }
            return .init(status: ranges.count > 1 ? .ambiguous : .needsConfirmation, range: nil, candidates: ranges, reason: .contextChanged)
        }
        let prefixLength = prefix.utf16.count, suffixLength = suffix.utf16.count
        var both: [NSRange] = [], supported: [NSRange] = []
        for range in ranges {
            var beforeEnd = range.location, afterStart = NSMaxRange(range)
            if beforeEnd > 0 && text.character(at: beforeEnd - 1) == 32 { beforeEnd -= 1 }
            if afterStart < text.length && text.character(at: afterStart) == 32 { afterStart += 1 }
            comparisonBudget -= prefixLength + suffixLength
            guard comparisonBudget >= 0 else { return .init(status: .needsConfirmation, range: nil, candidates: ranges, reason: .resourceLimit) }
            let left = !prefix.isEmpty && beforeEnd >= prefixLength && text.compare(prefix, options: .literal, range: NSRange(location: beforeEnd - prefixLength, length: prefixLength)) == .orderedSame
            let right = !suffix.isEmpty && suffixLength <= text.length - afterStart && text.compare(suffix, options: .literal, range: NSRange(location: afterStart, length: suffixLength)) == .orderedSame
            if (!prefix.isEmpty || !suffix.isEmpty) && (prefix.isEmpty || left) && (suffix.isEmpty || right) { both.append(range) }
            if left || right { supported.append(range) }
        }
        let best = !both.isEmpty ? both : supported
        if best.count == 1 { return .init(status: .attached, range: best[0], candidates: best) }
        if best.count > 1 { return .init(status: .ambiguous, range: nil, candidates: best) }
        return .init(status: .needsConfirmation, range: nil, candidates: ranges, reason: .contextChanged)
    }

    private static func track(_ range: NSRange, exact: String, previous: DiscussionTextProjection, current: DiscussionTextProjection, candidates: [NSRange], index: UnitIndex) -> Tracking {
        let old = previous.units, new = current.units
        let selected = old.indices.filter { NSIntersectionRange(old[$0].range, range).length > 0 }
        guard let first = selected.first, let last = selected.last else { return .unavailable }
        let oldKeys = index.oldKeys, newKeys = index.newKeys, unique = index.unique
        let moved = selected.compactMap { unique[$0] }
        if moved.count == selected.count, zip(moved, moved.dropFirst()).allSatisfy({ $0.1 == $0.0 + 1 }),
           let startUnit = moved.first, let endUnit = moved.last {
            let start = new[startUnit].range.location + range.location - old[first].range.location
            let end = new[endUnit].range.location + NSMaxRange(range) - old[last].range.location
            let mapped = NSRange(location: start, length: end - start)
            if selectable(mapped, in: current), (current.text as NSString).substring(with: mapped) == exact { return .mapped(mapped) }
        }
        let left = unique.keys.filter { $0 < first }.max(), right = unique.keys.filter { $0 > last }.min()
        guard left != nil || right != nil else { return candidates.isEmpty ? .deleted : .uncertain }
        let lower = left.flatMap { unique[$0] }.map { $0 + 1 } ?? 0
        let upper = right.flatMap { unique[$0] } ?? new.count
        guard lower <= upper else { return .uncertain }
        let lowerOffset = lower < new.count ? new[lower].range.location : current.text.utf16.count
        let upperOffset = upper < new.count ? new[upper].range.location : current.text.utf16.count
        let inside = candidates.filter { lowerOffset <= $0.location && NSMaxRange($0) <= upperOffset }
        guard !inside.isEmpty else { return .deleted }
        // Losing one duplicate and its distinguishing neighbor cannot establish
        // which equal paragraph survived. Never let a tie-breaking LCS decide.
        let oldLower = left.map { $0 + 1 } ?? 0, oldUpper = right ?? old.count
        for index in selected {
            let key = oldKeys[index]
            let oldCopies = (oldLower..<oldUpper).filter { oldKeys[$0] == key }.count
            let newCopies = (lower..<upper).filter { newKeys[$0] == key }.count
            if oldCopies > 1 && newCopies < oldCopies { return .uncertain }
        }
        return .constrained(inside)
    }
}

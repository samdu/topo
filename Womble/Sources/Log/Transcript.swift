import Foundation

/// Everything read from the log, as a graph of turns.
///
/// A transcript is complete when every parent a turn names is present and
/// every device's sequence runs from 1 with no gaps. An incomplete one has
/// turns Womble could not see — records not yet visible to the query, or
/// records that do not parse — and the screen says so rather than presenting
/// a partial read as the whole conversation.
struct Transcript {
    /// Every turn, parents before children, ties broken by time then ref.
    let ordered: [Turn]

    /// Turns no other turn continues from. More than one is a fork: two
    /// devices wrote from the same point and nothing has joined them yet.
    let heads: [TurnRef]

    /// Refs the log must hold and this read did not.
    let missing: Set<TurnRef>

    /// Records of the turn type whose name is not a ref with a sequence of
    /// 1 or more. Nothing can be said about them.
    let unreadable: [String]

    var isEmpty: Bool { return ordered.isEmpty }
    var isForked: Bool { return heads.count > 1 }
    var isComplete: Bool { return missing.isEmpty && unreadable.isEmpty }

    init(turns: [Turn], missing: Set<TurnRef> = [], unreadable: [String] = []) {
        var byRef: [TurnRef: Turn] = [:]
        for turn in turns { byRef[turn.ref] = turn }

        var missing = missing
        var lastSeen: [DeviceID: Int64] = [:]
        for turn in byRef.values {
            for parent in turn.parents where byRef[parent] == nil { missing.insert(parent) }
            lastSeen[turn.ref.device] = max(lastSeen[turn.ref.device] ?? 0, turn.ref.sequence)
        }
        for (device, last) in lastSeen where last >= 1 {
            for sequence in 1...last {
                let ref = TurnRef(device: device, sequence: sequence)
                if byRef[ref] == nil { missing.insert(ref) }
            }
        }

        var referenced = Set<TurnRef>()
        for turn in byRef.values { referenced.formUnion(turn.parents) }

        self.ordered = Transcript.order(byRef)
        self.heads = byRef.keys.filter { !referenced.contains($0) }.sorted()
        self.missing = missing
        self.unreadable = unreadable
    }

    /// Topological order: a turn follows every parent present in the read.
    /// Turns whose parents are all placed are taken oldest first, ties by
    /// ref, so the same log always renders in the same order.
    private static func order(_ byRef: [TurnRef: Turn]) -> [Turn] {
        var children: [TurnRef: [TurnRef]] = [:]
        var pending: [TurnRef: Int] = [:]
        for (ref, turn) in byRef {
            let parents = turn.parents.filter { byRef[$0] != nil }
            pending[ref] = parents.count
            for parent in parents { children[parent, default: []].append(ref) }
        }

        var ready = Set(byRef.keys.filter { pending[$0] == 0 })
        var out: [Turn] = []
        while let next = ready.min(by: { isBefore(byRef[$0]!, byRef[$1]!) }) {
            ready.remove(next)
            out.append(byRef[next]!)
            for child in children[next] ?? [] {
                pending[child]! -= 1
                if pending[child] == 0 { ready.insert(child) }
            }
        }
        // Corrupt data could name parents in a cycle, which leaves those
        // turns with a parent that never places. They are still turns
        // somebody wrote, so they go on the end rather than off the screen.
        if out.count < byRef.count {
            let placed = Set(out.map { $0.ref })
            out += byRef.values.filter { !placed.contains($0.ref) }.sorted(by: isBefore)
        }
        return out
    }

    private static func isBefore(_ a: Turn, _ b: Turn) -> Bool {
        if a.at != b.at { return a.at < b.at }
        return a.ref < b.ref
    }
}

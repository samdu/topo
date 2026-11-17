import Foundation
import TopoCore

/// Which turns of the log the mind's conversation has been told, kept per device as runs of
/// sequence numbers: the phone's `Coverage`, so a branch that arrives late is still found unseen.
struct MindCoverage: Codable, Equatable, Sendable {
    private(set) var runs: [String: [ClosedRange<Int64>]] = [:]

    init() {}
    init(_ refs: some Sequence<TurnRef>) { insert(refs) }

    func contains(_ ref: TurnRef) -> Bool {
        runs[ref.device.rawValue]?.contains { $0.contains(ref.sequence) } ?? false
    }

    var count: Int { runs.values.reduce(0) { $0 + $1.reduce(0) { $0 + Int($1.count) } } }

    mutating func insert(_ refs: some Sequence<TurnRef>) {
        var added: [String: [Int64]] = [:]
        for ref in refs { added[ref.device.rawValue, default: []].append(ref.sequence) }
        for (device, sequences) in added {
            let all = Set((runs[device] ?? []).flatMap { Array($0) } + sequences).sorted()
            var out: [ClosedRange<Int64>] = []
            for value in all {
                if let last = out.last, last.upperBound + 1 == value { out[out.count - 1] = last.lowerBound...value }
                else { out.append(value...value) }
            }
            runs[device] = out
        }
    }

    mutating func formUnion(_ other: MindCoverage) {
        for (device, ranges) in other.runs {
            insert(ranges.flatMap { $0.map { TurnRef(device: DeviceID(device), sequence: $0) } })
        }
    }
}

/// The mind's record on disk: the session its conversation is, what of the log that conversation
/// has been told, and the one input outstanding, recorded before it is sent.
struct MindLedger: Codable, Equatable, Sendable {
    var session: String?
    var seen = MindCoverage()
    var pending: Pending?

    struct Pending: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable {
            /// Written to the process, not yet echoed back: whether it was taken up is not known.
            case sent
            /// Echoed: the conversation has it.
            case received
            /// Answered; `text` is the reply, still to be in the log.
            case answered
            /// Received and ended with no answer (an error result, the process gone mid-turn):
            /// not asked again by itself.
            case unresolved
        }
        var input: String
        var nonce: String
        var parents: [TurnRef]
        var answering: [TurnRef]
        /// Every turn the input told, or for a fresh conversation counted as its history.
        var covers: MindCoverage
        var session: String?
        var sentAt: Date
        var state: State
        var text: String?
    }

    /// No file is an empty ledger. A file that cannot be read or decoded throws and is never taken
    /// for an empty one.
    static func load(_ url: URL) throws -> MindLedger {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return MindLedger()
        }
        return try JSONDecoder().decode(MindLedger.self, from: data)
    }

    func save(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

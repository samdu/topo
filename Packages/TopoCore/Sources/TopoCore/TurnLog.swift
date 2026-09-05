import Foundation

/// A device on the Apple ID: a phone, the hub, a viewer. Its raw value is
/// stable across launches (the app stores it) and unique across devices.
public struct DeviceID: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// Names one turn: the device that wrote it and its sequence number on that
/// device. Sequence numbers start at 1 and have no gaps per device.
public struct TurnRef: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let device: DeviceID
    public let sequence: Int64

    public init(device: DeviceID, sequence: Int64) {
        self.device = device
        self.sequence = sequence
    }

    public var description: String { "\(device.rawValue)/\(sequence)" }

    public static func < (a: TurnRef, b: TurnRef) -> Bool {
        (a.device.rawValue, a.sequence) < (b.device.rawValue, b.sequence)
    }

    /// Parses the form `device/sequence`. The device may itself contain slashes.
    public init?(parsing string: String) {
        guard let slash = string.lastIndex(of: "/"),
              let seq = Int64(string[string.index(after: slash)...]) else { return nil }
        self.init(device: DeviceID(String(string[..<slash])), sequence: seq)
    }
}

public enum TurnRole: String, Sendable, Codable, CaseIterable {
    case person
    case assistant
}

/// One turn of the transcript. Immutable once written.
///
/// `parents` are the turns this one continues from. A turn written in
/// sequence has one parent, the previous head. A turn written after the log
/// has forked lists every head as a parent, which is how a fork is carried
/// on: the reader sees the branches, the next turn joins them.
public struct Turn: Hashable, Sendable, Identifiable {
    public static let recordType = "Turn"

    public let ref: TurnRef
    public let parents: [TurnRef]
    public let role: TurnRole
    public let text: String
    public let at: Date

    public var id: TurnRef { ref }

    public init(ref: TurnRef, parents: [TurnRef], role: TurnRole, text: String, at: Date) {
        self.ref = ref
        self.parents = parents
        self.role = role
        self.text = text
        self.at = at
    }

    public static func recordID(for ref: TurnRef) -> RecordID {
        RecordID("turn/\(ref.description)")
    }

    /// The record for a new turn. Its tag is nil: the save is create-only.
    var record: Record {
        Record(type: Turn.recordType, id: Turn.recordID(for: ref), fields: [
            "device": .string(ref.device.rawValue),
            "sequence": .int(ref.sequence),
            "parents": .strings(parents.map(\.description)),
            "role": .string(role.rawValue),
            "text": .string(text),
            "at": .date(at),
        ])
    }

    /// Nil if the record is not a well-formed turn.
    public init?(record: Record) {
        guard record.type == Turn.recordType,
              let device = record.string("device"),
              let sequence = record.int("sequence"),
              let parentStrings = record.strings("parents"),
              let roleString = record.string("role"), let role = TurnRole(rawValue: roleString),
              let text = record.string("text"),
              let at = record.date("at") else { return nil }
        let parents = parentStrings.compactMap(TurnRef.init(parsing:))
        guard parents.count == parentStrings.count else { return nil }
        self.init(ref: TurnRef(device: DeviceID(device), sequence: sequence),
                  parents: parents, role: role, text: text, at: at)
    }
}

/// Everything read from the log, as a graph of turns.
public struct Transcript: Sendable {
    public let turns: [TurnRef: Turn]

    /// Turns no other turn continues from, sorted. One head is a straight
    /// line; more than one is a fork the next turn should carry on from.
    public let heads: [TurnRef]

    public init(turns: [Turn]) {
        var byRef: [TurnRef: Turn] = [:]
        for t in turns { byRef[t.ref] = t }
        let referenced = Set(turns.flatMap(\.parents))
        self.turns = byRef
        self.heads = byRef.keys.filter { !referenced.contains($0) }.sorted()
    }

    public var isEmpty: Bool { turns.isEmpty }
    public var isForked: Bool { heads.count > 1 }

    public subscript(ref: TurnRef) -> Turn? { turns[ref] }

    /// Every turn reachable from `ref` through parents, including `ref` itself.
    public func ancestry(of ref: TurnRef) -> Set<TurnRef> {
        var seen: Set<TurnRef> = []
        var stack = [ref]
        while let next = stack.popLast() {
            guard seen.insert(next).inserted, let turn = turns[next] else { continue }
            stack.append(contentsOf: turn.parents)
        }
        return seen
    }

    /// The turns only `head` reaches: what happened on that branch and on no
    /// other. On a forked log this is the "meanwhile, on the phone" material.
    /// Empty when `head` is the only head.
    public func exclusive(to head: TurnRef) -> [Turn] {
        var others: Set<TurnRef> = []
        for h in heads where h != head { others.formUnion(ancestry(of: h)) }
        return ordered(ancestry(of: head).subtracting(others))
    }

    /// Every turn, parents before children, ties broken by time then ref.
    public var ordered: [Turn] { ordered(Set(turns.keys)) }

    private func ordered(_ refs: Set<TurnRef>) -> [Turn] {
        var children: [TurnRef: [TurnRef]] = [:]
        var pending: [TurnRef: Int] = [:]
        for ref in refs {
            let parents = (turns[ref]?.parents ?? []).filter(refs.contains)
            pending[ref] = parents.count
            for parent in parents { children[parent, default: []].append(ref) }
        }
        var ready = Set(refs.filter { pending[$0] == 0 })
        var out: [Turn] = []
        while let next = ready.min(by: { (turns[$0]!.at, $0) < (turns[$1]!.at, $1) }) {
            ready.remove(next)
            out.append(turns[next]!)
            for child in children[next] ?? [] {
                pending[child]! -= 1
                if pending[child] == 0 { ready.insert(child) }
            }
        }
        return out
    }
}

public enum TurnLogError: Error, Sendable {
    /// Another writer for the same device kept taking the next sequence number.
    case sequenceContended(DeviceID)
}

/// Reads the append-only log.
public struct TurnLog: Sendable {
    let database: any RecordDatabase

    public init(database: any RecordDatabase) {
        self.database = database
    }

    /// The whole log. Records that are not well-formed turns are skipped.
    public func read() async throws -> Transcript {
        let records = try await database.query(RecordQuery(type: Turn.recordType))
        return Transcript(turns: records.compactMap(Turn.init(record:)))
    }

    /// One device's turns after a sequence number, in sequence order.
    /// `after: 0` is everything that device wrote.
    public func read(device: DeviceID, after sequence: Int64) async throws -> [Turn] {
        let records = try await database.query(RecordQuery(type: Turn.recordType, filters: [
            .init("device", .equals, .string(device.rawValue)),
            .init("sequence", .greaterThan, .int(sequence)),
        ]))
        return records.compactMap(Turn.init(record:)).sorted { $0.ref.sequence < $1.ref.sequence }
    }

    /// A writer for this device, starting after its last written turn.
    public func writer(for device: DeviceID) async throws -> TurnWriter {
        let last = try await read(device: device, after: 0).last?.ref.sequence ?? 0
        return TurnWriter(database: database, device: device, next: last + 1)
    }
}

/// Appends turns for one device. Each append creates a new record and never
/// touches an existing one: the record ID is the turn's ref, and the save is
/// create-only, so two writers for the same device cannot clobber each other.
/// A writer that loses a sequence number to another writer for its device
/// re-reads and takes the next one.
public actor TurnWriter {
    private let database: any RecordDatabase
    public let device: DeviceID
    private var next: Int64
    private var queue: Task<Turn, any Error>?

    init(database: any RecordDatabase, device: DeviceID, next: Int64) {
        self.database = database
        self.device = device
        self.next = next
    }

    /// The ref the next append will take, barring contention.
    public var nextRef: TurnRef { TurnRef(device: device, sequence: next) }

    /// Appends a turn continuing from `parents`. Pass the transcript's heads
    /// to carry on from wherever the log is, fork included. Appends on one
    /// writer run one at a time, in the order they were called.
    public func append(_ role: TurnRole, _ text: String, parents: [TurnRef], at: Date = Date()) async throws -> Turn {
        let previous = queue
        let task = Task<Turn, any Error> {
            _ = try? await previous?.value
            return try await appendNow(role, text, parents: parents, at: at)
        }
        queue = task
        return try await task.value
    }

    private func appendNow(_ role: TurnRole, _ text: String, parents: [TurnRef], at: Date) async throws -> Turn {
        for _ in 0..<3 {
            let turn = Turn(ref: nextRef, parents: parents, role: role, text: text, at: at)
            do {
                _ = try await database.save(turn.record)
                next += 1
                return turn
            } catch RecordDatabaseError.serverRecordChanged {
                let taken = try await TurnLog(database: database).read(device: device, after: next - 1)
                next = (taken.last?.ref.sequence ?? next) + 1
            }
        }
        throw TurnLogError.sequenceContended(device)
    }

    /// Appends a turn continuing from the transcript's heads.
    public func append(_ role: TurnRole, _ text: String, continuing transcript: Transcript, at: Date = Date()) async throws -> Turn {
        try await append(role, text, parents: transcript.heads, at: at)
    }
}

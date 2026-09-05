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
    static let recordPrefix = "turn/"

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

    /// The same turn, allowing for the date losing precision on the server.
    func isSameWrite(as other: Turn) -> Bool {
        ref == other.ref && parents == other.parents && role == other.role && text == other.text
            && abs(at.timeIntervalSince(other.at)) < 0.001
    }

    public static func recordID(for ref: TurnRef) -> RecordID {
        RecordID(recordPrefix + ref.description)
    }

    /// The ref a turn record's name carries, whatever the rest of it holds.
    static func ref(ofRecordNamed name: String) -> TurnRef? {
        guard name.hasPrefix(recordPrefix) else { return nil }
        return TurnRef(parsing: String(name.dropFirst(recordPrefix.count)))
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

    /// Nil if the record is not a well-formed turn. An absent `parents`
    /// field reads as no parents, since CloudKit may drop an empty list.
    public init?(record: Record) {
        guard record.type == Turn.recordType,
              let device = record.string("device"),
              let sequence = record.int("sequence"),
              let roleString = record.string("role"), let role = TurnRole(rawValue: roleString),
              let text = record.string("text"),
              let at = record.date("at") else { return nil }
        let parentStrings = record.strings("parents") ?? []
        let parents = parentStrings.compactMap(TurnRef.init(parsing:))
        guard parents.count == parentStrings.count else { return nil }
        self.init(ref: TurnRef(device: DeviceID(device), sequence: sequence),
                  parents: parents, role: role, text: text, at: at)
    }
}

/// Everything read from the log, as a graph of turns.
///
/// A transcript is complete when every parent a turn names is present and
/// every device's sequence runs from 1 with no gaps. An incomplete one has
/// turns the reader could not see: records not yet visible to the query,
/// or records that do not parse. Its `heads` may name a fork that never
/// happened, so nothing continues from an incomplete transcript.
public struct Transcript: Sendable {
    public let turns: [TurnRef: Turn]

    /// Turns no other turn continues from, sorted. One head is a straight
    /// line; more than one is a fork the next turn should carry on from.
    public let heads: [TurnRef]

    /// Refs the log must hold and this read did not: parents named by a
    /// turn but absent, sequence numbers missing from a device's run, and
    /// records whose name parses but whose fields do not.
    public let missing: Set<TurnRef>

    /// Records of the turn type whose name is not a ref. Nothing can be
    /// said about them.
    public let unreadable: [RecordID]

    public init(turns: [Turn], missing: Set<TurnRef> = [], unreadable: [RecordID] = []) {
        var byRef: [TurnRef: Turn] = [:]
        for t in turns { byRef[t.ref] = t }
        var missing = missing
        var lastSeen: [DeviceID: Int64] = [:]
        for t in turns {
            for p in t.parents where byRef[p] == nil { missing.insert(p) }
            lastSeen[t.ref.device] = max(lastSeen[t.ref.device] ?? 0, t.ref.sequence)
        }
        for (device, last) in lastSeen {
            for seq in 1...last where byRef[TurnRef(device: device, sequence: seq)] == nil {
                missing.insert(TurnRef(device: device, sequence: seq))
            }
        }
        let referenced = Set(turns.flatMap(\.parents))
        self.turns = byRef
        self.heads = byRef.keys.filter { !referenced.contains($0) }.sorted()
        self.missing = missing
        self.unreadable = unreadable
    }

    public var isEmpty: Bool { turns.isEmpty }
    public var isForked: Bool { heads.count > 1 }
    public var isComplete: Bool { missing.isEmpty && unreadable.isEmpty }

    public subscript(ref: TurnRef) -> Turn? { turns[ref] }

    /// Every present turn reachable from `ref` through parents, including
    /// `ref` itself if present. Missing turns are not followed.
    public func ancestry(of ref: TurnRef) -> Set<TurnRef> {
        var seen: Set<TurnRef> = []
        var stack = [ref]
        while let next = stack.popLast() {
            guard let turn = turns[next], seen.insert(next).inserted else { continue }
            stack.append(contentsOf: turn.parents)
        }
        return seen
    }

    /// The turns only `head` reaches, in order: what happened on that
    /// branch and on no other. On a forked log this is the "meanwhile, on
    /// the phone" material; with a single head it is the whole log.
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
        var ready = Set(refs.filter { pending[$0] == 0 && turns[$0] != nil })
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
    /// Other writers for this device kept taking every sequence number the
    /// writer reached for. Each loss means another writer got its turn in.
    case sequenceContended(DeviceID)
    /// The transcript is missing turns; continuing from it would write a
    /// fork that never happened. Read again once they are visible.
    case incompleteTranscript(missing: Set<TurnRef>, unreadable: [RecordID])
}

/// Reads the append-only log.
public struct TurnLog: Sendable {
    let database: any RecordDatabase

    public init(database: any RecordDatabase) {
        self.database = database
    }

    /// The whole log. A record that does not parse is reported in the
    /// transcript's `missing` (by the ref its name carries) or `unreadable`.
    public func read() async throws -> Transcript {
        let records = try await database.query(RecordQuery(type: Turn.recordType))
        return Self.transcript(from: records)
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

    static func transcript(from records: [Record]) -> Transcript {
        var turns: [Turn] = []
        var missing: Set<TurnRef> = []
        var unreadable: [RecordID] = []
        for record in records {
            if let turn = Turn(record: record) {
                turns.append(turn)
            } else if let ref = Turn.ref(ofRecordNamed: record.id.name) {
                missing.insert(ref)
            } else {
                unreadable.append(record.id)
            }
        }
        return Transcript(turns: turns, missing: missing, unreadable: unreadable)
    }
}

/// Appends turns for one device. Each append creates a new record and never
/// touches an existing one: the record ID is the turn's ref, and the save is
/// create-only, so two writers for the same device cannot clobber each other.
/// A writer that finds its sequence number taken moves past every taken
/// number, checking by ID rather than by query so a cold query index cannot
/// mislead it. A retry after a lost acknowledgement finds its own turn
/// already there and returns it rather than writing it twice.
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

    /// Appends a turn continuing from the transcript's heads. Throws
    /// `incompleteTranscript` rather than continue from a read with holes.
    public func append(_ role: TurnRole, _ text: String, continuing transcript: Transcript, at: Date = Date()) async throws -> Turn {
        guard transcript.isComplete else {
            throw TurnLogError.incompleteTranscript(missing: transcript.missing, unreadable: transcript.unreadable)
        }
        return try await append(role, text, parents: transcript.heads, at: at)
    }

    private func appendNow(_ role: TurnRole, _ text: String, parents: [TurnRef], at: Date) async throws -> Turn {
        for _ in 0..<32 {
            let turn = Turn(ref: nextRef, parents: parents, role: role, text: text, at: at)
            do {
                _ = try await database.save(turn.record)
                next += 1
                return turn
            } catch RecordDatabaseError.serverRecordChanged(_, let server) {
                if let existing = Turn(record: server), existing.isSameWrite(as: turn) {
                    next += 1
                    return existing
                }
                next = try await firstFreeSequence(from: next + 1)
            }
        }
        throw TurnLogError.sequenceContended(device)
    }

    /// The first sequence number at or after `start` with no record, found
    /// by fetching IDs in batches. Fetch by ID is read-your-writes; the
    /// query index is not.
    private func firstFreeSequence(from start: Int64) async throws -> Int64 {
        let batch: Int64 = 16
        var from = start
        for _ in 0..<4 {
            let refs = (from..<(from + batch)).map { TurnRef(device: device, sequence: $0) }
            let present = try await database.fetch(refs.map(Turn.recordID(for:)))
            if let free = refs.first(where: { present[Turn.recordID(for: $0)] == nil }) {
                return free.sequence
            }
            from += batch
        }
        throw TurnLogError.sequenceContended(device)
    }
}

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
    /// Marks the append that wrote this turn. A retry after a lost
    /// acknowledgement carries the same nonce, which is how the writer
    /// tells its own turn from another writer's at the same sequence.
    /// Empty when the record carried none: such a turn is nobody's retry.
    public let nonce: String

    public var id: TurnRef { ref }

    public init(ref: TurnRef, parents: [TurnRef], role: TurnRole, text: String, at: Date, nonce: String = UUID().uuidString) {
        self.ref = ref
        self.parents = parents
        self.role = role
        self.text = text
        self.at = at
        self.nonce = nonce
    }

    public static func recordID(for ref: TurnRef) -> RecordID {
        RecordID(recordPrefix + ref.description)
    }

    /// How a turn record, and the marker written beside it, are named. The
    /// marker is what makes a retry find its turn after a restart: creating
    /// it again fails, and the version on the server says where the turn
    /// went.
    static let naming = RecordNaming(prefix: recordPrefix, markerType: "Append",
                                     markerPrefix: "append/", markerField: "turn")

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
            "nonce": .string(nonce),
        ])
    }

    /// Nil if the record is not a well-formed turn: a sequence below 1 is
    /// not one, and so is a record whose fields name a different ref from
    /// its record name, which would otherwise let one record stand in for
    /// another. An absent `parents` field reads as no parents, since
    /// CloudKit may drop an empty list, and an absent `nonce` reads as
    /// empty, so a record written without one still reads as a turn.
    public init?(record: Record) {
        guard record.type == Turn.recordType,
              let device = record.string("device"),
              let sequence = record.int("sequence"), sequence >= 1,
              Turn.ref(ofRecordNamed: record.id.name) == TurnRef(device: DeviceID(device), sequence: sequence),
              let roleString = record.string("role"), let role = TurnRole(rawValue: roleString),
              let text = record.string("text"),
              let at = record.date("at") else { return nil }
        let parentStrings = record.strings("parents") ?? []
        let parents = parentStrings.compactMap(TurnRef.init(parsing:))
        guard parents.count == parentStrings.count else { return nil }
        self.init(ref: TurnRef(device: DeviceID(device), sequence: sequence),
                  parents: parents, role: role, text: text, at: at,
                  nonce: record.string("nonce") ?? "")
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

    /// Records of the turn type whose name is not a ref with a sequence of
    /// 1 or more. Nothing can be said about them.
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
        for (device, last) in lastSeen where last >= 1 {
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
    /// A marker for this nonce exists but the turn it names cannot be read.
    /// The two are written atomically, so this is a damaged log.
    case markerWithoutTurn(nonce: String)
}

/// Reads the append-only log.
public struct TurnLog: Sendable {
    let database: any RecordDatabase

    public init(database: any RecordDatabase) {
        self.database = database
    }

    /// The whole log. A record that does not parse is reported in the
    /// transcript's `missing` (by the ref its name carries) or `unreadable`.
    ///
    /// The records come from the zone's change feed, not a query: it needs
    /// no index and misses no record. The feed is eventually consistent and
    /// a newest turn it has not caught up with leaves no gap behind it, so
    /// after it every known device's next sequence is fetched by ID, which
    /// is read-your-writes; one that exists is reported missing. A device
    /// none of whose turns the feed returned cannot be probed this way; a
    /// writer checks its own newest turn itself before continuing.
    public func read() async throws -> Transcript {
        let records = try await database.records(ofType: Turn.recordType)
        let seen = Self.transcript(from: records)
        var last: [DeviceID: Int64] = [:]
        for ref in seen.turns.keys { last[ref.device] = max(last[ref.device] ?? 0, ref.sequence) }
        for ref in seen.missing { last[ref.device] = max(last[ref.device] ?? 0, ref.sequence) }
        let probes = last.map { TurnRef(device: $0.key, sequence: $0.value + 1) }
        guard !probes.isEmpty else { return seen }
        let present = try await database.fetch(probes.map(Turn.recordID(for:)))
        let hidden = probes.filter { present[Turn.recordID(for: $0)] != nil }
        guard !hidden.isEmpty else { return seen }
        return Transcript(turns: Array(seen.turns.values), missing: seen.missing.union(hidden), unreadable: seen.unreadable)
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

    /// A writer for this device, starting after its last written turn. The
    /// query gives the starting point and a fetch by ID past it corrects
    /// for an index that has not caught up.
    public func writer(for device: DeviceID) async throws -> TurnWriter {
        let last = try await read(device: device, after: 0).last?.ref.sequence ?? 0
        let writer = TurnWriter(database: database, device: device, next: last + 1)
        try await writer.syncWithLog()
        return writer
    }

    static func transcript(from records: [Record]) -> Transcript {
        var turns: [Turn] = []
        var missing: Set<TurnRef> = []
        var unreadable: [RecordID] = []
        for record in records {
            if let turn = Turn(record: record) {
                turns.append(turn)
            } else if let ref = Turn.ref(ofRecordNamed: record.id.name), ref.sequence >= 1 {
                missing.insert(ref)
            } else {
                unreadable.append(record.id)
            }
        }
        return Transcript(turns: turns, missing: missing, unreadable: unreadable)
    }
}

/// Appends turns for one device. Each append creates a new record and never
/// touches an existing one, under a sequence number that is this device's
/// alone; the writing itself is `SequenceAppender`, which is also what makes
/// an append idempotent under retry.
public actor TurnWriter {
    private let appender: SequenceAppender
    public let device: DeviceID

    init(database: any RecordDatabase, device: DeviceID, next: Int64) {
        self.device = device
        self.appender = SequenceAppender(database: database, naming: Turn.naming, device: device, next: next)
    }

    /// The ref the next append will take, barring contention.
    public var nextRef: TurnRef {
        get async { TurnRef(device: device, sequence: await appender.nextSequence) }
    }

    /// Appends a turn continuing from `parents`. Pass the transcript's heads
    /// to carry on from wherever the log is, fork included. Appends on one
    /// writer run one at a time, in the order they were called. `nonce`
    /// identifies this append; pass the same one again when retrying after
    /// `unavailable`, and leave it to default otherwise. An empty nonce is
    /// replaced by a fresh one: it could never name a marker.
    public func append(_ role: TurnRole, _ text: String, parents: [TurnRef], at: Date = Date(),
                       nonce: String = UUID().uuidString) async throws -> Turn {
        try await appended(role, text, parents: parents, at: at, nonce: nonce, save: nil)
    }

    /// Appends a turn in one atomic batch with a heartbeat of `lease`, so the
    /// turn lands only if this device still holds the lease it last wrote and
    /// a device displaced while it was working writes nothing. Returns nil,
    /// with nothing written, when the lease is not held (see
    /// `PrimaryLease.heartbeat(saving:)`); otherwise as `append(_:_:parents:at:nonce:)`,
    /// a retried nonce included.
    public func append(_ role: TurnRole, _ text: String, parents: [TurnRef], at: Date = Date(),
                       nonce: String = UUID().uuidString, renewing lease: PrimaryLease) async throws -> Turn? {
        do {
            return try await appended(role, text, parents: parents, at: at, nonce: nonce) { records in
                guard let saved = try await lease.heartbeat(saving: records) else { throw LeaseNotHeld() }
                return saved
            }
        } catch is LeaseNotHeld {
            return nil
        }
    }

    private struct LeaseNotHeld: Error {}

    private func appended(_ role: TurnRole, _ text: String, parents: [TurnRef], at: Date, nonce: String,
                          save: (@Sendable ([Record]) async throws -> [Record])?) async throws -> Turn {
        let device = self.device
        do {
            let record = try await appender.append(nonce: nonce, save: save) { sequence, nonce in
                Turn(ref: TurnRef(device: device, sequence: sequence), parents: parents,
                     role: role, text: text, at: at, nonce: nonce).record
            }
            guard let turn = Turn(record: record) else {
                throw TurnLogError.markerWithoutTurn(nonce: nonce)
            }
            return turn
        } catch SequenceError.contended(let device) {
            throw TurnLogError.sequenceContended(device)
        } catch SequenceError.markerWithoutRecord(let nonce) {
            throw TurnLogError.markerWithoutTurn(nonce: nonce)
        }
    }

    /// Appends a turn continuing from the transcript's heads. Throws
    /// `incompleteTranscript` rather than continue from a read with holes,
    /// including a read that lacks this device's newest turn: before the
    /// parents are chosen the writer checks by ID, which is read-your-
    /// writes, whether the log holds turns of this device beyond what it
    /// knows, and then whether the transcript holds the newest of them.
    public func append(_ role: TurnRole, _ text: String, continuing transcript: Transcript, at: Date = Date(),
                       nonce: String = UUID().uuidString) async throws -> Turn {
        try await syncWithLog()
        var missing = transcript.missing
        let next = await appender.nextSequence
        if next > 1 {
            let own = TurnRef(device: device, sequence: next - 1)
            if transcript[own] == nil { missing.insert(own) }
        }
        guard missing.isEmpty, transcript.unreadable.isEmpty else {
            throw TurnLogError.incompleteTranscript(missing: missing, unreadable: transcript.unreadable)
        }
        return try await append(role, text, parents: transcript.heads, at: at, nonce: nonce)
    }

    /// Moves past any turn of this device the log already holds at or after
    /// the next sequence number, found by ID rather than by query.
    func syncWithLog() async throws {
        do {
            try await appender.syncWithStore()
        } catch SequenceError.contended(let device) {
            throw TurnLogError.sequenceContended(device)
        }
    }
}

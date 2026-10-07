import Foundation

/// How one kind of sequenced record is named. Every append writes two
/// records in one atomic batch: the record itself, named by the device and
/// its sequence number, and a marker named by the append's nonce holding
/// the name of the record it wrote.
struct RecordNaming: Sendable {
    /// Prefixes the record's name; the rest is `device/sequence`.
    let prefix: String
    let markerType: String
    let markerPrefix: String
    /// The marker's one field, holding `device/sequence`.
    let markerField: String

    func recordID(_ device: DeviceID, _ sequence: Int64) -> RecordID {
        RecordID("\(prefix)\(device.rawValue)/\(sequence)")
    }

    /// The record named by a marker's field value.
    func recordID(named name: String) -> RecordID { RecordID(prefix + name) }

    func markerID(nonce: String) -> RecordID { RecordID(markerPrefix + nonce) }

    func marker(nonce: String, device: DeviceID, sequence: Int64) -> Record {
        Record(type: markerType, id: markerID(nonce: nonce),
               fields: [markerField: .string("\(device.rawValue)/\(sequence)")])
    }

    /// The sequence number a marker names, if it names a record of this
    /// device. Nil if it names another device's record or does not parse.
    func sequence(named marker: Record, device: DeviceID) -> Int64? {
        guard let value = marker.string(markerField),
              let slash = value.lastIndex(of: "/"),
              String(value[..<slash]) == device.rawValue,
              let sequence = Int64(value[value.index(after: slash)...]) else { return nil }
        return sequence
    }
}

enum SequenceError: Error, Sendable {
    /// Other writers for this device kept taking every sequence number this
    /// one reached for.
    case contended(DeviceID)
    /// A marker for this nonce exists but the record it names cannot be
    /// fetched. The two are written atomically, so this is damaged data.
    case markerWithoutRecord(nonce: String)
    /// An append that had to land on the sequence number it expected found that number taken,
    /// by another writer or by an append ahead of it. Nothing was written.
    case taken(Int64)
}

/// Writes create-only records under one device's sequence numbers, one
/// append at a time.
///
/// The record's name is the device and its sequence number, and the save is
/// create-only, so two writers for the same device cannot clobber each
/// other; a writer that finds its number taken moves past every taken
/// number, checking by ID rather than by query so a cold query index cannot
/// mislead it. Each append saves a marker named by its nonce in the same
/// atomic batch, so an append that throws `unavailable` after committing is
/// found again by any retry carrying the same nonce, on this appender or on
/// one started after a relaunch, however many appends have gone through in
/// between: the marker refuses to be created twice and names the record.
actor SequenceAppender {
    private let database: any RecordDatabase
    private let naming: RecordNaming
    let device: DeviceID
    private var next: Int64
    private var queue: Task<Record, any Error>?

    init(database: any RecordDatabase, naming: RecordNaming, device: DeviceID, next: Int64) {
        self.database = database
        self.naming = naming
        self.device = device
        self.next = next
    }

    /// The sequence number the next append will take, barring contention.
    var nextSequence: Int64 { next }

    /// Appends one record, built by `make` for whichever sequence number it
    /// lands on and under the nonce this append is actually carrying — which
    /// the record has to hold, since it is what a retry matches on. Appends
    /// run in the order they were called. Pass the same `nonce` again when
    /// retrying after `unavailable`. An empty nonce is replaced by a fresh
    /// one: it could never name a marker, and a record written without one
    /// reads as having an empty nonce, so an empty one would match every
    /// such record rather than this append's own.
    /// `save` is how the batch reaches the store. It defaults to a plain
    /// save; a caller that has to land the record together with something
    /// else of its own — a lease heartbeat, so a displaced device writes
    /// nothing — passes its own, and whatever that throws comes back out
    /// of here untouched. `exact` is for a record built from what the caller knew of this
    /// device's records, and is the sequence number it took to be next: when the append's turn
    /// comes and that number is no longer next (an append ahead of it in the queue took it),
    /// or another writer's record is found on it, there is a record the caller did not know
    /// of, and the append throws `taken` with nothing written rather than step past it. An
    /// append that already went through under this nonce is still found and returned.
    func append(nonce: String, exact: Int64? = nil,
                save: (@Sendable ([Record]) async throws -> [Record])? = nil,
                _ make: @escaping @Sendable (Int64, String) -> Record) async throws -> Record {
        let nonce = nonce.isEmpty ? UUID().uuidString : nonce
        let database = database
        let save = save ?? { try await database.save($0) }
        let previous = queue
        let task = Task<Record, any Error> {
            _ = try? await previous?.value
            return try await appendNow(nonce: nonce, exact: exact, save: save, make)
        }
        queue = task
        // The append runs in a task of its own so the next one can wait on it; the caller's
        // cancellation is passed on, so a `save` that waits (a lease's turn) can end unwritten.
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Moves past any record of this device the store already holds at or
    /// after the next sequence number, found by ID rather than by query.
    func syncWithStore() async throws {
        if try await database.fetch(naming.recordID(device, next)) != nil {
            next = try await firstFreeSequence(from: next + 1)
        }
    }

    private func appendNow(nonce: String, exact: Int64?,
                           save: @Sendable ([Record]) async throws -> [Record],
                           _ make: @Sendable (Int64, String) -> Record) async throws -> Record {
        if let exact, next != exact {
            if let marker = try await database.fetch(naming.markerID(nonce: nonce)) {
                return try await recordNamed(by: marker, nonce: nonce)
            }
            throw SequenceError.taken(exact)
        }
        for _ in 0..<32 {
            let record = make(next, nonce)
            let marker = naming.marker(nonce: nonce, device: device, sequence: next)
            do {
                _ = try await save([marker, record])
                next += 1
                return record
            } catch RecordDatabaseError.serverRecordChanged(let id, let server) {
                if id == naming.markerID(nonce: nonce) {
                    // This append already went through: the marker says where.
                    return try await recordNamed(by: server, nonce: nonce)
                }
                if server.string("nonce") == nonce {
                    // Another writer for this device wrote this very append.
                    next += 1
                    return server
                }
                let taken = next
                next = try await firstFreeSequence(from: next + 1)
                if exact != nil { throw SequenceError.taken(taken) }
            }
        }
        throw SequenceError.contended(device)
    }

    private func recordNamed(by marker: Record, nonce: String) async throws -> Record {
        guard let name = marker.string(naming.markerField),
              let record = try await database.fetch(naming.recordID(named: name)) else {
            throw SequenceError.markerWithoutRecord(nonce: nonce)
        }
        if let sequence = naming.sequence(named: marker, device: device) {
            next = max(next, sequence + 1)
        }
        return record
    }

    /// The first sequence number at or after `start` with no record, found
    /// by fetching IDs in batches. Fetch by ID is read-your-writes; the
    /// query index is not.
    private func firstFreeSequence(from start: Int64) async throws -> Int64 {
        let batch: Int64 = 16
        var from = start
        for _ in 0..<4 {
            let sequences = Array(from..<(from + batch))
            let present = try await database.fetch(sequences.map { naming.recordID(device, $0) })
            if let free = sequences.first(where: { present[naming.recordID(device, $0)] == nil }) {
                return free
            }
            from += batch
        }
        throw SequenceError.contended(device)
    }
}

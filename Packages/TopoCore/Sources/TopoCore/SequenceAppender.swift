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
    /// lands on. Appends run in the order they were called. Pass the same
    /// `nonce` again when retrying after `unavailable`.
    func append(nonce: String, _ make: @escaping @Sendable (Int64) -> Record) async throws -> Record {
        let previous = queue
        let task = Task<Record, any Error> {
            _ = try? await previous?.value
            return try await appendNow(nonce: nonce, make)
        }
        queue = task
        return try await task.value
    }

    /// Moves past any record of this device the store already holds at or
    /// after the next sequence number, found by ID rather than by query.
    func syncWithStore() async throws {
        if try await database.fetch(naming.recordID(device, next)) != nil {
            next = try await firstFreeSequence(from: next + 1)
        }
    }

    private func appendNow(nonce: String, _ make: @Sendable (Int64) -> Record) async throws -> Record {
        for _ in 0..<32 {
            let record = make(next)
            let marker = naming.marker(nonce: nonce, device: device, sequence: next)
            do {
                _ = try await database.save([marker, record])
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
                next = try await firstFreeSequence(from: next + 1)
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

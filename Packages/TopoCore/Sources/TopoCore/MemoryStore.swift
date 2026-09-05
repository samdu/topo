import Foundation

/// The memory: a folder of markdown held as records in the private
/// database, one record per revision.
///
/// It is the same arrangement as the transcript, for the same reason.
/// Nothing is ever overwritten: a revision's record is named by the device
/// that wrote it and its sequence number on that device, and every save is
/// create-only, so two devices writing the same file at the same moment
/// leave two revisions rather than one clobbering the other. What that
/// means for a reader is in `Vault`: the newer revision is the file, and
/// the other is a conflict copy beside it.
///
/// `VaultMirror` is what makes this a vault you can open: it keeps a
/// directory on disk holding these files, so Obsidian or the hub reads and
/// writes plain markdown and the store is what carries it between devices.
public struct MemoryStore: Sendable {
    let database: any RecordDatabase

    public init(database: any RecordDatabase) {
        self.database = database
    }

    /// The whole memory. A record that does not parse is reported in the
    /// vault's `missing` (by the ref its name carries) or `unreadable`.
    ///
    /// The query index is eventually consistent and a newest revision it
    /// has not caught up with leaves no gap behind it, so after the query
    /// every known device's next sequence is fetched by ID, which is
    /// read-your-writes; one that exists is reported missing. A device none
    /// of whose revisions the query returned cannot be probed this way; a
    /// writer checks its own by ID before it writes.
    public func read() async throws -> Vault {
        // Every revision has a positive sequence, so this is the whole
        // memory. It is not a match-all predicate because CloudKit answers
        // one of those from the record name's index, which the development
        // schema never marks queryable; the index behind a field of our own
        // is built when the first record carrying it is saved.
        let records = try await database.query(RecordQuery(type: Note.recordType, filters: [
            .init("sequence", .greaterThan, .int(0)),
        ]))
        let seen = Self.vault(from: records)
        var last: [DeviceID: Int64] = [:]
        for ref in seen.notes.keys { last[ref.device] = max(last[ref.device] ?? 0, ref.sequence) }
        for ref in seen.missing { last[ref.device] = max(last[ref.device] ?? 0, ref.sequence) }
        let probes = last.map { NoteRef(device: $0.key, sequence: $0.value + 1) }
        guard !probes.isEmpty else { return seen }
        let present = try await database.fetch(probes.map(Note.recordID(for:)))
        let hidden = probes.filter { present[Note.recordID(for: $0)] != nil }
        guard !hidden.isEmpty else { return seen }
        return Vault(notes: Array(seen.notes.values), missing: seen.missing.union(hidden),
                     unreadable: seen.unreadable)
    }

    /// One device's revisions after a sequence number, in sequence order.
    /// `after: 0` is everything that device wrote.
    public func read(device: DeviceID, after sequence: Int64) async throws -> [Note] {
        let records = try await database.query(RecordQuery(type: Note.recordType, filters: [
            .init("device", .equals, .string(device.rawValue)),
            .init("sequence", .greaterThan, .int(sequence)),
        ]))
        return records.compactMap(Note.init(record:)).sorted { $0.ref.sequence < $1.ref.sequence }
    }

    /// A writer for this device, starting after its last written revision.
    /// The query gives the starting point and a fetch by ID past it
    /// corrects for an index that has not caught up.
    public func writer(for device: DeviceID) async throws -> NoteWriter {
        let last = try await read(device: device, after: 0).last?.ref.sequence ?? 0
        let writer = NoteWriter(database: database, device: device, next: last + 1)
        try await writer.syncWithStore()
        return writer
    }

    /// Where the memory is mirrored outside CloudKit, or nil for nowhere.
    public func remote() async throws -> VaultRemote? {
        guard let record = try await database.fetch(VaultRemote.recordID),
              let url = record.string("url"), !url.isEmpty else { return nil }
        return VaultRemote(url: url, branch: record.string("branch") ?? "main")
    }

    /// Records where the memory is mirrored, or nothing. This one record is
    /// mutable, because it is a setting rather than a revision: the save is
    /// a compare-and-set on the version that was read, and a save that
    /// loses is tried again on the version that won.
    public func setRemote(_ remote: VaultRemote?) async throws {
        for _ in 0..<4 {
            var record = try await database.fetch(VaultRemote.recordID)
                ?? Record(type: VaultRemote.recordType, id: VaultRemote.recordID)
            record["url"] = .string(remote?.url ?? "")
            record["branch"] = .string(remote?.branch ?? "main")
            do {
                _ = try await database.save(record)
                return
            } catch RecordDatabaseError.serverRecordChanged {
                continue
            }
        }
        throw MemoryError.settingContended(VaultRemote.recordID)
    }

    static func vault(from records: [Record]) -> Vault {
        var notes: [Note] = []
        var missing: Set<NoteRef> = []
        var unreadable: [RecordID] = []
        for record in records {
            if let note = Note(record: record) {
                notes.append(note)
            } else if let ref = Note.ref(ofRecordNamed: record.id.name), ref.sequence >= 1 {
                missing.insert(ref)
            } else {
                unreadable.append(record.id)
            }
        }
        return Vault(notes: notes, missing: missing, unreadable: unreadable)
    }
}

/// Writes revisions for one device. Every write creates a new record and
/// touches no existing one; the writing itself is `SequenceAppender`, which
/// is also what makes a write idempotent under retry.
public actor NoteWriter {
    private let appender: SequenceAppender
    public let device: DeviceID

    init(database: any RecordDatabase, device: DeviceID, next: Int64) {
        self.device = device
        self.appender = SequenceAppender(database: database, naming: Note.naming, device: device, next: next)
    }

    /// The ref the next write will take, barring contention.
    public var nextRef: NoteRef {
        get async { NoteRef(device: device, sequence: await appender.nextSequence) }
    }

    /// Writes a file, continuing from the revisions of that path the writer
    /// actually saw. Naming a revision as a parent says this write replaces
    /// it, so `parents` is exactly what was read and edited from and never
    /// more: a revision written elsewhere since, and unseen here, must stay
    /// concurrent, which is what leaves a conflict copy rather than quietly
    /// dropping it. `nonce` identifies this write; pass the same one again
    /// when retrying after `unavailable`, and leave it to default otherwise.
    @discardableResult
    public func write(_ text: String, to path: VaultPath, after parents: [NoteRef], continuing vault: Vault,
                      at: Date = Date(), nonce: String = UUID().uuidString) async throws -> Note {
        try await save(text: text, deleted: false, to: path, after: parents, continuing: vault, at: at, nonce: nonce)
    }

    /// Writes a file, continuing from every revision of that path the vault
    /// holds as a head: for a writer working from a vault it has just read,
    /// which is a write that resolves a fork it can see.
    @discardableResult
    public func write(_ text: String, to path: VaultPath, continuing vault: Vault,
                      at: Date = Date(), nonce: String = UUID().uuidString) async throws -> Note {
        try await save(text: text, deleted: false, to: path, after: vault.heads(of: path),
                       continuing: vault, at: at, nonce: nonce)
    }

    /// Removes a file, by writing the revision that says it is gone, after
    /// the revisions the writer saw. An edit it did not see is not
    /// swallowed: it stays a head, and the vault keeps it as a file or a
    /// conflict copy.
    @discardableResult
    public func delete(_ path: VaultPath, after parents: [NoteRef], continuing vault: Vault,
                       at: Date = Date(), nonce: String = UUID().uuidString) async throws -> Note {
        try await save(text: "", deleted: true, to: path, after: parents, continuing: vault, at: at, nonce: nonce)
    }

    /// Removes a file, continuing from every revision of that path the
    /// vault holds as a head.
    @discardableResult
    public func delete(_ path: VaultPath, continuing vault: Vault,
                       at: Date = Date(), nonce: String = UUID().uuidString) async throws -> Note {
        try await save(text: "", deleted: true, to: path, after: vault.heads(of: path),
                       continuing: vault, at: at, nonce: nonce)
    }

    private func save(text: String, deleted: Bool, to path: VaultPath, after parents: [NoteRef],
                      continuing vault: Vault, at: Date, nonce: String) async throws -> Note {
        try await syncWithStore()
        guard vault.isComplete else {
            throw MemoryError.incompleteVault(missing: vault.missing, unreadable: vault.unreadable)
        }
        let device = self.device
        do {
            let record = try await appender.append(nonce: nonce) { sequence, nonce in
                Note(ref: NoteRef(device: device, sequence: sequence), path: path, text: text,
                     isDeleted: deleted, parents: parents, at: at, nonce: nonce).record
            }
            guard let note = Note(record: record) else { throw MemoryError.damagedNote(record.id) }
            return note
        } catch SequenceError.contended(let device) {
            throw MemoryError.sequenceContended(device)
        } catch SequenceError.markerWithoutRecord(let nonce) {
            throw MemoryError.markerWithoutNote(nonce: nonce)
        }
    }

    /// Moves past any revision of this device the store already holds at or
    /// after the next sequence number, found by ID rather than by query.
    func syncWithStore() async throws {
        do {
            try await appender.syncWithStore()
        } catch SequenceError.contended(let device) {
            throw MemoryError.sequenceContended(device)
        }
    }
}

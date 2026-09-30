import Foundation

/// One of the mind's widget slots as a record, so a device with no app group in common with the
/// phone — the watch — can draw it: the document as the phone kept it, its revision, and its
/// images. Record name `surface-<slot>`, type `Surface`, in the one zone.
///
/// The phone saves it beside its own file write and deletes it when the slot is cleared; the
/// watch reads it from the zone's change feed and judges the document itself, since nothing in a
/// record is trusted to have been read.
public struct SurfaceRecord: Equatable, Sendable {
    public static let type = "Surface"

    public var slot: String
    /// The kept document, as the phone wrote it.
    public var document: String
    public var revision: Int
    /// When the phone saved it. Queryable, as `sequence` is for `Turn`, so a subscription can
    /// match every save.
    public var updated: Date
    /// The device id of the phone that saved it: the one a tap on it is for.
    public var runner: String
    /// The slot's images by name, each a PNG.
    public var images: [String: Data]

    public init(slot: String, document: String, revision: Int, updated: Date, runner: String, images: [String: Data] = [:]) {
        self.slot = slot
        self.document = document
        self.revision = revision
        self.updated = updated
        self.runner = runner
        self.images = images
    }

    public static func id(slot: String) -> RecordID { RecordID("surface-\(slot)") }

    /// The slot a record name is for, or nil when it is not a surface's.
    public static func slot(of id: RecordID) -> String? {
        id.name.hasPrefix("surface-") ? String(id.name.dropFirst("surface-".count)) : nil
    }

    var fields: [String: FieldValue] {
        let names = images.keys.sorted()
        return [
            "slot": .string(slot), "document": .string(document), "revision": .int(Int64(revision)),
            "updated": .date(updated), "runner": .string(runner),
            "imageNames": .strings(names), "images": .assets(names.map { images[$0]! }),
        ]
    }

    /// A record read back, or nil when it is not a whole surface: a field missing, or images
    /// whose names and files do not line up.
    public init?(_ record: Record) {
        guard record.type == Self.type, let slot = Self.slot(of: record.id), record.string("slot") == slot,
              let document = record.string("document"), let revision = record.int("revision"),
              let updated = record.date("updated"), let runner = record.string("runner") else { return nil }
        let names = record.strings("imageNames") ?? []
        let files = record.assets("images") ?? []
        guard names.count == files.count, Set(names).count == names.count else { return nil }
        self.init(slot: slot, document: document, revision: Int(revision), updated: updated, runner: runner,
                  images: Dictionary(uniqueKeysWithValues: zip(names, files)))
    }
}

/// The `Surface` records: saved with a compare-and-set, deleted on a clear and a sign-out, and
/// read from the change feed. A record belongs to its `runner`, the phone that saved it: the newer
/// revision wins between two saves of one runner, a save over another runner's record replaces it,
/// and a sign-out deletes only the signing-out phone's own.
public struct SurfaceRecords: Sendable {
    public let database: any ZoneDatabase

    public init(database: any ZoneDatabase) {
        self.database = database
    }

    public enum Saved: Equatable, Sendable {
        case saved
        /// The server holds a later revision of this runner's than this one, which is kept.
        case newerKept(revision: Int)
    }

    /// Saves `surface` over the slot's record under its change tag. An older revision never
    /// overwrites a newer one of the same runner; the same revision does, since a toggle's state
    /// changes under one. Another runner's record is replaced whatever its revision: the counters
    /// are each phone's own, so its revision says nothing of this one's, and it is left over from
    /// a phone (or an install) that no longer writes the slots.
    /// A save refused for its tag — another writer between the fetch and the save — is judged
    /// again against the record the refusal carries and tried once more; a second refusal throws.
    @discardableResult
    public func save(_ surface: SurfaceRecord) async throws -> Saved {
        let id = SurfaceRecord.id(slot: surface.slot)
        var current = try await database.fetch(id)
        var attempt = 0
        while true {
            if let current, current.string("runner") == surface.runner,
               let revision = current.int("revision"), Int(revision) > surface.revision {
                return .newerKept(revision: Int(revision))
            }
            var record = current ?? Record(type: SurfaceRecord.type, id: id)
            record.fields = surface.fields
            do {
                _ = try await database.save(record)
                return .saved
            } catch RecordDatabaseError.serverRecordChanged(_, let server) where attempt == 0 {
                current = server
            } catch RecordDatabaseError.unknownItem where attempt == 0 {
                // Deleted between the fetch and the save: this save creates it.
                current = nil
            }
            attempt += 1
        }
    }

    /// Deletes the slot's record; one already gone is not an error.
    public func delete(slot: String) async throws {
        try await database.delete([SurfaceRecord.id(slot: slot)])
    }

    /// Deletes every surface record `runner` saved: a sign-out's, which leaves another phone's
    /// alone. Found from the change feed, which sees every record whether or not an index has
    /// caught up with it.
    public func deleteAll(of runner: String) async throws {
        let ids = try await database.records(ofType: SurfaceRecord.type).filter { $0.string("runner") == runner }.map(\.id)
        try await database.delete(ids)
    }

    /// Deletes every surface record not saved by `runner`, one with no runner included: what an
    /// earlier primary, or an earlier install of this one, left behind.
    public func deleteAll(except runner: String) async throws {
        let ids = try await database.records(ofType: SurfaceRecord.type).filter { $0.string("runner") != runner }.map(\.id)
        try await database.delete(ids)
    }

    /// Whether the slot's record is there now. `.gone` only when the store answered that there is
    /// none, which is the one answer that confirms a slot removed; a failure to ask throws.
    public func fetch(slot: String) async throws -> Fetched {
        guard let record = try await database.fetch(SurfaceRecord.id(slot: slot)) else { return .gone }
        return SurfaceRecord(record).map(Fetched.surface) ?? .unreadable
    }

    public enum Fetched: Equatable, Sendable {
        case surface(SurfaceRecord)
        /// There, but not a whole surface.
        case unreadable
        case gone
    }

    /// What changed since `token`: the surfaces saved (a record that is not a whole surface is
    /// listed by slot in `unreadable`), the slots deleted, and the next token.
    public func changes(since token: Data?) async throws -> Changes {
        let changes = try await database.changes(ofType: SurfaceRecord.type, since: token)
        var surfaces: [SurfaceRecord] = []
        var unreadable: [String] = []
        for record in changes.changed {
            if let surface = SurfaceRecord(record) { surfaces.append(surface) }
            else if let slot = SurfaceRecord.slot(of: record.id) { unreadable.append(slot) }
        }
        return Changes(saved: surfaces, unreadable: unreadable, deleted: changes.deleted.compactMap(SurfaceRecord.slot(of:)),
                       token: changes.token)
    }

    public struct Changes: Sendable {
        public var saved: [SurfaceRecord]
        public var unreadable: [String]
        public var deleted: [String]
        public var token: Data
    }
}

import Foundation

/// One of the mind's widget slots as a record, so a device with no app group in common with the
/// phone — the watch — can draw it: the document as the phone kept it, its revision, and its
/// images. Record name `surface-<slot>`, type `Surface`, in the one zone.
///
/// The phone saves it beside its own file write and clears it when the slot is cleared; the
/// watch reads it from the zone's change feed and judges the document itself, since nothing in a
/// record is trusted to have been read.
///
/// A slot is never physically deleted by the phone. CloudKit's deletes take record ids alone —
/// `savePolicy` governs saves, never `recordIDsToDelete` — so a delete cannot be made conditional
/// on what the deleting phone read, and another phone's newer record would go with it. A clear is
/// a save instead: a tombstone (`cleared`, the slot, the runner, `updated`, no document and no
/// images) under the change tag of the read it acted on, which the feed reports as a deletion.
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

/// The `Surface` records, as single compare-and-set steps: each write carries the change tag of
/// the read it acted on, so a record another phone wrote since that read refuses it with
/// `serverRecordChanged`, and what to do then — read again, ask whose it is, drop it — is the
/// caller's, which knows its role. A record belongs to its `runner`: the newer revision wins
/// between two saves of one runner, and a save over another runner's record replaces it.
public struct SurfaceRecords: Sendable {
    public let database: any ZoneDatabase

    public init(database: any ZoneDatabase) {
        self.database = database
    }

    /// A slot's record as one read found it, the change tag with it.
    public enum Read: Equatable, Sendable {
        /// No record.
        case none
        case live(SurfaceRecord, Record)
        /// A tombstone: the slot was cleared by `runner`.
        case cleared(runner: String?, Record)
        /// There, but not a whole surface or a tombstone.
        case unreadable(Record)

        public init(_ record: Record?) {
            guard let record else { self = .none; return }
            if record.int("cleared") == 1 {
                self = .cleared(runner: record.string("runner"), record)
            } else if let surface = SurfaceRecord(record) {
                self = .live(surface, record)
            } else {
                self = .unreadable(record)
            }
        }

        /// The record read, with its change tag; nil when there was none.
        public var record: Record? {
            switch self {
            case .none: nil
            case .live(_, let record), .cleared(_, let record), .unreadable(let record): record
            }
        }

        /// Who saved it, as far as the record says.
        public var runner: String? { record?.string("runner") }

        /// Whether it holds a slot: a whole surface, or a record that is not a tombstone.
        public var holds: Bool {
            switch self {
            case .live, .unreadable: true
            case .none, .cleared: false
            }
        }

        public var slot: String? { record.flatMap { SurfaceRecord.slot(of: $0.id) } }
    }

    public enum Saved: Equatable, Sendable {
        case saved
        /// The read found a later revision of this runner's than this one, which is kept.
        case newerKept(revision: Int)
    }

    public func read(slot: String) async throws -> Read {
        Read(try await database.fetch(SurfaceRecord.id(slot: slot)))
    }

    /// Every surface record in the zone, found from the change feed, which sees every record
    /// whether or not an index has caught up with it.
    public func all() async throws -> [Read] {
        try await database.records(ofType: SurfaceRecord.type).map(Read.init)
    }

    /// Saves `surface` over what `read` found, under its change tag: one attempt, refused with
    /// `serverRecordChanged` if the record moved since. An older revision never overwrites a newer
    /// one of the same runner; the same revision does, since a toggle's state changes under one.
    /// Another runner's record, and a tombstone, are replaced whatever they held.
    @discardableResult
    public func save(_ surface: SurfaceRecord, over read: Read) async throws -> Saved {
        if case .live(let current, _) = read, current.runner == surface.runner, current.revision > surface.revision {
            return .newerKept(revision: current.revision)
        }
        var record = read.record ?? Record(type: SurfaceRecord.type, id: SurfaceRecord.id(slot: surface.slot))
        record.fields = surface.fields
        _ = try await database.save(record)
        return .saved
    }

    /// Clears the slot over what `read` found, under its change tag: a tombstone saved by
    /// `runner`, refused with `serverRecordChanged` if the record moved since. Nothing is written
    /// where the read found no record or a tombstone. Answers the tombstone's record, with its tag.
    @discardableResult
    public func clear(slot: String, runner: String, at updated: Date, over read: Read) async throws -> Record? {
        guard read.holds, var record = read.record else { return nil }
        // The empty lists are written as nils, which takes the images off even where the record
        // read held assets that could not be loaded.
        record.fields = ["slot": .string(slot), "runner": .string(runner), "updated": .date(updated), "cleared": .int(1),
                         "imageNames": .strings([]), "images": .assets([])]
        return try await database.save(record)
    }

    /// Whether the slot's record is there now. `.gone` only when the store answered that there is
    /// none, which is the one answer that confirms a slot removed; a failure to ask throws.
    public func fetch(slot: String) async throws -> Fetched {
        switch try await read(slot: slot) {
        case .none, .cleared: return .gone
        case .live(let surface, _): return .surface(surface)
        case .unreadable: return .unreadable
        }
    }

    public enum Fetched: Equatable, Sendable {
        case surface(SurfaceRecord)
        /// There, but not a whole surface.
        case unreadable
        case gone
    }

    /// What changed since `token`: the surfaces saved (a record that is not a whole surface is
    /// listed by slot in `unreadable`), the slots cleared or deleted, and the next token.
    public func changes(since token: Data?) async throws -> Changes {
        let changes = try await database.changes(ofType: SurfaceRecord.type, since: token)
        var surfaces: [SurfaceRecord] = []
        var unreadable: [String] = []
        var deleted = changes.deleted.compactMap(SurfaceRecord.slot(of:))
        for record in changes.changed {
            guard let slot = SurfaceRecord.slot(of: record.id) else { continue }
            switch Read(record) {
            case .live(let surface, _): surfaces.append(surface)
            case .cleared: deleted.append(slot)
            case .unreadable: unreadable.append(slot)
            case .none: break
            }
        }
        return Changes(saved: surfaces, unreadable: unreadable, deleted: deleted, token: changes.token)
    }

    public struct Changes: Sendable {
        public var saved: [SurfaceRecord]
        public var unreadable: [String]
        public var deleted: [String]
        public var token: Data
    }
}

import Foundation

/// The record store of a phone with no iCloud account: `RecordStoreCore`'s semantics, which are
/// `InMemoryRecordDatabase`'s, held in memory and journalled to one file, so the log, the lease,
/// the memory's store and the widgets' slots survive a relaunch on a phone with nowhere else to
/// keep them.
///
/// The journal is a header frame and then one frame per save or delete, each a 4-byte
/// big-endian length and a binary plist, appended and synchronised to the disk before the call
/// answers. A batch is one frame, so it is on disk whole or not at all: a last frame cut short
/// or unreadable at open is a write whose caller never had an answer, which every writer
/// already settles as one that may have landed, and it is dropped and the file cut back to the
/// frame before it. A frame before the last that does not read is damage, not a torn write, and
/// opening refuses the file rather than guess at what it held.
///
/// When the journal holds more than twice as many saved records as the store does, opening
/// rewrites it as one snapshot under a new feed epoch (a sibling written whole and renamed
/// over), and every feed token handed out before expires, as CloudKit's do. Tags and tokens
/// carry the file's own id, so one from another file is never honoured.
///
/// The file's I/O runs on the actor's own serial queue, never the cooperative pool.
public actor LocalRecordDatabase: ZoneDatabase {
    /// What a frame holds.
    private enum Frame: Codable {
        /// The file's first frame: its id and the journal's version.
        case header(store: String, version: Int)
        /// The whole store as a compaction wrote it.
        case snapshot(records: [Record], minted: Int64, epoch: Int64)
        case applied(RecordStoreCore.Applied)
    }

    public enum OpenError: Error, Sendable {
        /// A frame before the last does not read, or the header is not this journal's.
        case damaged(URL, offset: Int)
    }

    static let version = 1

    private let queue: DispatchSerialQueue
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let file: URL
    private var core: RecordStoreCore
    private let handle: FileHandle
    /// Why the journal takes no more writes: a failed write it could not cut back.
    private var broken: (any Error)?

    /// Opens the journal at `file`, making it when it is not there.
    public init(file: URL) throws {
        self.file = file
        queue = DispatchSerialQueue(label: "topo.local-records")
        let manager = FileManager.default
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: Self.protection)
        if !manager.fileExists(atPath: file.path) {
            let store = UUID().uuidString
            var bytes = Data()
            try Self.append(.header(store: store, version: Self.version), to: &bytes)
            guard manager.createFile(atPath: file.path, contents: bytes, attributes: Self.protection) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
            }
        }
        var (core, savedInJournal, goodLength, fileLength) = try Self.replay(file)
        if goodLength < fileLength {
            // A torn last write: cut it away so the next frame follows the last whole one.
            let truncating = try FileHandle(forWritingTo: file)
            try truncating.truncate(atOffset: UInt64(goodLength))
            try truncating.synchronize()
            try truncating.close()
        }
        if savedInJournal > 2 * max(core.records.count, 1) {
            core.expireTokens()
            try Self.compact(core, into: file)
        }
        self.core = core
        handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    /// Until first unlock: turns are written behind the lock, so the file has to be writable
    /// then, and it is the person's only copy on this phone, so it is left in their backups.
    private static var protection: [FileAttributeKey: Any] {
        #if os(iOS)
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        [:]
        #endif
    }

    // MARK: The journal

    private static func append(_ frame: Frame, to bytes: inout Data) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let body = try encoder.encode(frame)
        var length = UInt32(body.count).bigEndian
        bytes.append(Data(bytes: &length, count: 4))
        bytes.append(body)
    }

    /// The store as the journal holds it, how many records its frames saved, how many bytes of
    /// it are whole frames, and how long the file is.
    private static func replay(_ file: URL) throws -> (RecordStoreCore, Int, Int, Int) {
        let bytes = try Data(contentsOf: file)
        let decoder = PropertyListDecoder()
        var offset = 0
        var core: RecordStoreCore?
        var saved = 0
        while offset < bytes.count {
            let start = offset
            guard bytes.count - offset >= 4 else { break }
            let length = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard bytes.count - offset >= length,
                  let frame = try? decoder.decode(Frame.self, from: bytes[offset..<offset + length]) else {
                // A frame that does not read: torn if it is the last, damage otherwise.
                if offset + length < bytes.count { throw OpenError.damaged(file, offset: start) }
                offset = start
                break
            }
            offset += length
            switch (frame, core) {
            case (.header(let store, let version), nil) where version == Self.version:
                core = RecordStoreCore(store: store)
            case (.snapshot(let records, let minted, let epoch), let current?):
                core = RecordStoreCore(store: current.store, records: records, minted: minted, epoch: epoch)
                saved = records.count
            case (.applied(let applied), var current?):
                current.apply(applied)
                core = current
                if case .saved(let records) = applied { saved += records.count }
            default:
                throw OpenError.damaged(file, offset: start)
            }
        }
        guard let core else { throw OpenError.damaged(file, offset: 0) }
        return (core, saved, offset, bytes.count)
    }

    /// Rewrites the journal as its header and one snapshot, written whole beside it and renamed
    /// over it.
    private static func compact(_ core: RecordStoreCore, into file: URL) throws {
        var bytes = Data()
        try append(.header(store: core.store, version: version), to: &bytes)
        try append(.snapshot(records: core.records.values.sorted { $0.id.name < $1.id.name },
                             minted: core.minted, epoch: core.epoch), to: &bytes)
        let sibling = file.appendingPathExtension("compacting")
        try? FileManager.default.removeItem(at: sibling)
        guard FileManager.default.createFile(atPath: sibling.path, contents: nil, attributes: protection) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: sibling.path])
        }
        let writer = try FileHandle(forWritingTo: sibling)
        try writer.write(contentsOf: bytes)
        try writer.synchronize()
        try writer.close()
        _ = try FileManager.default.replaceItemAt(file, withItemAt: sibling)
    }

    /// Appends one outcome and waits for it to reach the disk, then applies it. A write that
    /// fails leaves the store as it was, and says the store refused rather than that it might
    /// still land: the frame is either whole on disk, and replayed at the next open as it would
    /// have been applied now, or it is not.
    private func commit(_ applied: RecordStoreCore.Applied) throws {
        if let broken { throw RecordDatabaseError.rejected(underlying: broken) }
        var bytes = Data()
        try Self.append(.applied(applied), to: &bytes)
        let end = try handle.offset()
        do {
            try handle.write(contentsOf: bytes)
            try handle.synchronize()
        } catch {
            // Whatever part of the frame reached the file is cut away, so the next frame follows
            // the last whole one; a file that cannot be cut back takes no more writes this launch,
            // since a frame after a torn one would read as damage at the next open.
            do {
                try handle.truncate(atOffset: end)
                try handle.synchronize()
            } catch {
                broken = error
            }
            throw RecordDatabaseError.unavailable(underlying: error)
        }
        core.apply(applied)
    }

    // MARK: RecordDatabase

    /// The record the store holds now, or nil.
    public func current(_ id: RecordID) -> Record? { core.records[id] }

    public func save(_ records: [Record]) async throws -> [Record] {
        let applied = try core.prepareSave(records)
        try commit(applied)
        guard case .saved(let saved) = applied else { return [] }
        return saved
    }

    public func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { core.fetch(ids) }

    public func query(_ query: RecordQuery) async throws -> [Record] { core.query(query) }

    public func records(ofType type: String) async throws -> [Record] { core.records(ofType: type) }

    public func delete(_ ids: [RecordID]) async throws {
        let applied = core.prepareDelete(ids)
        guard case .deleted(let gone) = applied, !gone.isEmpty else { return }
        try commit(applied)
    }

    public func changes(ofType type: String, since token: Data?) async throws -> RecordChanges {
        try core.changes(ofType: type, since: token)
    }
}

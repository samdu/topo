import CryptoKit
import Foundation

/// The record store of a phone with no iCloud account: `RecordStoreCore`'s semantics, which are
/// `InMemoryRecordDatabase`'s, held in memory and journalled to one file, so the log, the lease,
/// the memory's store and the widgets' slots survive a relaunch on a phone with nowhere else to
/// keep them.
///
/// The journal is a header frame, written whole with the file, and then one frame per save or
/// delete, appended and synchronised to the disk before the call answers. A frame is its body's
/// length (4 bytes, big-endian), the length's complement, the first 4 bytes of the body's
/// SHA-256, and the body, a binary plist. A batch is one frame, so it is on disk whole or not at
/// all. At open a torn last write — fewer bytes left than a frame's prefix, a body running past
/// the end of the file, a body that ends the file and fails its checksum, or nothing but zeros
/// from there on — is a write whose caller never had an answer, which every writer already
/// settles as one that may have landed, and it is dropped and the file cut back to the frame
/// before it. Anything else that does not read — a length that fails its complement, a body
/// before the end that fails its checksum, a body that will not decode — is damage, and opening
/// refuses the file rather than guess at what it held, since a damaged length would otherwise
/// pass for a torn last frame and take every frame after it with it.
///
/// When the journal holds more than twice as many saved records as the store does, opening
/// rewrites it as one snapshot under a new feed epoch (a sibling written whole and renamed
/// over), and every feed token handed out before expires, as CloudKit's do. A compaction that
/// fails leaves the journal as it was and is logged; it is never a reason the store does not
/// open. Tags and tokens carry the file's own id, so one from another file is never honoured.
///
/// Opening reads the file synchronously, so a caller on the cooperative pool opens it from a
/// queue of its own (`RecordRoute`); the appends run on the actor's own serial queue.
public actor LocalRecordDatabase: ZoneDatabase {
    /// What a frame holds.
    private enum Frame: Codable {
        /// The file's first frame: its id and the journal's version.
        case header(store: String, version: Int)
        /// The whole store as a compaction wrote it.
        case snapshot(records: [Record], minted: Int64, epoch: Int64)
        case applied(RecordStoreCore.Applied)
    }

    /// What went wrong with the journal itself, as distinct from anything iCloud says.
    public enum Failure: Error, Sendable {
        /// A frame that is not a torn last write does not read, or the header is not this
        /// journal's: opening refuses the file.
        case damaged(offset: Int)
        /// The file or its folder could not be made, read or opened.
        case unopenable(underlying: any Error)
        /// An append did not reach the disk.
        case write(underlying: any Error)
    }

    static let version = 1

    /// True when the error is the journal's own — damaged, unopenable or a write that did not
    /// reach the disk — whether bare or as the store's refusal: a failure of this phone's
    /// records, never anything iCloud said, and never evidence of who is primary.
    public static func isJournalFailure(_ error: any Error) -> Bool {
        if error is Failure { return true }
        switch error {
        case RecordDatabaseError.rejected(let underlying), RecordDatabaseError.unavailable(let underlying):
            return underlying is Failure
        default:
            return false
        }
    }

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
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: Self.protection)
            if !manager.fileExists(atPath: file.path) {
                // Written whole and renamed into place, so a header is never torn: a file that
                // exists is a journal, and its existence is what puts the phone on it.
                var bytes = Data()
                try Self.append(.header(store: UUID().uuidString, version: Self.version), to: &bytes)
                try bytes.write(to: file, options: Self.writing)
            }
        } catch {
            throw Failure.unopenable(underlying: error)
        }
        let replayed: (RecordStoreCore, Int, Int, Int)
        do {
            replayed = try Self.replay(file)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unopenable(underlying: error)
        }
        var (core, savedInJournal, goodLength, fileLength) = replayed
        do {
            if goodLength < fileLength {
                // A torn last write: cut it away so the next frame follows the last whole one.
                let truncating = try FileHandle(forWritingTo: file)
                try truncating.truncate(atOffset: UInt64(goodLength))
                try truncating.synchronize()
                try truncating.close()
            }
        } catch {
            throw Failure.unopenable(underlying: error)
        }
        if savedInJournal > 2 * max(core.records.count, 1) {
            var compacted = core
            compacted.expireTokens()
            do {
                try Self.compact(compacted, into: file)
                core = compacted
            } catch {
                // The journal as it was is still whole: the store opens on it, tokens and all.
                TopoLog(.cloud).error("records: the journal on this phone could not be compacted (\(String(describing: type(of: error))))")
            }
        }
        self.core = core
        do {
            handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
        } catch {
            throw Failure.unopenable(underlying: error)
        }
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

    private static var writing: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        [.atomic]
        #endif
    }

    // MARK: The journal

    private static func append(_ frame: Frame, to bytes: inout Data) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let body = try encoder.encode(frame)
        bytes.append(contentsOf: bigEndian(UInt32(body.count)))
        bytes.append(contentsOf: bigEndian(~UInt32(body.count)))
        bytes.append(contentsOf: checksum(body))
        bytes.append(body)
    }

    /// A frame's prefix: the length, its complement and the body's checksum.
    static let prefix = 12

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private static func uint32(_ bytes: Data, at offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func checksum(_ body: Data) -> [UInt8] {
        Array(SHA256.hash(data: body).prefix(4))
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
            let rest = bytes.count - offset
            // A torn last write: a prefix cut short, or zeros the file was extended with.
            if rest < prefix || bytes[offset...].allSatisfy({ $0 == 0 }) { break }
            let length = uint32(bytes, at: offset)
            guard ~length == uint32(bytes, at: offset + 4) else { throw Failure.damaged(offset: start) }
            let bodyStart = offset + prefix
            // A length that passed its complement and runs past the end is the last write, cut.
            guard bytes.count - bodyStart >= Int(length) else { break }
            let body = bytes[bodyStart..<bodyStart + Int(length)]
            if Array(bytes[offset + 8..<offset + 12]) != checksum(Data(body)) {
                // Torn only where it ends the file; anywhere else it is damage.
                if bodyStart + Int(length) == bytes.count { break }
                throw Failure.damaged(offset: start)
            }
            guard let frame = try? decoder.decode(Frame.self, from: body) else { throw Failure.damaged(offset: start) }
            offset = bodyStart + Int(length)
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
                throw Failure.damaged(offset: start)
            }
        }
        guard let core else { throw Failure.damaged(offset: 0) }
        return (core, saved, offset, bytes.count)
    }

    /// Rewrites the journal as its header and one snapshot, written whole beside it and renamed
    /// over it.
    private static func compact(_ core: RecordStoreCore, into file: URL) throws {
        var bytes = Data()
        try append(.header(store: core.store, version: version), to: &bytes)
        try append(.snapshot(records: core.records.values.sorted { $0.id.name < $1.id.name },
                             minted: core.minted, epoch: core.epoch), to: &bytes)
        // `atomic` writes beside the file and renames over it.
        try bytes.write(to: file, options: writing)
    }

    /// Appends one outcome and waits for it to reach the disk, then applies it. A write that
    /// fails leaves the store in memory as it was and is `unavailable`, which writers take as a
    /// write that may have landed: the part that reached the file is cut back, but a frame that
    /// was synchronised whole before the failure is replayed at the next open as it would have
    /// been applied now.
    private func commit(_ applied: RecordStoreCore.Applied) throws {
        if let broken { throw RecordDatabaseError.rejected(underlying: Failure.write(underlying: broken)) }
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
            throw RecordDatabaseError.unavailable(underlying: Failure.write(underlying: error))
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

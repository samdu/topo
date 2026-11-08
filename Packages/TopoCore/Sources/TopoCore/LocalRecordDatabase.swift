import CryptoKit
import Foundation

/// The record store of a phone with no iCloud account: `RecordStoreCore`'s semantics, which are
/// `InMemoryRecordDatabase`'s, held in memory and journalled to one file, so the log, the lease,
/// the memory's store and the widgets' slots survive a relaunch on a phone with nowhere else to
/// keep them.
///
/// The file begins with two commit slots, then a header frame, then one frame per save or
/// delete. A frame is its body's length (4 bytes, big-endian), the length's complement, the first
/// 4 bytes of the body's SHA-256, and the body, a binary plist; a batch is one frame. A slot is a
/// sequence number and a committed length (8 bytes each, big-endian) and the first 4 bytes of
/// their SHA-256, and slot `n % 2` holds sequence `n`. A save writes its frame at the committed
/// length, puts a barrier behind it (`F_BARRIERFSYNC`), writes the next sequence and the new
/// length into the older slot, and synchronises the file before the call answers. The committed
/// length is the newest slot that reads.
///
/// So whether a write is whole is decided by the slots and never by what a frame holds: at open
/// the frames are read from the header to the committed length, each by the length the one before
/// it ends at, and nothing past the committed length is read but the one frame that begins there
/// (below). Anything inside it that does not read — a length that fails its complement or runs
/// past the committed length, a body that fails its checksum or will not decode, a header that is
/// not this journal's, a committed length past the end of the file, neither slot reading — is
/// damage, and opening refuses the file and cuts nothing. Whatever lies past the committed length
/// is a write whose call never answered success, which every writer settles as one that may have
/// landed; it is cut away and logged. Recovery reads each byte up to the committed length once,
/// plus at most that one frame, so a record's own bytes change neither what it decides nor what
/// it costs.
///
/// A slot that does not read is a slot write that tore, or a slot that rotted, and the two look
/// alike; so the committed length is the other slot's, and when the one frame that begins exactly
/// there is whole it is the frame the unread slot committed, kept and committed again into that
/// slot before the store opens. That frame was synchronised whole before its slot was written, so
/// keeping it is keeping a write whose call may have answered; when it is not whole, nothing was
/// committed past the other slot.
///
/// A frame that fails to reach the file leaves the store as it was: its bytes lie past the
/// committed length, which the next frame is written over. A slot that fails to reach the file may
/// or may not have committed its frame, so the journal takes no more writes this launch and the
/// next open decides.
///
/// When the journal holds more than twice as many saved records as the store does, opening
/// rewrites it as its slots and one header frame holding the whole store, under a new feed epoch
/// (a sibling written whole and renamed over), and every feed token handed out before expires,
/// as CloudKit's do. A compaction that fails leaves the journal as it was and is logged; it is
/// never a reason the store does not open. Tags and tokens carry the file's own id, so one from
/// another file is never honoured. The file's writes go through `JournalIO`, which a test
/// replaces to make them fail.
///
/// Opening reads the file synchronously, so a caller on the cooperative pool opens it from a
/// queue of its own (`RecordRoute`); the writes run on the actor's own serial queue.
public actor LocalRecordDatabase: ZoneDatabase {
    /// What a frame holds.
    private enum Frame: Codable {
        /// The file's first frame: its id, the journal's version, and after a compaction the
        /// whole store as it wrote it. It is only ever written whole with the file, so it is
        /// never a torn write: a first frame that does not read is damage.
        case header(store: String, version: Int, base: Base?)
        case applied(RecordStoreCore.Applied)
    }

    private struct Base: Codable {
        var records: [Record]
        var minted: Int64
        var epoch: Int64
    }

    /// What went wrong with the journal itself, as distinct from anything iCloud says.
    public enum Failure: Error, Sendable {
        /// Something up to the committed length does not read, or neither slot does: opening
        /// refuses the file. The offset is where.
        case damaged(offset: Int)
        /// The file or its folder could not be made, read or opened.
        case unopenable(underlying: any Error)
        /// A frame or a slot did not reach the disk.
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
    private let io: JournalIO
    private var core: RecordStoreCore
    private let handle: FileHandle
    /// The newest sequence and the length it committed.
    private var sequence: UInt64
    private var committed: UInt64
    /// Why the journal takes no more writes: a slot that may or may not have landed.
    private var broken: (any Error)?

    /// Opens the journal at `file`, making it when it is not there.
    public init(file: URL, io: JournalIO = .system) throws {
        self.file = file
        self.io = io
        queue = DispatchSerialQueue(label: "topo.local-records")
        do {
            try io.makeFolder(file.deletingLastPathComponent(), Self.folderAttributes)
            if !FileManager.default.fileExists(atPath: file.path) {
                // Written whole and renamed into place, so a new journal is never torn: a file
                // that exists is a journal, and its existence is what puts the phone on it.
                try io.replace(Self.fresh(.header(store: UUID().uuidString, version: Self.version, base: nil)),
                               file, Self.writing)
            }
        } catch {
            throw Failure.unopenable(underlying: error)
        }
        let replayed: Replayed
        do {
            replayed = try Self.replay(Data(contentsOf: file))
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unopenable(underlying: error)
        }
        var core = replayed.core
        var sequence = replayed.sequence
        var committed = UInt64(replayed.committed)
        let handle: FileHandle
        do {
            handle = try FileHandle(forUpdating: file)
        } catch {
            throw Failure.unopenable(underlying: error)
        }
        do {
            if replayed.recommit {
                // The frame an unread slot committed: committed again into that slot.
                try io.write(handle, Self.slotOffset(sequence), Self.slot(sequence, committed))
                try io.synchronize(handle)
            }
            if replayed.length > replayed.committed {
                TopoLog(.cloud).notice("records: \(replayed.length - replayed.committed) bytes past the committed length cut from the journal at \(replayed.committed)")
                try io.truncate(handle, committed)
                try io.synchronize(handle)
            }
        } catch {
            try? handle.close()
            throw Failure.unopenable(underlying: error)
        }
        if replayed.saved > 2 * max(core.records.count, 1) {
            var compacted = core
            compacted.expireTokens()
            do {
                let bytes = try Self.compacted(compacted)
                try io.replace(bytes, file, Self.writing)
                core = compacted
                (sequence, committed) = (1, UInt64(bytes.count))
            } catch {
                // The journal as it was is still whole: the store opens on it, tokens and all.
                TopoLog(.cloud).error("records: the journal on this phone could not be compacted (\(String(describing: type(of: error))))")
            }
        }
        // The compaction renamed a new file over the one the handle has open.
        let current: FileHandle
        do {
            current = try FileHandle(forUpdating: file)
        } catch {
            try? handle.close()
            throw Failure.unopenable(underlying: error)
        }
        try? handle.close()
        self.core = core
        self.handle = current
        self.sequence = sequence
        self.committed = committed
    }

    deinit { try? handle.close() }

    /// Until first unlock: turns are written behind the lock, so the file has to be writable
    /// then. It is the person's only copy on this phone, so nothing here excludes it or its
    /// folder from their backups.
    #if os(iOS)
    public static let protectionClass: FileProtectionType? = .completeUntilFirstUserAuthentication
    #else
    public static let protectionClass: FileProtectionType? = nil
    #endif

    static var folderAttributes: [FileAttributeKey: any Sendable] {
        protectionClass.map { [.protectionKey: $0] } ?? [:]
    }

    static var writing: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        [.atomic]
        #endif
    }

    // MARK: The journal

    private static func frame(_ frame: Frame) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let body = try encoder.encode(frame)
        var bytes = Data()
        bytes.append(contentsOf: bigEndian(UInt32(body.count)))
        bytes.append(contentsOf: bigEndian(~UInt32(body.count)))
        bytes.append(contentsOf: checksum(body))
        bytes.append(body)
        return bytes
    }

    /// A frame's prefix: the length, its complement and the body's checksum.
    static let prefix = 12
    /// A slot: the sequence, the committed length and their checksum.
    static let slotSize = 20
    /// Where the frames begin, after the two slots.
    static let slots = 2 * slotSize

    static func slotOffset(_ sequence: UInt64) -> UInt64 { UInt64(sequence % 2) * UInt64(slotSize) }

    static func slot(_ sequence: UInt64, _ committed: UInt64) -> Data {
        var bytes = Data(bigEndian(sequence) + bigEndian(committed))
        bytes.append(contentsOf: checksum(bytes))
        return bytes
    }

    /// The slot at index 0 or 1, when it reads and holds a sequence of its own index.
    static func readSlot(_ bytes: Data, _ index: Int) -> (sequence: UInt64, committed: UInt64)? {
        let at = index * slotSize
        let fields = bytes[at..<at + 16]
        guard Array(bytes[at + 16..<at + 20]) == checksum(fields) else { return nil }
        let sequence = uint64(bytes, at: at)
        guard Int(sequence % 2) == index else { return nil }
        return (sequence, uint64(bytes, at: at + 8))
    }

    /// A journal of its slots and one header frame, the slots committing it.
    private static func fresh(_ header: Frame) throws -> Data {
        let body = try frame(header)
        let committed = UInt64(slots + body.count)
        return slot(0, committed) + slot(1, committed) + body
    }

    private static func compacted(_ core: RecordStoreCore) throws -> Data {
        let base = Base(records: core.records.values.sorted { $0.id.name < $1.id.name },
                        minted: core.minted, epoch: core.epoch)
        return try fresh(.header(store: core.store, version: version, base: base))
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private static func bigEndian(_ value: UInt64) -> [UInt8] {
        bigEndian(UInt32(value >> 32)) + bigEndian(UInt32(value & 0xFFFF_FFFF))
    }

    private static func uint32(_ bytes: Data, at offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func uint64(_ bytes: Data, at offset: Int) -> UInt64 {
        bytes[offset..<offset + 8].reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private static func checksum<D: DataProtocol>(_ body: D) -> [UInt8] {
        Array(SHA256.hash(data: body).prefix(4))
    }

    /// The body of the frame at `offset` when it is whole within `end`, or nil.
    static func whole(_ bytes: Data, at offset: Int, within end: Int, examined: inout Int) -> Range<Int>? {
        guard offset + prefix <= end else { return nil }
        let length = uint32(bytes, at: offset)
        guard ~length == uint32(bytes, at: offset + 4), Int(length) <= end - offset - prefix else { return nil }
        let body = offset + prefix..<offset + prefix + Int(length)
        examined += prefix + body.count
        guard Array(bytes[offset + 8..<offset + 12]) == checksum(bytes[body]) else { return nil }
        return body
    }

    struct Replayed {
        var core: RecordStoreCore
        /// Records the journal's frames saved, its header's included.
        var saved: Int
        /// The newest sequence and the length it commits.
        var sequence: UInt64
        var committed: Int
        /// The file's length.
        var length: Int
        /// Whether the open owes the unread slot its frame (`sequence`, `committed`).
        var recommit: Bool
        /// The bytes recovery hashed: never more than the committed length and one frame past it.
        var examined: Int
    }

    static func replay(_ bytes: Data) throws -> Replayed {
        guard bytes.count >= slots else { throw Failure.damaged(offset: 0) }
        let read = [readSlot(bytes, 0), readSlot(bytes, 1)]
        guard let newest = read.compactMap({ $0 }).max(by: { $0.sequence < $1.sequence }) else {
            throw Failure.damaged(offset: 0)
        }
        var sequence = newest.sequence
        var committed = Int(clamping: newest.committed)
        guard committed >= slots, committed <= bytes.count else { throw Failure.damaged(offset: committed) }
        var examined = 0
        var recommit = false
        if read.contains(where: { $0 == nil }), let next = whole(bytes, at: committed, within: bytes.count, examined: &examined) {
            committed = next.upperBound
            sequence += 1
            recommit = true
        }
        let decoder = PropertyListDecoder()
        var offset = slots
        var core: RecordStoreCore?
        var saved = 0
        while offset < committed {
            guard let body = whole(bytes, at: offset, within: committed, examined: &examined),
                  let frame = try? decoder.decode(Frame.self, from: bytes[body]) else {
                throw Failure.damaged(offset: offset)
            }
            switch frame {
            case .header(let store, let version, let base) where core == nil && version == Self.version:
                if let base {
                    core = RecordStoreCore(store: store, records: base.records, minted: base.minted, epoch: base.epoch)
                    saved = base.records.count
                } else {
                    core = RecordStoreCore(store: store)
                }
            case .applied(let applied) where core != nil:
                core!.apply(applied)
                if case .saved(let records) = applied { saved += records.count }
            default:
                throw Failure.damaged(offset: offset)
            }
            offset = body.upperBound
        }
        guard let core else { throw Failure.damaged(offset: slots) }
        return Replayed(core: core, saved: saved, sequence: sequence, committed: committed,
                        length: bytes.count, recommit: recommit, examined: examined)
    }

    /// Writes one outcome's frame at the committed length and commits it in the older slot, then
    /// applies it. A write that fails leaves the store in memory as it was and is `unavailable`,
    /// which writers take as a write that may have landed.
    private func commit(_ applied: RecordStoreCore.Applied) throws {
        if let broken { throw RecordDatabaseError.rejected(underlying: Failure.write(underlying: broken)) }
        let bytes = try Self.frame(.applied(applied))
        do {
            try io.write(handle, committed, bytes)
            try io.barrier(handle)
        } catch {
            // Past the committed length: never read, and the next frame is written over it.
            throw RecordDatabaseError.unavailable(underlying: Failure.write(underlying: error))
        }
        let next = sequence + 1
        let end = committed + UInt64(bytes.count)
        do {
            try io.write(handle, Self.slotOffset(next), Self.slot(next, end))
            try io.synchronize(handle)
        } catch {
            // The slot may have landed: the next open decides, and nothing more is written.
            broken = error
            throw RecordDatabaseError.unavailable(underlying: Failure.write(underlying: error))
        }
        (sequence, committed) = (next, end)
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

/// The journal's file operations, which a test replaces to make one fail.
public struct JournalIO: Sendable {
    /// Writes a whole file in place of any there.
    public var replace: @Sendable (Data, URL, Data.WritingOptions) throws -> Void
    /// Makes a folder, and any above it, with these attributes.
    public var makeFolder: @Sendable (URL, [FileAttributeKey: any Sendable]) throws -> Void
    /// Writes bytes at an offset.
    public var write: @Sendable (FileHandle, UInt64, Data) throws -> Void
    /// Orders what was written before it ahead of anything written after it.
    public var barrier: @Sendable (FileHandle) throws -> Void
    public var synchronize: @Sendable (FileHandle) throws -> Void
    public var truncate: @Sendable (FileHandle, UInt64) throws -> Void

    public init(replace: @escaping @Sendable (Data, URL, Data.WritingOptions) throws -> Void,
                makeFolder: @escaping @Sendable (URL, [FileAttributeKey: any Sendable]) throws -> Void,
                write: @escaping @Sendable (FileHandle, UInt64, Data) throws -> Void,
                barrier: @escaping @Sendable (FileHandle) throws -> Void,
                synchronize: @escaping @Sendable (FileHandle) throws -> Void,
                truncate: @escaping @Sendable (FileHandle, UInt64) throws -> Void) {
        self.replace = replace
        self.makeFolder = makeFolder
        self.write = write
        self.barrier = barrier
        self.synchronize = synchronize
        self.truncate = truncate
    }

    public static let system = JournalIO(
        replace: { data, url, options in try data.write(to: url, options: options) },
        makeFolder: { url, attributes in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
        },
        write: { handle, offset, data in
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: data)
        },
        barrier: { handle in
            // A file system without barriers is given a full synchronise instead.
            if fcntl(handle.fileDescriptor, F_BARRIERFSYNC) == -1 { try handle.synchronize() }
        },
        synchronize: { handle in try handle.synchronize() },
        truncate: { handle, offset in try handle.truncate(atOffset: offset) })
}

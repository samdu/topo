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
/// from there on, with no whole frame anywhere after it — is a write whose caller never had an
/// answer, which every writer already settles as one that may have landed, and it is dropped
/// and the file cut back to the frame before it. Anything else that does not read — a frame
/// that runs out with a whole frame after it, a length that fails its complement, a body before
/// the end that fails its checksum, a body that will not decode, a header that does not read —
/// is damage, and opening refuses the file and cuts nothing rather than guess at what it held.
/// The header is written only whole with the file, so it is never torn.
///
/// When the journal holds more than twice as many saved records as the store does, opening
/// rewrites it as one header frame holding the whole store, under a new feed epoch (a sibling
/// written whole and renamed over), and every feed token handed out before expires, as CloudKit's do. A compaction that
/// fails leaves the journal as it was and is logged; it is never a reason the store does not
/// open. Tags and tokens carry the file's own id, so one from another file is never honoured.
///
/// An append that fails is cut back to where it began and the handle put back there; one that
/// cannot be cut back leaves the journal taking no more writes this launch, so no frame is ever
/// written after a torn one. The file's reads and writes go through `JournalIO`, which a test
/// replaces to make them fail.
///
/// Opening reads the file synchronously, so a caller on the cooperative pool opens it from a
/// queue of its own (`RecordRoute`); the appends run on the actor's own serial queue.
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
    private let io: JournalIO
    private var core: RecordStoreCore
    private let handle: FileHandle
    /// Why the journal takes no more writes: a failed write it could not cut back.
    private var broken: (any Error)?

    /// Opens the journal at `file`, making it when it is not there.
    public init(file: URL, io: JournalIO = .system) throws {
        self.file = file
        self.io = io
        queue = DispatchSerialQueue(label: "topo.local-records")
        do {
            try io.makeFolder(file.deletingLastPathComponent(), Self.folderAttributes)
            if !FileManager.default.fileExists(atPath: file.path) {
                // Written whole and renamed into place, so a header is never torn: a file that
                // exists is a journal, and its existence is what puts the phone on it.
                var bytes = Data()
                try Self.append(.header(store: UUID().uuidString, version: Self.version, base: nil), to: &bytes)
                try io.replace(bytes, file, Self.writing)
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
        do {
            if replayed.whole < replayed.length {
                // A torn last write: cut it away so the next frame follows the last whole one.
                TopoLog(.cloud).notice("records: a torn last write of \(replayed.length - replayed.whole) bytes cut from the journal at \(replayed.whole)")
                let truncating = try FileHandle(forWritingTo: file)
                defer { try? truncating.close() }
                try io.truncate(truncating, UInt64(replayed.whole))
                try io.synchronize(truncating)
            }
        } catch {
            throw Failure.unopenable(underlying: error)
        }
        if replayed.saved > 2 * max(core.records.count, 1) {
            var compacted = core
            compacted.expireTokens()
            do {
                try Self.compact(compacted, into: file, io: io)
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

    private static func checksum<D: DataProtocol>(_ body: D) -> [UInt8] {
        Array(SHA256.hash(data: body).prefix(4))
    }

    /// What the bytes at an offset are.
    enum FrameAt: Equatable {
        /// A frame whose prefix and checksum hold, and the offset after it.
        case whole(body: Range<Int>, next: Int)
        /// It runs out: a prefix cut short, zeros to the end, a body past the end, or a body
        /// that ends the file and fails its checksum. A torn last write, if it is the last.
        case runsOut
        /// Its length fails its complement, or its body fails its checksum before the end.
        case damaged
    }

    /// The frame at `offset`, where `zeros` is the offset from which the bytes are all zeros
    /// (`zeros(in:)`), found once for the whole file.
    static func frame(in bytes: Data, at offset: Int, zeros: Int) -> FrameAt {
        let rest = bytes.count - offset
        if rest < prefix || offset >= zeros { return .runsOut }
        let length = uint32(bytes, at: offset)
        guard ~length == uint32(bytes, at: offset + 4) else { return .damaged }
        let bodyStart = offset + prefix
        guard bytes.count - bodyStart >= Int(length) else { return .runsOut }
        let body = bodyStart..<bodyStart + Int(length)
        guard Array(bytes[offset + 8..<offset + 12]) == checksum(bytes[body]) else {
            return body.upperBound == bytes.count ? .runsOut : .damaged
        }
        return .whole(body: body, next: body.upperBound)
    }

    /// True when a whole frame begins anywhere after `offset`: what tells a frame that runs out
    /// in the middle of the journal (damage) from the torn last write.
    /// No frame begins in the zeros at the end (its complement would not hold), so the scan stops
    /// there and costs one pass over the rest of the file.
    static func wholeFrame(in bytes: Data, after offset: Int, zeros: Int) -> Bool {
        var at = offset + 1
        while at < zeros && at + prefix <= bytes.count {
            if case .whole = frame(in: bytes, at: at, zeros: zeros) { return true }
            at += 1
        }
        return false
    }

    /// The offset from which every byte to the end is zero, or the file's length.
    static func zeros(in bytes: Data) -> Int {
        var end = bytes.endIndex
        while end > bytes.startIndex, bytes[end - 1] == 0 { end -= 1 }
        return end - bytes.startIndex
    }

    struct Replayed {
        var core: RecordStoreCore
        /// Records the journal's frames saved, its header's included.
        var saved: Int
        /// The bytes that are whole frames, and the file's length.
        var whole: Int
        var length: Int
    }

    static func replay(_ bytes: Data) throws -> Replayed {
        let decoder = PropertyListDecoder()
        var offset = 0
        var core: RecordStoreCore?
        var saved = 0
        let zeros = zeros(in: bytes)
        reading: while offset < bytes.count {
            let start = offset
            let body: Range<Int>
            switch frame(in: bytes, at: offset, zeros: zeros) {
            case .whole(let range, let next):
                body = range
                offset = next
            case .runsOut:
                if wholeFrame(in: bytes, after: start, zeros: zeros) { throw Failure.damaged(offset: start) }
                break reading
            case .damaged:
                throw Failure.damaged(offset: start)
            }
            guard let frame = try? decoder.decode(Frame.self, from: bytes[body]) else {
                throw Failure.damaged(offset: start)
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
                throw Failure.damaged(offset: start)
            }
        }
        guard let core else { throw Failure.damaged(offset: 0) }
        return Replayed(core: core, saved: saved, whole: offset, length: bytes.count)
    }

    /// Rewrites the journal as one header frame holding the whole store, written whole beside it
    /// and renamed over it.
    private static func compact(_ core: RecordStoreCore, into file: URL, io: JournalIO) throws {
        var bytes = Data()
        let base = Base(records: core.records.values.sorted { $0.id.name < $1.id.name },
                        minted: core.minted, epoch: core.epoch)
        try append(.header(store: core.store, version: version, base: base), to: &bytes)
        try io.replace(bytes, file, writing)
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
        let end: UInt64
        do {
            end = try handle.offset()
        } catch {
            throw RecordDatabaseError.unavailable(underlying: Failure.write(underlying: error))
        }
        do {
            try io.append(handle, bytes)
            try io.synchronize(handle)
        } catch {
            // Whatever part of the frame reached the file is cut away and the handle put back
            // where the frame began, so the next frame follows the last whole one; a file that
            // cannot be cut back takes no more writes this launch, since a frame after a torn
            // one is damage at the next open.
            do {
                try io.truncate(handle, end)
                try io.synchronize(handle)
                try handle.seek(toOffset: end)
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

/// The journal's file operations, which a test replaces to make one fail.
public struct JournalIO: Sendable {
    /// Writes a whole file in place of any there.
    public var replace: @Sendable (Data, URL, Data.WritingOptions) throws -> Void
    /// Makes a folder, and any above it, with these attributes.
    public var makeFolder: @Sendable (URL, [FileAttributeKey: any Sendable]) throws -> Void
    /// Writes bytes at the handle's offset.
    public var append: @Sendable (FileHandle, Data) throws -> Void
    public var synchronize: @Sendable (FileHandle) throws -> Void
    public var truncate: @Sendable (FileHandle, UInt64) throws -> Void

    public init(replace: @escaping @Sendable (Data, URL, Data.WritingOptions) throws -> Void,
                makeFolder: @escaping @Sendable (URL, [FileAttributeKey: any Sendable]) throws -> Void,
                append: @escaping @Sendable (FileHandle, Data) throws -> Void,
                synchronize: @escaping @Sendable (FileHandle) throws -> Void,
                truncate: @escaping @Sendable (FileHandle, UInt64) throws -> Void) {
        self.replace = replace
        self.makeFolder = makeFolder
        self.append = append
        self.synchronize = synchronize
        self.truncate = truncate
    }

    public static let system = JournalIO(
        replace: { data, url, options in try data.write(to: url, options: options) },
        makeFolder: { url, attributes in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
        },
        append: { handle, data in try handle.write(contentsOf: data) },
        synchronize: { handle in try handle.synchronize() },
        truncate: { handle, offset in try handle.truncate(atOffset: offset) })
}

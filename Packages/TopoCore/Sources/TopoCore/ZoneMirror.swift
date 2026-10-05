import Foundation

/// One page of a zone's change feed: what was saved and what was deleted since the token it was
/// asked from, the token to ask from next, and whether the feed has more to give now.
public struct ZoneFeedPage: Sendable {
    public var changed: [Record]
    public var deleted: [RecordID]
    public var token: Data
    public var moreComing: Bool

    public init(changed: [Record], deleted: [RecordID], token: Data, moreComing: Bool) {
        self.changed = changed
        self.deleted = deleted
        self.token = token
        self.moreComing = moreComing
    }
}

/// A zone as the process last read it, kept so that reading it again costs what changed and not
/// the whole of it: every record of every type, and the feed's token after the last page taken.
/// A read asks the feed from that token, folds the pages in, and answers from what it holds, so
/// it returns what a walk of the feed from the beginning would, as of the same moment.
///
/// Reads go one at a time, each asking the feed itself: a read begun after a save returns the
/// saved record, as a walk from the beginning does. A page is folded in whole or not at all, and
/// its token kept with it, so a read that fails partway leaves what earlier pages gave and the
/// next one carries on from there.
///
/// Given a file, the copy is kept there between launches, so a launch asks the feed from where
/// the last one stopped instead of from the beginning. The file holds the records, the token
/// they were read up to and whose zone they are (`owner`), written whole and atomically after a
/// read that changed anything; a file that is missing, unreadable, of another version or of
/// another owner is a walk from the beginning. `forget()` removes it.
public actor ZoneMirror {
    public typealias Pull = @Sendable (_ since: Data?) async throws -> ZoneFeedPage

    /// What is kept on disk, and where: the file, and whose zone it is. A copy kept under one
    /// owner is never read under another.
    public struct Store: Sendable {
        public var file: URL
        public var owner: Data
        public init(file: URL, owner: Data) {
            self.file = file
            self.owner = owner
        }
    }

    private struct Kept: Codable {
        static let version = 1
        var version = Kept.version
        var owner: Data
        var token: Data
        var records: [Record]
    }

    private let pull: Pull
    private let store: Store?
    private var records: [RecordID: Record] = [:]
    private var token: Data?
    private var last: Task<Void, any Error>?
    private var loaded = false
    /// Moved by `forget`: a walk begun before it folds nothing in and keeps nothing after.
    private var forgotten = 0

    /// `pull` answers one page of the feed from a token, nil being the beginning, and throws
    /// `RecordChangesError.tokenExpired` when the store no longer answers from that token.
    public init(store: Store? = nil, pull: @escaping Pull) {
        self.store = store
        self.pull = pull
    }

    /// Forgets the zone, here and on disk: the next read walks the feed from the beginning, and a
    /// read under way throws `CancellationError` rather than bring back what was forgotten.
    public func forget() {
        forgotten += 1
        reset()
        loaded = true
        if let store { try? FileManager.default.removeItem(at: store.file) }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let store, let data = try? Data(contentsOf: store.file),
              let kept = try? PropertyListDecoder().decode(Kept.self, from: data),
              kept.version == Kept.version, kept.owner == store.owner else { return }
        records = Dictionary(kept.records.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        token = kept.token
        Perf.mark("zone.loaded records=\(records.count) bytes=\(data.count)")
    }

    private func keep() {
        guard let store, let token else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(Kept(owner: store.owner, token: token, records: Array(records.values))) else { return }
        try? FileManager.default.createDirectory(at: store.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(macOS)
        try? data.write(to: store.file, options: .atomic)
        #else
        try? data.write(to: store.file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #endif
        Perf.mark("zone.kept records=\(records.count) bytes=\(data.count)")
    }

    /// Every record of `type` in the zone now, in the order of their names.
    public func records(ofType type: String) async throws -> [Record] {
        let previous = last
        let read = Task {
            _ = await previous?.result
            try await self.catchUp()
        }
        last = read
        try await read.value
        return records.values.filter { $0.type == type }.sorted { $0.id.name < $1.id.name }
    }

    private func reset() {
        records = [:]
        token = nil
    }

    private func catchUp() async throws {
        load()
        let began = forgotten
        var changed = false
        defer { if changed, began == forgotten { keep() } }
        var more = true
        while more {
            let page: ZoneFeedPage
            do {
                page = try await pull(token)
            } catch RecordChangesError.tokenExpired where token != nil {
                guard began == forgotten else { throw CancellationError() }
                reset()
                changed = true
                continue
            }
            // The zone was forgotten while the page was on its way: it is the page of a token
            // that is gone, and nothing of it is held or kept.
            guard began == forgotten else { throw CancellationError() }
            for record in page.changed { records[record.id] = record }
            for id in page.deleted { records[id] = nil }
            if !page.changed.isEmpty || !page.deleted.isEmpty { changed = true }
            token = page.token
            more = page.moreComing
        }
    }
}

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
/// Nothing is written to disk: a launch reads the zone from the beginning once.
public actor ZoneMirror {
    public typealias Pull = @Sendable (_ since: Data?) async throws -> ZoneFeedPage

    private let pull: Pull
    private var records: [RecordID: Record] = [:]
    private var token: Data?
    private var last: Task<Void, any Error>?

    /// `pull` answers one page of the feed from a token, nil being the beginning, and throws
    /// `RecordChangesError.tokenExpired` when the store no longer answers from that token.
    public init(pull: @escaping Pull) {
        self.pull = pull
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

    /// Forgets the zone, so the next read walks the feed from the beginning.
    public func reset() {
        records = [:]
        token = nil
    }

    private func catchUp() async throws {
        var more = true
        while more {
            let page: ZoneFeedPage
            do {
                page = try await pull(token)
            } catch RecordChangesError.tokenExpired where token != nil {
                reset()
                continue
            }
            for record in page.changed { records[record.id] = record }
            for id in page.deleted { records[id] = nil }
            token = page.token
            more = page.moreComing
        }
    }
}

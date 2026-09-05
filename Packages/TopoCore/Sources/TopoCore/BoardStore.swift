import Foundation

/// The household board: cards in a zone shared across the house's Apple
/// IDs, one record per revision.
///
/// It is a store of its own, in a container of its own, and that is the
/// point rather than an accident: the transcript and the memory are one
/// person's and never leave their Apple ID, while the board is the one
/// thing several people hold at once. Nothing here can reach the other two.
///
/// Everything else is the arrangement the log and the memory already use.
/// A revision is named by the device that wrote it and its sequence number
/// there, saved create-only, and lists the revisions it replaces; every
/// device writes through its own login, so a card carries who posted it and
/// a tick carries who ticked.
public struct BoardStore: Sendable {
    let database: any RecordDatabase

    public init(database: any RecordDatabase) {
        self.database = database
    }

    /// The whole board, from the zone's change feed: no index needed, and
    /// every record however malformed, so a damaged revision is reported
    /// rather than quietly missed.
    public func read() async throws -> Board {
        let records = try await database.records(ofType: CardRevision.recordType)
        let seen = Self.board(from: records)
        var last: [DeviceID: Int64] = [:]
        for ref in seen.revisions.keys { last[ref.device] = max(last[ref.device] ?? 0, ref.sequence) }
        for ref in seen.missing { last[ref.device] = max(last[ref.device] ?? 0, ref.sequence) }
        let probes = last.map { CardRef(device: $0.key, sequence: $0.value + 1) }
        guard !probes.isEmpty else { return seen }
        let present = try await database.fetch(probes.map(CardRevision.recordID(for:)))
        let hidden = probes.filter { present[CardRevision.recordID(for: $0)] != nil }
        guard !hidden.isEmpty else { return seen }
        return Board(revisions: Array(seen.revisions.values), missing: seen.missing.union(hidden),
                     unreadable: seen.unreadable)
    }

    /// One device's revisions after a sequence number, in sequence order.
    public func read(device: DeviceID, after sequence: Int64) async throws -> [CardRevision] {
        let records = try await database.query(RecordQuery(type: CardRevision.recordType, filters: [
            .init("device", .equals, .string(device.rawValue)),
            .init("sequence", .greaterThan, .int(sequence)),
        ]))
        return records.compactMap(CardRevision.init(record:)).sorted { $0.ref.sequence < $1.ref.sequence }
    }

    public func writer(for device: DeviceID) async throws -> BoardWriter {
        let last = try await read(device: device, after: 0).last?.ref.sequence ?? 0
        let writer = BoardWriter(database: database, device: device, next: last + 1)
        try await writer.syncWithStore()
        return writer
    }

    static func board(from records: [Record]) -> Board {
        var revisions: [CardRevision] = []
        var missing: Set<CardRef> = []
        var unreadable: [RecordID] = []
        for record in records {
            if let revision = CardRevision(record: record) {
                revisions.append(revision)
            } else if let ref = CardRevision.ref(ofRecordNamed: record.id.name), ref.sequence >= 1 {
                missing.insert(ref)
            } else {
                unreadable.append(record.id)
            }
        }
        return Board(revisions: revisions, missing: missing, unreadable: unreadable)
    }
}

/// Writes revisions for one device: posting a card, and the three things
/// anyone in the house can do to one.
public actor BoardWriter {
    private let appender: SequenceAppender
    public let device: DeviceID

    init(database: any RecordDatabase, device: DeviceID, next: Int64) {
        self.device = device
        self.appender = SequenceAppender(database: database, naming: CardRevision.naming,
                                         device: device, next: next)
    }

    public var nextRef: CardRef {
        get async { CardRef(device: device, sequence: await appender.nextSequence) }
    }

    /// Posts a new card, owned by this device.
    @discardableResult
    public func post(_ body: String, at: Date = Date(), nonce: String = UUID().uuidString) async throws -> CardRevision {
        let device = self.device
        return try await write(nonce: nonce) { ref in
            // A new card is named by the revision that opens it, so nothing
            // else can be that card.
            CardRevision(ref: ref, card: CardID(ref), owner: device, body: body, state: .posted,
                         parents: [], at: at, nonce: nonce)
        }
    }

    /// Ticks a card off. Anyone in the house may; the card keeps its owner.
    @discardableResult
    public func tick(_ card: CardID, on board: Board, at: Date = Date(),
                     nonce: String = UUID().uuidString) async throws -> CardRevision {
        try await change(card, on: board, to: .ticked, body: nil, at: at, nonce: nonce)
    }

    /// Takes a card off the board without ticking it: not done, not wanted.
    @discardableResult
    public func dismiss(_ card: CardID, on board: Board, at: Date = Date(),
                        nonce: String = UUID().uuidString) async throws -> CardRevision {
        try await change(card, on: board, to: .dismissed, body: nil, at: at, nonce: nonce)
    }

    /// Puts a card back on the board, which is how a tick is undone.
    @discardableResult
    public func repost(_ card: CardID, on board: Board, at: Date = Date(),
                       nonce: String = UUID().uuidString) async throws -> CardRevision {
        try await change(card, on: board, to: .posted, body: nil, at: at, nonce: nonce)
    }

    /// Changes what a card says, keeping where it has got to.
    @discardableResult
    public func amend(_ card: CardID, to body: String, on board: Board, at: Date = Date(),
                      nonce: String = UUID().uuidString) async throws -> CardRevision {
        try await change(card, on: board, to: nil, body: body, at: at, nonce: nonce)
    }

    private func change(_ card: CardID, on board: Board, to state: CardState?, body: String?,
                        at: Date, nonce: String) async throws -> CardRevision {
        guard board.isComplete else {
            throw BoardError.incompleteBoard(missing: board.missing, unreadable: board.unreadable)
        }
        guard let current = board[card] else { throw BoardError.noSuchCard(card) }
        let parents = board.heads(of: card)
        return try await write(nonce: nonce) { ref in
            CardRevision(ref: ref, card: card, owner: current.owner, body: body ?? current.body,
                         state: state ?? current.state, parents: parents, at: at, nonce: nonce)
        }
    }

    private func write(nonce: String, _ make: @escaping @Sendable (CardRef) -> CardRevision) async throws -> CardRevision {
        let device = self.device
        do {
            let record = try await appender.append(nonce: nonce) { sequence, nonce in
                var revision = make(CardRef(device: device, sequence: sequence))
                // The nonce the append is carrying, which is what a retry
                // matches on, not the one it was called with.
                revision = CardRevision(ref: revision.ref, card: revision.card, owner: revision.owner,
                                        body: revision.body, state: revision.state,
                                        parents: revision.parents, at: revision.at, nonce: nonce)
                return revision.record
            }
            guard let revision = CardRevision(record: record) else {
                throw BoardError.damagedRevision(record.id)
            }
            return revision
        } catch SequenceError.contended(let device) {
            throw BoardError.sequenceContended(device)
        } catch SequenceError.markerWithoutRecord(let nonce) {
            throw BoardError.markerWithoutRevision(nonce: nonce)
        }
    }

    func syncWithStore() async throws {
        do {
            try await appender.syncWithStore()
        } catch SequenceError.contended(let device) {
            throw BoardError.sequenceContended(device)
        }
    }
}

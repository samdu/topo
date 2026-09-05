import Foundation

/// A card on the household board: something posted for the house to see,
/// which somebody can tick off or dismiss.
///
/// The board is not the transcript and not the memory. It is shared across
/// Apple IDs — a zone one person creates and shares with the household —
/// so every device writes through its own login and every card says whose
/// it is. What a card cannot do is need judgement: posting, ticking and
/// dismissing are the whole of it, and anything more is a message to an
/// agent rather than a change to a card.
public struct CardID: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    /// The revision that first wrote the card, which nothing else can be.
    public let origin: String

    public init(_ origin: String) { self.origin = origin }
    public init(_ ref: CardRef) { self.origin = ref.description }

    public var description: String { origin }
    public static func < (a: CardID, b: CardID) -> Bool { a.origin < b.origin }
}

/// Names one revision of one card: the device that wrote it and its
/// sequence number on that device.
public struct CardRef: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let device: DeviceID
    public let sequence: Int64

    public init(device: DeviceID, sequence: Int64) {
        self.device = device
        self.sequence = sequence
    }

    public var description: String { "\(device.rawValue)/\(sequence)" }

    public static func < (a: CardRef, b: CardRef) -> Bool {
        (a.device.rawValue, a.sequence) < (b.device.rawValue, b.sequence)
    }

    public init?(parsing string: String) {
        guard let slash = string.lastIndex(of: "/"),
              let sequence = Int64(string[string.index(after: slash)...]) else { return nil }
        self.init(device: DeviceID(String(string[..<slash])), sequence: sequence)
    }
}

/// Where a card has got to. A dismissed card is not deleted: the board is
/// append-only like everything else here, and what leaves the board is a
/// revision saying so.
public enum CardState: String, Sendable, Codable, CaseIterable {
    case posted
    case ticked
    case dismissed
}

/// One revision of one card. Immutable once written.
public struct CardRevision: Hashable, Sendable, Identifiable {
    public static let recordType = "Card"
    static let recordPrefix = "card/"
    static let naming = RecordNaming(prefix: recordPrefix, markerType: "CardWrite",
                                     markerPrefix: "cardwrite/", markerField: "card")

    public let ref: CardRef
    public let card: CardID
    /// Whose card it is: the person's device, as their own login wrote it.
    /// A card someone else ticks keeps its owner.
    public let owner: DeviceID
    public let body: String
    public let state: CardState
    /// The revisions of this card that this one replaces.
    public let parents: [CardRef]
    public let at: Date
    public let nonce: String

    public var id: CardRef { ref }

    public init(ref: CardRef, card: CardID, owner: DeviceID, body: String, state: CardState,
                parents: [CardRef], at: Date, nonce: String = UUID().uuidString) {
        self.ref = ref
        self.card = card
        self.owner = owner
        self.body = body
        self.state = state
        self.parents = parents
        self.at = at
        self.nonce = nonce
    }

    public static func recordID(for ref: CardRef) -> RecordID {
        naming.recordID(ref.device, ref.sequence)
    }

    static func ref(ofRecordNamed name: String) -> CardRef? {
        guard name.hasPrefix(recordPrefix) else { return nil }
        return CardRef(parsing: String(name.dropFirst(recordPrefix.count)))
    }

    var record: Record {
        Record(type: CardRevision.recordType, id: CardRevision.recordID(for: ref), fields: [
            "device": .string(ref.device.rawValue),
            "sequence": .int(ref.sequence),
            "card": .string(card.origin),
            "owner": .string(owner.rawValue),
            "body": .string(body),
            "state": .string(state.rawValue),
            "parents": .strings(parents.map(\.description)),
            "at": .date(at),
            "nonce": .string(nonce),
        ])
    }

    public init?(record: Record) {
        guard record.type == CardRevision.recordType,
              let device = record.string("device"),
              let sequence = record.int("sequence"), sequence >= 1,
              let card = record.string("card"), !card.isEmpty,
              let owner = record.string("owner"),
              let body = record.string("body"),
              let stateString = record.string("state"), let state = CardState(rawValue: stateString),
              let at = record.date("at") else { return nil }
        let parentStrings = record.strings("parents") ?? []
        let parents = parentStrings.compactMap(CardRef.init(parsing:))
        guard parents.count == parentStrings.count else { return nil }
        self.init(ref: CardRef(device: DeviceID(device), sequence: sequence), card: CardID(card),
                  owner: DeviceID(owner), body: body, state: state, parents: parents, at: at,
                  nonce: record.string("nonce") ?? "")
    }
}

/// A card as the board shows it: the newest thing said about it.
public struct Card: Hashable, Sendable, Identifiable {
    public let id: CardID
    public let owner: DeviceID
    public let body: String
    public let state: CardState
    /// When the card was first posted, which is the order the board is in.
    public let postedAt: Date
    /// When it last changed.
    public let at: Date
    public let head: CardRef

    public var isOpen: Bool { state == .posted }
}

/// The board as read: every revision, and the cards they come to.
///
/// Where two devices change one card without seeing each other, the newer
/// revision is the card and the older is not shown. That is the opposite of
/// what the memory does with a note, and deliberately: a note is a document
/// where losing somebody's paragraph is unacceptable, and a card is one
/// line that a household is looking at together, where two answers on the
/// wall is worse than the older one being superseded. Nothing is destroyed
/// either way — every revision stays in the log, and the one that lost is
/// there to read.
public struct Board: Sendable {
    public let revisions: [CardRef: CardRevision]
    /// Every card, newest posting first.
    public let cards: [Card]
    public let missing: Set<CardRef>
    public let unreadable: [RecordID]

    private let headsByCard: [CardID: [CardRef]]

    public init(revisions: [CardRevision], missing: Set<CardRef> = [], unreadable: [RecordID] = []) {
        var byRef: [CardRef: CardRevision] = [:]
        for revision in revisions { byRef[revision.ref] = revision }

        var missing = missing
        var lastSeen: [DeviceID: Int64] = [:]
        for revision in byRef.values {
            for parent in revision.parents where byRef[parent] == nil { missing.insert(parent) }
            lastSeen[revision.ref.device] = max(lastSeen[revision.ref.device] ?? 0, revision.ref.sequence)
        }
        for (device, last) in lastSeen where last >= 1 {
            for sequence in 1...last where byRef[CardRef(device: device, sequence: sequence)] == nil {
                missing.insert(CardRef(device: device, sequence: sequence))
            }
        }

        var byCard: [CardID: [CardRevision]] = [:]
        for revision in byRef.values { byCard[revision.card, default: []].append(revision) }

        var heads: [CardID: [CardRef]] = [:]
        var cards: [Card] = []
        for (id, all) in byCard {
            let refs = Set(all.map(\.ref))
            let replaced = Set(all.flatMap(\.parents)).intersection(refs)
            let cardHeads = all.filter { !replaced.contains($0.ref) }
            heads[id] = cardHeads.map(\.ref).sorted()
            // Later wins; the ref breaks a tie, so every device shows the
            // same card with no clock to agree on.
            guard let newest = cardHeads.max(by: { ($0.at, $0.ref) < ($1.at, $1.ref) }) else { continue }
            let posted = all.min(by: { ($0.at, $0.ref) < ($1.at, $1.ref) }) ?? newest
            cards.append(Card(id: id, owner: newest.owner, body: newest.body, state: newest.state,
                              postedAt: posted.at, at: newest.at, head: newest.ref))
        }

        self.revisions = byRef
        self.cards = cards.sorted { ($0.postedAt, $0.id) > ($1.postedAt, $1.id) }
        self.missing = missing
        self.unreadable = unreadable
        self.headsByCard = heads
    }

    public var isEmpty: Bool { cards.isEmpty }
    public var isComplete: Bool { missing.isEmpty && unreadable.isEmpty }
    /// The cards still asking for something: what a screen shows.
    public var open: [Card] { cards.filter(\.isOpen) }

    public subscript(id: CardID) -> Card? { cards.first { $0.id == id } }

    public func heads(of card: CardID) -> [CardRef] { headsByCard[card] ?? [] }
}

public enum BoardError: Error, Sendable {
    /// The board is missing revisions; a change written from it could
    /// replace something nobody has seen. Read again.
    case incompleteBoard(missing: Set<CardRef>, unreadable: [RecordID])
    /// A change was asked for on a card the board does not hold.
    case noSuchCard(CardID)
    case sequenceContended(DeviceID)
    case markerWithoutRevision(nonce: String)
    case damagedRevision(RecordID)
}

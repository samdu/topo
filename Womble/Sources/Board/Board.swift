import CloudKit
import Foundation

/// Where a card has got to.
enum CardState: String {
    case posted
    case ticked
    case dismissed
}

/// One revision of one card, as this screen reads it. Womble writes none:
/// it shows the house what the house put there.
struct CardRevision {
    static let recordType = "Card"
    static let recordPrefix = "card/"

    let ref: String
    let card: String
    let owner: String
    let body: String
    let state: CardState
    let parents: [String]
    let at: Date

    /// Nil for anything that is not a well-formed revision.
    init?(record: CKRecord) {
        guard record.recordType == CardRevision.recordType,
              record.recordID.recordName.hasPrefix(CardRevision.recordPrefix),
              let card = record["card"] as? String, !card.isEmpty,
              let owner = record["owner"] as? String,
              let body = record["body"] as? String,
              let stateName = record["state"] as? String,
              let state = CardState(rawValue: stateName),
              let at = record["at"] as? Date else { return nil }
        self.ref = String(record.recordID.recordName.dropFirst(CardRevision.recordPrefix.count))
        self.card = card
        self.owner = owner
        self.body = body
        self.state = state
        self.parents = record["parents"] as? [String] ?? []
        self.at = at
    }

    init(ref: String, card: String, owner: String, body: String, state: CardState,
         parents: [String], at: Date) {
        self.ref = ref
        self.card = card
        self.owner = owner
        self.body = body
        self.state = state
        self.parents = parents
        self.at = at
    }
}

/// A card as the board shows it: the newest thing said about it.
struct Card: Equatable {
    let id: String
    let owner: String
    let body: String
    let state: CardState
    let postedAt: Date
    let at: Date

    var isOpen: Bool { return state == .posted }
}

/// The board: every revision read, resolved to cards.
///
/// Where two devices changed one card without seeing each other, the newer
/// revision is the card. A board converges rather than forking — two
/// answers on a wall is worse than the older one being superseded — and
/// nothing is destroyed by it: every revision stays in the log.
struct Board {
    let cards: [Card]

    init(revisions: [CardRevision]) {
        var byCard: [String: [CardRevision]] = [:]
        for revision in revisions {
            byCard[revision.card, default: []].append(revision)
        }
        var cards: [Card] = []
        for (id, all) in byCard {
            let refs = Set(all.map { $0.ref })
            var replaced = Set<String>()
            for revision in all {
                for parent in revision.parents where refs.contains(parent) { replaced.insert(parent) }
            }
            let heads = all.filter { !replaced.contains($0.ref) }
            guard let newest = heads.max(by: { ($0.at, $0.ref) < ($1.at, $1.ref) }) else { continue }
            let posted = all.min(by: { ($0.at, $0.ref) < ($1.at, $1.ref) }) ?? newest
            cards.append(Card(id: id, owner: newest.owner, body: newest.body, state: newest.state,
                              postedAt: posted.at, at: newest.at))
        }
        self.cards = cards.sorted { ($0.postedAt, $0.id) > ($1.postedAt, $1.id) }
    }

    /// What a screen in a room shows: the cards still asking for something.
    var open: [Card] { return cards.filter { $0.isOpen } }
    var isEmpty: Bool { return cards.isEmpty }
}

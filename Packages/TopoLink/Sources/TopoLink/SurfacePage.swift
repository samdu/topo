import CryptoKit
import Foundation
import TopoCore

/// The one document a web-page Womble reads: the house board and the
/// transcript, together, because a wall screen wants the two to agree with
/// each other and two requests can disagree. `docs/surfaces.md` is the
/// shape; this is that shape and nothing else, so a field added there is a
/// field added here.
public struct SurfaceDocument: Codable, Sendable, Equatable {
    public var version = 1
    /// What to call the household, or absent.
    public var house: String?
    public var transcript: Transcript
    public var board: Board

    public struct Transcript: Codable, Sendable, Equatable {
        /// False when the read could not be finished. The page says so above
        /// the turns whether or not a notice came with it: a partial
        /// conversation shown as the whole one is the transcript's one
        /// unforgivable failure.
        public var complete: Bool
        public var notice: String?
        /// Oldest first, as the log orders them.
        public var turns: [Turn]

        public init(complete: Bool, notice: String?, turns: [Turn]) {
            self.complete = complete
            self.notice = notice
            self.turns = turns
        }

        /// `notice` is written even when there is none, as `null`: the
        /// document says what it holds rather than leaving the page to tell
        /// an absent field from one nobody set.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(complete, forKey: .complete)
            try container.encode(notice, forKey: .notice)
            try container.encode(turns, forKey: .turns)
        }
    }

    public struct Turn: Codable, Sendable, Equatable {
        public var ref: String
        /// `person` or `assistant`.
        public var role: String
        public var text: String
        public var at: Date

        public init(ref: String, role: String, text: String, at: Date) {
            self.ref = ref
            self.role = role
            self.text = text
            self.at = at
        }
    }

    public struct Board: Codable, Sendable, Equatable {
        /// Newest posting first.
        public var cards: [Card]

        public init(cards: [Card]) {
            self.cards = cards
        }
    }

    public struct Card: Codable, Sendable, Equatable {
        public var id: String
        public var owner: String
        public var body: String
        /// `posted`, `ticked` or `dismissed`.
        public var state: String
        public var postedAt: Date
        public var at: Date

        public init(id: String, owner: String, body: String, state: String, postedAt: Date, at: Date) {
            self.id = id
            self.owner = owner
            self.body = body
            self.state = state
            self.postedAt = postedAt
            self.at = at
        }
    }

    public init(house: String?, transcript: Transcript, board: Board) {
        self.house = house
        self.transcript = transcript
        self.board = board
    }

    /// The same document encodes to the same bytes every time — keys in
    /// order, dates in RFC 3339 — which is what lets the ETag be a hash of
    /// them and a screen that has not missed anything be answered `304`.
    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func etag(for json: Data) -> String {
        let digest = SHA256.hash(data: json)
        return "\"" + digest.compactMap { String(format: "%02x", $0) }.joined().prefix(32) + "\""
    }
}

extension SurfaceDocument {
    /// The document as the log and the board read: the transcript in the
    /// order the log puts it, every card the board holds, and the notice the
    /// app would show above the turns.
    public init(house: String?, transcript: TopoCore.Transcript, notice: String?, board: TopoCore.Board) {
        self.init(
            house: house,
            transcript: Transcript(
                complete: transcript.isComplete,
                notice: notice,
                turns: transcript.ordered.map {
                    Turn(ref: $0.ref.description, role: $0.role.rawValue, text: $0.text, at: $0.at)
                }),
            board: Board(cards: board.cards.map {
                Card(id: $0.id.description, owner: $0.owner.rawValue, body: $0.body,
                     state: $0.state.rawValue, postedAt: $0.postedAt, at: $0.at)
            }))
    }
}

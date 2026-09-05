import CloudKit
import Foundation

/// Where the board comes from. The screen holds one of these and knows
/// nothing else about CloudKit.
protocol BoardSource: AnyObject {
    /// Reads the whole board. The completion runs on the main queue.
    func read(_ completion: @escaping (Result<Board, TranscriptError>) -> Void)
}

/// Reads the board: the query, then a probe past the end of every device's
/// run.
///
/// The zone's change feed is eventually consistent, and a tick nobody has
/// caught up with leaves no gap behind it — a board short by its tail looks
/// complete, and a done thing stays on the wall. So after the read, every
/// known device's next revision is fetched by ID, which is read-your-writes,
/// and what is there is folded in. A card is small and its newest revision
/// is the whole answer, so unlike the transcript there is nothing to report:
/// the record is fetched and shown.
///
/// A probe that fails is a read that failed. Reporting the query's answer
/// would present a possibly stale board as the current one, and on a wall
/// that is exactly the mistake worth avoiding.
final class BoardReader: BoardSource {
    /// How many times to look past the end. One round covers a write the
    /// index has not caught up with; the bound stops a busy house from
    /// keeping a screen fetching.
    private static let probeRounds = 4

    private let store: CardRecordStore

    init(store: CardRecordStore = CloudKitCardStore()) {
        self.store = store
    }

    func read(_ completion: @escaping (Result<Board, TranscriptError>) -> Void) {
        let finish: (Result<Board, TranscriptError>) -> Void = { result in
            DispatchQueue.main.async { completion(result) }
        }
        store.allCards { result in
            switch result {
            case .failure(let error):
                finish(.failure(error))
            case .success(let records):
                self.probeTail(after: records.compactMap(CardRevision.init(record:)),
                               round: 0, finish)
            }
        }
    }

    private func probeTail(after revisions: [CardRevision], round: Int,
                           _ completion: @escaping (Result<Board, TranscriptError>) -> Void) {
        guard round < BoardReader.probeRounds else {
            return completion(.success(Board(revisions: revisions)))
        }
        var last: [String: Int64] = [:]
        for revision in revisions {
            guard let (device, sequence) = BoardReader.split(revision.ref) else { continue }
            last[device] = max(last[device] ?? 0, sequence)
        }
        let names = last.map { CardRevision.recordPrefix + "\($0.key)/\($0.value + 1)" }
        guard !names.isEmpty else { return completion(.success(Board(revisions: revisions))) }

        store.fetchCards(named: names) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let records):
                let found = records.compactMap(CardRevision.init(record:))
                guard !found.isEmpty else {
                    return completion(.success(Board(revisions: revisions)))
                }
                self.probeTail(after: revisions + found, round: round + 1, completion)
            }
        }
    }

    /// `device/sequence`, where the device may itself contain slashes.
    static func split(_ ref: String) -> (String, Int64)? {
        guard let slash = ref.lastIndex(of: "/"),
              let sequence = Int64(ref[ref.index(after: slash)...]) else { return nil }
        return (String(ref[..<slash]), sequence)
    }
}

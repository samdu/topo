import CloudKit
import Foundation

/// Reads the turn log: the query, then a probe past the end of every device's
/// run.
///
/// CloudKit is truth here, and for Womble it is the whole truth: there is no
/// socket, no live turn and nothing to be fast about. It reads the records,
/// and a read that cannot be completed says so rather than showing part of a
/// conversation as all of it.
///
/// The query index is eventually consistent, and a newest turn it has not
/// caught up with leaves no gap behind it — a transcript that is short by
/// its tail looks complete. So after the query, every known device's next
/// sequence is fetched by ID, which is read-your-writes, and one that exists
/// is reported missing. This mirrors `TurnLog.read` in TopoCore, deliberately
/// and exactly: a device none of whose turns the query returned cannot be
/// probed this way, and a viewer has no writer of its own to ask.
final class CloudKitTranscriptSource: TranscriptSource {
    private let store: TurnRecordStore

    init(store: TurnRecordStore = CloudKitStore()) {
        self.store = store
    }

    func read(completion: @escaping (Result<Transcript, TranscriptError>) -> Void) {
        let finish: (Result<Transcript, TranscriptError>) -> Void = { result in
            DispatchQueue.main.async { completion(result) }
        }
        store.accountAvailable { result in
            switch result {
            case .failure(let error):
                finish(.failure(error))
            case .success:
                self.store.queryTurns { result in
                    switch result {
                    case .failure(let error):
                        finish(.failure(error))
                    case .success(let records):
                        self.probingTail(of: CloudKitTranscriptSource.transcript(from: records), finish)
                    }
                }
            }
        }
    }

    /// The turns the query returned, plus any that exist just past the end of
    /// a device's run and the index has not caught up with.
    private func probingTail(of seen: Transcript,
                             _ completion: @escaping (Result<Transcript, TranscriptError>) -> Void) {
        var last: [DeviceID: Int64] = [:]
        for ref in seen.ordered.map({ $0.ref }) + Array(seen.missing) {
            last[ref.device] = max(last[ref.device] ?? 0, ref.sequence)
        }
        let probes = last.map { TurnRef(device: $0.key, sequence: $0.value + 1) }
        guard !probes.isEmpty else { return completion(.success(seen)) }

        store.fetchTurns(named: probes.map(Turn.recordName(for:))) { result in
            switch result {
            case .failure(let error):
                // The probe is part of the read, so a probe that fails is a
                // read that failed: reporting the query's answer here would
                // be presenting a possibly short transcript as the whole one.
                completion(.failure(error))
            case .success(let present):
                let hidden = probes.filter { present.contains(Turn.recordName(for: $0)) }
                guard !hidden.isEmpty else { return completion(.success(seen)) }
                completion(.success(Transcript(turns: seen.ordered,
                                               missing: seen.missing.union(hidden),
                                               unreadable: seen.unreadable)))
            }
        }
    }

    /// The turns, and what the read could not make sense of. A record whose
    /// name is a ref but whose fields do not parse is reported as missing
    /// under that ref: something is there, and it is not readable as the turn
    /// it claims to be.
    static func transcript(from records: [CKRecord]) -> Transcript {
        var turns: [Turn] = []
        var missing = Set<TurnRef>()
        var unreadable: [String] = []
        for record in records {
            let name = record.recordID.recordName
            if let turn = Turn(recordName: name, fields: fields(of: record)) {
                turns.append(turn)
            } else if let ref = Turn.ref(ofRecordNamed: name) {
                missing.insert(ref)
            } else {
                unreadable.append(name)
            }
        }
        return Transcript(turns: turns, missing: missing, unreadable: unreadable)
    }

    static func fields(of record: CKRecord) -> [String: Any] {
        var fields: [String: Any] = [:]
        for key in record.allKeys() {
            if let value = record[key] { fields[key] = value }
        }
        return fields
    }
}

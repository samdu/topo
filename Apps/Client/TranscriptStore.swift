import Foundation
import Observation
import TopoCore
import TopoLink

/// The transcript, as a screen sees it: the turns, whether the last read
/// worked, and — on a device that carries a microphone — a way to add one.
///
/// CloudKit is truth, so this reads the records and nothing else. A failed
/// refresh keeps the turns already on screen: what the log last said is
/// still what it said.
@MainActor
@Observable
final class TranscriptStore {
    enum Phase: Equatable {
        case reading
        case ready
        /// Nothing to show, and this is why.
        case failed(String)
        /// Nothing to show because nothing has been written anywhere yet.
        case noLogYet
    }

    private(set) var turns: [Turn] = []
    private(set) var phase: Phase = .reading
    /// A line above the transcript when the log is not a plain straight
    /// line: turns missing from the read, a fork, a refresh that failed.
    private(set) var notice: String?
    private(set) var isSending = false
    /// What the person has said that is not in the log yet, oldest first.
    /// Nothing said is dropped: a turn that fails stays here, and anything
    /// said after it queues behind it so the log keeps the order it was
    /// said in.
    var outbox: [String] { pending.map(\.text) }

    let device: DeviceID
    private let database: any RecordDatabase
    private let log: TurnLog
    private let ensureZone: @Sendable () async throws -> Void
    private let defaults: UserDefaults
    private var writer: TurnWriter?
    /// Asks the primary over the LAN to answer a turn now: the reply's ref and text, or nil.
    /// The socket client in the app; a stub in tests.
    private let ask: @Sendable (String, TurnRef) async -> LiveReply?
    /// A reply that came back over the socket and is shown before the read has its record.
    /// Cleared once a read shows it, or shows a reply to the same turn from the log.
    private var live: Turn?
    /// Each queued turn keeps the nonce it was first attempted under, which
    /// is what makes a retry exactly-once.
    private var pending: [Outgoing] = []

    private static let outboxKey = "topo.outbox"

    private struct Outgoing: Codable, Equatable {
        var text: String
        var nonce: String
    }

    /// - Parameter ensureZone: run before the first append, because the zone
    ///   every record goes in has to exist before anything can be written
    ///   into it. Injected so a test can hold a database and no iCloud.
    init(database: any RecordDatabase, device: DeviceID = DeviceIdentity.current,
         ensureZone: @escaping @Sendable () async throws -> Void = { try await TopoCloudKit.ensureZone() },
         defaults: UserDefaults = .standard,
         ask: @escaping @Sendable (String, TurnRef) async -> LiveReply? = { endpoint, ref in
             await SocketTurnClient().ask(endpoint, toAnswer: ref)
         }) {
        self.device = device
        self.database = database
        self.log = TurnLog(database: database)
        self.ensureZone = ensureZone
        self.defaults = defaults
        self.ask = ask
        // Sends that were in flight when the app went away are still owed,
        // so they survive the launch that lost them.
        if let data = defaults.data(forKey: TranscriptStore.outboxKey),
           let saved = try? JSONDecoder().decode([Outgoing].self, from: data) {
            self.pending = saved
        }
    }

    func refresh() async {
        if turns.isEmpty, phase != .reading { phase = .reading }
        do {
            let transcript = try await log.read()
            var ordered = transcript.ordered
            // A reply that came over the socket stays on screen until the read has it, or has
            // another reply to the same turn.
            if let live {
                if transcript[live.ref] != nil || ordered.contains(where: { $0.role == .assistant && $0.parents == live.parents }) {
                    self.live = nil
                } else {
                    ordered.append(live)
                }
            }
            turns = ordered
            notice = TranscriptStore.notice(for: transcript)
            phase = .ready
        } catch {
            guard turns.isEmpty else {
                // Keep what is on screen; say the refresh did not land.
                notice = "Could not read just now. Showing the last read."
                return
            }
            phase = TopoCloudKit.meansNoLogYet(error) ? .noLogYet : .failed(TranscriptStore.message(for: error))
        }
    }

    /// Re-reads until the calling task is cancelled. Subscriptions are the
    /// design's answer for staying current and are not wired yet, so a
    /// screen that stays open reads again on an interval; without this a
    /// device shows the transcript as it was when the screen opened.
    func refreshing(every interval: Duration) async {
        while !Task.isCancelled {
            await refresh()
            // Anything the person said that has not landed goes with the
            // next read, so a send that failed on a bad minute is not left
            // waiting on them to press it again.
            if !pending.isEmpty { await flush() }
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    /// Appends what the person said, as a turn of theirs.
    ///
    /// This is a limb writing, not a mind answering: the turn goes in the
    /// log and whichever device is primary picks it up. The read that
    /// precedes it is what the turn continues from, and an incomplete one
    /// is refused rather than written, because continuing from a read with
    /// holes writes a fork that never happened.
    ///
    /// What is said goes on a queue first, written down before any attempt,
    /// and the queue drains in order. So nothing said is lost to a failed
    /// send or a relaunch, and saying something new does not step over a
    /// turn that has not landed yet.
    func send(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        pending.append(Outgoing(text: text, nonce: UUID().uuidString))
        save(pending)
        await flush()
    }

    /// Sends whatever is queued, oldest first. Stops at the first one that
    /// will not go, so the order the person said things in is the order the
    /// log gets them.
    ///
    /// An append that fails may still have committed — CloudKit can lose the
    /// acknowledgement, not the write — so each queued turn keeps the nonce
    /// it was first attempted under. TopoCore's writer saves a marker record
    /// under that nonce alongside the turn, so a retry carrying it finds the
    /// marker, follows it to the turn already there and hands that back.
    /// Exactly-once is the writer's; not losing the nonce is this side's.
    func flush() async {
        guard !isSending, !pending.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        // The read at the end has its own notice to set, so what went wrong
        // here is put back after it rather than being written over.
        var failure: String?
        while let next = pending.first {
            do {
                try await ensureZone()
                let transcript = try await log.read()
                let writer: TurnWriter
                if let existing = self.writer {
                    writer = existing
                } else {
                    writer = try await log.writer(for: device)
                    self.writer = writer
                }
                let person = try await writer.append(.person, next.text, continuing: transcript, nonce: next.nonce)
                pending.removeFirst()
                save(pending)
                await askPrimary(toAnswer: person)
            } catch TurnLogError.incompleteTranscript {
                failure = "Not every turn has arrived yet. Topo will send it in a moment."
                break
            } catch {
                failure = "That didn't send: \(TranscriptStore.message(for: error))"
                break
            }
        }
        await refresh()
        if let failure { notice = failure }
    }

    /// The live path: the turn is in the log, so ask the primary, at the endpoint its lease
    /// names, to answer it now and show the reply at once. CloudKit is truth and sockets are
    /// speed: no endpoint, no answer or a dead socket costs nothing, since the primary's own
    /// pass answers the turn from the log and the next read shows it.
    private func askPrimary(toAnswer person: Turn) async {
        guard let record = try? await database.fetch(Lease.recordID), let lease = Lease(record: record),
              !lease.isExpired(at: Date()), let endpoint = lease.endpoint else { return }
        guard let reply = await ask(endpoint, person.ref) else { return }
        live = Turn(ref: reply.ref, parents: [person.ref], role: .assistant, text: reply.text, at: Date())
        if !turns.contains(where: { $0.ref == reply.ref }) { turns.append(live!) }
    }

    private func save(_ pending: [Outgoing]) {
        guard !pending.isEmpty else {
            defaults.removeObject(forKey: TranscriptStore.outboxKey)
            return
        }
        defaults.set(try? JSONEncoder().encode(pending), forKey: TranscriptStore.outboxKey)
    }

    static func notice(for transcript: Transcript) -> String? {
        if !transcript.isComplete { return "Some turns aren't here yet. What arrived is below." }
        if transcript.isForked { return "Two devices carried on from the same point. Both are below." }
        return nil
    }

    static func message(for error: any Error) -> String {
        switch error {
        case RecordDatabaseError.unavailable:
            return "iCloud is out of reach. Topo will try again."
        case RecordDatabaseError.rejected:
            return "iCloud refused the read. Check you're signed in on this device."
        case RecordDatabaseError.serverRecordChanged, RecordDatabaseError.unknownItem:
            return "The log moved under us. Try again."
        case TurnLogError.sequenceContended:
            return "Another device is writing as fast as we are. Try again."
        default:
            return (error as NSError).localizedDescription
        }
    }
}

import Foundation
import Observation
import TopoCore

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

    let device: DeviceID
    private let log: TurnLog
    private let ensureZone: @Sendable () async throws -> Void
    private var writer: TurnWriter?

    /// - Parameter ensureZone: run before the first append, because the zone
    ///   every record goes in has to exist before anything can be written
    ///   into it. Injected so a test can hold a database and no iCloud.
    init(database: any RecordDatabase, device: DeviceID = DeviceIdentity.current,
         ensureZone: @escaping @Sendable () async throws -> Void = { try await TopoCloudKit.ensureZone() }) {
        self.device = device
        self.log = TurnLog(database: database)
        self.ensureZone = ensureZone
    }

    func refresh() async {
        if turns.isEmpty, phase != .reading { phase = .reading }
        do {
            let transcript = try await log.read()
            turns = transcript.ordered
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

    /// Appends what the person said, as a turn of theirs.
    ///
    /// This is a limb writing, not a mind answering: the turn goes in the
    /// log and whichever device is primary picks it up. The read that
    /// precedes it is what the turn continues from, and an incomplete one
    /// is refused rather than written, because continuing from a read with
    /// holes writes a fork that never happened.
    func send(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        defer { isSending = false }
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
            _ = try await writer.append(.person, text, continuing: transcript)
            await refresh()
        } catch TurnLogError.incompleteTranscript {
            notice = "Not every turn has arrived yet. Try again in a moment."
        } catch {
            notice = "That didn't send: \(TranscriptStore.message(for: error))"
        }
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

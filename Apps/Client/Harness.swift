#if os(iOS)
import Foundation
import Observation
import TopoAuth
import TopoCore
import TopoTurn

/// The phone harness as the UI sees it: the transcript, the model setting, and one turn at a time.
/// The log is the shared CloudKit log, on the person's own Apple ID.
@MainActor
@Observable
final class Harness {
    static let modelKey = "model"

    private(set) var turns: [Turn] = []
    private(set) var notice: String?
    private(set) var busy = false
    private(set) var error: String?
    let device: DeviceID

    private let database: any RecordDatabase
    private let log: TurnLog
    private let ensureZone: @Sendable () async throws -> Void
    private let tokens: TokenProvider
    private var runner: TurnRunner?
    private var inFlight: Task<Void, Never>?

    init(database: any RecordDatabase, tokens: TokenProvider, device: DeviceID = DeviceIdentity.current,
         ensureZone: @escaping @Sendable () async throws -> Void = { try await TopoCloudKit.ensureZone() }) {
        self.database = database
        self.tokens = tokens
        self.device = device
        self.ensureZone = ensureZone
        log = TurnLog(database: database)
    }

    /// The app's harness: the shared CloudKit log and the keychain's tokens.
    static func standard(store: TokenStore = KeychainTokenStore()) -> Harness {
        Harness(database: TopoCloudKit.database(), tokens: StoredTokenProvider(store: store))
    }

    var model: ClaudeModel {
        get { UserDefaults.standard.string(forKey: Self.modelKey).flatMap(ClaudeModel.init(rawValue:)) ?? .default }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.modelKey) }
    }

    /// Sign-out: the turn in flight is cancelled and its result dropped, the runner and screen
    /// are cleared, and the next sign-in starts at the first question. The log itself stays where
    /// it is, in the person's own iCloud; nothing of it is on this device to remove.
    func forget() {
        inFlight?.cancel()
        inFlight = nil
        runner = nil
        turns = []
        notice = nil
        error = nil
        busy = false
        UserDefaults.standard.removeObject(forKey: "firstRunAnswer")
    }

    func refresh() async {
        do {
            let transcript = try await log.read()
            turns = transcript.ordered
            notice = TranscriptStore.notice(for: transcript)
        } catch {
            guard !TopoCloudKit.meansNoLogYet(error) else { turns = []; return }
            self.error = "Couldn't read the transcript: \(TranscriptStore.message(for: error))"
        }
    }

    /// One turn: the words go in the log, the reply comes back into it.
    func send(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        busy = true
        error = nil
        let task = Task { await run(text) }
        inFlight = task
        await task.value
        if inFlight == task { inFlight = nil; busy = false }
    }

    private func run(_ text: String) async {
        let generation = inFlight
        do {
            if runner == nil {
                try await ensureZone()
                runner = try await makeRunner()
            }
            guard let runner else { return }
            let result = try await runner.run(text, model: model)
            // A sign-out during the turn cleared the screen; this result is not for it.
            guard inFlight == generation, !Task.isCancelled else { return }
            turns.append(result.person)
            turns.append(result.assistant)
        } catch is CancellationError {
            return
        } catch TurnRunnerError.notPrimary(let outcome) {
            error = Self.describe(outcome)
            await refresh()
        } catch TurnRunnerError.displaced {
            error = "Another device became primary while Claude was answering; it will answer."
            await refresh()
        } catch MessagesAPIError.refused {
            error = "Claude declined that one."
            await refresh()
        } catch MessagesAPIError.http(let status, let message) {
            error = message ?? "Claude answered \(status)."
            await refresh()
        } catch TokenProviderError.signedOut {
            error = "Signed out. Sign in again to continue."
        } catch {
            guard inFlight == generation else { return }
            self.error = TranscriptStore.message(for: error)
            await refresh()
        }
    }

    private func makeRunner() async throws -> TurnRunner {
        let writer = try await log.writer(for: device)
        let lease = PrimaryLease(database: database, device: device, endpoint: nil, probe: NoSocketProbe())
        return TurnRunner(log: log, writer: writer, lease: lease, api: MessagesAPI(tokens: tokens))
    }

    static func describe(_ outcome: LeaseOutcome) -> String {
        switch outcome {
        case .primary: "This device is primary."
        case .held(let by): "\(by.holder.rawValue) is primary right now."
        case .unreachable(let lease): "\(lease.holder.rawValue) took over and can't be reached; try again shortly."
        case .contended: "Another device is claiming primary; try again."
        }
    }
}
#endif

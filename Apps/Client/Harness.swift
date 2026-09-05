#if os(iOS)
import Foundation
import Observation
import TopoAuth
import TopoCore
import TopoTurn

/// The phone harness as the UI sees it: the transcript, the model setting, and one turn at a time.
///
/// The log lives in a local record database in Application Support. CloudKit is the design's home
/// for it and `RecordDatabase` is the seam; the app carries no iCloud entitlement yet.
@MainActor
@Observable
final class Harness {
    static let modelKey = "model"

    private(set) var turns: [Turn] = []
    private(set) var busy = false
    private(set) var error: String?
    let device: DeviceID

    private let database: any RecordDatabase
    private let log: TurnLog
    private var runner: TurnRunner?
    private let tokens: TokenProvider

    init(database: any RecordDatabase, tokens: TokenProvider, device: DeviceID) {
        self.database = database
        self.tokens = tokens
        self.device = device
        log = TurnLog(database: database)
    }

    /// The app's harness: a file-backed log and the keychain's tokens.
    static func standard(store: TokenStore = KeychainTokenStore()) throws -> Harness {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let database = try LocalRecordDatabase(url: support.appendingPathComponent("Topo/log.json"))
        return Harness(database: database, tokens: StoredTokenProvider(store: store), device: Self.deviceID())
    }

    /// Stable across launches, unique across devices.
    static func deviceID() -> DeviceID {
        let key = "deviceID"
        if let saved = UserDefaults.standard.string(forKey: key) { return DeviceID(saved) }
        let fresh = "phone-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: key)
        return DeviceID(fresh)
    }

    var model: ClaudeModel {
        get { UserDefaults.standard.string(forKey: Self.modelKey).flatMap(ClaudeModel.init(rawValue:)) ?? .default }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.modelKey) }
    }

    func refresh() async {
        do {
            turns = try await log.read().ordered
        } catch {
            self.error = "Couldn't read the transcript: \(error)"
        }
    }

    /// One turn: the words go in the log, the reply comes back into it.
    func send(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            if runner == nil { runner = try await makeRunner() }
            guard let runner else { return }
            let result = try await runner.run(text, model: model)
            turns.append(result.person)
            turns.append(result.assistant)
        } catch TurnRunnerError.notPrimary(let outcome) {
            error = Self.describe(outcome)
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
            self.error = "\(error)"
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

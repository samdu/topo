import Foundation
import Network
import TopoCore

/// The phone's word to the hub that holds the lease: the log moved. One `moved` line over TCP to
/// the endpoint the lease record names (`ProbeWire`), held open until the hub answers: `read`
/// once the pass that read the log after the nudge has ended, when the reply it wrote (if it
/// wrote one) is in the log for the phone to read now.
///
/// It is only ever a hint. It carries the lease it is for and the turn's mark, no words and
/// nothing secret, and nothing waits on it: with no answer the poll and the push bring the same
/// turn and the same reply, a few seconds later. Every way it can fail is `unreached`.
public enum HubNudge {
    public enum Answer: Equatable, Sendable {
        /// The hub's pass has ended: read the log.
        case read
        /// The hub has no pass to run for this lease, or too many nudges waiting.
        case no
        /// No answer: the endpoint could not be reached, closed, or said nothing in time. The
        /// kind of failure, for a mark.
        case unreached(String)
    }

    /// How long the connection is given to be made: a LAN round trip is milliseconds, and a phone
    /// off the hub's network fails at once or waits here.
    public static let connectBound: TimeInterval = 2
    /// How long the answer is waited for: a pass is the model's whole turn.
    public static let answerBound: TimeInterval = 600

    /// Says the log moved to the holder of `lease`, at its endpoint, and waits for its answer.
    public static func send(for lease: Lease, mark: String, connectBound: TimeInterval = connectBound,
                            answerBound: TimeInterval = answerBound) async -> Answer {
        guard let endpoint = lease.endpoint, let (host, port) = SocketLeaseProbe.parse(endpoint) else {
            return .unreached("noEndpoint")
        }
        guard ProbeWire.isMark(Substring(mark)) else { return .unreached("badMark") }
        let connection = NWConnection(host: host, port: port, using: .tcp)
        let stage = Stage()
        // Each bound cancels the connection, which fails whichever step is pending.
        let connecting = Task {
            try? await Task.sleep(for: .seconds(connectBound))
            if stage.isConnecting { connection.cancel() }
        }
        // From the moment the line is sent.
        var answering: Task<Void, Never>?
        defer {
            connecting.cancel()
            answering?.cancel()
            connection.cancel()
        }
        return await withTaskCancellationHandler {
            connection.start(queue: DispatchQueue(label: "zone.hexagon.topo.link.nudge"))
            do {
                try await connection.waitUntilReady()
            } catch {
                return .unreached(Self.kind(error, connection))
            }
            stage.connected()
            do {
                try await connection.send(ProbeWire.nudge(lease, mark: mark))
            } catch {
                return .unreached("send")
            }
            Perf.mark("nudge.sent")
            answering = Task {
                try? await Task.sleep(for: .seconds(answerBound))
                connection.cancel()
            }
            guard let line = try? await connection.readLine(maximum: 16) else { return .unreached("answer") }
            switch line.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "read": return .read
            case "no": return .no
            default: return .unreached("answer")
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Why a connection was not made, by kind: denied local network access says so, since it is
    /// the one a person can change.
    private static func kind(_ error: any Error, _ connection: NWConnection) -> String {
        if connection.currentPath?.unsatisfiedReason == .localNetworkDenied { return "localNetworkDenied" }
        if error is CancellationError { return "connectTimeout" }
        return "connect"
    }

    private final class Stage: @unchecked Sendable {
        private let lock = NSLock()
        private var made = false
        var isConnecting: Bool { lock.withLock { !made } }
        func connected() { lock.withLock { made = true } }
    }
}

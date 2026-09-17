#if os(iOS)
import Foundation
import OSLog

/// What the audio paths say about themselves where a debugger cannot be: every hold and keeper
/// transition, every rebuild of the play queue. Unified logging rather than the console, because
/// the evidence for a reply heard behind the lock comes off a phone running with nothing attached
/// — Xcode's debugger keeps a backgrounded app alive, so anything it shows about the background is
/// wrong — and is read back afterwards with `log collect --device` and `log show --predicate
/// 'subsystem == "zone.hexagon.topo"'`.
///
/// A debug build says the same lines on the console through `DebugRun`, so a simulator run reads
/// them where it reads everything else.
enum AudioLog {
    private static let log = Logger(subsystem: "zone.hexagon.topo", category: "audio")

    static func say(_ line: @autoclosure () -> String) {
        let line = line()
        log.notice("\(line, privacy: .public)")
        #if DEBUG
        DebugRun.say("audio: \(line)")
        #endif
    }

    #if DEBUG
    /// A line every five seconds for as long as the process is running, which is how a device run
    /// says when iOS suspended it: the heartbeat stops. Debug builds only — a release build has
    /// nobody reading it.
    @MainActor
    static func startHeartbeat() {
        guard heartbeat == nil else { return }
        heartbeat = Task {
            var beat = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                beat += 1
                say("heartbeat \(beat)")
            }
        }
    }

    @MainActor
    private static var heartbeat: Task<Void, Never>?
    #endif
}
#endif

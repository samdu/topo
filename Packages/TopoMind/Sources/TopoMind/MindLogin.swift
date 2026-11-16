import Foundation
import TopoAuth

/// Whether the mind's Claude Code is signed in, as `claude auth status --json` says it with the
/// mind's own config directory: the method and the subscription, never the credential, which
/// nothing here reads. The login itself is made outside the app, in that config directory.
public enum MindLogin: Sendable, Equatable {
    /// Signed in; the method and the subscription (`ClaudeLoginStatus.summary`).
    case signedIn(String)
    case signedOut
    /// Claude Code could not be asked, or gave no status: why.
    case unknown(String)

    public var isSignedIn: Bool {
        if case .signedIn = self { true } else { false }
    }

    /// Asks the configuration's `claude` in its environment and working directory, bounded: a
    /// status not given within `bound` is `.unknown`, and the process is ended either way.
    public static func check(_ configuration: NativeBrain.Configuration,
                             within bound: Duration = .seconds(20)) async -> MindLogin {
        let process: MindProcess
        do {
            process = try MindProcess(executable: configuration.claude.path, arguments: ["auth", "status", "--json"],
                                      environment: NativeBrain.environment(for: configuration),
                                      directory: configuration.workingDirectory.path)
        } catch {
            return .unknown(String(describing: error))
        }
        process.closeInput()
        let output: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                var lines: [String] = []
                while true {
                    switch await process.stdout.next() {
                    case .line(let line): lines.append(line)
                    case .end: return lines.joined(separator: "\n")
                    case .cancelled: return nil
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: bound)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        _ = await process.terminate(grace: .seconds(1))
        guard let output else { return .unknown("claude auth status gave no answer within \(bound)") }
        guard let status = ClaudeLoginStatus.parse(output) else { return .unknown("claude auth status printed no status") }
        return status.loggedIn ? .signedIn(status.summary) : .signedOut
    }
}

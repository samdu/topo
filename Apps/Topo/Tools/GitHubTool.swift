import Foundation
import TopoAuth
import TopoTools

/// `topo github`: whether GitHub is connected, and — as `token` and `credential`, the forms the
/// guest's `gh` wrapper and `git` credential helper call and which the usage leaves out — the
/// token for one command. Any guest process can call those forms too, since every one inherits the
/// service's token; `docs/design.md` says what that means. The token is read from the keychain on every
/// call and kept nowhere, so a disconnect reaches the guest at its next call.
struct GitHubTool: Tool {
    let store: any ConnectionStore
    /// A clear refused at a sign-out, a takeover or a demotion: while it stands the token is an
    /// earlier login's, and nothing is handed out.
    var leftBehind = ConnectionsLeftBehind()

    let name = "github"
    let summary = "whether GitHub is connected, and as whom; git and gh use it by themselves"
    let usage = """
    topo github                 connected as whom, or not connected

    git over https:// and gh use the connection without being told; nothing needs the token
    written into a file, a remote URL or a config.
    """

    static let notConnected = "GitHub is not connected: the person connects it in Settings › Connections › GitHub.\n"

    func run(_ arguments: [String]) async -> ToolReply {
        guard arguments.count <= 1 else { return .usage(usage) }
        let form = arguments.first
        guard form == nil || form == "token" || form == "credential" else { return .usage(usage) }
        if let words = leftBehind.words {
            return .failed("GitHub is not handed out: at an earlier sign-out \(words). "
                           + "The app tries again at each launch, and Disconnect in Settings › Connections tries now.\n")
        }
        let connection: Connection?
        do {
            connection = try await load()
        } catch {
            return .failed("The GitHub connection could not be read from the keychain: \(error)\n")
        }
        guard let connection else { return ToolReply(status: ToolReply.failed, text: Self.notConnected) }
        switch form {
        case "token": return .ok(connection.token + "\n")
        case "credential": return .ok("username=\(connection.account)\npassword=\(connection.token)\n")
        default: return .ok("connected as \(connection.account)\n")
        }
    }

    /// The keychain read is a synchronous framework call, so it runs on a queue of its own and not
    /// on the cooperative pool.
    private func load() async throws -> Connection? {
        let store = store
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try store.load(.github) })
            }
        }
    }
}

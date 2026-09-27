import Foundation
import TopoAuth
import TopoTools

/// `topo secret`: the person's secrets from the 1Password vaults their service account reaches,
/// read by `op` in a guest process the app starts with the token only the app holds. The mind is
/// answered with values, never the token. Reads only: `vault list`, `item list` and `read` are
/// all `op` is ever asked.
struct SecretTool: Tool {
    let store: any ConnectionStore
    let onePassword: any OnePasswordRunning

    let name = "secret"
    let summary = "the person's secrets from their connected 1Password vaults: list them, read one"
    let usage = """
    topo secret vaults                      the vaults the connection reaches, id first
    topo secret list [VAULT]                the items, one a line: id, title, category, vault
    topo secret get op://VAULT/ITEM/FIELD   one field's value
    """

    static let notConnected = "1Password is not connected: the person connects it in Settings › Connections › 1Password.\n"

    enum Call: Equatable {
        case vaults
        case list(vault: String?)
        case get(reference: String)

        var arguments: [String] {
            switch self {
            case .vaults: OnePasswordVaults.arguments
            case .list(nil): ["item", "list", "--format", "json"]
            case .list(let vault?): ["item", "list", "--vault", vault, "--format", "json"]
            case .get(let reference): ["read", "--no-newline", "--", reference]
            }
        }
    }

    static func parse(_ arguments: [String]) -> Call? {
        switch arguments.first {
        case "vaults" where arguments.count == 1: return .vaults
        case "list" where arguments.count == 1: return .list(vault: nil)
        case "list" where arguments.count == 2 && !arguments[1].hasPrefix("-") && !arguments[1].isEmpty:
            return .list(vault: arguments[1])
        case "get" where arguments.count == 2 && isReference(arguments[1]): return .get(reference: arguments[1])
        default: return nil
        }
    }

    /// `op://vault/item/field`, or with a section, and nothing that is not printable on one line.
    static func isReference(_ text: String) -> Bool {
        guard text.hasPrefix("op://"), !text.contains(where: { $0.isWhitespace && $0 != " " }),
              !text.contains(where: \.isNewline) else { return false }
        let parts = text.dropFirst(5).split(separator: "/", omittingEmptySubsequences: false)
        return (3...4).contains(parts.count) && parts.allSatisfy { !$0.isEmpty }
    }

    func run(_ arguments: [String]) async -> ToolReply {
        guard let call = Self.parse(arguments) else { return .usage(usage) }
        let connection: Connection?
        do {
            let store = store
            connection = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try store.load(.onePassword) })
                }
            }
        } catch {
            return .failed("The 1Password connection could not be read from the keychain: \(error)\n")
        }
        guard let connection else { return ToolReply(status: ToolReply.failed, text: Self.notConnected) }
        let exit: OnePasswordExit
        do {
            exit = try await onePassword.run(call.arguments, token: connection.token)
        } catch {
            return .failed("1Password's op could not be run in the guest: \(error)\n")
        }
        guard exit.status == 0 else {
            return .failed("op: \(exit.said.isEmpty ? "status \(exit.status)" : exit.said)\n")
        }
        switch call {
        case .vaults:
            guard let vaults = OnePasswordVaults.read(exit.output) else { return .failed("op answered something unreadable\n") }
            return .ok(PhoneTool.lines(vaults.map { PhoneTool.line([$0.id, $0.name]) }, none: "no vaults"))
        case .list:
            struct Item: Decodable {
                struct Vault: Decodable { var name: String }
                var id: String
                var title: String
                var category: String
                var vault: Vault?
            }
            guard let items = try? JSONDecoder().decode([Item].self, from: Data(exit.output.utf8)) else {
                return .failed("op answered something unreadable\n")
            }
            return .ok(PhoneTool.lines(items.map { PhoneTool.line([$0.id, $0.title, $0.category, $0.vault?.name]) },
                                       none: "no items"))
        case .get:
            return .ok(exit.output + "\n")
        }
    }
}

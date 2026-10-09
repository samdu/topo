import Foundation
import TopoAuth
import TopoTools

/// `topo secret`: the person's secrets from the 1Password vaults their service account reaches,
/// read by `op` in a guest process the app starts with the token only the app holds. The mind is
/// answered with values, never the token. Reads only: `vault list`, `item list`, `item get` and
/// `read` are all `op` is ever asked.
struct SecretTool: Tool {
    let store: any ConnectionStore
    let onePassword: any OnePasswordRunning
    /// A clear refused at a sign-out, a takeover or a demotion: while it stands the token is an
    /// earlier login's, and `op` is not run with it.
    var leftBehind = ConnectionsLeftBehind()
    /// Where a request waits on no clear of the token and a clear ends it: `Connections.secrets`.
    var requests = SecretRequests()

    let name = "secret"
    let summary = "the person's secrets from their connected 1Password vaults: list them, read one"
    let usage = """
    topo secret vaults                      the vaults the connection reaches, id first
    topo secret list [VAULT]                the items, one a line: id, title, category, vault
    topo secret show ITEM VAULT             what one item holds, no values: an `item` line, then a line for each
                                            field (label, type, purpose, section) and each file (name, size),
                                            ending in the reference `get` takes where `op` gave one. ITEM is an
                                            id or a title, VAULT the vault `list` names: a service account is
                                            refused an item without its vault
    topo secret get op://VAULT/ITEM/FIELD   one field's value, or one file's text with the file's name for FIELD
    topo secret get op://VAULT/ITEM         the text of the item's one file (a Document); an item with several
                                            files is status 2 naming each, and one with none status 1

    A file is answered as text: one that is not UTF-8 does not come back whole.
    """

    static let notConnected = "1Password is not connected: the person connects it in Settings › Connections › 1Password.\n"

    enum Call: Equatable {
        case vaults
        case list(vault: String?)
        case get(reference: String)
        /// What an item holds, its values withheld.
        case show(item: String, vault: String)
        /// The one file of an item, by `op://VAULT/ITEM`.
        case file(vault: String, item: String)

        /// What `op` is asked first: for `file`, what the item holds, and then one `read`.
        var arguments: [String] {
            switch self {
            case .vaults: OnePasswordVaults.arguments
            case .list(nil): ["item", "list", "--format", "json"]
            case .list(let vault?): ["item", "list", "--vault", vault, "--format", "json"]
            case .get(let reference): Self.read(reference)
            case .show(let item, let vault), .file(let vault, let item):
                ["item", "get", "--vault", vault, "--format", "json", "--", item]
            }
        }

        static func read(_ reference: String) -> [String] { ["read", "--no-newline", "--", reference] }
    }

    /// What `op item get --format json` says of an item, less every value: nothing here has a
    /// property a field's value, a one-time code or a URL could be decoded into, so none can
    /// reach an answer.
    struct Item: Decodable, Equatable {
        struct Vault: Decodable, Equatable {
            var id: String
            var name: String
        }
        struct Section: Decodable, Equatable {
            var label: String?
        }
        struct Field: Decodable, Equatable {
            var id: String
            var label: String?
            var type: String?
            var purpose: String?
            var section: Section?
            var reference: String?
        }
        struct File: Decodable, Equatable {
            var id: String
            var name: String?
            var size: Int?
            var section: Section?
        }
        var id: String
        var title: String
        var category: String
        var vault: Vault
        var fields: [Field]?
        var files: [File]?

        static func read(_ output: String) -> Item? {
            try? JSONDecoder().decode(Item.self, from: Data(output.utf8))
        }

        /// A file's reference by ids, which reach it whatever its name holds.
        func reference(to file: File) -> String { "op://\(vault.id)/\(id)/\(file.id)" }

        private func line(_ file: File) -> String {
            PhoneTool.line(["file", file.name ?? file.id, file.size.map { "\($0) bytes" },
                            file.section?.label.map { "section " + $0 }, reference(to: file)])
        }

        /// The `item` line, then a line a field and a line a file, each ending in its reference where
        /// `op` gave one.
        var lines: [String] {
            [PhoneTool.line(["item", id, title, category, vault.name])]
                + (fields ?? []).map { PhoneTool.line(["field", $0.label ?? $0.id, $0.type, $0.purpose, $0.section?.label.map { "section " + $0 },
                                                       $0.reference]) }
                + (files ?? []).map(line)
        }

        /// Each file's line, for an item `get` cannot choose one of.
        var fileLines: [String] { (files ?? []).map(line) }
    }

    static func parse(_ arguments: [String]) -> Call? {
        switch arguments.first {
        case "vaults" where arguments.count == 1: return .vaults
        case "list" where arguments.count == 1: return .list(vault: nil)
        case "list" where arguments.count == 2 && !arguments[1].hasPrefix("-") && !arguments[1].isEmpty:
            return .list(vault: arguments[1])
        case "get" where arguments.count == 2 && isReference(arguments[1]): return .get(reference: arguments[1])
        case "get" where arguments.count == 2:
            guard let parts = parts(of: arguments[1]), parts.count == 2, isName(parts[0]) else { return nil }
            return .file(vault: parts[0], item: parts[1])
        case "show" where arguments.count == 3 && isName(arguments[1], dashed: true) && isName(arguments[2]):
            return .show(item: arguments[1], vault: arguments[2])
        default: return nil
        }
    }

    /// `op://vault/item/field`, or with a section, and nothing that is not printable on one line.
    static func isReference(_ text: String) -> Bool {
        parts(of: text).map { (3...4).contains($0.count) } ?? false
    }

    /// The parts of `op://a/b/…`, each non-empty, or nil for text that is not that or is not
    /// printable on one line.
    private static func parts(of text: String) -> [String]? {
        guard text.hasPrefix("op://"), !text.contains(where: { $0.isWhitespace && $0 != " " }),
              !text.contains(where: \.isNewline) else { return nil }
        let parts = text.dropFirst(5).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return parts.allSatisfy { !$0.isEmpty } ? parts : nil
    }

    /// A vault's or an item's name or id as an argument of `op`'s: one line, not empty, and not
    /// starting with a dash unless it is the item, which follows `--`.
    private static func isName(_ text: String, dashed: Bool = false) -> Bool {
        !text.isEmpty && !text.contains(where: { $0.isWhitespace && $0 != " " }) && !text.contains(where: \.isNewline)
            && (dashed || !text.hasPrefix("-"))
    }

    /// Said while a refused clear stands.
    private func refused(_ words: String) -> ToolReply {
        .failed("1Password is not used: at an earlier sign-out \(words). "
                + "The app tries again at each launch, and Disconnect in Settings › Connections tries now.\n")
    }

    /// One request through `requests`: refused while a refused clear stands or a clear runs,
    /// and answering nothing if a clear starts while it runs.
    func run(_ arguments: [String]) async -> ToolReply {
        guard let call = Self.parse(arguments) else { return .usage(usage) }
        let leftBehind = leftBehind
        return await requests.run(refusal: { leftBehind.words.map(refused) }) { await answer(call) }
    }

    private func answer(_ call: Call) async -> ToolReply {
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
        // A clear that started while the keychain was read cancelled this request: the token read
        // may be a login's that is gone, and `op` is not run with it.
        guard !Task.isCancelled else { return SecretRequests.stopped }
        let output: String
        switch await ask(call.arguments, connection) {
        case .success(let said): output = said
        case .failure(let refusal): return refusal.reply
        }
        switch call {
        case .vaults:
            guard let vaults = OnePasswordVaults.read(output) else { return .failed("op answered something unreadable\n") }
            return .ok(PhoneTool.lines(vaults.map { PhoneTool.line([$0.id, $0.name]) }, none: "no vaults"))
        case .list:
            struct Listed: Decodable {
                struct Vault: Decodable { var name: String }
                var id: String
                var title: String
                var category: String
                var vault: Vault?
            }
            guard let items = try? JSONDecoder().decode([Listed].self, from: Data(output.utf8)) else {
                return .failed("op answered something unreadable\n")
            }
            return .ok(PhoneTool.lines(items.map { PhoneTool.line([$0.id, $0.title, $0.category, $0.vault?.name]) },
                                       none: "no items"))
        case .get:
            return .ok(output + "\n")
        case .show:
            guard let item = Item.read(output) else { return .failed("op answered something unreadable\n") }
            return .ok(PhoneTool.lines(item.lines, none: "nothing"))
        case .file(let vault, let name):
            guard let item = Item.read(output) else { return .failed("op answered something unreadable\n") }
            let files = item.files ?? []
            guard let file = files.first else {
                return .failed("\(item.title) holds no file: topo secret show \(Self.quoted(name)) \(Self.quoted(vault)) lists its fields\n")
            }
            guard files.count == 1 else {
                return .usage("\(item.title) holds \(files.count) files; get one by its reference:\n" + PhoneTool.lines(item.fileLines, none: ""))
            }
            // A clear that started while the item was read: the second read is not made.
            guard !Task.isCancelled else { return SecretRequests.stopped }
            switch await ask(Call.read(item.reference(to: file)), connection) {
            // The file as `op` gave it: no line is added to one that may end in its own.
            case .success(let text): return .ok(text)
            case .failure(let refusal): return refusal.reply
            }
        }
    }

    /// A reply carried as a failure.
    private struct Refusal: Error {
        var reply: ToolReply
    }

    /// One run of `op`: what it printed, or why that is not an answer. The token is never an
    /// answer, however op comes by it: a field holding the service account's own token, or a name
    /// that is it, is refused whole, and so is an item holding it, shown or not.
    private func ask(_ arguments: [String], _ connection: Connection) async -> Result<String, Refusal> {
        let exit: OnePasswordExit
        do {
            exit = try await onePassword.run(arguments, token: connection.token)
        } catch {
            return .failure(Refusal(reply: .failed("1Password's op could not be run in the guest: \(error)\n")))
        }
        guard exit.status == 0 else {
            return .failure(Refusal(reply: .failed("op: \(exit.said.isEmpty ? "status \(exit.status)" : exit.said)\n")))
        }
        guard !exit.output.contains(connection.token) else {
            return .failure(Refusal(reply: .failed("1Password answered this connection's own service-account token, which is never answered.\n")))
        }
        return .success(exit.output)
    }

    /// A name as a shell word, for a call the answer suggests.
    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

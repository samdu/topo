import Foundation
import Network
import Security
import TopoAuth
import TopoTools

/// A control's request made: its secrets resolved from the keychain immediately before, then one
/// data task on an ephemeral session under an absolute deadline, no redirect followed, no retry,
/// and the response read no further than its status. What it carried — a header's value, a secret,
/// the query, the body, the response — goes nowhere: not the taps' log, not a log line (Review
/// Focus 13).
extension ControlRequest {
    /// From the start to the answer, whatever the server trickles.
    static let deadline: Duration = .seconds(10)

    /// A request's status as A's taps record a run's: `0` for a 2xx, `1` for anything else or
    /// nothing sent, `4` at the deadline; with the HTTP code when the server answered one.
    struct Answer: Equatable, Sendable {
        var status: Int32
        var code: Int?
    }

    static func perform(_ form: Form, secrets: ControlSecrets, leftBehind: ConnectionsLeftBehind = ConnectionsLeftBehind(),
                        deadline: Duration = deadline) async -> Answer {
        // While a clear of the control secrets refused at a sign-out stands, what the keychain
        // holds is an earlier login's, so a request naming one sends nothing.
        if !form.secrets.isEmpty, leftBehind.controlSecrets != nil { return Answer(status: ToolReply.failed) }
        // A reference to a missing secret sends nothing.
        guard let request = form.urlRequest(secret: { try? secrets.read($0) }) else { return Answer(status: ToolReply.failed) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        let seconds = Double(deadline.components.seconds) + Double(deadline.components.attoseconds) / 1e18
        configuration.timeoutIntervalForRequest = seconds
        configuration.timeoutIntervalForResource = seconds
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return await withTaskGroup(of: Answer?.self) { group in
            group.addTask {
                do {
                    // The bytes are never read: the answer is the status line and its headers.
                    let (_, response) = try await session.bytes(for: request)
                    let code = (response as? HTTPURLResponse)?.statusCode
                    return Answer(status: (200..<300).contains(code ?? 0) ? 0 : ToolReply.failed, code: code)
                } catch {
                    return Task.isCancelled ? nil : Answer(status: ToolReply.failed)
                }
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return Task.isCancelled ? nil : Answer(status: ToolReply.timedOut)
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? Answer(status: ToolReply.timedOut)
        }
    }

    /// A 3xx is the answer: the redirect is declined, and the response it came in is returned.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }
}

extension ControlRequest.Answer {
    init(status: Int32) { self.init(status: status, code: nil) }
}

extension ControlRequest.Form {
    /// The request this form sends, each `${secret:<name>}` replaced by `secret`'s value, or nil
    /// when one names a secret the keychain does not hold.
    func urlRequest(secret: (String) -> String?) -> URLRequest? {
        var values: [String: String] = [:]
        for name in secrets {
            guard let value = secret(name) else { return nil }
            values[name] = value
        }
        func resolve(_ text: String) -> String {
            text.replacing(ControlRequest.reference) { values[String($0.output.1)] ?? "" }
        }
        guard let url = URL(string: self.url) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        for header in headers { request.setValue(resolve(header.value), forHTTPHeaderField: header.name) }
        if let body { request.httpBody = Data(resolve(body).utf8) }
        return request
    }
}

/// The credentials a control's `request` names, set by `topo control secret`: one generic-password
/// item per name in the device keychain, this device only and never synced, under their own
/// service. A document never holds a value, only its name (Review Focus 14); a sign-out removes
/// every one.
struct ControlSecrets: Sendable {
    static let service = "zone.hexagon.topo.control-secret"
    /// A secret's name: what a `${secret:<name>}` reference can name.
    static func isName(_ name: String) -> Bool { name.wholeMatch(of: /[A-Za-z0-9_.-]{1,64}/) != nil }

    var service = ControlSecrets.service

    struct Failure: Error, Equatable {
        var status: OSStatus
    }

    private func item(_ name: String) -> KeychainItem { KeychainItem(service: service, account: name) }

    func read(_ name: String) throws -> String? {
        try item(name).read().map { String(decoding: $0, as: UTF8.self) }
    }

    func set(_ value: String, name: String) throws {
        try item(name).write(Data(value.utf8))
    }

    func clear(_ name: String) throws {
        try item(name).delete()
    }

    /// The names held, never their values.
    func names() throws -> [String] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw Failure(status: status) }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    /// Every one, at a sign-out.
    func clearAll() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}

/// Local network access for a control's request to the home network. A background request made
/// while it is undetermined is denied with no prompt (TN3179), so it is asked for in the
/// foreground only: `ask` opens a connection to the request's host and port and cancels it with
/// nothing sent, which raises the system's prompt without making the request. A host asked for
/// while the app is away waits for the next foreground. What the last ask found is kept, for
/// `topo control` to report.
@MainActor
final class LocalNetworkAccess {
    static let shared = LocalNetworkAccess()

    enum State: String, Sendable {
        case allowed, denied
        case notAsked = "not asked"
    }

    private let defaults: UserDefaults
    private static let key = "topo.control.localNetwork"
    /// Hosts and ports named while the app was away, asked at the next foreground.
    private var waiting: [NWEndpoint] = []
    private var connections: [NWConnection] = []
    /// Whether the app is in front, which only the app knows.
    var isActive: () -> Bool = { false }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var state: State { defaults.string(forKey: Self.key).flatMap(State.init(rawValue:)) ?? .notAsked }

    /// Whether `url`'s host is on the local network: a private or link-local address, or a
    /// `.local` name.
    nonisolated static func isLocal(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return false }
        if host.hasSuffix(".local") || host.hasSuffix(".local.") { return true }
        if let v4 = IPv4Address(host) {
            let b = [UInt8](v4.rawValue)
            return b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
                || (b[0] == 169 && b[1] == 254)
        }
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        if let v6 = IPv6Address(bare) {
            let b = [UInt8](v6.rawValue)
            return (b[0] == 0xfe && b[1] & 0xc0 == 0x80) || b[0] & 0xfe == 0xfc
        }
        return false
    }

    /// Asks for access to `url`'s host if it is local: now when the app is in front, else at the
    /// next foreground.
    func ask(for url: URL) {
        guard Self.isLocal(url), let host = url.host() else { return }
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: endpointPort)
        if isActive() { open(endpoint) } else { waiting.append(endpoint) }
    }

    /// The app has come forward: what waited is asked now.
    func becameActive() {
        let asked = waiting
        waiting = []
        asked.forEach(open)
    }

    private func open(_ endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connections.append(connection)
        let finish: @MainActor (State?) -> Void = { [weak self, weak connection] found in
            guard let self, let connection else { return }
            if let found { self.defaults.set(found.rawValue, forKey: Self.key) }
            connection.cancel()
            self.connections.removeAll { $0 === connection }
        }
        connection.stateUpdateHandler = { @Sendable state in
            let found: State?
            switch state {
            case .ready: found = .allowed
            case .waiting, .failed:
                found = connection.currentPath?.unsatisfiedReason == .localNetworkDenied ? .denied : nil
            default: return
            }
            Task { @MainActor in finish(found) }
        }
        connection.start(queue: .global(qos: .utility))
        // A host that never answers is given up on; nothing is ever sent on the connection.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            finish(nil)
        }
    }
}

import Foundation

/// Connecting GitHub: the OAuth device flow against Topo's OAuth App. The person approves on
/// github.com with a code the app shows; the app polls until GitHub hands over a token. No client
/// secret and no redirect are involved, which is why this flow and not the web one: the app ships
/// to phones and a secret in it would be no secret. An OAuth App's tokens (`gho_`) do not expire,
/// so there is nothing to refresh; they last until the person revokes them on GitHub.
public struct GitHubDeviceFlow: Sendable {
    public struct Configuration: Sendable {
        public var codeURL: URL
        public var tokenURL: URL
        public var userURL: URL
        public var clientID: String
        /// What the token may do, as GitHub's OAuth scopes.
        public var scopes: [String]

        /// Topo's OAuth App, registered by Sam (samdu/topo#235): `repo` to clone and push private
        /// repositories and open pull requests, `read:org` for `gh` to list organizations' repositories
        /// and teams, `workflow` to push a change under `.github/workflows`, which `repo` alone refuses.
        public static let topo = Configuration(
            codeURL: URL(string: "https://github.com/login/device/code")!,
            tokenURL: URL(string: "https://github.com/login/oauth/access_token")!,
            userURL: URL(string: "https://api.github.com/user")!,
            clientID: "Ov23liOQVQHli5vrchlv",
            scopes: ["repo", "read:org", "workflow"]
        )

        public init(codeURL: URL, tokenURL: URL, userURL: URL, clientID: String, scopes: [String]) {
            self.codeURL = codeURL
            self.tokenURL = tokenURL
            self.userURL = userURL
            self.clientID = clientID
            self.scopes = scopes
        }
    }

    /// What GitHub answers a start with: the code the person types, where they type it, and what
    /// the poll needs.
    public struct Code: Sendable, Equatable {
        public var userCode: String
        public var verificationURL: URL
        public var deviceCode: String
        /// Seconds between polls, as GitHub asks.
        public var interval: Int
        /// Seconds the code lasts from the start.
        public var expiresIn: Int
        /// When the start was answered, on the flow's clock.
        public var issued: Date

        public init(userCode: String, verificationURL: URL, deviceCode: String, interval: Int, expiresIn: Int, issued: Date) {
            self.userCode = userCode
            self.verificationURL = verificationURL
            self.deviceCode = deviceCode
            self.interval = interval
            self.expiresIn = expiresIn
            self.issued = issued
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// The code ran out before the person approved it.
        case expired
        /// The person declined on GitHub.
        case denied
        /// GitHub answered something else; its own words where it gave any.
        case github(String)

        public var description: String {
            switch self {
            case .expired: "The code expired before it was approved. Connect again for a new one."
            case .denied: "GitHub says the request was declined."
            case .github(let words): "GitHub: \(words)"
            }
        }
    }

    public var configuration: Configuration
    var session: URLSession
    var now: @Sendable () -> Date
    var sleep: @Sendable (Duration) async throws -> Void

    public init(configuration: Configuration = .topo, session: URLSession = .shared,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.configuration = configuration
        self.session = session
        self.now = now
        self.sleep = sleep
    }

    /// Asks GitHub for a code: the client ID and the scopes, space-separated.
    public func start() async throws -> Code {
        let json = try await post(configuration.codeURL, [
            "client_id": configuration.clientID,
            "scope": configuration.scopes.joined(separator: " "),
        ])
        guard let userCode = json["user_code"] as? String,
              let deviceCode = json["device_code"] as? String,
              let verification = (json["verification_uri"] as? String).flatMap(URL.init(string:)) else {
            throw Failure.github(json["error_description"] as? String ?? "no code in the answer")
        }
        return Code(userCode: userCode, verificationURL: verification, deviceCode: deviceCode,
                    interval: json["interval"] as? Int ?? 5, expiresIn: json["expires_in"] as? Int ?? 900,
                    issued: now())
    }

    /// Polls until GitHub hands over the token, the person declines, or the code expires. Waits
    /// `interval` before each poll, and from every `slow_down` on the interval GitHub names or five
    /// seconds more, whichever is longer, as GitHub asks. A poll the network failed is polled again
    /// at the next interval — a phone moving between networks while the person approves is the
    /// ordinary case — so only the code's expiry ends it on the network's account. Cancelling the
    /// task ends it at its next wait.
    public func token(for code: Code) async throws -> String {
        let deadline = code.issued.addingTimeInterval(TimeInterval(code.expiresIn))
        var interval = code.interval
        while true {
            try await sleep(.seconds(interval))
            try Task.checkCancellation()
            guard now() < deadline else { throw Failure.expired }
            let json: [String: Any]
            do {
                json = try await post(configuration.tokenURL, [
                    "client_id": configuration.clientID,
                    "device_code": code.deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ])
            } catch is URLError {
                continue
            }
            if let token = json["access_token"] as? String, !token.isEmpty { return token }
            switch json["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval = (json["interval"] as? Int).map { max($0, interval + 5) } ?? interval + 5
            case "expired_token": throw Failure.expired
            case "access_denied": throw Failure.denied
            case let error:
                throw Failure.github(json["error_description"] as? String ?? error ?? "no token in the answer")
            }
        }
    }

    /// Who the token belongs to: the GitHub login.
    public func login(token: String) async throws -> String {
        var request = URLRequest(url: configuration.userURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Topo", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard status == 200, let login = json["login"] as? String else {
            throw Failure.github(json["message"] as? String ?? "HTTP \(status) from /user")
        }
        return login
    }

    private func post(_ url: URL, _ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var components = URLComponents()
        components.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.github("HTTP \(status), not JSON")
        }
        return json
    }
}

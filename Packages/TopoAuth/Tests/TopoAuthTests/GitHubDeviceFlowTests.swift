import Foundation
import Testing
@testable import TopoAuth

/// A clock that only moves when the flow sleeps, or when a stubbed answer moves it.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_000_000)
    private var slept: [Duration] = []

    var now: Date { lock.withLock { time } }
    var sleeps: [Duration] { lock.withLock { slept } }

    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }

    func sleep(_ duration: Duration) {
        lock.withLock {
            slept.append(duration)
            time += TimeInterval(duration.components.seconds)
        }
    }
}

func form(_ body: Data) -> [String: String] {
    var components = URLComponents()
    components.percentEncodedQuery = String(decoding: body, as: UTF8.self)
    return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

extension Stubbed {
    @Suite struct GitHubDeviceFlowTests {
        let clock = TestClock()

        func flow() -> GitHubDeviceFlow {
            let clock = clock
            return GitHubDeviceFlow(session: StubURLProtocol.session(), now: { clock.now }, sleep: { clock.sleep($0) })
        }

        func code(interval: Int = 5, expiresIn: Int = 900) -> GitHubDeviceFlow.Code {
            GitHubDeviceFlow.Code(userCode: "ABCD-1234", verificationURL: URL(string: "https://github.com/login/device")!,
                                  deviceCode: "dev", interval: interval, expiresIn: expiresIn, issued: clock.now)
        }

        /// Answers each token poll from `answers` in turn, the last one for every poll after.
        func poll(_ answers: [String], onPoll: @escaping @Sendable (Int) -> Void = { _ in }) {
            let count = Counter()
            StubURLProtocol.requestResponder = { _, _ in
                let n = count.next()
                onPoll(n)
                return (200, answers[min(n, answers.count - 1)])
            }
        }

        @Test func startSendsTheClientIDAndScopesAndNoSecret() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.requestResponder = { _, _ in
                (200, #"{"device_code":"dev","user_code":"5632-7741","verification_uri":"https://github.com/login/device","expires_in":899,"interval":5}"#)
            }
            let code = try await flow().start()
            #expect(code.userCode == "5632-7741")
            #expect(code.verificationURL.absoluteString == "https://github.com/login/device")
            #expect(code.deviceCode == "dev" && code.interval == 5 && code.expiresIn == 899)
            #expect(StubURLProtocol.lastRequest?.url?.absoluteString == "https://github.com/login/device/code")
            #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(form(StubURLProtocol.bodies[0]) == ["client_id": "Ov23liOQVQHli5vrchlv", "scope": "repo read:org workflow"])
        }

        @Test func pollSendsNoSecretAndReturnsTheToken() async throws {
            StubURLProtocol.reset()
            poll([#"{"access_token":"gho_x","token_type":"bearer","scope":"repo,read:org,workflow"}"#])
            let token = try await flow().token(for: code())
            #expect(token == "gho_x")
            #expect(StubURLProtocol.lastRequest?.url?.absoluteString == "https://github.com/login/oauth/access_token")
            #expect(form(StubURLProtocol.bodies[0]) == [
                "client_id": "Ov23liOQVQHli5vrchlv",
                "device_code": "dev",
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            #expect(clock.sleeps == [.seconds(5)], "the first poll waits the interval")
        }

        /// A token that does not carry every scope asked for is refused with what it does carry,
        /// rather than saved as a connection that fails at its first private repository.
        @Test func aTokenMissingAScopeIsRefused() async throws {
            for (granted, words) in [("", "it carries no scope"), ("repo,read:org", "it carries repo,read:org")] {
                StubURLProtocol.reset()
                poll([#"{"access_token":"gho_x","token_type":"bearer","scope":"\#(granted)"}"#])
                await #expect(throws: GitHubDeviceFlow.Failure.scopes(granted: granted)) { try await flow().token(for: code()) }
                #expect(GitHubDeviceFlow.Failure.scopes(granted: granted).description.contains(words))
            }
            StubURLProtocol.reset()
            poll([#"{"access_token":"gho_x"}"#])
            await #expect(throws: GitHubDeviceFlow.Failure.scopes(granted: "")) { try await flow().token(for: code()) }
        }

        @Test func pendingPollsAgain() async throws {
            StubURLProtocol.reset()
            poll([#"{"error":"authorization_pending"}"#, #"{"error":"authorization_pending"}"#, #"{"access_token":"gho_y","scope":"repo,read:org,workflow"}"#])
            #expect(try await flow().token(for: code()) == "gho_y")
            #expect(clock.sleeps == [.seconds(5), .seconds(5), .seconds(5)])
        }

        @Test func slowDownAddsFiveSeconds() async throws {
            StubURLProtocol.reset()
            poll([#"{"error":"slow_down"}"#, #"{"error":"authorization_pending"}"#, #"{"error":"slow_down"}"#, #"{"access_token":"gho_z","scope":"repo,read:org,workflow"}"#])
            #expect(try await flow().token(for: code()) == "gho_z")
            #expect(clock.sleeps == [.seconds(5), .seconds(10), .seconds(10), .seconds(15)])
        }

        /// GitHub's own interval on a `slow_down` wins when it is longer than five seconds more.
        @Test func slowDownTakesGitHubsLongerInterval() async throws {
            StubURLProtocol.reset()
            poll([#"{"error":"slow_down","interval":20}"#, #"{"error":"slow_down","interval":6}"#, #"{"access_token":"gho_w","scope":"repo,read:org,workflow"}"#])
            #expect(try await flow().token(for: code()) == "gho_w")
            #expect(clock.sleeps == [.seconds(5), .seconds(20), .seconds(25)])
        }

        /// A poll the network failed is polled again at the next interval, not the end of it.
        @Test func aNetworkFailurePollsAgain() async throws {
            StubURLProtocol.reset()
            let count = Counter()
            StubURLProtocol.requestResponder = { _, _ in
                count.next() == 0 ? (-1, "") : (200, #"{"access_token":"gho_n","scope":"repo,read:org,workflow"}"#)
            }
            #expect(try await flow().token(for: code()) == "gho_n")
            #expect(clock.sleeps == [.seconds(5), .seconds(5)])
        }

        @Test func expiredTokenEndsIt() async throws {
            StubURLProtocol.reset()
            poll([#"{"error":"expired_token"}"#])
            await #expect(throws: GitHubDeviceFlow.Failure.expired) { try await flow().token(for: code()) }
        }

        @Test func accessDeniedEndsIt() async throws {
            StubURLProtocol.reset()
            poll([#"{"error":"access_denied"}"#])
            await #expect(throws: GitHubDeviceFlow.Failure.denied) { try await flow().token(for: code()) }
        }

        @Test func anyOtherErrorEndsItInGitHubsWords() async throws {
            StubURLProtocol.reset()
            poll([#"{"error":"unsupported_grant_type","error_description":"The grant type is not supported."}"#])
            await #expect(throws: GitHubDeviceFlow.Failure.github("The grant type is not supported.")) {
                try await flow().token(for: code())
            }
        }

        /// The bound is judged on the clock, not on a count of polls: a poll that itself takes the
        /// clock past `expires_in` is the last one.
        @Test func theBoundEndsItWithoutAnotherPoll() async throws {
            StubURLProtocol.reset()
            let clock = clock
            poll([#"{"error":"authorization_pending"}"#], onPoll: { _ in clock.advance(60) })
            await #expect(throws: GitHubDeviceFlow.Failure.expired) {
                try await flow().token(for: code(interval: 5, expiresIn: 100))
            }
            // Polls at 5, 70 (5 + 60 + 5); the next wait lands at 140, past 100, with no poll.
            #expect(StubURLProtocol.bodies.count == 2)
        }

        @Test func cancellingEndsIt() async throws {
            StubURLProtocol.reset()
            poll([#"{"error":"authorization_pending"}"#])
            let flow = GitHubDeviceFlow(session: StubURLProtocol.session(), sleep: { try await Task.sleep(for: .milliseconds(10 * $0.components.seconds)) })
            var code = code()
            code.issued = Date()
            let task = Task { [code] in try await flow.token(for: code) }
            try await Task.sleep(for: .milliseconds(120))
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        }

        @Test func loginNamesTheUser() async throws {
            StubURLProtocol.reset()
            // Answered by its own request and no other: a poll the test before cancelled can still
            // reach the stub after this one's, and `lastRequest` would then be that poll.
            StubURLProtocol.requestResponder = { request, _ in
                guard request.url?.absoluteString == "https://api.github.com/user",
                      request.value(forHTTPHeaderField: "Authorization") == "Bearer gho_x" else { return (404, #"{"message":"Not Found"}"#) }
                return (200, #"{"login":"samdu","id":1}"#)
            }
            #expect(try await flow().login(token: "gho_x") == "samdu")
        }

        @Test func loginRefusedSaysSo() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.requestResponder = { _, _ in (401, #"{"message":"Bad credentials"}"#) }
            await #expect(throws: GitHubDeviceFlow.Failure.github("Bad credentials")) { try await flow().login(token: "x") }
        }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { defer { n += 1 }; return n } }
}

@Suite struct ConnectionStoreTests {
    @Test func roundTripsThroughTheKeychain() throws {
        var store = KeychainConnectionStore()
        #if os(macOS)
        let keychain = try TemporaryKeychain()
        defer { keychain.delete() }
        store.keychainPath = keychain.path
        #endif
        defer { try? store.clearAll() }
        #expect(try store.load(.github) == nil)
        let connection = Connection(token: "gho_a", account: "samdu")
        try store.save(connection, for: .github)
        #if os(macOS)
        #expect(keychain.holdsItem(service: KeychainConnectionStore.service, account: "github"),
                "the store wrote outside the keychain it was pointed at")
        #endif
        #expect(try store.load(.github) == connection)
        try store.save(Connection(token: "gho_b", account: "samdu"), for: .github)
        #expect(try store.load(.github)?.token == "gho_b")
        try store.clear(.github)
        #expect(try store.load(.github) == nil)
    }

    @Test func clearAllClearsEveryService() throws {
        let store = InMemoryConnectionStore([.github: Connection(token: "t", account: "a")])
        try store.clearAll()
        for service in ConnectionService.allCases { #expect(try store.load(service) == nil) }
    }
}

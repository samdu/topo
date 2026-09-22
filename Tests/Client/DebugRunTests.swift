import TopoAuth
import TopoCore
import XCTest

@testable import Topo

/// The debug-only launch hooks. This bundle is itself a debug build, which is why it can see them.
final class DebugRunTests: XCTestCase {
    func testATokenInTheEnvironmentSignsTheAppIn() throws {
        let store = InMemoryTokenStore()
        let guest = InMemoryTokenStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(DebugRun.signIn(store: store, guestStore: guest,
                                      environment: ["TOPO_CLAUDE_SETUP_TOKEN": "  sk-ant-oat01-test  ",
                                                    "TOPO_CLAUDE_SETUP_TOKEN_DAYS": "2"],
                                      now: now))
        let tokens = try XCTUnwrap(try store.load())
        XCTAssertEqual(tokens.accessToken, "sk-ant-oat01-test")
        // A setup token cannot be exchanged, so nothing is kept to exchange it with.
        XCTAssertTrue(tokens.refreshToken.isEmpty)
        XCTAssertEqual(tokens.expiresAt, now.addingTimeInterval(2 * 86_400))
        XCTAssertFalse(tokens.isExpired(at: now))
        // A setup token is the long-lived kind, so the guest is handed the same one.
        XCTAssertEqual(try guest.load(), tokens)
    }

    /// The device run's evidence of the guest's authorization: its scope and the days its token
    /// has left, never a value.
    func testTheMintLineNamesTheScopeAndExpiryAndNeverAValue() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let minted = Tokens(accessToken: "sk-secret", refreshToken: "", expiresAt: now.addingTimeInterval(31_536_000),
                            scopes: ["user:inference"])
        let line = DebugRun.mintLine(minted, now: now)
        XCTAssertEqual(line, "userland: mint scope: user:inference, expires in 365 days")
        XCTAssertFalse(line.contains("sk-secret"))
        XCTAssertEqual(DebugRun.mintLine(nil), "userland: mint: none held, the guest runs on the ordinary access token")
    }

    /// The device run's evidence that the ordinary tokens are refreshable after sign-in: one refresh
    /// with the refresh token they hold, and the scope string it came back with, or its refusal.
    func testTheOrdinaryRefreshLineSaysWhatTheRefreshGranted() async throws {
        let ordinary = Tokens(accessToken: "sk-ordinary", refreshToken: "rt-first", expiresAt: .distantFuture,
                              scopes: ["user:profile", "user:inference"])
        func line(answer status: Int, _ json: String, holding tokens: Tokens?) async throws -> (String, InMemoryTokenStore) {
            RefreshStub.answer = (status, Data(json.utf8))
            let store = InMemoryTokenStore(tokens)
            let oauth = ClaudeOAuth(session: RefreshStub.session())
            return (await DebugRun.ordinaryRefreshLine(try store.load(), provider: StoredTokenProvider(store: store, oauth: oauth)), store)
        }

        let (intact, store) = try await line(answer: 200, #"{"access_token":"sk-new","refresh_token":"rt-next","expires_in":28800,"scope":"user:profile user:inference"}"#, holding: ordinary)
        XCTAssertEqual(intact, "userland: ordinary refresh scope: user:profile user:inference")
        XCTAssertEqual(try store.load()?.refreshToken, "rt-next", "the rotated refresh token was not written back")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(RefreshStub.lastBody)) as? [String: String])
        XCTAssertEqual(body["refresh_token"], "rt-first")
        XCTAssertEqual(body["scope"], "user:profile user:inference")

        let (refused, _) = try await line(answer: 400, #"{"error":"invalid_scope"}"#, holding: ordinary)
        XCTAssertEqual(refused, "userland: ordinary refresh failed: http(status: 400)")

        var seeded = ordinary
        seeded.refreshToken = ""
        let (unchecked, _) = try await line(answer: 200, "{}", holding: seeded)
        XCTAssertEqual(unchecked, "userland: ordinary refresh: not checked, no refresh token held (a seeded setup token)")
        let (signedOut, _) = try await line(answer: 200, "{}", holding: nil)
        XCTAssertEqual(signedOut, "userland: ordinary refresh: not checked, not signed in")
        for text in [intact, refused] {
            XCTAssertFalse(text.contains("sk-") || text.contains("rt-"), text)
        }
    }

    /// The launch's hand-over as the device run meets it with no long-lived token and the ordinary
    /// access token in its last minute: the diagnostic refresh and the fallback are one grant, and
    /// the guest is handed what that grant returned.
    func testTheLaunchSpendsOneRefreshGrantWhenTheGuestFallsBack() async throws {
        let scopes = ["user:profile", "user:inference"]
        func handOver(answer status: Int, _ json: String, guest: Tokens? = nil) async -> (environment: [String: String], lines: [String]) {
            RefreshStub.answer = (status, Data(json.utf8))
            RefreshStub.requests = 0
            let ordinary = InMemoryTokenStore(Tokens(accessToken: "sk-stale", refreshToken: "rt-first",
                                                     expiresAt: Date().addingTimeInterval(30), scopes: scopes))
            return await DebugRun.handOver(port: 4242, guestStore: InMemoryTokenStore(guest), ordinaryStore: ordinary,
                                           oauth: ClaudeOAuth(session: RefreshStub.session()))
        }
        let granted = #"{"access_token":"sk-fresh","refresh_token":"rt-next","expires_in":28800,"scope":"user:profile user:inference"}"#

        let fellBack = await handOver(answer: 200, granted)
        XCTAssertEqual(RefreshStub.requests, 1, "the launch spent more than one refresh grant")
        XCTAssertEqual(fellBack.environment["CLAUDE_CODE_OAUTH_TOKEN"], "sk-fresh")
        XCTAssertEqual(fellBack.lines, ["userland: proxy on http://127.0.0.1:4242, guest token: access token",
                                        "userland: mint: none held, the guest runs on the ordinary access token",
                                        "userland: ordinary refresh scope: user:profile user:inference"])

        let refused = await handOver(answer: 400, #"{"error":"invalid_grant"}"#)
        XCTAssertEqual(RefreshStub.requests, 1, "a refused refresh was asked for again")
        XCTAssertNil(refused.environment["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertEqual(refused.lines, ["userland: proxy on http://127.0.0.1:4242, no guest token: http(status: 400)",
                                       "userland: ordinary refresh failed: http(status: 400)"])

        let longLived = Tokens(accessToken: "sk-long-lived", refreshToken: "", expiresAt: Date().addingTimeInterval(86_400 * 300),
                               scopes: ["user:inference"])
        let withGuest = await handOver(answer: 200, granted, guest: longLived)
        XCTAssertEqual(RefreshStub.requests, 1)
        XCTAssertEqual(withGuest.environment["CLAUDE_CODE_OAUTH_TOKEN"], "sk-long-lived")
        XCTAssertEqual(withGuest.lines.first, "userland: proxy on http://127.0.0.1:4242, guest token: long-lived")
    }

    func testWithoutOneNothingIsTouched() throws {
        let store = InMemoryTokenStore()
        let guest = InMemoryTokenStore()
        XCTAssertFalse(DebugRun.signIn(store: store, guestStore: guest, environment: [:]))
        XCTAssertFalse(DebugRun.signIn(store: store, guestStore: guest, environment: ["TOPO_CLAUDE_SETUP_TOKEN": "   "]))
        XCTAssertNil(try store.load())
        XCTAssertNil(try guest.load())
    }

    func testOnlyAnAskedForTurnIsSent() {
        XCTAssertNil(DebugRun.words([:]))
        XCTAssertNil(DebugRun.words(["TOPO_DEBUG_SEND": " \n "]))
        XCTAssertEqual(DebugRun.words(["TOPO_DEBUG_SEND": " what did I forget "]), "what did I forget")
    }

    // MARK: Which reply is this run's

    private func turn(_ device: String, _ sequence: Int64, _ role: TurnRole, _ text: String,
                      parents: [TurnRef] = [], nonce: String = UUID().uuidString) -> Turn {
        Turn(ref: TurnRef(device: DeviceID(device), sequence: sequence), parents: parents, role: role,
             text: text, at: Date(timeIntervalSince1970: 1_800_000_000 + Double(sequence)), nonce: nonce)
    }

    func testAnOlderReplyIsNotTheAnswerToAPendingTurn() {
        let asked = turn("phone", 1, .person, "yesterday")
        let older = turn("phone", 2, .assistant, "an older answer", parents: [asked.ref])
        let pending = turn("phone", 3, .person, "today", parents: [older.ref], nonce: "this-run")
        XCTAssertEqual(DebugRun.answer(to: "this-run", in: [asked, older, pending]), .unanswered(pending))
        XCTAssertEqual(DebugRun.line(for: .unanswered(pending), nonce: "this-run", run: "R"),
                       "no reply to phone/3 in run R")
    }

    func testTheReplyIsTheOneToTheSubmittedTurnNotTheNewest() {
        let mine = turn("phone", 1, .person, "mine", nonce: "this-run")
        let reply = turn("phone", 2, .assistant, "to mine", parents: [mine.ref])
        let limb = turn("watch", 1, .person, "a limb's words", parents: [reply.ref])
        let later = turn("phone", 3, .assistant, "to the limb", parents: [limb.ref])
        XCTAssertEqual(DebugRun.answer(to: "this-run", in: [mine, reply, limb, later]), .answered(mine, reply: reply))
        XCTAssertEqual(DebugRun.line(for: .answered(mine, reply: reply), nonce: "this-run", run: "R"),
                       "reply to phone/1 in run R: to mine")
    }

    func testAReplyJoiningSeveralHeadsAnswersEachOfThem() {
        let other = turn("watch", 1, .person, "from the watch")
        let mine = turn("phone", 1, .person, "mine", nonce: "this-run")
        let joined = turn("phone", 2, .assistant, "to both", parents: [mine.ref, other.ref])
        XCTAssertEqual(DebugRun.answer(to: "this-run", in: [other, mine, joined]), .answered(mine, reply: joined))
    }

    func testATurnThatNeverReachedTheLogHasNoAnswer() {
        let asked = turn("phone", 1, .person, "someone else's", nonce: "another-run")
        let reply = turn("phone", 2, .assistant, "to them", parents: [asked.ref])
        XCTAssertEqual(DebugRun.answer(to: "this-run", in: [asked, reply]), .notInLog)
        // A nonce is never empty on a turn this run sent; an empty one names no turn at all.
        XCTAssertEqual(DebugRun.answer(to: "", in: [turn("phone", 3, .person, "old", nonce: "")]), .notInLog)
    }
}

/// The token endpoint for `testTheOrdinaryRefreshLineSaysWhatTheRefreshGranted`: one scripted
/// answer, and the body it was asked with.
final class RefreshStub: URLProtocol {
    nonisolated(unsafe) static var answer: (Int, Data) = (200, Data())
    nonisolated(unsafe) static var lastBody: Data?
    /// Every request since it was last set to zero, each one a grant spent.
    nonisolated(unsafe) static var requests = 0

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefreshStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return data
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.answer.0, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.answer.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

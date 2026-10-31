import TopoAuth
import TopoCore
import XCTest

@testable import Topo

/// The debug-only launch hooks. This bundle is itself a debug build, which is why it can see them.
final class DebugRunTests: XCTestCase {
    /// A developer's token in the launch environment marks the app signed in, as Claude Code's
    /// `oauth_token`, and is what every `claude` the app starts is handed; nothing in the cache
    /// holds the token.
    func testATokenInTheEnvironmentSignsTheAppIn() throws {
        let cache = LoginCache(defaults: UserDefaults(suiteName: "debug-run-\(UUID().uuidString)")!)
        let environment = ["TOPO_CLAUDE_SETUP_TOKEN": "  sk-ant-oat01-test  "]
        XCTAssertTrue(DebugRun.signIn(cache: cache, environment: environment))
        XCTAssertEqual(cache.status, ClaudeLoginStatus(loggedIn: true, authMethod: "oauth_token"))
        XCTAssertEqual(DebugRun.developerToken(environment), "sk-ant-oat01-test")
        XCTAssertTrue(DebugRun.accepts(environment)(ClaudeLoginStatus(loggedIn: true, authMethod: "oauth_token")))
        XCTAssertFalse(DebugRun.accepts([:])(ClaudeLoginStatus(loggedIn: true, authMethod: "oauth_token")))
        XCTAssertTrue(DebugRun.accepts([:])(ClaudeLoginStatus(loggedIn: true, authMethod: "claude.ai")))
        let data = try XCTUnwrap(cache.defaults.data(forKey: LoginCache.key))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("oat01"))
    }

    /// The userland run's line about its credential: the developer's token named, never shown.
    func testTheUserlandHandOverNamesTheCredentialAndNeverItsValue() {
        let handed = DebugRun.handOver(port: 4242, developer: ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-secret"])
        XCTAssertEqual(handed.environment, ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-secret"])
        XCTAssertEqual(handed.lines, ["userland: proxy on http://127.0.0.1:4242, credential: the developer's token"])
        XCTAssertEqual(DebugRun.handOver(port: 4242, developer: [:]).lines, ["userland: proxy on http://127.0.0.1:4242, credential: none"])
    }

    /// A tool result as the guest-turn run prints it for `simulator-run.sh --guest-turn`: the tool,
    /// ok or error, the text on one line, a credential redacted and a long result cut.
    func testAToolResultLineIsOneLineWithNoCredentialInIt() {
        XCTAssertEqual(DebugRun.toolResultLine(tool: "Bash", isError: false, text: "topo-42\n"),
                       "tool result: Bash: ok: topo-42")
        XCTAssertEqual(DebugRun.toolResultLine(tool: "Bash", isError: true, text: "No suitable shell found.\nTry again"),
                       #"tool result: Bash: error: No suitable shell found.\nTry again"#)
        let secret = "sk-ant-oat01-" + String(repeating: "x", count: 40)
        let leaked = DebugRun.toolResultLine(tool: "Bash", isError: false,
                                             text: "CLAUDE_CODE_OAUTH_TOKEN=\(secret)\nAuthorization: Bearer abc.def\nkey \(secret)")
        XCTAssertFalse(leaked.contains(secret), leaked)
        XCTAssertFalse(leaked.contains("abc.def"), leaked)
        XCTAssertFalse(leaked.contains("oat01"), leaked)
        let long = DebugRun.toolResultLine(tool: "Read", isError: false, text: String(repeating: "a", count: 1000))
        XCTAssertEqual(long, "tool result: Read: ok: " + String(repeating: "a", count: 300) + "…")
    }

    /// A connection's token printed by a tool — `topo github token`, a `gh auth status` — is
    /// redacted too: GitHub's prefixes and 1Password's service-account one.
    func testAConnectionTokenInAToolResultIsRedacted() {
        let github = "gho_" + String(repeating: "A1", count: 18)
        let pat = "github_pat_" + String(repeating: "b2", count: 20)
        let onePassword = "ops_eyJzaWduSW5BZGRyZXNzIjoibXkuMXBhc3N3b3JkLmNvbSJ9" + String(repeating: "Z", count: 30)
        let line = DebugRun.toolResultLine(tool: "Bash", isError: false,
                                           text: "\(github)\npassword=\(github)\n\(pat)\ntoken: \(onePassword)")
        XCTAssertFalse(line.contains(String(github.dropFirst(4))), line)
        XCTAssertFalse(line.contains(String(pat.dropFirst(11))), line)
        XCTAssertFalse(line.contains(String(onePassword.dropFirst(4))), line)
        XCTAssertTrue(line.contains("gho_[redacted]"), line)
    }

    func testWithoutOneNothingIsTouched() {
        let cache = LoginCache(defaults: UserDefaults(suiteName: "debug-run-\(UUID().uuidString)")!)
        XCTAssertFalse(DebugRun.signIn(cache: cache, environment: [:]))
        XCTAssertFalse(DebugRun.signIn(cache: cache, environment: ["TOPO_CLAUDE_SETUP_TOKEN": "   "]))
        XCTAssertNil(cache.status)
        XCTAssertNil(DebugRun.developerToken(["TOPO_CLAUDE_SETUP_TOKEN": "   "]))
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
                       "reply to phone/1 in run R from session none, process none: to mine")
        XCTAssertEqual(DebugRun.line(for: .answered(mine, reply: reply), nonce: "this-run", run: "R",
                                     by: (session: "S1", pid: 42)),
                       "reply to phone/1 in run R from session S1, process 42: to mine")
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

    /// The chat's debug report carries the facing `Mascot` hands the engine, as the word the
    /// engine reads, under `facing` in its JSON.
    func testTheChatReportSaysTheFacing() throws {
        for facing in MascotFacing.allCases {
            let raw = DebugRun.chatReport(spoken: nil, turns: [], error: nil, speaker: Speaker.Report(),
                                          voice: .ready, facing: facing)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any], raw)
            XCTAssertEqual(json["facing"] as? String, facing.rawValue, raw)
        }
    }
}

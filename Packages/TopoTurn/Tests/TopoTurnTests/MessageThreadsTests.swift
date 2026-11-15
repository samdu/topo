import XCTest

@testable import TopoTurn

/// The message threads setting: on unless it was turned off, and the variable's name one the
/// mind may rename only to one about threads, with no part that reaches a credential, a provider,
/// a URL or the resident's settings.
final class MessageThreadsTests: XCTestCase {
    func testTheOneReaderTakesAClaudeCodeNameAboutThreadsAndNothingThatReachesFurther() {
        XCTAssertEqual(MessageThreads.variable("CLAUDE_CODE_TETHER_LIVE"), "CLAUDE_CODE_TETHER_LIVE")
        XCTAssertEqual(MessageThreads.variable(" CLAUDE_CODE_MESSAGE_THREADS "), "CLAUDE_CODE_MESSAGE_THREADS")
        XCTAssertEqual(MessageThreads.variable("CLAUDE_CODE_TETHER"), "CLAUDE_CODE_TETHER")
        XCTAssertEqual(MessageThreads.variable("default"), MessageThreads.defaultVariable)
        let refused = [
            "", "CLAUDE_CODE_", "claude_code_tether_live", "CLAUDE_CODE__THREADS", "CLAUDE_CODE_THREADS_", "CLAUDE_TETHER", "TETHER_LIVE",
            "CLAUDE_CODE_THREADS=1", "CLAUDE_CODE_THREADS X", "CLAUDE_CODE_THREADSÉ",
            "CLAUDE_CODE_THREADS_" + String(repeating: "A", count: MessageThreads.longest),
            // Real names at the pin a 1 would change: none is about threads.
            "CLAUDE_CODE_AUTO_MODE_COMPACT_THREAD_RULE", "CLAUDE_CODE_AUTO_MODE_THREAD_ASK_HELD", "CLAUDE_CODE_HOOKS_SAME_THREAD",
            "CLAUDE_CODE_THREAD", "CLAUDE_CODE_SIMPLE", "CLAUDE_CODE_SHELL_PREFIX", "CLAUDE_CODE_HOST_CREDS_FILE", "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB",
            "CLAUDE_CODE_AUTO_COMPACT_WINDOW", "CLAUDE_CODE_EMIT_STARTUP_TIMING", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
            "ANTHROPIC_BASE_URL", "HOME", "IS_SANDBOX", "TOPO_LAUNCH",
        ]
        for word in refused {
            XCTAssertNil(MessageThreads.variable(word), word)
            XCTAssertNotEqual(MessageThreads.refusal(word), "no name", word)
        }
        // Every part that reaches further refuses a name about threads that carries it, wherever
        // it sits. Named here, not read from the list, so a part dropped from it fails.
        let reaching = ["TOKEN", "KEY", "SECRET", "AUTH", "PASSWORD", "CREDENTIAL", "USE", "SKIP", "URL", "PROXY", "PROVIDER",
                        "DANGEROUS", "BYPASS", "SANDBOX", "SIMPLE", "SHELL", "REMOTE", "MANAGED", "SETTINGS", "ENV", "HOOK", "MODE", "WORKER"]
        for clean in reaching {
            for name in ["CLAUDE_CODE_THREADS_\(clean)_X", "CLAUDE_CODE_\(clean)_TETHER"] {
                XCTAssertNil(MessageThreads.variable(name), name)
            }
        }
    }

    func testItIsOnUntilTurnedOffAndAKeptNameNoReaderTakesReadsAsTheDefault() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MessageThreadsTests-\(UUID().uuidString)"))
        XCTAssertEqual(MessageThreads.Setting(defaults: defaults), .standard)
        XCTAssertEqual(MessageThreads.Setting(defaults: defaults).launched, "CLAUDE_CODE_TETHER_LIVE")

        MessageThreads.Setting(on: false, variable: "CLAUDE_CODE_THREADS").keep(in: defaults)
        XCTAssertEqual(MessageThreads.Setting(defaults: defaults), MessageThreads.Setting(on: false, variable: "CLAUDE_CODE_THREADS"))
        XCTAssertNil(MessageThreads.Setting(defaults: defaults).launched)

        MessageThreads.Setting(on: true, variable: "CLAUDE_CODE_THREADS").keep(in: defaults)
        XCTAssertEqual(MessageThreads.Setting(defaults: defaults).launched, "CLAUDE_CODE_THREADS")

        defaults.set("CLAUDE_CODE_OAUTH_TOKEN", forKey: MessageThreads.variableKey)
        XCTAssertEqual(MessageThreads.Setting(defaults: defaults).launched, MessageThreads.defaultVariable)
        XCTAssertEqual(MessageThreads.Setting(on: true, variable: "HOME").variable, MessageThreads.defaultVariable)
    }
}

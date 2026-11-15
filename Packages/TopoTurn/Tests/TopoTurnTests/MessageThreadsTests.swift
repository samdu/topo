import XCTest

@testable import TopoTurn

/// The message threads setting: on unless it was turned off, and the variable's name one the
/// mind may rename only within a shape that cannot reach a credential, a provider or the launch's
/// own variables.
final class MessageThreadsTests: XCTestCase {
    func testTheOneReaderTakesAClaudeCodeNameAndNothingThatReachesFurther() {
        XCTAssertEqual(MessageThreads.variable("CLAUDE_CODE_TETHER_LIVE"), "CLAUDE_CODE_TETHER_LIVE")
        XCTAssertEqual(MessageThreads.variable(" CLAUDE_CODE_MESSAGE_THREADS "), "CLAUDE_CODE_MESSAGE_THREADS")
        XCTAssertEqual(MessageThreads.variable("default"), MessageThreads.defaultVariable)
        let refused = [
            "", "CLAUDE_CODE_", "claude_code_tether_live", "CLAUDE_CODE__X", "CLAUDE_CODE_X_", "CLAUDE_TETHER", "TETHER_LIVE",
            "ANTHROPIC_BASE_URL", "HOME", "IS_SANDBOX", "PATH", "TOPO_LAUNCH", "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE",
            "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_API_KEY_HELPER", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_SKIP_BEDROCK_AUTH",
            "CLAUDE_CODE_PROXY_RESOLVES_HOSTS", "CLAUDE_CODE_AUTO_COMPACT_WINDOW", "CLAUDE_CODE_EMIT_STARTUP_TIMING",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "CLAUDE_CODE_X=1", "CLAUDE_CODE_X Y", "CLAUDE_CODE_É",
            "CLAUDE_CODE_" + String(repeating: "A", count: MessageThreads.longest),
        ]
        for word in refused {
            XCTAssertNil(MessageThreads.variable(word), word)
            XCTAssertNotEqual(MessageThreads.refusal(word), "no name", word)
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

import Foundation
import TopoTools
import TopoUserland
import XCTest

/// The guest's `topo`, run in the booted guest under the rootfs' own bash and BusyBox `wget`,
/// against a tool service in this process: its arguments reach the tool whatever they hold, the
/// tool's status is the command's, and a service that is gone or refuses it is status 3 with a
/// sentence and never the token.
final class GuestToolScriptTests: XCTestCase {
    private var home: URL!
    private var point: String!
    private var service: ToolService?
    /// What the service logged, which a failure message carries.
    private let lines = Lines()

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func add(_ line: String) { lock.withLock { all.append(line) } }
        var text: String { lock.withLock { all.joined(separator: "; ") } }
    }

    override func setUp() async throws {
        _ = try SharedGuest.booted()
        home = FileManager.default.temporaryDirectory.appendingPathComponent("tools-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try GuestTools.install(home: home)
        point = "/opt/tools-\(UUID().uuidString.prefix(8))"
        try Guest.shared.mount(home, at: point)
    }

    override func tearDown() async throws {
        await service?.stop()
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    /// Echoes its arguments one to a line, each between brackets, and exits with the status the
    /// first names.
    private struct Echo: Tool {
        let name = "echo"
        let summary = "echoes"
        let usage = "topo echo <status> <arguments…>"
        func run(_ arguments: [String]) async -> ToolReply {
            ToolReply(status: Int32(arguments.first ?? "0") ?? 0,
                      text: arguments.dropFirst().map { "[\($0)]" }.joined(separator: "\n") + "\n")
        }
    }

    private func started() async throws -> [String: String] {
        let lines = lines
        let service = try ToolService(tools: [Echo()], log: { lines.add($0) })
        self.service = service
        let port = try await service.start()
        return ToolService.environment(port: port, token: await service.token)
    }

    private func topo(_ command: String, _ environment: [String: String]) async throws -> Guest.Exit {
        var env = Guest.environment
        env.merge(environment) { _, new in new }
        return try await Guest.shared.run("/bin/bash", ["-c", "\(point!)/\(GuestTools.scriptPath) \(command)"], environment: env)
    }

    func testTheScriptIsExecutableInTheGuest() async throws {
        let exit = try await Guest.shared.run("/bin/sh", ["-c", "[ -x \(point!)/\(GuestTools.scriptPath) ] && head -1 \(point!)/\(GuestTools.scriptPath)"])
        XCTAssertEqual(exit.output, "#!/bin/bash\n")
        let skill = try String(contentsOf: home.appendingPathComponent(GuestTools.skillPath), encoding: .utf8)
        XCTAssertTrue(skill.hasPrefix("---\nname: topo\ndescription: "))
    }

    /// Review focus 13: every argument arrives as it was given.
    func testArgumentsArriveAsTheyWereGivenAndTheStatusIsTheTools() async throws {
        let environment = try await started()
        let exit = try await topo(#"echo 0 "a b" "" 'ü $HOME' "it's" "$(printf 'x\ny')" '"q"'"#, environment)
        XCTAssertEqual(exit.status, 0, exit.errors + " service: " + lines.text)
        XCTAssertEqual(exit.output, "[a b]\n[]\n[ü $HOME]\n[it's]\n[x\ny]\n[\"q\"]\n")
        let failed = try await topo("echo 6 refused", environment)
        XCTAssertEqual(failed.status, 6)
        XCTAssertEqual(failed.output, "[refused]\n")
    }

    /// Codex on #189: a process's argv is readable by every process in the guest, so the token
    /// is never in one. Every command `topo` runs is put behind a wrapper that writes down its
    /// arguments before running the real one, and none of what was written holds the token.
    func testNoCommandTopoRunsIsGivenTheTokenAsAnArgument() async throws {
        let environment = try await started()
        let token = try XCTUnwrap(environment[ToolService.tokenVariable])
        let script = "\(point!)/\(GuestTools.scriptPath)"
        let commands = try String(contentsOf: home.appendingPathComponent(GuestTools.scriptPath), encoding: .utf8)
        let named = ["wget", "base64", "tr", "mktemp", "rm", "tail", "cat", "head", "sed"]
            .filter { commands.contains($0 + " ") || commands.contains("$(" + $0) }
        XCTAssertTrue(named.contains("wget"))
        let wrap = """
        wrapped=$(mktemp -d) || exit 90
        for name in \(named.joined(separator: " ")); do
            real=$(command -v "$name") || continue
            case "$real" in /*) ;; *) continue ;; esac
            printf '#!/bin/sh\\nprintf "%%s\\\\n" "%s $*" >> %s/argv\\nexec %s "$@"\\n' "$name" "$wrapped" "$real" > "$wrapped/$name"
            chmod +x "$wrapped/$name"
        done
        PATH="$wrapped:$PATH" \(script) echo 0 a; echo "status $?"
        cat "$wrapped/argv"
        """
        var env = Guest.environment
        env.merge(environment) { _, new in new }
        let exit = try await Guest.shared.run("/bin/bash", ["-c", wrap], environment: env)
        XCTAssertTrue(exit.output.hasPrefix("[a]\nstatus 0\n"), exit.output + exit.errors + " service: " + lines.text)
        XCTAssertTrue(exit.output.contains("\nwget "), "the wrapper never ran: " + exit.output)
        XCTAssertFalse(exit.output.contains(token), "a command was given the token: " + exit.output)
    }

    func testNoArgumentsIsHelp() async throws {
        let environment = try await started()
        let exit = try await topo("", environment)
        XCTAssertEqual(exit.status, 0, exit.errors)
        XCTAssertTrue(exit.output.contains("  echo  echoes"), exit.output)
    }

    /// Review focus 3: a refusal and a service that is gone are status 3, and neither says the token.
    func testARefusedCallAndAGoneServiceAreStatusThreeAndNeverShowTheToken() async throws {
        var environment = try await started()
        let token = try XCTUnwrap(environment[ToolService.tokenVariable])
        environment[ToolService.tokenVariable] = "not-the-token"
        let refused = try await topo("echo 0 x", environment)
        XCTAssertEqual(refused.status, 3)
        XCTAssertEqual(refused.output, "")
        XCTAssertTrue(refused.errors.contains("refused"), refused.errors)

        environment[ToolService.tokenVariable] = token
        await service?.stop()
        let gone = try await topo("echo 0 x", environment)
        XCTAssertEqual(gone.status, 3)
        XCTAssertTrue(gone.errors.contains("did not answer"), gone.errors)
        for exit in [refused, gone] {
            XCTAssertFalse((exit.output + exit.errors).contains(token))
        }

        let missing = try await topo("echo 0 x", [:])
        XCTAssertEqual(missing.status, 3)
        XCTAssertTrue(missing.errors.contains("not in this environment"), missing.errors)
    }
}

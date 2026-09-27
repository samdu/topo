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

    // MARK: The GitHub shims

    /// `topo github`, as the app's `GitHubTool` answers it: connected with `token`, or not.
    private struct GitHub: Tool {
        let token: String?
        let name = "github"
        let summary = "github"
        let usage = "topo github [token|credential]"
        func run(_ arguments: [String]) async -> ToolReply {
            guard let token else { return .failed("GitHub is not connected\n") }
            switch arguments.first {
            case "token": return .ok(token + "\n")
            case "credential": return .ok("username=samdu\npassword=\(token)\n")
            default: return .ok("connected as samdu\n")
            }
        }
    }

    private func startedGitHub(token: String?) async throws -> [String: String] {
        let lines = lines
        let service = try ToolService(tools: [GitHub(token: token)], log: { lines.add($0) })
        self.service = service
        let port = try await service.start()
        return ToolService.environment(port: port, token: await service.token)
    }

    /// Runs `command` in bash with the home's `.topo/bin` first on the path, as the app's links
    /// put `topo`, `git-credential-topo` and `gh` first in `/usr/local/bin`.
    private func shell(_ command: String, _ environment: [String: String]) async throws -> Guest.Exit {
        var env = Guest.environment
        env.merge(environment) { _, new in new }
        env["PATH"] = "\(point!)/.topo/bin:" + (env["PATH"] ?? "")
        return try await Guest.shared.run("/bin/bash", ["-c", command], environment: env)
    }

    func testTheShimsAreWrittenExecutable() async throws {
        for path in [GuestTools.credentialHelperPath, GuestTools.ghPath] {
            let exit = try await Guest.shared.run("/bin/sh", ["-c", "[ -x \(point!)/\(path) ] && head -1 \(point!)/\(path)"])
            XCTAssertEqual(exit.output, "#!/bin/bash\n", path)
        }
        XCTAssertEqual(GuestTools.links.map(\.command), [GuestTools.command, GuestTools.credentialHelperCommand, GuestTools.ghCommand])
        // An empty helper first, which clears every helper configured before it, then this one.
        XCTAssertEqual(GuestTools.environment["GIT_CONFIG_COUNT"], "2")
        XCTAssertEqual(GuestTools.environment["GIT_CONFIG_KEY_0"], "credential.https://github.com.helper")
        XCTAssertEqual(GuestTools.environment["GIT_CONFIG_VALUE_0"], "")
        XCTAssertEqual(GuestTools.environment["GIT_CONFIG_KEY_1"], "credential.https://github.com.helper")
        XCTAssertEqual(GuestTools.environment["GIT_CONFIG_VALUE_1"], "topo")
        XCTAssertFalse(GuestTools.environment.keys.contains { $0.hasPrefix("GH_") || $0.hasPrefix("GITHUB_") },
                       "no GitHub token rides the environment the resident is given")
    }

    /// The helper answers github.com over https with what `topo github credential` says, and
    /// nothing for any other host, for another action, or when GitHub is not connected; the token
    /// is in none of the service's log lines.
    func testTheCredentialHelperAnswersGitHubOnly() async throws {
        let token = "gho_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let environment = try await startedGitHub(token: token)
        let helper = "git-credential-topo"
        let github = try await shell("printf 'protocol=https\\nhost=github.com\\n\\n' | \(helper) get", environment)
        XCTAssertEqual(github.status, 0, github.errors + " service: " + lines.text)
        XCTAssertEqual(github.output, "username=samdu\npassword=\(token)\n")
        let other = try await shell("printf 'protocol=https\\nhost=gitlab.com\\n\\n' | \(helper) get", environment)
        XCTAssertEqual(other.status, 0)
        XCTAssertEqual(other.output, "")
        let plain = try await shell("printf 'protocol=http\\nhost=github.com\\n\\n' | \(helper) get", environment)
        XCTAssertEqual(plain.output, "")
        let store = try await shell("printf 'protocol=https\\nhost=github.com\\npassword=x\\n\\n' | \(helper) store", environment)
        XCTAssertEqual(store.status, 0)
        XCTAssertEqual(store.output, "")
        XCTAssertFalse(lines.text.contains(token), "a log line carried the token: " + lines.text)
    }

    func testTheCredentialHelperSaysWhereToConnectAndAnswersNothing() async throws {
        let environment = try await startedGitHub(token: nil)
        let exit = try await shell("printf 'protocol=https\\nhost=github.com\\n\\n' | git-credential-topo get", environment)
        XCTAssertEqual(exit.status, 0)
        XCTAssertEqual(exit.output, "", "git gets no username or password")
        XCTAssertTrue(exit.errors.contains("GitHub is not connected"), exit.errors)
        XCTAssertTrue(exit.errors.contains("status 1"), exit.errors)
    }

    /// An app that does not answer is said as that, not as GitHub not being connected.
    func testTheShimsSayTheAppDidNotAnswer() async throws {
        let environment = try await startedGitHub(token: "gho_x")
        await service?.stop()
        let helper = try await shell("printf 'protocol=https\\nhost=github.com\\n\\n' | git-credential-topo get", environment)
        XCTAssertEqual(helper.output, "")
        XCTAssertTrue(helper.errors.contains("did not answer"), helper.errors)
        XCTAssertTrue(helper.errors.contains("status 3"), helper.errors)
        XCTAssertFalse(helper.errors.contains("not connected"), helper.errors)
    }

    /// What a tool answers never lands in a file: the request goes through a FIFO and the answer
    /// comes back on wget's standard output, so neither a finished `topo` nor one killed mid-call
    /// leaves GitHub's token, or the service's, in a file on the guest's disk.
    func testNoAnswerIsEverWrittenToAFile() async throws {
        let token = "gho_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let environment = try await startedGitHub(token: token)
        let exit = try await shell("""
        topo github token > /dev/null; echo "status $?"
        for delay in 0 0.01 0.05 0.1 0.2; do
            topo github token > /dev/null & pid=$!
            sleep $delay; kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null
        done
        find /tmp /root -type f -exec grep -l -e \(token) -e "$TOPO_TOOLS_TOKEN" {} + 2>/dev/null; true
        """, environment)
        XCTAssertEqual(exit.output, "status 0\n", "the token is in a file: " + exit.output + exit.errors)
    }

    /// git with the environment the resident is given fills github.com's credential from the app,
    /// and hands it to no helper the home configured: a `credential.helper store` in `.gitconfig`
    /// writes no `.git-credentials` on approve.
    func testGitAsksTheAppAloneAndStoresNothing() async throws {
        let present = try await Guest.shared.run("/bin/sh", ["-c", "command -v git"])
        try XCTSkipIf(present.status != 0, "this rootfs has no git")
        let token = "gho_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var environment = try await startedGitHub(token: token)
        environment.merge(GuestTools.environment) { _, new in new }
        let exit = try await shell("""
        export HOME="$(mktemp -d)"
        git config --global credential.helper store
        answer="$(printf 'protocol=https\\nhost=github.com\\n\\n' | git credential fill)" || exit 9
        printf '%s\\n\\n' "$answer" | git credential approve
        printf '%s\\n' "$answer"
        [ -e "$HOME/.git-credentials" ] && echo stored
        rm -rf "$HOME"
        """, environment)
        XCTAssertEqual(exit.status, 0, exit.errors)
        XCTAssertTrue(exit.output.contains("password=\(token)\n"), exit.output + exit.errors)
        XCTAssertFalse(exit.output.contains("stored"), "a configured store helper was handed the token")
    }

    func testTheGhWrapperHandsTheTokenToGhAlone() async throws {
        let present = try await Guest.shared.run("/bin/sh", ["-c", "[ -e /usr/bin/gh ]"])
        try XCTSkipIf(present.status == 0, "this rootfs has a real gh; the stand-in would replace it")
        let fake = try await Guest.shared.run("/bin/sh", ["-c", "printf '#!/bin/sh\\necho \"token=${GH_TOKEN:-none} args=$*\"\\n' > /usr/bin/gh && chmod +x /usr/bin/gh"])
        XCTAssertEqual(fake.status, 0, fake.errors)
        let token = "gho_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let environment = try await startedGitHub(token: token)
        let wrapped = try await shell("gh api user; echo \"after=${GH_TOKEN:-unset}\"", environment)
        XCTAssertEqual(wrapped.output, "token=\(token) args=api user\nafter=unset\n", wrapped.errors)
        let own = try await shell("GH_TOKEN=mine gh auth status", environment)
        XCTAssertEqual(own.output, "token=mine args=auth status\n")

        await service?.stop()
        let none = try await startedGitHub(token: nil)
        let unconnected = try await shell("gh api user", none)
        XCTAssertEqual(unconnected.output, "token=none args=api user\n")
        XCTAssertTrue(unconnected.errors.contains("not connected"), unconnected.errors)
        _ = try await Guest.shared.run("/bin/rm", ["-f", "/usr/bin/gh"])
    }

    func testTheGhWrapperWithNoGhSaysHowToInstallIt() async throws {
        let present = try await Guest.shared.run("/bin/sh", ["-c", "[ -e /usr/bin/gh ]"])
        try XCTSkipIf(present.status == 0, "this rootfs has gh")
        let exit = try await shell("gh api user", try await startedGitHub(token: "gho_x"))
        XCTAssertEqual(exit.status, 127)
        XCTAssertTrue(exit.errors.contains("apk add github-cli"), exit.errors)
    }
}

import Foundation
import TopoUserland
import XCTest

/// `OnePasswordRun` in the booted guest, with a stand-in for `op` that behaves as the real one does
/// under iSH: it leaves a daemon behind in a session of its own, holding the token in its
/// environment, its pid written under `TMPDIR` after `op` has returned (`daemon(_:)`). Nothing of the run outlives it — not the daemon, not a run that
/// was cancelled — and the token is in the stand-in's environment and in no process's arguments.
final class OnePasswordRunTests: XCTestCase {
    private let token = "ops_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")

    override func setUp() async throws {
        _ = try SharedGuest.booted()
    }

    private func sh(_ command: String) async throws -> Guest.Exit {
        try await Guest.shared.run("/bin/sh", ["-c", command])
    }

    /// Writes an executable stand-in at a path of its own and answers the path.
    private func standIn(_ body: String) async throws -> String {
        let path = "/tmp/op-\(UUID().uuidString.prefix(8))"
        let made = try await sh("printf '%s\\n' '#!/bin/sh' \(shellQuoted(body)) > \(path) && chmod +x \(path)")
        XCTAssertEqual(made.status, 0, made.errors)
        return path
    }

    private func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The stand-in's daemon, as `op daemon` starts: a launcher in a session of its own, reparented
    /// to init, whose child is the daemon; the daemon has a child of its own and writes its pid
    /// under `TMPDIR` a second after `op` has returned, into a file that is there, empty, before.
    /// Every pid is written to `/tmp/<marker>-*` for `survivors` to find.
    /// With `late`, the launcher waits a second before it makes the daemon's directory, and `op`
    /// does not wait for the daemon.
    private func daemon(_ marker: String, late: Bool = false) -> String {
        """
        setsid sh -c 'echo $$ > /tmp/\(marker)-launcher; \(late ? "sleep 1; " : "")\\
        p="$TMPDIR/com.agilebits.op.0"; mkdir -p "$p"; : > "$p/op-daemon.pid"; \\
        sh -c "sleep 300 & echo \\$! > /tmp/\(marker)-child; (sleep 1; echo \\$\\$ > $p/op-daemon.pid) & \\
        echo \\$\\$ > /tmp/\(marker)-daemon; exec sleep 300" & exec sleep 300' \\
        </dev/null >/dev/null 2>&1 & \\
        while [ ! -s /tmp/\(marker)-\(late ? "launcher" : "daemon") ] || [ ! -s /tmp/\(marker)-\(late ? "launcher" : "child") ]; do sleep 0.1; done
        """
    }

    /// Processes still running whose environment was handed the token: a daemon holds the token
    /// in its `OP_SERVICE_ACCOUNT_TOKEN`, so it is found by what the stand-in wrote for it.
    private func survivors(_ marker: String) async throws -> String {
        try await sh("for f in /tmp/\(marker)-*; do [ -e \"$f\" ] || continue; p=$(cat \"$f\"); [ -d /proc/$p ] && echo $p; done; true").output
    }

    func testTheTokenIsInOpsEnvironmentAndNoArgumentAndTheDaemonGoesWithTheCall() async throws {
        let marker = "daemon-\(UUID().uuidString.prefix(8))"
        // The stand-in starts a daemon the way op does — a background child that outlives it,
        // reparented to init — records its pid, and reports what it was given.
        let op = try await standIn("""
        \(daemon(marker)); \
        for c in /proc/[0-9]*/cmdline; do tr '\\000' ' ' < $c 2>/dev/null; echo; done | grep -c 'ops_[0-9A-F]' > /tmp/\(marker).argv; \
        echo "token=$([ "$OP_SERVICE_ACCOUNT_TOKEN" = "\(token)" ] && echo given) cache=$OP_CACHE config=$([ -d "$OP_CONFIG_DIR" ] && [ "$TMPDIR" = "$OP_CONFIG_DIR" ] && echo made) args=$*"; \
        echo "$OP_CONFIG_DIR" > /tmp/\(marker).config; exit 3
        """)
        let clock = ContinuousClock.now
        let exit = try await OnePasswordRun.run(["vault", "list", "--format", "json"], token: token, command: op)
        XCTAssertLessThan(ContinuousClock.now - clock, .seconds(20), "the call waited on its daemon")
        XCTAssertEqual(exit.status, 3, exit.errors)
        XCTAssertEqual(exit.output, "token=given cache=false config=made args=vault list --format json\n")
        let argv = try await sh("cat /tmp/\(marker).argv").output
        XCTAssertEqual(argv, "0\n", "a process's arguments held the token")
        let config = try await sh("d=$(cat /tmp/\(marker).config); [ -e \"$d\" ] && echo left || echo gone").output
        XCTAssertEqual(config, "gone\n", "the call's config directory outlived it")
        let left = try await survivors(marker)
        XCTAssertEqual(left, "", "op's daemon outlived the call: \(left)")
        _ = try await sh("rm -f /tmp/\(marker)* \(op)")
    }

    /// A run cancelled while `op` is still working — the daemon's launcher forked, the daemon not
    /// yet started — ends `op`, and the daemon and its child once they start, not only its answer,
    /// and removes its config directory.
    func testACancelledRunEndsOpAndItsDaemon() async throws {
        let marker = "cancel-\(UUID().uuidString.prefix(8))"
        let op = try await standIn("""
        \(daemon(marker, late: true)); echo "$OP_CONFIG_DIR" > /tmp/\(marker).config; \
        echo $$ > /tmp/\(marker)-op; sleep 300
        """)
        let token = token
        let run = Task { try await OnePasswordRun.run(["read", "op://a/b/c"], token: token, command: op) }
        var started = false
        for _ in 0..<100 {
            if try await sh("[ -s /tmp/\(marker)-op ] && [ -s /tmp/\(marker)-launcher ]").status == 0 { started = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(started, "the stand-in never started")
        let clock = ContinuousClock.now
        run.cancel()
        let ended = try await run.value
        XCTAssertLessThan(ContinuousClock.now - clock, .seconds(20), "a cancelled run went on until its bound")
        XCTAssertNotEqual(ended.status, 0)
        // The daemon starts a second after its launcher, after the cancel; the cancel has to end it then.
        var daemonStarted = false
        for _ in 0..<100 {
            if try await sh("[ -s /tmp/\(marker)-daemon ]").status == 0 { daemonStarted = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(daemonStarted, "the stand-in's daemon never started")
        var left = "unchecked"
        for _ in 0..<80 {
            left = try await survivors(marker)
            if left.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(left, "", "a cancelled run left op or its daemon running: \(left)")
        let config = try await sh("d=$(cat /tmp/\(marker).config); [ -e \"$d\" ] && echo left || echo gone").output
        XCTAssertEqual(config, "gone\n", "a cancelled run left its config directory")
        _ = try await sh("rm -f /tmp/\(marker)* \(op)")
    }

    /// A run cancelled before it starts runs nothing in the guest.
    func testARunCancelledBeforeItStartsRunsNoOp() async throws {
        let marker = "early-\(UUID().uuidString.prefix(8))"
        let op = try await standIn("echo $$ > /tmp/\(marker)-op")
        let token = token
        let run = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await OnePasswordRun.run(["vault", "list"], token: token, command: op)
        }
        do {
            _ = try await run.value
            XCTFail("a cancelled run answered")
        } catch is CancellationError {}
        let ran = try await sh("[ -e /tmp/\(marker)-op ] && echo ran || echo not").output
        XCTAssertEqual(ran, "not\n")
        _ = try await sh("rm -f /tmp/\(marker)* \(op)")
    }

    /// A cancel that lands before the script has written its group file leaves its mark, which the
    /// script reads once it has: it runs nothing and leaves nothing.
    func testACancelMarkLeftBeforeTheGroupFileStopsTheScript() async throws {
        let marker = "mark-\(UUID().uuidString.prefix(8))"
        let op = try await standIn("echo $$ > /tmp/\(marker)-op")
        let group = "/tmp/\(marker).group"
        _ = try await sh(": > \(group).cancelled")
        var environment = Guest.environment
        environment["TOPO_OP_GROUP"] = group
        let exit = try await Guest.shared.run("/bin/sh", ["-c", OnePasswordRun.script(command: op), "op", "vault", "list"],
                                              environment: environment)
        XCTAssertEqual(exit.status, 130, exit.errors)
        let left = try await sh("ls -d /tmp/\(marker)* 2>/dev/null; true").output
        XCTAssertEqual(left, "", "the stand-in ran or the call's files stayed: \(left)")
        _ = try await sh("rm -f \(op)")
    }

    /// A daemon whose launcher makes its directory only after `op` has returned, and writes its pid
    /// a second after that, is still ended with the call, and its directory does not come back.
    func testADaemonStartedAfterOpReturnedGoesWithTheCall() async throws {
        let marker = "after-\(UUID().uuidString.prefix(8))"
        let op = try await standIn("""
        \(daemon(marker, late: true)); echo "$OP_CONFIG_DIR" > /tmp/\(marker).config; exit 0
        """)
        let exit = try await OnePasswordRun.run(["vault", "list"], token: token, command: op)
        XCTAssertEqual(exit.status, 0, exit.errors)
        let left = try await survivors(marker)
        XCTAssertEqual(left, "", "a daemon started after op returned outlived the call: \(left)")
        try await Task.sleep(for: .seconds(2))
        let config = try await sh("d=$(cat /tmp/\(marker).config); [ -e \"$d\" ] && echo left || echo gone").output
        XCTAssertEqual(config, "gone\n", "the call's directory came back")
        _ = try await sh("rm -f /tmp/\(marker)* \(op)")
    }

    /// A shell SIGKILLed by another guest process before its own end: the app ends what it left —
    /// `op` and the daemon — and removes the call's files, and the call answers well inside the
    /// watcher's bound, which no longer holds its output.
    func testAShellKilledFromOutsideLeavesNothing() async throws {
        let marker = "killed-\(UUID().uuidString.prefix(8))"
        let op = try await standIn("""
        \(daemon(marker)); echo "$OP_CONFIG_DIR" > /tmp/\(marker).config; echo $$ > /tmp/\(marker)-op; \
        kill -KILL $PPID; exec sleep 300
        """)
        let clock = ContinuousClock.now
        let exit = try await OnePasswordRun.run(["vault", "list"], token: token, command: op)
        XCTAssertLessThan(ContinuousClock.now - clock, .seconds(20), "the call waited on what the shell left")
        XCTAssertEqual(exit.status, 137, exit.errors)
        let left = try await survivors(marker)
        XCTAssertEqual(left, "", "a killed shell left op or its daemon running: \(left)")
        let files = try await sh("d=$(cat /tmp/\(marker).config); ls -d \"$d\" \"${d%.d}\" \"${d%.d}.cancelled\" 2>/dev/null; true").output
        XCTAssertEqual(files, "", "a killed shell left the call's files: \(files)")
        _ = try await sh("rm -f /tmp/\(marker)* \(op)")
    }

    /// A daemon that writes its pid only after the 5 s the call waits for it is found by its
    /// arguments and ended with the call. The stand-in runs itself as `<command> daemon`, as `op`
    /// runs `op daemon`, in a session of its own, and stays that process — no `exec`, no subshell
    /// of its own that would carry the same arguments — writing its pid itself 30 s late, long
    /// after the call's 5 s poll however slow the guest, so only the sweep by name can end it.
    func testADaemonWhosePidComesAfterTheWaitIsFoundByName() async throws {
        let marker = "named-\(UUID().uuidString.prefix(8))"
        let op = try await standIn("""
        if [ "$1" = daemon ]; then \
        p="$TMPDIR/com.agilebits.op.0"; mkdir -p "$p"; : > "$p/op-daemon.pid"; \
        sh -c "sleep 300 & echo \\$! > /tmp/\(marker)-child; exec sleep 300" </dev/null >/dev/null 2>&1 & \
        echo $$ > /tmp/\(marker)-daemon; i=0; \
        while :; do sleep 1; i=$((i + 1)); [ $i = 30 ] && echo $$ > "$p/op-daemon.pid"; done; fi; \
        setsid "$0" daemon </dev/null >/dev/null 2>&1 & \
        while [ ! -s /tmp/\(marker)-daemon ] || [ ! -s /tmp/\(marker)-child ]; do sleep 0.1; done; exit 0
        """)
        let clock = ContinuousClock.now
        let exit = try await OnePasswordRun.run(["vault", "list"], token: token, command: op)
        XCTAssertLessThan(ContinuousClock.now - clock, .seconds(20), "the call waited on its daemon")
        XCTAssertEqual(exit.status, 0, exit.errors)
        let left = try await survivors(marker)
        XCTAssertEqual(left, "", "a daemon whose pid came late outlived the call: \(left)")
        _ = try await sh("rm -f /tmp/\(marker)* \(op)")
    }

    /// A wait that throws while the shell is still starting, before it has written its group file:
    /// the shell stops at the file and `op` never runs with the token. The guest here throws at
    /// once and starts the real shell a second later.
    func testAWaitThatThrowsBeforeTheGroupFileRunsNoOp() async throws {
        let marker = "early-\(UUID().uuidString.prefix(8))"
        let op = try await standIn("echo ran > /tmp/\(marker)-op; exit 0")
        let guest = LateGuest()
        do {
            _ = try await OnePasswordRun.run(["vault", "list"], token: token, command: op, guest: guest)
            XCTFail("a failed wait was answered")
        } catch is LateGuest.WaitFailed {}
        let shell = try await guest.late()
        XCTAssertEqual(shell.status, 130, "the shell went on past its group file: \(shell)")
        let ran = try await sh("[ -e /tmp/\(marker)-op ] && echo ran || echo not").output
        XCTAssertEqual(ran, "not\n", "op ran after its wait threw")
        _ = try await sh("rm -f /tmp/\(marker)* \(op)")
    }
}

/// The real guest, except that its first run answers a failed wait at once and starts the program
/// a second later, as a shell still starting when the wait failed.
private final class LateGuest: GuestRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var first = true
    private var started: Task<Guest.Exit, Error>?
    struct WaitFailed: Error {}

    func run(_ path: String, _ arguments: [String], environment: [String: String]) async throws -> Guest.Exit {
        let isFirst = lock.withLock { () -> Bool in defer { first = false }; return first }
        guard isFirst else { return try await Guest.shared.run(path, arguments, environment: environment) }
        lock.withLock {
            started = Task {
                try await Task.sleep(for: .seconds(1))
                return try await Guest.shared.run(path, arguments, environment: environment)
            }
        }
        throw WaitFailed()
    }

    /// What the program started late answered.
    func late() async throws -> Guest.Exit {
        try await XCTUnwrap(lock.withLock { started }).value
    }
}

/// A guest whose first run throws after the program has started, as a failed wait does, and whose
/// runs after it answer; every run recorded.
private final class ThrowingGuest: GuestRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var runs: [(arguments: [String], environment: [String: String])] = []
    struct WaitFailed: Error {}

    func run(_ path: String, _ arguments: [String], environment: [String: String]) async throws -> Guest.Exit {
        let first = lock.withLock { () -> Bool in
            runs.append((arguments, environment))
            return runs.count == 1
        }
        if first { throw WaitFailed() }
        return Guest.Exit(status: 0, output: "", errors: "")
    }
}

final class OnePasswordRunCleanupTests: XCTestCase {
    /// A run whose wait throws still ends what it left: the cancel runs for its group file before
    /// the error is thrown on, since the shell may still be running.
    func testAWaitThatThrowsStillEndsWhatTheRunLeft() async throws {
        let guest = ThrowingGuest()
        do {
            _ = try await OnePasswordRun.run(["vault", "list"], token: "ops_x", command: "/opt/op-cli/op", guest: guest)
            XCTFail("a failed wait was answered")
        } catch is ThrowingGuest.WaitFailed {}
        let runs = guest.runs
        XCTAssertEqual(runs.count, 2, "no ending ran after the failed wait")
        let group = try XCTUnwrap(runs.first?.environment["TOPO_OP_GROUP"])
        let ending = try XCTUnwrap(runs.last?.arguments)
        XCTAssertEqual(Array(ending.dropFirst(2)), ["cancel", group, "/opt/op-cli/op"])
        XCTAssertEqual(ending.first, "-c")
        XCTAssertNil(runs.last?.environment["OP_SERVICE_ACCOUNT_TOKEN"], "the ending was handed the token")
    }
}

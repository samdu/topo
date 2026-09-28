import XCTest
import TopoUserland

/// The kernel booted on Alpine's minirootfs with bash laid in, running programs as init's children.
final class GuestTests: XCTestCase {
    func testEchoRunsInTheGuest() async throws {
        _ = try SharedGuest.booted()
        let exit = try await Guest.shared.run("/bin/echo", ["hello from the guest"])
        XCTAssertEqual(exit.status, 0)
        XCTAssertEqual(exit.output, "hello from the guest\n")
        XCTAssertEqual(exit.errors, "")
    }

    func testTheExitStatusAndStderrComeBack() async throws {
        _ = try SharedGuest.booted()
        let exit = try await Guest.shared.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        XCTAssertEqual(exit.status, 3)
        XCTAssertEqual(exit.output, "out\n")
        XCTAssertEqual(exit.errors, "err\n")
    }

    /// The guest is written the phone's name servers as a file the fakefs knows, over whatever
    /// the file held — the minirootfs's none, a stale one, the mind's own — and the public
    /// fallback when the phone lists none.
    func testTheGuestsResolverIsThePhonesAndReplacesWhatWasThere() async throws {
        _ = try SharedGuest.booted()
        _ = try await Guest.shared.run("/bin/rm", ["-f", "/etc/resolv.conf"])
        try await Guest.shared.writeResolver(servers: ["100.100.100.100"])
        let written = try await Guest.shared.run("/bin/sh", ["-c", "cat /etc/resolv.conf && [ -f /etc/resolv.conf ]"])
        XCTAssertEqual(written.status, 0, written.errors)
        XCTAssertEqual(written.output, "nameserver 100.100.100.100\n")

        _ = try await Guest.shared.run("/bin/sh", ["-c", "echo 'nameserver 9.9.9.9' > /etc/resolv.conf"])
        try await Guest.shared.writeResolver(servers: ["10.0.0.1", "fd7a:115c:a1e0::53"])
        let replaced = try await Guest.shared.run("/bin/sh", ["-c", "cat /etc/resolv.conf; ls /etc/resolv.conf.topo 2>/dev/null"])
        XCTAssertEqual(replaced.output, "nameserver 10.0.0.1\nnameserver fd7a:115c:a1e0::53\n")

        try await Guest.shared.writeResolver(servers: [])
        let fallback = try await Guest.shared.run("/bin/cat", ["/etc/resolv.conf"])
        XCTAssertEqual(fallback.output, "nameserver 1.1.1.1\nnameserver 8.8.8.8\n")
    }

    /// Only numeric addresses with no scope reach the file, IPv4 first, three at most, each once;
    /// a list with none of those is the fallback.
    func testTheResolverFileTakesAddressesOnly() {
        XCTAssertEqual(Guest.resolverFile(for: ["2001:558:feed::1", "fe80::1%en0", "192.168.1.1", "192.168.1.1",
                                                "not an address", "10.0.0.1", "10.0.0.2"]),
                       "nameserver 192.168.1.1\nnameserver 10.0.0.1\nnameserver 10.0.0.2\n")
        XCTAssertEqual(Guest.resolverFile(for: ["fe80::1%en0", "; rm -rf /", ""]),
                       "nameserver 1.1.1.1\nnameserver 8.8.8.8\n")
    }

    /// The phone's resolver answers numeric addresses, the simulator's being its Mac's, which
    /// lists at least one.
    func testThePhonesNameserversAreAddresses() {
        let servers = Guest.systemNameservers()
        XCTAssertFalse(servers.isEmpty, "res_ninit listed no server, or failed")
        for server in servers {
            XCTAssertNotEqual(Guest.resolverFile(for: [server]), Guest.resolverFile(for: []), server)
        }
    }

    /// The guest tells the time in the zone `/etc/localtime` is pointed at, standard time and
    /// summer time each on its own date, from the tzdata laid in with the packages; a second zone
    /// replaces the first, with nothing left beside it.
    func testTheGuestKeepsThePhonesZone() async throws {
        _ = try SharedGuest.booted()
        defer { Task { _ = try? await Guest.shared.run("/bin/rm", ["-f", "/etc/localtime"]) } }
        let probe = "readlink /etc/localtime; date -d @1737000000 +%z; date -d @1752000000 +%z; ls /etc/localtime.topo 2>/dev/null"

        try await Guest.shared.writeTimeZone(identifier: "America/Los_Angeles")
        let pacific = try await Guest.shared.run("/bin/sh", ["-c", probe])
        XCTAssertEqual(pacific.output, "/usr/share/zoneinfo/America/Los_Angeles\n-0800\n-0700\n", pacific.errors)

        try await Guest.shared.writeTimeZone(identifier: "Europe/London")
        let london = try await Guest.shared.run("/bin/sh", ["-c", probe])
        XCTAssertEqual(london.output, "/usr/share/zoneinfo/Europe/London\n+0000\n+0100\n", london.errors)
    }

    /// A name that is not a zone's, or a zone the guest has no zoneinfo for, throws and leaves
    /// `/etc/localtime` where it was: no path out of the zoneinfo, and nothing the shell runs.
    func testTheTimeZoneRefusesWhatIsNotAZoneName() async throws {
        _ = try SharedGuest.booted()
        defer { Task { _ = try? await Guest.shared.run("/bin/rm", ["-f", "/etc/localtime"]) } }
        try await Guest.shared.writeTimeZone(identifier: "Europe/London")
        let refused = ["../../etc/passwd", "/etc/passwd", "America/$(touch /tmp/ran)", "America/..", "America//Denver",
                       "", "a b", String(repeating: "A", count: 65), "Mars/Olympus", "America", "zone.tab", "tzdata.zi"]
        for name in refused {
            do {
                try await Guest.shared.writeTimeZone(identifier: name)
                XCTFail("\(name) was written")
            } catch let failure as Guest.Failure {
                guard case .timeZone = failure else { return XCTFail("\(name): \(failure)") }
            }
        }
        let after = try await Guest.shared.run("/bin/sh", ["-c", "readlink /etc/localtime; ls /etc/localtime.topo /tmp/ran 2>/dev/null"])
        XCTAssertEqual(after.output, "/usr/share/zoneinfo/Europe/London\n")
    }

    /// The guest answers to its own name, whatever the host is called: busybox's shell asks at
    /// start, and a host name longer than the kernel's 65-byte field is a crash rather than a name.
    func testTheGuestHasItsOwnHostname() async throws {
        _ = try SharedGuest.booted()
        let exit = try await Guest.shared.run("/bin/uname", ["-n"])
        XCTAssertEqual(exit.status, 0, exit.errors)
        XCTAssertEqual(exit.output, "topo\n")
    }

    /// bash is in the userland — Alpine's package and the libraries it links, laid in beside the
    /// rootfs — and runs: the version it reports is the pinned package's.
    func testBashRunsInTheGuest() async throws {
        _ = try SharedGuest.booted()
        let exit = try await Guest.shared.run("/bin/bash", ["-c", "echo $BASH_VERSION"])
        XCTAssertEqual(exit.status, 0, exit.errors)
        XCTAssertEqual(exit.output, "5.2.37(1)-release\n")
        XCTAssertEqual(exit.errors, "")
    }

    /// The shell every guest program is handed is bash, and it is the one at that path: what
    /// Claude Code's Bash tool finds, and what anything it starts inherits.
    func testTheShellInTheEnvironmentIsBash() async throws {
        _ = try SharedGuest.booted()
        XCTAssertEqual(Guest.environment["SHELL"], "/bin/bash")
        let exit = try await Guest.shared.run("/bin/sh", ["-c", #""$SHELL" -c 'echo "topo-$((6*7)) ${BASH_VERSINFO[0]}"'"#])
        XCTAssertEqual(exit.status, 0, exit.errors)
        XCTAssertEqual(exit.output, "topo-42 5\n")
    }

    /// A program that does not exist is refused, and leaves nothing behind: the task made for it
    /// ends, so a termination after it, which counts every task in the guest, is still confirmed.
    func testAMissingProgramIsRefusedAtTheStartAndLeavesNoTask() async throws {
        _ = try SharedGuest.booted()
        do {
            _ = try await Guest.shared.run("/bin/no-such-program")
            XCTFail("a program that does not exist started")
        } catch Guest.Failure.spawn {
        }
        let after = try await Guest.shared.spawn("/bin/sleep", ["30"])
        let termination = await after.terminate(within: .seconds(5))
        XCTAssertTrue(termination.confirmed, "\(termination)")
    }

    /// iSH's kernel is process-global: a second boot would be a second init and a second root
    /// mounted over the first. It is refused, and the first kernel goes on answering.
    func testASecondBootIsRefusedAndTheFirstKernelStands() async throws {
        let fakefs = try SharedGuest.booted()
        XCTAssertEqual(Guest.shared.kernels, 1)

        XCTAssertThrowsError(try Guest.shared.boot(fakefs: fakefs)) { error in
            XCTAssertEqual(error as? Guest.Failure, .alreadyBooted)
        }
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("no-fakefs-\(UUID().uuidString)")
        XCTAssertThrowsError(try Guest.shared.boot(fakefs: elsewhere)) { error in
            XCTAssertEqual(error as? Guest.Failure, .alreadyBooted)
        }
        XCTAssertEqual(Guest.shared.kernels, 1, "a second kernel was made")

        let exit = try await Guest.shared.run("/bin/echo", ["still here"])
        XCTAssertEqual(exit.output, "still here\n")
    }
}

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

    func testAMissingProgramIsRefusedAtTheStart() async throws {
        _ = try SharedGuest.booted()
        do {
            _ = try await Guest.shared.run("/bin/no-such-program")
            XCTFail("a program that does not exist started")
        } catch Guest.Failure.spawn {
        }
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

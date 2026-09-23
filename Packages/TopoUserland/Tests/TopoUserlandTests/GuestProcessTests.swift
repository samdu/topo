import XCTest
@testable import TopoUserland

/// A guest process the app talks to: stdin a pipe, stdout by line as it arrives, and a deliberate
/// end confirmed — the process reaped, its descendants gone and both pipes closed.
final class GuestProcessTests: XCTestCase {
    func testCatEchoesEachLineAsItIsWrittenAndEndsWhenStdinCloses() async throws {
        _ = try SharedGuest.booted()
        let cat = try await Guest.shared.spawn("/bin/cat")
        var lines = cat.lines.makeAsyncIterator()

        try await cat.write("hello from the host")
        let first = await lines.next()
        XCTAssertEqual(first, "hello from the host", "the line did not come back while the program ran")
        XCTAssertFalse(cat.hasExited)

        try await cat.write("{\"type\":\"user\",\"message\":\"é ✓\"}")
        let second = await lines.next()
        XCTAssertEqual(second, "{\"type\":\"user\",\"message\":\"é ✓\"}")

        cat.closeInput()
        let end = await lines.next()
        XCTAssertNil(end, "stdout did not end when stdin closed")
        await eventually("cat reaped") { cat.hasExited }
        XCTAssertEqual(cat.exitStatus, 0)
        do {
            try await cat.write("too late")
            XCTFail("a write after the input closed was taken")
        } catch GuestProcess.Failure.inputClosed {
        }
    }

    func testAWriteAfterTheProgramHasGoneFailsRatherThanRaisingSigpipe() async throws {
        _ = try SharedGuest.booted()
        let gone = try await Guest.shared.spawn("/bin/sh", ["-c", "exit 0"])
        await eventually("the program exited") { gone.hasExited }
        for await _ in gone.lines {}
        do {
            // A pipe with no reader: EPIPE, never a signal that ends the app.
            for _ in 0..<4 { try await gone.write(String(repeating: "x", count: 70_000)) }
            XCTFail("writes to a program that has gone were all taken")
        } catch GuestProcess.Failure.inputClosed {
        }
    }

    func testStderrKeepsItsLast16KB() async throws {
        _ = try SharedGuest.booted()
        // A start that must be dropped, 20 KB after it, then a marker that must be kept.
        let noisy = try await Guest.shared.spawn("/bin/sh", ["-c", """
            printf EARLIEST >&2
            head -c 20480 /dev/zero | tr '\\0' a >&2
            printf MARKER >&2
            """])
        for await _ in noisy.lines {}
        await eventually("exited") { noisy.hasExited }
        await eventually("stderr read to its end") { noisy.errors.hasSuffix("MARKER") }
        let tail = noisy.errors
        XCTAssertEqual(tail.utf8.count, 16 * 1024, "the tail is not exactly 16 KB")
        XCTAssertTrue(tail.hasSuffix("MARKER"), "the marker written last was not kept")
        XCTAssertFalse(tail.contains("EARLIEST"), "the earliest bytes were kept")
        XCTAssertEqual(tail.dropLast("MARKER".count).allSatisfy { $0 == "a" }, true)
    }

    func testTerminateEndsTheWholeTreeAndConfirmsIt() async throws {
        _ = try SharedGuest.booted()
        // A shell holding two children, one of which holds a grandchild, all sharing the pipes.
        let tree = try await Guest.shared.spawn("/bin/sh", ["-c", """
            sleep 300 &
            sh -c 'sleep 300 & wait' &
            echo started
            wait
            """])
        var lines = tree.lines.makeAsyncIterator()
        let started = await lines.next()
        XCTAssertEqual(started, "started")
        await eventually("the tree grown") { await GuestProcess.guestTasks().count >= 4 }
        let pids = await GuestProcess.guestTasks()
        XCTAssertTrue(pids.contains(tree.pid))

        let termination = await tree.terminate(within: .seconds(5))
        XCTAssertTrue(termination.confirmed, "\(termination)")
        XCTAssertEqual(termination.signalled, pids.count)
        XCTAssertEqual(termination.status, 128 + 9, "the shell was not the one killed")
        let running = await GuestProcess.running(pids)
        XCTAssertEqual(running, 0, "a descendant survived the teardown")
        let end = await lines.next()
        XCTAssertNil(end, "stdout was still open after the teardown")
    }

    func testTerminatingAProcessThatAlreadyExitedIsConfirmedAtOnce() async throws {
        _ = try SharedGuest.booted()
        let done = try await Guest.shared.spawn("/bin/echo", ["bye"])
        await eventually("exited") { done.hasExited }
        let termination = await done.terminate(within: .seconds(2))
        XCTAssertTrue(termination.confirmed, "\(termination)")
        XCTAssertEqual(termination.signalled, 0)
        XCTAssertEqual(termination.status, 0)
    }

    func testATerminationIsConfirmedOnlyWhenTheWholeTreeHasEnded() async throws {
        _ = try SharedGuest.booted()
        // Sleeps holding none of the pipes, so the pipes closing says nothing about them: only a
        // termination that reached every one of them can say the guest ended.
        let tree = try await Guest.shared.spawn("/bin/sh", ["-c", """
            for i in 1 2 3 4; do sleep 300 </dev/null >/dev/null 2>&1 & done
            echo started
            wait
            """])
        var lines = tree.lines.makeAsyncIterator()
        _ = await lines.next()
        await eventually("the tree grown") { await GuestProcess.guestTasks().count >= 5 }
        let whole = await GuestProcess.guestTasks()
        let termination = await tree.terminate(within: .seconds(5))
        let survivors = await GuestProcess.running(whole.filter { $0 != tree.pid })
        XCTAssertEqual(survivors, 0, "\(termination)")
        XCTAssertTrue(termination.confirmed, "\(termination)")
    }

    func testTheResidentsEndReachesWhatWasOrphanedToInitMidTeardown() async throws {
        _ = try SharedGuest.booted()
        let before = Self.guestTasks()
        // A program that keeps forking a child which forks a sleep and exits at once: every sleep
        // is handed to init as it starts, before, during and after the kill, so no parent link
        // leads from the program to it.
        let resident = try await Guest.shared.spawn("/bin/sh", ["-c", """
            echo started
            while :; do (sleep 300 </dev/null >/dev/null 2>&1 &); done
            """])
        var lines = resident.lines.makeAsyncIterator()
        _ = await lines.next()
        await eventually("orphans made") { Self.guestTasks().subtracting(before).count >= 4 }
        let termination = await resident.end(within: .seconds(5))
        let left = Self.guestTasks().subtracting(before)
        XCTAssertEqual(left, [], "\(left.map(GuestProcess.describe)); \(termination)")
        XCTAssertTrue(termination.confirmed, "\(termination)")
    }

    /// Every guest task but init that is not a zombie, read pid by pid.
    private static func guestTasks() -> Set<Int32> {
        Set((2...Int32(1 << 15)).filter { GuestProcess.running([$0]) > 0 })
    }

    func testATerminationTheBoundRunsOutOnSaysWhatStayed() {
        let termination = GuestProcess.Termination(status: nil, signalled: 3, running: 1, pipesClosed: false,
                                                   elapsed: .milliseconds(7_004), stragglers: ["41 (node): running"])
        XCTAssertFalse(termination.confirmed)
        XCTAssertEqual(termination.description,
                       "not reaped, 3 signalled, 1 still running, pipes open, in 7004 ms; still there: 41 (node): running")
        XCTAssertFalse(GuestProcess.Termination(status: 137, signalled: 0, running: 0, pipesClosed: true, walked: false).confirmed,
                       "a tree that could not be walked was confirmed ended")
    }
}

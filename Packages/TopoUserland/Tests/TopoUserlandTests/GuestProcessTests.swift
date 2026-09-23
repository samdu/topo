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
        await eventually("the tree grown") { await tree.tree().count >= 4 }
        let pids = await tree.tree()
        XCTAssertEqual(pids.first, tree.pid)

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

    func testATreeLargerThanTheListIsWalkedWholeAndKilledWhole() async throws {
        _ = try SharedGuest.booted()
        let tree = try await Guest.shared.spawn("/bin/sh", ["-c", """
            sleep 300 &
            sleep 300 &
            sh -c 'sleep 300 & wait' &
            echo started
            wait
            """])
        var lines = tree.lines.makeAsyncIterator()
        _ = await lines.next()
        await eventually("the tree grown") { await tree.tree().count >= 5 }
        let whole = await tree.tree()
        // A list with room for two: the walk still reaches, reports and kills every task.
        let listed = try XCTUnwrap(GuestProcess.signalTree(tree.pid, 0, capacity: 2))
        XCTAssertEqual(Set(listed), Set(whole), "a tree larger than the list was reported cut short")
        let killed = try XCTUnwrap(GuestProcess.signalTree(tree.pid, 9 /* SIGKILL */, capacity: 1))
        XCTAssertEqual(Set(killed), Set(whole))
        await eventually("every task ended") { await GuestProcess.running(whole.filter { $0 != tree.pid }) == 0 }
        await eventually("the shell reaped") { tree.hasExited }
    }

    func testATerminationIsConfirmedOnlyWhenTheWholeTreeHasEnded() async throws {
        _ = try SharedGuest.booted()
        // Sleeps holding none of the pipes, so the pipes closing says nothing about them: only a
        // walk that reached every one of them can say the tree ended.
        let tree = try await Guest.shared.spawn("/bin/sh", ["-c", """
            for i in 1 2 3 4; do sleep 300 </dev/null >/dev/null 2>&1 & done
            echo started
            wait
            """])
        var lines = tree.lines.makeAsyncIterator()
        _ = await lines.next()
        await eventually("the tree grown") { await tree.tree().count >= 5 }
        let whole = await tree.tree()
        let termination = await tree.terminate(within: .seconds(5))
        let survivors = await GuestProcess.running(whole.filter { $0 != tree.pid })
        XCTAssertEqual(survivors, 0, "\(termination)")
        XCTAssertTrue(termination.confirmed, "\(termination)")
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

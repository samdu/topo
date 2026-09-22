import XCTest
import TopoUserland

/// Mounts and links made from one host thread while other host threads start guest programs and
/// wait for them to exit. Each of those calls swaps the kernel's `current` to init and back; it is
/// thread-local (kernel/task.h:145), so no swap can leak into another thread's call. If one did, a
/// mount would resolve against the wrong task, a link would land somewhere else, or a wait would
/// reap the wrong child.
final class GuestConcurrencyTests: XCTestCase {
    /// 100 mount-and-link pairs on one thread against four threads running 50 exiting commands
    /// each (200 exits): enough for the waits to land between the pairs' swaps many times over, in
    /// a few seconds of CI.
    func testMountsAndLinksLandWhileGuestProgramsExitOnOtherThreads() async throws {
        _ = try SharedGuest.booted()
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("interleave-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let tag = UUID().uuidString.prefix(6)
        let pairs = 100, threads = 4, exits = 50
        let hosts = try (0..<pairs).map { i -> URL in
            let host = base.appendingPathComponent("\(i)", isDirectory: true)
            try fm.createDirectory(at: host, withIntermediateDirectories: true)
            try Data("\(i)\n".utf8).write(to: host.appendingPathComponent("which"))
            return host
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        done.resume(with: Result {
                            for (i, host) in hosts.enumerated() {
                                try Guest.shared.mount(host, at: "/opt/interleave-\(tag)-\(i)")
                                try Guest.shared.link("/opt/interleave-\(tag)-\(i)/which", at: "/tmp/interleave-\(tag)-\(i)")
                            }
                        })
                    }
                }
            }
            for _ in 0..<threads {
                group.addTask {
                    for _ in 0..<exits {
                        let exit = try await Guest.shared.run("/bin/sh", ["-c", "exit 3"])
                        XCTAssertEqual(exit.status, 3, "a wait reaped something other than its own child")
                    }
                }
            }
            try await group.waitForAll()
        }

        // As init sees it: every link reads its own host's file, and every mount is there once.
        let check = try await Guest.shared.run("/bin/sh", ["-c", """
            n=0; for i in $(seq 0 \(pairs - 1)); do [ "$(cat /tmp/interleave-\(tag)-$i)" = "$i" ] && n=$((n+1)); done
            echo $n; grep -c ' /opt/interleave-\(tag)-' /proc/mounts
            """])
        XCTAssertEqual(check.output, "\(pairs)\n\(pairs)\n", check.errors)
        // And the host thread is itself again: a plain run still starts and reaps its own child.
        let after = try await Guest.shared.run("/bin/echo", ["after"])
        XCTAssertEqual(after.output, "after\n")
    }
}

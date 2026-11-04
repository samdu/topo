import XCTest
import TopoUserland

/// A path through procfs is the process's own: `/proc/self` names the process that asks, and
/// `/proc/self/fd/N` its own file, however soon after another process asked for the same path,
/// and an fd link that did not resolve a moment ago resolves once the fd is open. The fork's path
/// cache is shared by every process, and a walk that looks anything up on procfs is kept out of
/// it (`patches/ish/0016-path-cache-procfs-links.patch`); the lookups here follow one another
/// well inside the cache's 100 ms.
final class GuestProcLinksTests: XCTestCase {
    override func setUpWithError() throws {
        _ = try SharedGuest.booted()
    }

    private func sh(_ command: String) async throws -> Guest.Exit {
        try await Guest.shared.run("/bin/sh", ["-c", command])
    }

    func testProcSelfIsTheProcessThatAsks() async throws {
        // `exec` keeps the shell's pid, so the pid /proc/self/stat names is the $$ printed before it.
        let run = try await sh("""
            for i in $(seq 20); do
              out=$(sh -c 'echo $$; exec cut -d" " -f1 /proc/self/stat')
              set -- $out
              [ $# = 2 ] && [ "$1" = "$2" ] && echo ok || echo "other: $out"
            done
            """)
        XCTAssertEqual(run.output, String(repeating: "ok\n", count: 20), run.errors)
        XCTAssertEqual(run.status, 0, run.errors)
    }

    func testProcSelfFdIsTheProcessesOwnFile() async throws {
        let dir = "/tmp/proc-links-\(UUID().uuidString.prefix(8))"
        let run = try await sh("""
            mkdir -p \(dir) && echo a > \(dir)/a && echo b > \(dir)/b
            for i in $(seq 10); do
              for f in a b; do sh -c "exec 3< \(dir)/$f; read l < /proc/self/fd/3; echo \\$l"; done
            done
            rm -r \(dir)
            """)
        XCTAssertEqual(run.output, String(repeating: "a\nb\n", count: 10), run.errors)
        XCTAssertEqual(run.status, 0, run.errors)
    }

    func testAnFdLinkThatDidNotResolveResolvesOnceTheFdIsOpen() async throws {
        // `cat` asks for the shell's fd 3 while it is closed, which fails; the shell then opens
        // it and reads the same path, which a cached unresolved walk would refuse as a link.
        let dir = "/tmp/proc-links-\(UUID().uuidString.prefix(8))"
        let run = try await sh("""
            mkdir -p \(dir) && echo a > \(dir)/a
            for i in $(seq 10); do
              sh -c 'exec 3<&-; cat /proc/$$/fd/3 2>/dev/null; exec 3< \(dir)/a; read l < /proc/$$/fd/3; echo $l'
            done
            rm -r \(dir)
            """)
        XCTAssertEqual(run.output, String(repeating: "a\n", count: 10), run.errors)
        XCTAssertEqual(run.status, 0, run.errors)
    }
}

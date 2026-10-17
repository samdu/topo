import XCTest
import TopoUserland

/// The two calls Claude Code is reached through, in the booted guest: a bind mount that is left
/// alone when asked for again and refuses a second source at its point, and a link that is left
/// alone, replaced when it points elsewhere, and never put over something that is not a link. And
/// the guest's own `mount(2)`, which never reaches the host
/// (`patches/ish/0004-guest-mount-real-refused.patch`), and its own `umount(2)` of a tmpfs, which
/// the app survives (`patches/ish/0008-tmpfs-umount.patch`).
final class GuestMountTests: XCTestCase {
    private let fm = FileManager.default
    private var hosts: [URL] = []

    override func setUpWithError() throws {
        _ = try SharedGuest.booted()
    }

    override func tearDownWithError() throws {
        hosts.forEach { try? fm.removeItem(at: $0) }
    }

    /// A host directory holding one file whose text names it.
    private func host(_ name: String) throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("mount-\(name)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("\(name)\n".utf8).write(to: url.appendingPathComponent("which"))
        hosts.append(url)
        return url
    }

    private func sh(_ command: String) async throws -> Guest.Exit {
        try await Guest.shared.run("/bin/sh", ["-c", command])
    }

    func testTheSameMountIsLeftAloneAndASecondSourceIsRefused() async throws {
        let a = try host("a"), b = try host("b")
        let point = "/opt/mount-\(UUID().uuidString.prefix(8))"

        try Guest.shared.mount(a, at: point)
        try Guest.shared.mount(a, at: point)
        let mounts = try await sh("grep -c ' \(point) ' /proc/mounts")
        XCTAssertEqual(mounts.output, "1\n", "asking for the same mount again stacked a second one")

        XCTAssertThrowsError(try Guest.shared.mount(b, at: point)) { error in
            XCTAssertEqual(error as? Guest.Failure, .mount(-16), "a second source was not refused with EBUSY")
        }
        let which = try await sh("cat \(point)/which; grep -c ' \(point) ' /proc/mounts")
        XCTAssertEqual(which.output, "a\n1\n", "the refused source reached the point")
    }

    func testALinkIsLeftAloneReplacedWhenItPointsElsewhereAndNeverPutOverAFile() async throws {
        let path = "/usr/local/bin/link-\(UUID().uuidString.prefix(8))"

        try Guest.shared.link("/opt/a/claude", at: path)
        try Guest.shared.link("/opt/a/claude", at: path)
        let first = try await sh("readlink \(path)")
        XCTAssertEqual(first.output, "/opt/a/claude\n")

        try Guest.shared.link("/opt/b/claude", at: path)
        let replaced = try await sh("readlink \(path)")
        XCTAssertEqual(replaced.output, "/opt/b/claude\n", "a link pointing elsewhere was not replaced")

        let file = "/usr/local/bin/file-\(UUID().uuidString.prefix(8))"
        _ = try await sh("echo keep > \(file)")
        XCTAssertThrowsError(try Guest.shared.link("/opt/a/claude", at: file)) { error in
            XCTAssertEqual(error as? Guest.Failure, .link(-17, path: file), "a file at the path was not refused with EEXIST")
            XCTAssertTrue("\(error)".contains(file), "the refusal names the path")
        }
        let kept = try await sh("[ -L \(file) ] && echo link; cat \(file)")
        XCTAssertEqual(kept.output, "keep\n", "the file at the path was replaced")
    }

    /// A command's path is the app's: a regular file left there (the mind's own `gh` script from
    /// before the app had one) gives way to the link, on this launch and every one after; a
    /// directory there is never removed, and the refusal names it.
    func testACommandLinkReplacesAFileButNeverADirectory() async throws {
        let file = "/usr/local/bin/cmd-\(UUID().uuidString.prefix(8))"
        _ = try await sh("printf '#!/bin/sh\\necho mine\\n' > \(file); chmod +x \(file)")
        try await Guest.shared.linkCommand("/opt/a/tool", at: file)
        try await Guest.shared.linkCommand("/opt/a/tool", at: file)
        let linked = try await sh("readlink \(file)")
        XCTAssertEqual(linked.output, "/opt/a/tool\n")

        let directory = "/usr/local/bin/dir-\(UUID().uuidString.prefix(8))"
        _ = try await sh("mkdir -p \(directory) && echo note > \(directory)/keep")
        do {
            try await Guest.shared.linkCommand("/opt/a/tool", at: directory)
            XCTFail("a directory was taken for a link")
        } catch {
            XCTAssertEqual(error as? Guest.Failure, .link(-17, path: directory))
        }
        let kept = try await sh("cat \(directory)/keep")
        XCTAssertEqual(kept.output, "note\n")
    }

    /// The guest runs as root, so a realfs mount it could make for itself would be a bind mount of
    /// any host path the app's sandbox can open. What it reaches is what the app mounts, and only
    /// that.
    func testTheGuestCannotMountTheHost() async throws {
        let outside = try host("outside")
        let point = "/mnt/host-\(UUID().uuidString.prefix(8))"
        let attempt = try await sh("mkdir -p \(point) && mount -t real '\(outside.path)' \(point)")
        XCTAssertNotEqual(attempt.status, 0, "the guest mounted a host directory: \(attempt.output)")
        // EPERM, which BusyBox's mount words as its own.
        XCTAssertTrue(attempt.errors.contains("permission denied"),
                      "the mount was not refused as not permitted: \(attempt.errors)")
        let reached = try await sh("cat \(point)/which; grep -c ' \(point) ' /proc/mounts")
        XCTAssertEqual(reached.output, "0\n", "the host directory is reachable at \(point)")
    }

    /// What the refusal leaves alone: the guest's own filesystems, which reach nothing of the host,
    /// are still its to mount.
    func testTheGuestStillMountsItsOwnFilesystems() async throws {
        let tmp = "/mnt/tmp-\(UUID().uuidString.prefix(8))"
        let tmpfs = try await sh("mkdir -p \(tmp) && mount -t tmpfs tmpfs \(tmp) && echo kept > \(tmp)/f && cat \(tmp)/f "
            + "&& grep -c ' \(tmp) ' /proc/mounts")
        XCTAssertEqual(tmpfs.status, 0, tmpfs.errors)
        XCTAssertEqual(tmpfs.output, "kept\n1\n")

        let proc = "/mnt/proc-\(UUID().uuidString.prefix(8))"
        let procfs = try await sh("mkdir -p \(proc) && mount -t proc proc \(proc) && [ -e \(proc)/self ] && echo proc")
        XCTAssertEqual(procfs.status, 0, procfs.errors)
        XCTAssertEqual(procfs.output, "proc\n")
    }

    /// A tmpfs the guest made is its to unmount, with the app still standing
    /// (`patches/ish/0008-tmpfs-umount.patch`): the mount goes, its point is the empty directory it
    /// was, and a tmpfs mounted there again starts empty. While something in it is open the unmount
    /// is refused and the files stay; closed, it goes.
    func testTheGuestUnmountsItsOwnTmpfs() async throws {
        let point = "/mnt/tmpfs-\(UUID().uuidString.prefix(8))"
        let filled = try await sh("mkdir -p \(point) && mount -t tmpfs tmpfs \(point) && mkdir \(point)/d "
            + "&& echo deep > \(point)/d/f && echo top > \(point)/f && ls \(point) \(point)/d > /dev/null "
            + "&& umount \(point) && echo unmounted; grep -c ' \(point) ' /proc/mounts; ls -A \(point)")
        XCTAssertEqual(filled.output, "unmounted\n0\n", filled.errors)

        let busy = try await sh("mount -t tmpfs tmpfs \(point) && { [ -e \(point)/f ] || echo fresh; } "
            + "&& echo again > \(point)/f && exec 3< \(point)/f; umount \(point) 2> /dev/null || echo refused; "
            + "cat \(point)/f; exec 3<&-; umount \(point) && echo unmounted; grep -c ' \(point) ' /proc/mounts")
        XCTAssertEqual(busy.output, "fresh\nrefused\nagain\nunmounted\n0\n", busy.errors)
    }
    /// Lookups under a tmpfs's point beside a loop that mounts and unmounts it
    /// (`patches/ish/0011-mount-find-cache-under-lock.patch`): each reader is one shell testing
    /// for the directory's own `under` and the tmpfs's `over` with a builtin, so every lookup is
    /// on one guest thread, whose cached mount is the tmpfs another process is unmounting. A
    /// stat holds the mount only for its lookup, so the loop's unmounts land between them. Both
    /// files are seen, and the loop ends with nothing mounted. A use of a freed mount is a window
    /// of a few instructions that this does not reproduce on demand; what it proves is that the
    /// lookups still take the lock without deadlocking and still find the mount the point has.
    func testLookupsBesideAMountAndUnmountLoopFindTheMountThePointHas() async throws {
        let id = UUID().uuidString.prefix(8)
        let point = "/mnt/race-\(id)", out = "/tmp/race-\(id)"
        let script = #"""
        p="$1"; o="$2"
        mkdir -p "$p" "$o" && touch "$p/under" || exit 70
        for r in 1 2 3 4; do
            (
                under=0; over=0
                while [ ! -e "$o/stop" ]; do
                    [ -e "$p/under" ] && under=$((under + 1))
                    [ -e "$p/over" ] && over=$((over + 1))
                done
                echo "$under $over" > "$o/$r"
            ) &
        done
        trap 'touch "$o/stop"' EXIT
        i=0
        while [ $i -lt 300 ]; do
            mount -t tmpfs tmpfs "$p" || exit 71
            : > "$p/over" && [ -e "$p/over" ] && [ ! -e "$p/under" ] || exit 73
            j=0
            while [ $j -lt 20 ]; do [ -e "$p/over" ]; j=$((j + 1)); done
            tries=0
            until umount "$p" 2> /dev/null; do
                tries=$((tries + 1))
                [ $tries -lt 5000 ] || exit 72
            done
            i=$((i + 1))
        done
        touch "$o/stop"
        wait
        cat "$o"/1 "$o"/2 "$o"/3 "$o"/4
        grep -c " $p " /proc/mounts
        ls "$p"
        rm -rf "$o"
        """#
        let exit = try await Guest.shared.run("/bin/sh", ["-c", script, "sh", point, out])
        XCTAssertEqual(exit.status, 0, exit.errors)
        var lines = exit.output.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.popLast(), "under", exit.output)
        XCTAssertEqual(lines.popLast(), "0", exit.output)
        XCTAssertEqual(lines.count, 4, exit.output)
        let counts = lines.map { $0.split(separator: " ").compactMap { Int($0) } }
        XCTAssertTrue(counts.allSatisfy { $0.count == 2 }, exit.output)
        XCTAssertGreaterThan(counts.map { $0.first ?? 0 }.reduce(0, +), 0, exit.output)
        XCTAssertGreaterThan(counts.map { $0.last ?? 0 }.reduce(0, +), 0, exit.output)
    }
}

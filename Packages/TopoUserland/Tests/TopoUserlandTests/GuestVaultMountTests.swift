import XCTest
import TopoUserland

/// The memory's folder in the booted guest (`Guest.mountVault`): the guest reads and writes the
/// host's files, every open of a regular file waits for a coordinated writer and a write holds its
/// coordination until the file closes, a wait that cannot end is bounded and a SIGKILL ends it, a
/// parked open stalls nothing else, the mirror's `.topo` is hidden, and a mount is taken away
/// only when nothing in the guest holds it.
///
/// Coordination here is `NSFileCoordinator` in the test's own process, which is how the mirror and
/// the guest meet in the app's.
final class GuestVaultMountTests: XCTestCase {
    private let fm = FileManager.default
    private var hosts: [URL] = []
    private var points: [String] = []

    override func setUpWithError() throws {
        _ = try SharedGuest.booted()
    }

    override func tearDownWithError() throws {
        for point in points { try? Guest.shared.unmount(point) }
        hosts.forEach { try? fm.removeItem(at: $0) }
    }

    /// A host folder holding one note, mounted at a fresh point.
    private func vault(_ note: String = "first\n") throws -> (host: URL, point: String) {
        let host = fm.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: host, withIntermediateDirectories: true)
        try Data(note.utf8).write(to: host.appendingPathComponent("note.md"))
        hosts.append(host)
        let point = "/vault-\(UUID().uuidString.prefix(8))"
        try Guest.shared.mountVault(host, at: point)
        points.append(point)
        return (host, point)
    }

    private func sh(_ command: String) async throws -> Guest.Exit {
        try await Guest.shared.run("/bin/sh", ["-c", command])
    }

    /// A coordinated write on `url`, held from another thread from `entered` until `release`, with
    /// `body` run inside it just before it lets go.
    private final class Writer: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)

        init(_ url: URL, body: @escaping @Sendable () -> Void = {}) {
            DispatchQueue.global().async { [self] in
                var error: NSError?
                NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &error) { _ in
                    entered.signal()
                    release.wait()
                    body()
                }
                done.signal()
            }
            entered.wait()
        }
    }

    func testTheGuestReadsAndWritesTheFolder() async throws {
        let (host, point) = try vault("from the host\n")
        let read = try await sh("cat \(point)/note.md")
        XCTAssertEqual(read.output, "from the host\n")

        let wrote = try await sh("mkdir -p \(point)/notes && printf 'from the guest\\n' > \(point)/notes/new.md "
            + "&& mv \(point)/notes/new.md \(point)/notes/moved.md && rm \(point)/note.md")
        XCTAssertEqual(wrote.status, 0, wrote.errors)
        let moved = try String(contentsOf: host.appendingPathComponent("notes/moved.md"), encoding: .utf8)
        XCTAssertEqual(moved, "from the guest\n")
        XCTAssertFalse(fm.fileExists(atPath: host.appendingPathComponent("note.md").path))
        XCTAssertFalse(fm.fileExists(atPath: host.appendingPathComponent("notes/new.md").path))
    }

    /// Half a file is never read: an open waits for a writer, and reads what the writer left.
    func testAnOpenWaitsForACoordinatedWriter() async throws {
        let (host, point) = try vault("old text\n")
        let note = host.appendingPathComponent("note.md")
        let writer = Writer(note) { try? Data("new text, whole\n".utf8).write(to: note) }
        let cat = try await Guest.shared.spawn("/bin/cat", ["\(point)/note.md"])
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(cat.hasExited, "the open did not wait for the writer")
        writer.release.signal()
        var lines = cat.lines.makeAsyncIterator()
        let line = await lines.next()
        XCTAssertEqual(line, "new text, whole")
        await eventually("cat exited") { cat.hasExited }
        XCTAssertEqual(cat.exitStatus, 0)
    }

    /// A read is coordinated by what the open found, not by a stat before it: a note made under a
    /// coordinated write after the guest's stat found nothing, and before its open, is still read
    /// under the coordination. A loop of builtins in the guest reads the name while the host, over
    /// and over, makes the note under a held write, leaves it half written, finishes it and removes
    /// it; a read that was let in uncoordinated reads the half.
    func testANoteMadeBetweenTheStatAndTheOpenIsReadWhole() async throws {
        let (host, point) = try vault()
        let note = host.appendingPathComponent("made.md")
        let stop = host.appendingPathComponent("stop").path
        let made = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for _ in 0..<150 {
                var error: NSError?
                NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: note, options: [], error: &error) { url in
                    let fd = open(url.path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
                    _ = "half".withCString { write(fd, $0, 4) }
                    usleep(10_000)
                    _ = " whole\n".withCString { write(fd, $0, 7) }
                    close(fd)
                }
                NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: note, options: .forDeleting, error: &error) { url in
                    unlink(url.path)
                }
                usleep(3_000)
            }
            close(open(stop, O_CREAT | O_WRONLY, 0o644))
            made.signal()
        }
        let loop = try await sh("cd \(point) && { i=0; n=0; while [ ! -e stop ] && [ $i -lt 200000 ]; do "
            + "if { l=; read -r l || true; } < made.md; then n=$((n+1)); [ \"$l\" = 'half whole' ] || echo \"HALF [$l]\"; fi; "
            + "i=$((i+1)); done; echo \"loops $i reads $n\"; } 2>/dev/null")
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { made.wait(); continuation.resume() }
        }
        XCTAssertTrue(loop.output.contains("loops "), loop.output)
        XCTAssertFalse(loop.output.contains("reads 0\n"), "the guest never read the note: \(loop.output)")
        XCTAssertFalse(loop.output.contains("HALF"), "a read was let in while the note's writer held it: \(loop.output.prefix(300))")
    }

    /// Half a note the guest is writing is never read by the mirror: a write open holds its
    /// coordination until the file closes.
    func testAGuestWriteHoldsItsCoordinationUntilClose() async throws {
        let (host, point) = try vault()
        // The last program is exec'd, as the process suites' are: a SIGKILL landing while the shell
        // forks it can leave a child that never runs and is never confirmed gone.
        let writing = try await Guest.shared.spawn("/bin/sh", ["-c",
            "exec 3>\(point)/n.md; echo a >&3; echo opened; sleep 1; echo b >&3; exec 3>&-; echo closed; exec sleep 300"])
        var lines = writing.lines.makeAsyncIterator()
        let opened = await lines.next()
        XCTAssertEqual(opened, "opened")

        let url = host.appendingPathComponent("n.md")
        let read: String = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var error: NSError?
                var text = "(no access)"
                NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &error) { granted in
                    text = (try? String(contentsOf: granted, encoding: .utf8)) ?? "(unreadable)"
                }
                continuation.resume(returning: text)
            }
        }
        let closed = await lines.next()
        XCTAssertEqual(closed, "closed")
        XCTAssertEqual(read, "a\nb\n", "the read was let in before the guest's write closed")
        _ = await writing.terminate(within: .seconds(5))
        await eventually("the writer ended") { writing.hasExited }
    }

    /// A writer that never lets go, or a file that never comes down, is a failed read at the bound
    /// and never a read of nothing.
    func testAnOpenThatCannotBeCoordinatedFailsAtItsBound() async throws {
        let (host, point) = try vault("never read\n")
        let writer = Writer(host.appendingPathComponent("note.md"))
        let start = ContinuousClock.now
        let cat = try await sh("cat \(point)/note.md")
        let waited = ContinuousClock.now - start
        writer.release.signal()
        XCTAssertNotEqual(cat.status, 0, "the read did not fail")
        XCTAssertEqual(cat.output, "", "a read that could not be coordinated printed text")
        XCTAssertTrue(cat.errors.contains("I/O error"), cat.errors)
        XCTAssertGreaterThanOrEqual(waited, Guest.vaultWait - .seconds(1))
        XCTAssertLessThan(waited, Guest.vaultWait + .seconds(10), "the wait ran on past its bound")
    }

    /// SIGKILL does not wake a host wait, so the wait looks for it: a task parked in a coordination
    /// is ended inside the teardown's bound, and confirmed.
    func testATaskParkedInCoordinationIsEndedWithinTheTeardownBound() async throws {
        let (host, point) = try vault()
        let writer = Writer(host.appendingPathComponent("note.md"))
        defer { writer.release.signal() }
        let cat = try await Guest.shared.spawn("/bin/cat", ["\(point)/note.md"])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(cat.hasExited)
        let start = ContinuousClock.now
        let ending = Task { await cat.terminate(within: .seconds(7)) }
        await eventually("the parked task was ended by its SIGKILL", within: 2) { cat.hasExited }
        XCTAssertEqual(cat.exitStatus, 128 + 9)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        let termination = await ending.value
        XCTAssertTrue(termination.confirmed, "\(termination)")
        XCTAssertLessThan(termination.elapsed, .seconds(7))
        var lines = cat.lines.makeAsyncIterator()
        let printed = await lines.next()
        XCTAssertNil(printed, "the parked cat printed the note")
    }

    /// The wait holds no lock of the kernel's: while one open is parked, other guest programs run
    /// and the same folder is listed and read.
    func testAParkedOpenStallsNoOtherGuestTask() async throws {
        let (host, point) = try vault()
        try Data("other\n".utf8).write(to: host.appendingPathComponent("other.md"))
        let writer = Writer(host.appendingPathComponent("note.md"))
        let parked = try await Guest.shared.spawn("/bin/cat", ["\(point)/note.md"])
        try await Task.sleep(for: .milliseconds(300))

        let start = ContinuousClock.now
        let others = try await sh("ls / > /dev/null && ls \(point) && cat \(point)/other.md")
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        XCTAssertEqual(others.output, "note.md\nother.md\nother\n")
        XCTAssertFalse(parked.hasExited)

        writer.release.signal()
        await eventually("the parked cat finished once the writer let go") { parked.hasExited }
    }

    /// The mirror's baseline is the heads the folder last saw; the guest can neither read nor
    /// change it, and emptying the vault from inside leaves it as it was.
    func testTheMirrorsOwnFolderIsNotTheGuests() async throws {
        let (host, point, baseline) = try vaultWithBaseline()
        let own = host.appendingPathComponent(".topo", isDirectory: true)

        for command in [
            "cat \(point)/.topo/mirror.json",
            "ls \(point)/.topo",
            "touch \(point)/.topo/x",
            "echo {} > \(point)/.topo/mirror.json",
            "mv \(point)/.topo \(point)/topo",
            "mv \(point)/note.md \(point)/.topo/note.md",
            "rmdir \(point)/.topo",
            "rm \(point)/.topo/mirror.json",
            "mkdir \(point)/.topo",
            "echo {} > \(point)/.topo",
            "ln -s note.md \(point)/.topo",
            "mv \(point)/note.md \(point)/.topo",
            "chmod 777 \(point)/.topo",
            "ln \(point)/note.md \(point)/.topo",
            "ln \(point)/.topo/mirror.json \(point)/copy.json",
            "mknod \(point)/.topo p",
            "mkdir \(point)/.topo/made",
        ] {
            let attempt = try await sh(command)
            XCTAssertNotEqual(attempt.status, 0, "the guest reached the mirror's own folder: \(command)")
        }
        // `rm -rf` of a name that is not there is no failure, here as anywhere.
        let removed = try await sh("rm -rf \(point)/.topo")
        XCTAssertEqual(removed.status, 0, removed.errors)
        XCTAssertEqual(removed.errors, "")
        _ = try await sh("rm -rf \(point)/* \(point)/.[!.]*")
        XCTAssertEqual(try Data(contentsOf: own.appendingPathComponent("mirror.json")), baseline)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: own.path), ["mirror.json"])
        XCTAssertFalse(fm.fileExists(atPath: host.appendingPathComponent("note.md").path),
                       "the rest of the vault was not the guest's to empty")
    }

    /// #246: the mirror's folder is hidden, not forbidden. A listing of a healthy vault exits 0
    /// and does not name it, a path under it is no such file, and what would make the name is
    /// refused; `.topo` anywhere but the root is a folder like any other.
    func testTheMirrorsOwnFolderIsHiddenFromAListing() async throws {
        let (host, point, baseline) = try vaultWithBaseline()
        try fm.createDirectory(at: host.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try fm.createDirectory(at: host.appendingPathComponent("notes/.topo"), withIntermediateDirectories: true)
        try Data("deep\n".utf8).write(to: host.appendingPathComponent("notes/.topo/kept.md"))

        let listing = try await sh("ls -la \(point)")
        XCTAssertEqual(listing.status, 0, listing.errors)
        XCTAssertEqual(listing.errors, "")
        XCTAssertFalse(listing.output.contains(".topo"), listing.output)
        XCTAssertTrue(listing.output.contains(".obsidian") && listing.output.contains("note.md"), listing.output)

        let found = try await sh("find \(point)")
        XCTAssertEqual(found.status, 0, found.errors)
        XCTAssertEqual(found.errors, "")
        XCTAssertEqual(found.output.split(separator: "\n").map(String.init).sorted(), [point, "\(point)/.obsidian", "\(point)/note.md", "\(point)/notes", "\(point)/notes/.topo",
                                      "\(point)/notes/.topo/kept.md"])
        let used = try await sh("du -s \(point) > /dev/null")
        XCTAssertEqual(used.status, 0, used.errors)
        let deep = try await sh("cat \(point)/notes/.topo/kept.md && ls -a \(point)/notes")
        XCTAssertEqual(deep.output, "deep\n.\n..\n.topo\n")

        for command in ["cat \(point)/.topo/mirror.json", "ls \(point)/.topo", "stat \(point)/.topo", "rmdir \(point)/.topo",
                        "echo x >> \(point)/.topo/mirror.json", "touch \(point)/.topo/x", "mkdir \(point)/.topo/made",
                        "mv \(point)/.topo \(point)/topo", "ln \(point)/.topo/mirror.json \(point)/copy.json",
                        "mv \(point)/note.md \(point)/.topo/note.md"] {
            let absent = try await sh(command)
            XCTAssertNotEqual(absent.status, 0, command)
            // The shell's own word for `ENOENT` on a redirect is "nonexistent directory".
            XCTAssertTrue(absent.errors.contains("No such file or directory") || absent.errors.contains("nonexistent directory"),
                          "\(command): \(absent.errors)")
        }
        let present = try await sh("[ -e \(point)/.topo ] && echo there || echo absent")
        XCTAssertEqual(present.output, "absent\n")
        for command in ["mkdir \(point)/.topo", "echo {} > \(point)/.topo", "ln -s note.md \(point)/.topo",
                        "ln \(point)/note.md \(point)/.topo", "mknod \(point)/.topo p", "mv \(point)/note.md \(point)/.topo"] {
            let refused = try await sh(command)
            XCTAssertNotEqual(refused.status, 0, command)
            XCTAssertTrue(refused.errors.contains("Permission denied"), "\(command): \(refused.errors)")
        }
        XCTAssertEqual(try Data(contentsOf: host.appendingPathComponent(".topo/mirror.json")), baseline)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: host.appendingPathComponent(".topo").path), ["mirror.json"])
        XCTAssertTrue(fm.fileExists(atPath: host.appendingPathComponent("note.md").path))
    }

    /// The calls BusyBox makes with no `stat` before them — unlink, readlink, utime — each answer
    /// no such file for the mirror's folder and for a name under it.
    func testACallMadeStraightAtTheMirrorsFolderFindsNoSuchFile() async throws {
        let (host, point, baseline) = try vaultWithBaseline()
        let own = host.appendingPathComponent(".topo", isDirectory: true)
        let json = own.appendingPathComponent("mirror.json")
        func facts(_ url: URL) throws -> [String] {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            return ["\(attributes[.posixPermissions] ?? "")", "\(attributes[.modificationDate] ?? "")"]
        }
        let before = try (facts(own), facts(json))

        for command in ["unlink \(point)/.topo", "unlink \(point)/.topo/mirror.json",
                        "readlink -v \(point)/.topo", "readlink -v \(point)/.topo/mirror.json"] {
            let absent = try await sh(command)
            XCTAssertNotEqual(absent.status, 0, command)
            XCTAssertTrue(absent.errors.contains("No such file or directory"), "\(command): \(absent.errors)")
        }
        // `touch -c` sets the times and forgives only no such file: any other answer it says.
        let touched = try await sh("touch -c -d '2001-01-01 00:00:00' \(point)/.topo \(point)/.topo/mirror.json")
        XCTAssertEqual(touched.status, 0, touched.errors)
        XCTAssertEqual(touched.errors, "")
        // The same on a name that is there moves its time, so the option is not what kept these.
        let moved = try await sh("touch -c -d '2001-01-01 00:00:00' \(point)/note.md && stat -c %Y \(point)/note.md")
        XCTAssertEqual(moved.output, "978307200\n", moved.errors)

        XCTAssertEqual(try facts(own), before.0)
        XCTAssertEqual(try facts(json), before.1)
        XCTAssertEqual(try Data(contentsOf: json), baseline)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: own.path), ["mirror.json"])
    }

    /// A vault holding the mirror's baseline, as the mirror leaves it.
    private func vaultWithBaseline() throws -> (host: URL, point: String, baseline: Data) {
        let (host, point) = try vault()
        let own = host.appendingPathComponent(".topo", isDirectory: true)
        try fm.createDirectory(at: own, withIntermediateDirectories: true)
        let baseline = Data(#"{"version":1,"files":{},"heads":{}}"#.utf8)
        try baseline.write(to: own.appendingPathComponent("mirror.json"))
        return (host, point, baseline)
    }

    /// A link the guest makes to the mirror's folder, or to its baseline, reaches neither: not
    /// read through, not written through, not removed through.
    func testALinkToTheMirrorsFolderReachesNothingThroughIt() async throws {
        let (host, point, baseline) = try vaultWithBaseline()
        for command in [
            "cd \(point) && ln -s .topo alias && cat alias/mirror.json",
            "cd \(point) && echo {} > alias/mirror.json",
            "cd \(point) && ln -s .topo/mirror.json m && cat m",
            "cd \(point) && echo {} > m",
            "cd \(point) && rm alias/mirror.json",
            "cd \(point) && mv alias/mirror.json taken.json",
        ] {
            let attempt = try await sh(command)
            XCTAssertNotEqual(attempt.status, 0, "reached the mirror's folder through a link: \(command)")
            XCTAssertFalse(attempt.output.contains("version"), "read the baseline through a link: \(command)")
        }
        XCTAssertEqual(try Data(contentsOf: host.appendingPathComponent(".topo/mirror.json")), baseline)
    }

    /// The guest resolves a path's links before the vault's filesystem sees it, and keeps what it
    /// resolved for a while (per thread, 100 ms), so by the time the host opens the path a folder
    /// in it can have become a link — here to the mirror's folder. A shell reads and writes
    /// `d/mirror.json` in a loop of builtins, one thread, while `d` goes back and forth between a
    /// folder and a link to `.topo` under it: the host follows no link on the way, so the loop never
    /// reads the baseline and never writes it.
    func testAFolderSwappedForALinkUnderTheGuestReachesNothing() async throws {
        let (host, point, baseline) = try vaultWithBaseline()
        let d = host.appendingPathComponent("d").path
        let parked = host.appendingPathComponent("d-parked").path
        XCTAssertEqual(mkdir(d, 0o755), 0)

        // Eight swaps each way, then `stop` in the vault ends the guest's loop.
        let stop = host.appendingPathComponent("stop").path
        let swapping = Task.detached {
            for _ in 0..<8 {
                rename(d, parked)
                symlink(".topo", d)
                usleep(130_000)
                unlink(d)
                rename(parked, d)
                usleep(130_000)
            }
            close(open(stop, O_CREAT | O_WRONLY, 0o644))
        }
        let loop = try await sh("cd \(point) && { i=0; while [ ! -e stop ] && [ $i -lt 200000 ]; do l=; read -r l < d/mirror.json; "
            + "case \"$l\" in *version*) echo \"READ $l\";; esac; echo corrupted > d/mirror.json; i=$((i+1)); done; "
            + "echo \"loops $i\"; } 2>/dev/null")
        await swapping.value
        XCTAssertTrue(loop.output.contains("loops "), loop.output)
        XCTAssertFalse(loop.output.contains("READ"), "the guest read the baseline through a swapped folder: \(loop.output.prefix(200))")
        XCTAssertEqual(try Data(contentsOf: host.appendingPathComponent(".topo/mirror.json")), baseline,
                       "the guest wrote the baseline through a swapped folder")
    }

    /// Sign-out's order in the guest: the resident is ended, and only then is the vault taken away.
    /// The resident here holds a file in the vault open, as Claude Code does mid-Read, so a mount
    /// taken away before its end has answered is refused as busy.
    func testASignOutEndsTheResidentBeforeTheVaultIsTakenAway() async throws {
        let (host, point) = try vault()
        let session = try holdingSession(HoldingLauncher(point: point))
        await session.foreground()
        try await session.ready()
        await eventually("the resident holds a file in the vault") {
            fm.fileExists(atPath: host.appendingPathComponent("holding-1").path)
        }
        XCTAssertThrowsError(try Guest.shared.unmount(point), "the resident did not hold the vault")

        await session.forgetSession()
        XCTAssertNoThrow(try Guest.shared.unmount(point), "the vault was taken away before the resident had ended")
        points.removeAll { $0 == point }

        let outcome = await session.background(budget: .zero)
        if case .ended(_, let termination) = outcome { XCTAssertTrue(termination.confirmed, "\(termination)") }
    }

    /// A sign-out in the foreground starts no replacement before the vault is taken away. Every
    /// process this launcher starts opens a file in the vault, as Claude Code does as soon as it
    /// reads its memory, so a replacement started as the old process's end answered would hold the
    /// mount and the unmount after the sign-out would be refused as busy. The replacement is given
    /// time to have opened its file before the unmount; a `ready()` after the take-away starts one.
    func testASignOutInTheForegroundStartsNoReplacementThatHoldsTheVault() async throws {
        let (host, point) = try vault()
        let launcher = HoldingLauncher(point: point)
        let session = try holdingSession(launcher)
        await session.foreground()
        try await session.ready()
        await eventually("the resident holds a file in the vault") {
            fm.fileExists(atPath: host.appendingPathComponent("holding-1").path)
        }

        await session.forgetSession()
        let replacement = host.appendingPathComponent("holding-2").path
        for _ in 0..<30 where !fm.fileExists(atPath: replacement) {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(launcher.count, 1, "the sign-out launched a replacement before the vault was taken away")
        XCTAssertNoThrow(try Guest.shared.unmount(point), "a replacement held the vault when the sign-out took it away")
        points.removeAll { $0 == point }

        let outcome = await session.background(budget: .zero)
        if case .ended(_, let termination) = outcome { XCTAssertTrue(termination.confirmed, "\(termination)") }
    }

    private func holdingSession(_ launcher: HoldingLauncher) throws -> GuestSession {
        let directory = fm.temporaryDirectory.appendingPathComponent("session-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        hosts.append(directory)
        return GuestSession(launcher: launcher, store: SessionFile(url: directory.appendingPathComponent(".guest-session")))
    }

    /// A folder made again is reached through a mount made again.
    func testUnmountAndMountAgainReachesTheNewFolder() async throws {
        let (_, point) = try vault("a\n")
        let b = fm.temporaryDirectory.appendingPathComponent("vault-b-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        try Data("b\n".utf8).write(to: b.appendingPathComponent("note.md"))
        hosts.append(b)

        XCTAssertThrowsError(try Guest.shared.mountVault(b, at: point)) { error in
            XCTAssertEqual(error as? Guest.Failure, .mount(-16), "a second folder was mounted over the first")
        }
        try Guest.shared.unmount(point)
        try Guest.shared.mountVault(b, at: point)
        let read = try await sh("cat \(point)/note.md; grep -c ' \(point) ' /proc/mounts")
        XCTAssertEqual(read.output, "b\n1\n")
    }

    func testUnmountWhileAGuestHoldsAFileIsRefusedAndTheMountStands() async throws {
        let (_, point) = try vault("held\n")
        let holder = try await Guest.shared.spawn("/bin/sh", ["-c", "exec 3<\(point)/note.md; echo holding; exec sleep 300"])
        var lines = holder.lines.makeAsyncIterator()
        _ = await lines.next()

        XCTAssertThrowsError(try Guest.shared.unmount(point)) { error in
            XCTAssertEqual(error as? Guest.Failure, .unmount(-16), "a mount a guest file holds was taken away")
        }
        let still = try await sh("cat \(point)/note.md")
        XCTAssertEqual(still.output, "held\n")

        _ = await holder.terminate(within: .seconds(5))
        await eventually("the holder ended") { holder.hasExited }
        try Guest.shared.unmount(point)
        points.removeAll { $0 == point }
    }

    /// The app's shape: the vault mounted beside a home and linked into it. A write through the
    /// link lands in the vault, never in the home's own folder under the link's name.
    func testAWriteThroughTheHomesLinkLandsInTheVault() async throws {
        let (vaultHost, point) = try vault()
        let home = fm.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        hosts.append(home)
        let homePoint = "/home-\(UUID().uuidString.prefix(8))"
        try Guest.shared.mount(home, at: homePoint)
        try Guest.shared.link(point, at: "\(homePoint)/memory")

        let wrote = try await sh("cd \(homePoint) && ls > /dev/null && printf 'kept\\n' > memory/p6.md")
        XCTAssertEqual(wrote.status, 0, wrote.errors)
        XCTAssertEqual(try String(contentsOf: vaultHost.appendingPathComponent("p6.md"), encoding: .utf8), "kept\n")
    }
}

/// A resident that holds a file of the vault open, as Claude Code does in the middle of a Read, and
/// says so with a file beside it named for its launch: `holding-1`, `holding-2`, and on.
private final class HoldingLauncher: ResidentLauncher, @unchecked Sendable {
    let point: String
    private let lock = NSLock()
    private var launches = 0

    init(point: String) { self.point = point }

    var count: Int { lock.withLock { launches } }

    func launch(resume session: String?, model: String?, memory: Bool?) async throws -> any ResidentProcess {
        let n = lock.withLock { () -> Int in launches += 1; return launches }
        return try await Guest.shared.spawn("/bin/sh", ["-c", "exec 3<\(point)/note.md; : > \(point)/holding-\(n); exec sleep 300"])
    }
}

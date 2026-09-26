import XCTest
import TopoUserland

/// The memory's folder in the booted guest (`Guest.mountVault`): the guest reads and writes the
/// host's files, every open of a regular file waits for a coordinated writer and a write holds its
/// coordination until the file closes, a wait that cannot end is bounded and a SIGKILL ends it, a
/// parked open stalls nothing else, the mirror's `.topo` is refused, and a mount is taken away
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

    /// Half a note the guest is writing is never read by the mirror: a write open holds its
    /// coordination until the file closes.
    func testAGuestWriteHoldsItsCoordinationUntilClose() async throws {
        let (host, point) = try vault()
        let writing = try await Guest.shared.spawn("/bin/sh", ["-c",
            "exec 3>\(point)/n.md; echo a >&3; echo opened; sleep 1; echo b >&3; exec 3>&-; echo closed; sleep 300"])
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
        XCTAssertLessThan(waited, Guest.vaultWait + .seconds(3))
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
        let termination = await cat.terminate(within: .seconds(7))
        XCTAssertTrue(termination.confirmed, "\(termination)")
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(7))
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
        let (host, point) = try vault()
        let own = host.appendingPathComponent(".topo", isDirectory: true)
        try fm.createDirectory(at: own, withIntermediateDirectories: true)
        let baseline = Data(#"{"version":1,"files":{},"heads":{}}"#.utf8)
        try baseline.write(to: own.appendingPathComponent("mirror.json"))

        for command in [
            "cat \(point)/.topo/mirror.json",
            "ls \(point)/.topo",
            "touch \(point)/.topo/x",
            "echo {} > \(point)/.topo/mirror.json",
            "mv \(point)/.topo \(point)/topo",
            "mv \(point)/note.md \(point)/.topo/note.md",
            "rm -rf \(point)/.topo",
        ] {
            let attempt = try await sh(command)
            XCTAssertNotEqual(attempt.status, 0, "the guest reached the mirror's own folder: \(command)")
        }
        _ = try await sh("rm -rf \(point)/* \(point)/.[!.]*")
        XCTAssertEqual(try Data(contentsOf: own.appendingPathComponent("mirror.json")), baseline)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: own.path), ["mirror.json"])
        XCTAssertFalse(fm.fileExists(atPath: host.appendingPathComponent("note.md").path),
                       "the rest of the vault was not the guest's to empty")
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
        let holder = try await Guest.shared.spawn("/bin/sh", ["-c", "exec 3<\(point)/note.md; echo holding; sleep 300"])
        var lines = holder.lines.makeAsyncIterator()
        _ = await lines.next()

        XCTAssertThrowsError(try Guest.shared.unmount(point)) { error in
            XCTAssertEqual(error as? Guest.Failure, .unmount(-16), "a mount a guest file holds was taken away")
        }
        let still = try await sh("cat \(point)/note.md")
        XCTAssertEqual(still.output, "held\n")

        let termination = await holder.terminate(within: .seconds(5))
        XCTAssertTrue(termination.confirmed, "\(termination)")
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

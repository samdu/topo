import Foundation
import TopoCore
import TopoCoreTesting
import TopoUserland
import XCTest

@testable import Topo

/// A move of the memory while a guest turn is in flight, over a real `GuestSession` with a scripted
/// process, a real `Memory` and its move over temporary folders, and a `VaultMount` whose seam
/// records which folder the guest's mount reaches. The turn's note is written into the folder the
/// mount reaches, as the guest's write would be: the move waits for the turn, so the note is in the
/// folder when the move carries it, and the next turn goes into a mount of the new home.
@MainActor
final class MemoryMoveDuringTurnTests: XCTestCase {
    private let phone = DeviceID("phone")
    private let hub = DeviceID("hub")
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// The folder the guest's mount reaches, as the seam was last told.
    @MainActor
    private final class Mounted {
        var folder: URL?
        var seam: VaultMount.Seam {
            VaultMount.Seam(
                mount: { self.folder = $0 },
                unmount: { self.folder = nil },
                link: {},
                startAccess: { _ in true },
                stopAccess: { _ in },
                identity: { VaultMount.Identity.of($0) },
                makeFolder: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) })
        }
    }

    /// One scripted resident process: what it is sent is ignored, and it answers when told.
    private final class Process: ResidentProcess, @unchecked Sendable {
        let pid: Int32 = 7
        let lines: AsyncStream<String>
        private let continuation: AsyncStream<String>.Continuation
        var errors: String { "" }

        init() { (lines, continuation) = AsyncStream<String>.makeStream() }

        func write(_ line: String) async throws {}
        func emit(_ line: String) { continuation.yield(line) }
        func end(within bound: Duration) async -> GuestProcess.Termination {
            continuation.finish()
            return .init(status: 137, signalled: 1, running: 0, pipesClosed: true)
        }
    }

    private final class Launcher: ResidentLauncher, @unchecked Sendable {
        private let lock = NSLock()
        private var made: [Process] = []
        var last: Process? { lock.withLock { made.last } }

        func launch(resume session: String?, model: String?, memory: Bool?) async throws -> any ResidentProcess {
            let process = Process()
            lock.withLock { made.append(process) }
            return process
        }
    }

    private func text(_ name: String, in folder: URL) -> String? {
        (try? Data(contentsOf: folder.appendingPathComponent(name))).map { String(decoding: $0, as: UTF8.self) }
    }

    func testAMoveDuringATurnWaitsForItAndCarriesWhatTheTurnWrote() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("topo-move-turn-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("Documents/Vault", isDirectory: true)
        let ubiquity = root.appendingPathComponent("Library/Mobile Documents", isDirectory: true)
        let obsidian = ubiquity.appendingPathComponent("iCloud~md~obsidian/Documents/Memory", isDirectory: true)
        try FileManager.default.createDirectory(at: obsidian, withIntermediateDirectories: true)

        let database = InMemoryRecordDatabase()
        let store = MemoryStore(database: database)
        try await store.writer(for: hub).write("eggs", to: VaultPath("Groceries.md")!, continuing: store.read(), at: t0)
        let prefix = ubiquity.standardizedFileURL.path
        let memory = Memory(directory: local, store: MemoryStore(database: database), device: phone,
                            isSignedIn: { true }, bookmarks: InMemoryBookmarkStore(), ubiquityRoot: ubiquity,
                            isUbiquitous: { $0.standardizedFileURL.path.hasPrefix(prefix) },
                            warm: { _ in VaultDownloads.Report() }, ensureZone: {}, now: { [t0] in t0 })
        await memory.sync()
        XCTAssertEqual(text("Groceries.md", in: local), "eggs")

        let mounted = Mounted()
        let vault = VaultMount(seam: mounted.seam)
        let launcher = Launcher()
        let session = GuestSession(launcher: launcher, store: SessionFile(url: root.appendingPathComponent(".guest-session")))
        await session.foreground()
        try await session.ready()

        // The app's wiring: turns sent as `ResidentConversation.send` sends them, and the memory's
        // moves held apart from them.
        let turns = MemoryTurns { session }
        memory.writer = turns
        let reconcile: @MainActor () throws -> Bool = { try vault.reconcile(home: memory.home, local: memory.localDirectory) }
        let updates = try await turns.send("write a note called P6 local", id: "t1", to: session, reconcile: reconcile)
        XCTAssertEqual(mounted.folder, local)
        let turn = Task { for await _ in updates {} }

        // The person moves the memory into iCloud Drive while the turn runs.
        let move = Task { await memory.keepInICloudDrive(obsidian) }
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(memory.moving, "the move did not begin")
        XCTAssertEqual(memory.home, .local, "the move committed while a turn was in flight")
        XCTAssertEqual(text("Groceries.md", in: local), "eggs", "the move emptied the folder a turn's mount reaches")

        // The turn writes its note through the mount it was sent into, then answers.
        let reached = try XCTUnwrap(mounted.folder)
        try? Data("hello".utf8).write(to: reached.appendingPathComponent("P6 local.md"))
        let process = try XCTUnwrap(launcher.last)
        process.emit(#"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"S1"}"#)
        await turn.value

        let refusal = await move.value
        XCTAssertNil(refusal)
        XCTAssertEqual(memory.home.folder?.resolvingSymlinksInPath().path, obsidian.resolvingSymlinksInPath().path)
        XCTAssertEqual(text("P6 local.md", in: obsidian), "hello", "the turn's note did not reach the new home")
        XCTAssertEqual(text("Groceries.md", in: obsidian), "eggs")

        // The next turn goes into a mount of the new home.
        let next = try await turns.send("read it back", id: "t2", to: session, reconcile: reconcile)
        XCTAssertEqual(mounted.folder?.resolvingSymlinksInPath().path, obsidian.resolvingSymlinksInPath().path)
        process.emit(#"{"type":"result","subtype":"success","is_error":false,"result":"hello","session_id":"S1"}"#)
        for await _ in next {}
    }
}

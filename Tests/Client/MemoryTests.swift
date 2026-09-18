import CloudKit
import TopoAuth
import TopoCore
import TopoCoreTesting
import TopoTurn
import XCTest

@testable import Topo

/// The memory on the phone: one mirror, one sync at a time, driven by the app's cues and taken
/// away at a sign-out. Every test here runs over the in-memory database and a directory of its
/// own; nothing touches iCloud.
@MainActor
final class MemoryTests: XCTestCase {
    private let phone = DeviceID("phone")
    private let hub = DeviceID("hub")
    private let note = VaultPath("Meeting notes.md")!
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("topo-memory-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        return url.appendingPathComponent("Vault", isDirectory: true)
    }

    private func memory(_ database: any RecordDatabase, at directory: URL,
                        signedIn: Login = Login()) -> Memory {
        Memory(directory: directory, store: MemoryStore(database: database), device: phone,
               isSignedIn: { signedIn.holds }, ensureZone: {})
    }

    private func text(_ name: String, in directory: URL) -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ text: String, to path: VaultPath, in database: any RecordDatabase,
                       as device: DeviceID, at when: Date) async throws {
        let store = MemoryStore(database: database)
        let writer = try await store.writer(for: device)
        try await writer.write(text, to: path, continuing: store.read(), at: when)
    }

    /// Lets everything that can run, run. Nothing here waits on time or on iCloud, so a
    /// handful of turns is the whole of what any of it needs; this asserts nothing, because
    /// what it is used for is to give a wrong answer its chance to appear.
    private func settle(_ turns: Int = 400) async {
        for _ in 0..<turns { await Task.yield() }
    }

    /// Waits for something the test can observe, failing rather than hanging when it never comes.
    private func eventually(_ what: String, within seconds: TimeInterval = 10,
                            _ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !(await condition()) {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(what)")
                throw Timeout()
            }
            await Task.yield()
        }
    }

    // MARK: One sync at a time

    /// Requests that arrive while a pass is running are one more pass, not a pass each: two
    /// mirrors over one folder would each read what the other was halfway through writing.
    func testRequestsDuringOnePassCoalesceIntoOneMorePass() async throws {
        let gate = GatedDatabase(InMemoryRecordDatabase())
        let directory = makeDirectory()
        let memory = memory(gate, at: directory)

        let first = Task { await memory.sync() }
        try await eventually("the first pass to reach the store") { await gate.waiting == 1 }
        let second = Task { await memory.sync() }
        let third = Task { await memory.sync() }
        try await eventually("both requests to be in") { memory.requests == 3 }

        await gate.release()
        try await eventually("the pass they asked for") { await gate.waiting == 1 }
        XCTAssertEqual(memory.passes, 2, "two requests during one pass ask for one more pass")
        await gate.release()
        await first.value
        await second.value
        await third.value
        XCTAssertEqual(memory.passes, 2)
    }

    // MARK: The cues

    /// The loop is what makes the folder current with no push and no turn: every pass syncs
    /// before it looks for a turn to answer, so a revision written on another device arrives
    /// within the interval and the model is never called for it.
    func testALoopPassBringsARevisionToTheFolderWithNoTurnAndNoModelCall() async throws {
        let db = InMemoryRecordDatabase()
        let directory = makeDirectory()
        let memory = memory(db, at: directory)
        try await write("from the hub", to: note, in: db, as: hub, at: t0)

        let transport = ScriptedTransport()
        let beats = Beats()
        let harness = Harness(database: db, tokens: FixedToken(), device: phone, ensureZone: {},
                              defaults: makeDefaults(), transport: transport,
                              leaseSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
                              pause: { try await beats.pause($0) })
        harness.onPass = { [memory] in await memory.sync() }

        let loop = Task { await harness.answering(every: .seconds(5)) }
        try await eventually("the first pass") { await beats.passes >= 1 }
        loop.cancel()
        await loop.value

        XCTAssertEqual(text("Meeting notes.md", in: directory), "from the hub")
        XCTAssertTrue(transport.sent.isEmpty, "the log held no question, so nothing went to the model")
    }

    /// The order around a turn: the memory goes out before the model is asked, and again once
    /// the reply is in the log.
    func testTheMemorySyncsBeforeTheModelIsAskedAndAgainAfterTheReplyIsWritten() async throws {
        let db = InMemoryRecordDatabase()
        let directory = makeDirectory()
        let memory = memory(db, at: directory)
        let order = Order()

        let transport = ScriptedTransport((200, reply("and hello to you")))
        transport.duringRequest = { await order.add("model") }
        let beats = Beats()
        let harness = Harness(database: db, tokens: FixedToken(), device: phone, ensureZone: {},
                              defaults: makeDefaults(), transport: transport,
                              leaseSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
                              pause: { try await beats.pause($0) })
        harness.onPass = { [memory] in
            await order.add("sync")
            await memory.sync()
        }
        // A limb's turn, waiting in the log for this device to answer.
        let log = TurnLog(database: db)
        let limb = try await log.writer(for: DeviceID("watch"))
        _ = try await limb.append(.person, "hello", continuing: log.read(), at: t0)

        let loop = Task { await harness.answering(every: .seconds(5)) }
        try await eventually("the first pass") { await beats.passes >= 1 }
        loop.cancel()
        await loop.value

        let seen = await order.entries
        XCTAssertEqual(seen, ["sync", "model", "sync"])
        XCTAssertEqual(memory.passes, 2)
    }

    /// And around a turn this phone typed: the reply lands in `run`, not in a pass, so the same
    /// order has to hold for it — the memory out before the model is asked, and again once the
    /// reply is in the log.
    func testATypedTurnSyncsTheMemoryOnceItsReplyIsInTheLog() async throws {
        let db = InMemoryRecordDatabase()
        let directory = makeDirectory()
        let memory = memory(db, at: directory)
        let order = Order()

        let transport = ScriptedTransport((200, reply("and hello to you")))
        transport.duringRequest = { await order.add("model") }
        let beats = Beats()
        let harness = Harness(database: db, tokens: FixedToken(), device: phone, ensureZone: {},
                              defaults: makeDefaults(), transport: transport,
                              leaseSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
                              pause: { try await beats.pause($0) })
        harness.onPass = { [memory] in
            await order.add("sync")
            await memory.sync()
        }

        let loop = Task { await harness.answering(every: .seconds(5)) }
        try await eventually("the first pass") { await beats.passes >= 1 }
        await harness.send("hello")
        loop.cancel()
        await loop.value

        let seen = await order.entries
        XCTAssertEqual(seen, ["sync", "model", "sync"])
    }

    /// The wake follows the login, not the chat: a signed-in phone that never got as far as the
    /// chat screen — a data reset with the keychain login intact — still answers a note push.
    /// Delivering a real one is beyond any suite, since a hand-made push carries no subscription
    /// id; what is held here is that the handler is up while the login is, and that it is this
    /// device's memory it syncs.
    @MainActor
    func testTheNoteWakeIsUpWhileTheLoginIsAndSyncsTheMemory() async throws {
        let db = InMemoryRecordDatabase()
        let directory = makeDirectory()
        let memory = memory(db, at: directory)
        try await write("from the hub", to: note, in: db, as: hub, at: t0)
        defer { MemoryWake.remove() }

        MemoryWake.follow(signedIn: true, memory: memory)
        let handler = try XCTUnwrap(MemoryWake.handler, "the login is held, so the wake is up")
        await handler()
        try await eventually("the pass") { memory.passes >= 1 }
        XCTAssertEqual(text("Meeting notes.md", in: directory), "from the hub")

        MemoryWake.follow(signedIn: false, memory: memory)
        XCTAssertNil(MemoryWake.handler, "the login went, so a push now reaches nothing")
    }

    // MARK: Only while signed in

    /// The cue that arrives whether or not anybody is signed in: a foreground. A phone with
    /// no login keeps no memory, so it makes no folder and runs no pass.
    func testACueOnAPhoneWithNoLoginMakesNoFolder() async throws {
        let db = InMemoryRecordDatabase()
        let directory = makeDirectory()
        let signedOut = Login(false)
        let memory = memory(db, at: directory, signedIn: signedOut)
        try await write("from the hub", to: note, in: db, as: hub, at: t0)

        await memory.sync()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(memory.passes, 0)
        XCTAssertNil(memory.lastSync)
        XCTAssertNil(memory.lastError, "nothing was attempted, so nothing failed")
    }

    /// A sign-out that did not get to the end of itself — the app killed between the login
    /// going and the folder going — settles at the next cue rather than standing, and the
    /// cue does not fill it up first.
    func testACueAfterTheLoginWentTakesTheFolderAway() async throws {
        let db = InMemoryRecordDatabase()
        let directory = makeDirectory()
        let login = Login()
        let memory = memory(db, at: directory, signedIn: login)
        try await write("from the hub", to: note, in: db, as: hub, at: t0)

        await memory.sync()
        XCTAssertEqual(text("Meeting notes.md", in: directory), "from the hub")

        login.holds = false
        await memory.sync()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(memory.passes, 1, "no pass ran without a login")
    }

    // MARK: Sign-out

    /// A sync suspended in its database call when the person signs out writes nothing when it is
    /// released, and the folder it would have written into is gone.
    func testASyncInFlightAtSignOutWritesNothingAndTheFolderGoes() async throws {
        let db = InMemoryRecordDatabase()
        let gate = GatedDatabase(db)
        let directory = makeDirectory()
        let memory = memory(gate, at: directory)
        try await write("from the hub", to: note, in: db, as: hub, at: t0)

        let sync = Task { await memory.sync() }
        try await eventually("the sync to reach the store") { await gate.waiting == 1 }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), "the folder is made up front")

        memory.forget()
        await gate.release()
        await sync.value

        try await eventually("the folder to go") { !FileManager.default.fileExists(atPath: directory.path) }
        XCTAssertNil(text("Meeting notes.md", in: directory))
        XCTAssertNil(memory.lastReport)
        XCTAssertNil(memory.lastSync)
        XCTAssertNil(memory.lastError, "an abandoned sync is not a failure to report")
    }

    /// Sign out and straight back in while a pass is still stopping. The new login's sync
    /// waits for the old one to stop rather than running beside it — so the folder it makes
    /// is made after the sign-out's cleanup, not before it, and stands.
    func testASyncFromBeforeASignOutNeitherRunsBesideNorDeletesTheOneAfterIt() async throws {
        let db = InMemoryRecordDatabase()
        let gate = GatedDatabase(db)
        let directory = makeDirectory()
        let login = Login()
        let memory = memory(gate, at: directory, signedIn: login)
        try await write("from the hub", to: note, in: db, as: hub, at: t0)

        let before = Task { await memory.sync() }
        try await eventually("the first sync to reach the store") { await gate.waiting == 1 }

        login.holds = false
        memory.forget()
        login.holds = true

        // The store is open to whoever asks next, so nothing but the mirror itself keeps the
        // new login's sync from running right now, beside the one that has not stopped.
        await gate.permit()
        let after = Task { await memory.sync() }
        try await eventually("the second sync to ask") { memory.requests == 2 }
        await settle()
        XCTAssertNil(text("Meeting notes.md", in: directory),
                     "the sync after the sign-in ran beside the one before it, over the same folder")

        // The old pass stops here, and the sign-out's cleanup follows it.
        await gate.release()
        await before.value
        await after.value

        XCTAssertEqual(text("Meeting notes.md", in: directory), "from the hub")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path),
                      "the sign-out's cleanup took away the folder the new login made")
    }

    // MARK: A failure at each stage

    /// The store cannot be read: nothing is on disk, no state is left behind, and the error
    /// stands until the next cue retries it.
    func testAFailureReadingTheStoreLeavesTheFolderEmpty() async throws {
        let directory = makeDirectory()
        let memory = memory(UnreachableDatabase(), at: directory)

        await memory.sync()

        XCTAssertNotNil(memory.lastError)
        XCTAssertNil(memory.lastSync)
        XCTAssertNil(text("Meeting notes.md", in: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".topo").path),
                       "a sync that never reached the disk wrote no state")
    }

    /// The disk cannot be written: the file is not there, no state is saved, and the next sync
    /// over a writable folder writes it.
    func testAFailureWritingToDiskLeavesNoStateAndIsRetried() async throws {
        let db = InMemoryRecordDatabase()
        let directory = makeDirectory()
        let memory = memory(db, at: directory)
        try await write("from the hub", to: note, in: db, as: hub, at: t0)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        await memory.sync()

        XCTAssertNotNil(memory.lastError)
        XCTAssertNil(memory.lastSync)
        XCTAssertNil(text("Meeting notes.md", in: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".topo").path))

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        await memory.sync()
        XCTAssertEqual(text("Meeting notes.md", in: directory), "from the hub")
        XCTAssertEqual(memory.lastReport?.written, [note])
        XCTAssertNil(memory.lastError)
    }

    /// The state cannot be saved: what the store holds is on disk, the state file is not, and
    /// the next sync applies the same files again rather than writing a revision of them.
    func testAFailureSavingTheStateLeavesTheFilesAndWritesNoRevision() async throws {
        let db = InMemoryRecordDatabase()
        let directory = makeDirectory()
        let memory = memory(db, at: directory)
        try await write("from the hub", to: note, in: db, as: hub, at: t0)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A file standing where the state's folder has to go, so saving it is what fails.
        try Data().write(to: directory.appendingPathComponent(".topo"))

        await memory.sync()

        XCTAssertNotNil(memory.lastError)
        XCTAssertNil(memory.lastSync)
        XCTAssertEqual(text("Meeting notes.md", in: directory), "from the hub",
                       "the stage it failed at is after the files were written")
        var isFolder: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".topo").path,
                                                     isDirectory: &isFolder))
        XCTAssertFalse(isFolder.boolValue, "nothing of the state was written over it")

        let revisions = try await MemoryStore(database: db).read()
        XCTAssertEqual(revisions.notes.count, 1, "the file on disk is the store's own and no revision of it")
    }

    private func makeDefaults() -> UserDefaults {
        let name = "topo.tests.memory.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }
}

/// `NotePush`, and the delegate's routing of it. What is asserted about a push arriving is the
/// refusal: `CKNotification` has no public initialiser and the remote-notification dictionary is
/// an undocumented shape, so a payload built here proves nothing about one APNs delivers — as
/// `TurnPushTests` says of the same guard. What matters is that neither subscription's handler is
/// reached by anything that is not its own.
final class NotePushTests: XCTestCase {
    func testItAsksForRevisionsAsTheyAreCreated() {
        let subscription = NotePush.subscription()
        XCTAssertEqual(subscription.recordType, Note.recordType)
        XCTAssertTrue(subscription.querySubscriptionOptions.contains(.firesOnRecordCreation))
        // A revision's record is written once and never updated.
        XCTAssertFalse(subscription.querySubscriptionOptions.contains(.firesOnRecordUpdate))
        XCTAssertFalse(subscription.querySubscriptionOptions.contains(.firesOnRecordDeletion))
    }

    func testItIsScopedToTheMemorysZone() {
        XCTAssertEqual(NotePush.subscription().zoneID, TopoCloudKit.zoneID)
    }

    /// A field the schema marks queryable rather than a match-all, which is answered out of the
    /// record name's index the development schema never builds.
    func testItAsksAboutSequenceRatherThanMatchingEverything() {
        let predicate = NotePush.subscription().predicate
        XCTAssertNotEqual(predicate.predicateFormat, NSPredicate(value: true).predicateFormat)
        XCTAssertEqual(predicate.predicateFormat, "sequence > 0")
    }

    func testItIsSilent() {
        let info = NotePush.subscription().notificationInfo
        XCTAssertEqual(info?.shouldSendContentAvailable, true)
        XCTAssertNil(info?.alertBody)
        XCTAssertNil(info?.soundName)
    }

    /// Two subscriptions, two names: a push about a turn and a push about a revision are told
    /// apart by the id they carry and nothing else.
    func testTheTwoSubscriptionsAreNamedApart() {
        XCTAssertEqual(NotePush.subscription().subscriptionID, NotePush.subscriptionID)
        XCTAssertNotEqual(NotePush.subscriptionID, TurnPush.subscriptionID)
    }

    func testAPushThatIsNotOursIsRefused() {
        XCTAssertFalse(NotePush.isOurs([:]))
        XCTAssertFalse(NotePush.isOurs(["aps": ["content-available": 1]]))
        XCTAssertFalse(NotePush.isOurs(["ck": ["ce": 2, "cd": ["sid": TurnPush.subscriptionID]]]))
    }

    /// A push that is neither subscription's reaches neither handler, however many are installed.
    @MainActor
    func testAPushThatIsNobodysWakesNothing() async {
        let woken = Woken()
        PushWake.install { await woken.add("turn") }
        MemoryWake.install { await woken.add("note") }
        defer { PushWake.remove(); MemoryWake.remove() }

        let delegate = TopoAppDelegate()
        let result = await delegate.application(UIApplication.shared,
                                                didReceiveRemoteNotification: ["aps": ["content-available": 1]])

        XCTAssertEqual(result, .noData)
        let seen = await woken.entries
        XCTAssertEqual(seen, [])
    }
}

// MARK: - Doubles

/// A database that parks every read of the change feed until it is let through, so a test can
/// hold a sync at the moment it is waiting on the store. `release` lets a read that is already
/// parked go on; `permit` lets the next read to arrive pass without parking at all, which is
/// how one sync is held while another is let run.
private actor GatedDatabase: RecordDatabase {
    private let inner: InMemoryRecordDatabase
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var permits = 0
    private(set) var waiting = 0

    init(_ inner: InMemoryRecordDatabase) { self.inner = inner }

    func permit() { permits += 1 }

    func release() {
        guard !parked.isEmpty else { return }
        waiting -= 1
        parked.removeFirst().resume()
    }

    func save(_ records: [Record]) async throws -> [Record] { try await inner.save(records) }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await inner.fetch(ids) }
    func query(_ query: RecordQuery) async throws -> [Record] { try await inner.query(query) }

    func records(ofType type: String) async throws -> [Record] {
        if permits > 0 {
            permits -= 1
        } else {
            waiting += 1
            await withCheckedContinuation { parked.append($0) }
        }
        return try await inner.records(ofType: type)
    }
}

/// A database that cannot be reached at all.
private struct UnreachableDatabase: RecordDatabase {
    private struct Offline: Error {}
    func save(_ records: [Record]) async throws -> [Record] { throw RecordDatabaseError.unavailable(underlying: Offline()) }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { throw RecordDatabaseError.unavailable(underlying: Offline()) }
    func query(_ query: RecordQuery) async throws -> [Record] { throw RecordDatabaseError.unavailable(underlying: Offline()) }
    func records(ofType type: String) async throws -> [Record] { throw RecordDatabaseError.unavailable(underlying: Offline()) }
}

/// Whether this device holds a login, which a test moves under the mirror's feet.
final class Login: @unchecked Sendable {
    var holds: Bool
    init(_ holds: Bool = true) { self.holds = holds }
}

/// What happened, in order.
private actor Order {
    private(set) var entries: [String] = []
    func add(_ what: String) { entries.append(what) }
}

private actor Woken {
    private(set) var entries: [String] = []
    func add(_ what: String) { entries.append(what) }
}

/// The answering loop's pause, counted and let through by hand. A cancelled pause throws, as a
/// real sleep does, or the loop's task would never return.
private actor Beats {
    private(set) var passes = 0
    private var permits = 0
    private var waiter: CheckedContinuation<Void, any Error>?

    func pause(_ interval: Duration) async throws {
        passes += 1
        try Task.checkCancellation()
        if permits > 0 {
            permits -= 1
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter = $0 }
        } onCancel: {
            Task { await self.release() }
        }
    }

    func tick() {
        if let waiter {
            self.waiter = nil
            waiter.resume()
        } else {
            permits += 1
        }
    }

    private func release() {
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }
}

private struct Timeout: Error {}

/// The Messages API's far end: answers from a queue and records what each request carried.
private final class ScriptedTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(Int, String)]
    private var _sent: [[String]] = []
    /// Runs while a request is in flight, before its answer.
    var duringRequest: (@Sendable () async -> Void)?

    init(_ replies: (Int, String)...) { self.replies = replies }

    var sent: [[String]] { lock.withLock { _sent } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let contents = (body?["messages"] as? [[String: Any]])?.compactMap { $0["content"] as? String } ?? []
        lock.withLock { _sent.append(contents) }
        await duringRequest?()
        return lock.withLock {
            let (status, text) = replies.isEmpty ? (500, "{}") : replies.removeFirst()
            return (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

private func reply(_ text: String) -> String {
    #"{"id":"msg","type":"message","model":"claude-haiku-4-5","content":[{"type":"text","text":"\#(text)"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#
}

private struct FixedToken: TokenProvider {
    func accessToken() async throws -> String { "tok" }
}

import TopoCore
import TopoCoreTesting
import XCTest

@testable import Topo

/// The in-memory store, refusing saves or deletes while told to, as iCloud does with no network.
private actor Outage: ZoneDatabase {
    let inner = InMemoryRecordDatabase()
    var saves = false
    var deletes = false
    /// Whether the zone is there, as it is not on an account nothing has written to yet.
    var zone = true
    private(set) var zonesMade = 0

    func removeZone() { zone = false }
    func makeZone() { zone = true; zonesMade += 1 }

    func fail(saves: Bool, deletes: Bool) {
        self.saves = saves
        self.deletes = deletes
    }

    private func check(_ failing: Bool) throws {
        if !zone { throw RecordDatabaseError.unavailable(underlying: URLError(.resourceUnavailable)) }
        if failing { throw RecordDatabaseError.unavailable(underlying: URLError(.notConnectedToInternet)) }
    }

    func save(_ records: [Record]) async throws -> [Record] { try check(saves); return try await inner.save(records) }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await inner.fetch(ids) }
    func query(_ query: RecordQuery) async throws -> [Record] { try await inner.query(query) }
    func records(ofType type: String) async throws -> [Record] { try await inner.records(ofType: type) }
    func delete(_ ids: [RecordID]) async throws { try check(deletes); try await inner.delete(ids) }
    func changes(ofType type: String, since token: Data?) async throws -> RecordChanges {
        try await inner.changes(ofType: type, since: token)
    }
}

/// Review Focus 2 and 8 of widgets B, the phone's half: each slot's record follows its file, what
/// did not reach iCloud is sent again, and a sign-out takes every record.
@MainActor
final class SurfaceSyncTests: XCTestCase {
    private var folder: URL!
    private var store: SurfaceStore!
    private var database: Outage!
    private var reloader: SurfaceReloader!
    private var sync: SurfaceSync!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("surface-sync-\(UUID().uuidString)")
        store = SurfaceStore(folder: folder)
        database = Outage()
        reloader = SurfaceReloader(reloadKind: { _ in }, reloadEverything: {}, schedule: { _, _ in })
        sync = makeSync(defaults: UserDefaults(suiteName: "surface-sync-\(UUID().uuidString)")!)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeSync(defaults: UserDefaults, runner: String = "phone-1", store: SurfaceStore? = nil,
                          mayOwn: @escaping @Sendable () async throws -> Bool = { true }) -> SurfaceSync {
        let database = database!, store = store ?? self.store!
        return SurfaceSync(records: { SurfaceRecords(database: database) }, ensureZone: { await database.makeZone() },
                           mayOwn: mayOwn, store: { store }, runner: runner,
                           defaults: defaults, reloader: reloader, now: { Date(timeIntervalSince1970: 100) })
    }

    private func write(_ slot: String, _ text: String = "Hi") throws -> Int {
        try store.write(WidgetDocument.read(#"{"families": {"default": {"kind": "text", "text": "\#(text)"}}}"#).document, slot: slot)
    }

    private func stored(_ slot: String) async -> Record? {
        await database.inner.current(SurfaceRecord.id(slot: slot))
    }

    func testAWriteSavesTheSlotsRecord() async throws {
        let revision = try write("weather")
        try store.writeImage(Data([0x89, 1]), slot: "weather", name: "sky")
        sync.changed(slot: "weather")
        await sync.flush()
        let found = await stored("weather")
        let record = try XCTUnwrap(found)
        let surface = try XCTUnwrap(SurfaceRecord(record))
        XCTAssertEqual(surface.revision, revision)
        XCTAssertEqual(surface.runner, "phone-1")
        XCTAssertEqual(surface.images, ["sky": Data([0x89, 1])])
        XCTAssertEqual(surface.document, store.read(slot: "weather")?.document.text)
        XCTAssertEqual(sync.pending, [])
    }

    /// No network at the write: the file is written, the slot waits, and the next write sends it.
    func testAFailedSaveIsRetriedAtTheNextWrite() async throws {
        await database.fail(saves: true, deletes: false)
        _ = try write("weather")
        sync.changed(slot: "weather")
        await sync.flush()
        let missing = await stored("weather")
        XCTAssertNil(missing)
        XCTAssertEqual(sync.pending, ["weather"], "a save that failed was forgotten")
        await database.fail(saves: false, deletes: false)
        _ = try write("tides")
        sync.changed(slot: "tides")
        await sync.flush()
        let weather = await stored("weather"), tides = await stored("tides")
        XCTAssertNotNil(weather, "the waiting slot was not sent with the next write")
        XCTAssertNotNil(tides)
        XCTAssertEqual(sync.pending, [])
    }

    /// What is owed outlives the process: a new launch's sync, reading the same defaults, sends it.
    func testAFailedSaveIsRetriedAtTheNextLaunch() async throws {
        let defaults = UserDefaults(suiteName: "surface-sync-\(UUID().uuidString)")!
        let first = makeSync(defaults: defaults)
        await database.fail(saves: true, deletes: false)
        _ = try write("weather")
        first.changed(slot: "weather")
        await first.flush()
        await database.fail(saves: false, deletes: false)
        let relaunched = makeSync(defaults: defaults)
        XCTAssertEqual(relaunched.pending, ["weather"])
        await relaunched.flush()
        let saved = await stored("weather")
        XCTAssertNotNil(saved)
    }

    func testAClearDeletesTheRecord() async throws {
        _ = try write("weather")
        sync.changed(slot: "weather")
        await sync.flush()
        try store.remove(slot: "weather")
        sync.cleared(slot: "weather")
        await sync.flush()
        let gone = await stored("weather")
        XCTAssertNil(gone)
    }

    /// A document that cannot be read just now is not a slot cleared: its record stays, and the
    /// slot waits for the next try. Only a clear deletes.
    func testAnUnreadableDocumentIsNotACleared() async throws {
        _ = try write("weather")
        sync.changed(slot: "weather")
        await sync.flush()
        let before = await stored("weather")
        try Data("{ half a document".utf8).write(to: store.url(slot: "weather"))
        sync.changed(slot: "weather")
        await sync.flush()
        let after = await stored("weather")
        XCTAssertNotNil(after, "a document that could not be read deleted the slot's record")
        XCTAssertEqual(after, before)
        XCTAssertEqual(sync.pending, ["weather"], "the slot was taken off the waiting list with nothing sent")

        _ = try write("weather")
        await sync.flush()
        XCTAssertEqual(sync.pending, [])
    }

    /// A save is of the whole slot: an image that cannot be read just now leaves the record as it
    /// was and the save owed, never a record without the image.
    func testAnUnreadableImageKeepsTheSaveOwed() async throws {
        _ = try write("weather")
        try store.writeImage(Data([0x89, 1]), slot: "weather", name: "sky")
        sync.changed(slot: "weather")
        await sync.flush()
        let before = await stored("weather")

        let revision = try write("weather", "rain")
        let sky = store.image(slot: "weather", name: "sky").path
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: sky)
        sync.changed(slot: "weather")
        await sync.flush()
        let after = await stored("weather")
        XCTAssertEqual(after, before, "a record was saved without the image the slot holds")
        XCTAssertEqual(sync.pending, ["weather"])

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sky)
        await sync.flush()
        let saved = await stored("weather")
        let surface = try XCTUnwrap(saved.flatMap(SurfaceRecord.init))
        XCTAssertEqual(surface.revision, revision)
        XCTAssertEqual(surface.images, ["sky": Data([0x89, 1])])
        XCTAssertEqual(sync.pending, [])
    }

    /// The record mirrors the file: a save owed for a slot whose document has gone deletes it.
    func testASaveForAGoneDocumentDeletesTheRecord() async throws {
        _ = try write("weather")
        sync.changed(slot: "weather")
        await sync.flush()
        try store.remove(slot: "weather")
        sync.changed(slot: "weather")
        await sync.flush()
        let gone = await stored("weather")
        XCTAssertNil(gone, "a record outlived its slot's file")
        XCTAssertEqual(sync.pending, [])
    }

    /// A fresh account has no zone until something writes one; a widget can be the first.
    func testTheZoneIsMadeBeforeTheFirstSave() async throws {
        await database.removeZone()
        _ = try write("weather")
        sync.changed(slot: "weather")
        await sync.flush()
        let saved = await stored("weather")
        XCTAssertNotNil(saved, "a save on an account with no zone never made one")
        XCTAssertEqual(sync.pending, [])
    }

    /// A second write to a slot whose save is in flight, owed while the save's answer is already
    /// queued ahead of the flush it asks for: the pass must not settle the slot on the first
    /// write's save.
    func testASecondWriteDuringASaveIsNotSettledAway() async throws {
        let gate = Gate()
        await database.inner.setBeforeSave { _ in await gate.wait() }
        _ = try write("weather", "one")
        sync.changed(slot: "weather")
        for _ in 0..<2000 where !gate.isWaiting { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(gate.isWaiting)
        let second = try write("weather", "two")
        gate.open()
        usleep(300_000) // the main actor busy while the save lands, so its answer queues first
        sync.changed(slot: "weather")
        await database.inner.setBeforeSave { _ in }
        try await Task.sleep(for: .milliseconds(300))
        await sync.flush()
        let saved = await stored("weather")
        XCTAssertEqual(saved.flatMap(SurfaceRecord.init)?.revision, second, "the second write was settled on the first's save")
        XCTAssertEqual(sync.pending, [])
    }

    /// A save owed before the write, and a process ended before `changed`: the relaunch still
    /// sends what the file holds.
    func testASaveOwedBeforeTheWriteOutlivesTheProcess() async throws {
        let defaults = UserDefaults(suiteName: "surface-sync-\(UUID().uuidString)")!
        makeSync(defaults: defaults).expect(slot: "weather")
        let revision = try write("weather")
        let relaunched = makeSync(defaults: defaults)
        XCTAssertEqual(relaunched.owed, ["weather": .save])
        await relaunched.flush()
        let saved = await stored("weather")
        XCTAssertEqual(saved.flatMap(SurfaceRecord.init)?.revision, revision)
    }

    /// Revisions are each phone's own: a record another runner left at a higher revision is
    /// replaced, not kept over this phone's document.
    func testAnotherRunnersHigherRevisionIsReplaced() async throws {
        let old = SurfaceRecord(slot: "weather", document: "{}", revision: 5, updated: Date(), runner: "phone-0")
        _ = try await SurfaceRecords(database: database).save(old)
        let revision = try write("weather", "new")
        sync.changed(slot: "weather")
        await sync.flush()
        let surface = await stored("weather").flatMap(SurfaceRecord.init)
        XCTAssertEqual(surface?.revision, revision)
        XCTAssertEqual(surface?.runner, "phone-1")
        XCTAssertEqual(sync.pending, [])
    }

    /// Phone B took over; phone A, demoted, signs out. A's records go and B's stay, and B's next
    /// sweep takes what A left; A, its role record a viewer's, sweeps nothing.
    func testADemotedPhonesSignOutLeavesTheNewPrimarysRecords() async throws {
        let storeB = SurfaceStore(folder: folder.appendingPathComponent("b"))
        defer { try? FileManager.default.removeItem(at: storeB.folder) }
        let a = makeSync(defaults: UserDefaults(suiteName: "surface-sync-a-\(UUID().uuidString)")!, runner: "phone-A",
                         mayOwn: { false })
        let b = makeSync(defaults: UserDefaults(suiteName: "surface-sync-b-\(UUID().uuidString)")!, runner: "phone-B", store: storeB)
        _ = try write("weather")
        _ = try write("lamp")
        a.changed(slot: "weather")
        a.changed(slot: "lamp")
        await a.flush()
        _ = try storeB.write(WidgetDocument.read(#"{"families": {"default": {"kind": "text", "text": "B"}}}"#).document, slot: "tides")
        b.changed(slot: "tides")
        await b.flush()

        a.sweep()
        await a.flush()
        let beforeSignOut = await stored("tides")
        XCTAssertNotNil(beforeSignOut, "a demoted phone swept the new primary's record")

        await database.fail(saves: false, deletes: true)
        a.forget()
        await a.flush()
        await database.fail(saves: false, deletes: false)
        // One sign-out delete refused, then allowed: A's records all go at its next pass.
        await a.flush()
        let tides = await stored("tides"), weather = await stored("weather"), lamp = await stored("lamp")
        XCTAssertNotNil(tides, "a demoted phone's sign-out deleted the new primary's record")
        XCTAssertNil(weather)
        XCTAssertNil(lamp)
        XCTAssertEqual(b.pending, [])

        // A leaves a record behind it never signs out of: B's sweep takes it.
        let left = SurfaceRecord(slot: "left", document: "{}", revision: 1, updated: Date(), runner: "phone-A")
        _ = try await SurfaceRecords(database: database).save(left)
        b.sweep()
        await b.flush()
        let gone = await stored("left"), kept = await stored("tides")
        XCTAssertNil(gone, "the primary's sweep left another runner's record")
        XCTAssertNotNil(kept)
    }

    /// A sweep asked for and not yet run when the login ends takes nothing: a signed-out phone
    /// owns nothing.
    func testASignOutCancelsASweep() async throws {
        let other = SurfaceRecord(slot: "tides", document: "{}", revision: 1, updated: Date(), runner: "phone-B")
        _ = try await SurfaceRecords(database: database).save(other)
        sync.sweep()
        sync.forget()
        await sync.flush()
        let kept = await stored("tides")
        XCTAssertNotNil(kept, "a signed-out phone swept another phone's record")
    }

    /// A sign-out's deletes go before anything the next login saves.
    func testASignOutDeletesBeforeTheNextLoginSaves() async throws {
        _ = try write("weather")
        sync.changed(slot: "weather")
        await sync.flush()
        await database.fail(saves: false, deletes: true)
        sync.forget()
        await sync.flush()
        await database.fail(saves: false, deletes: false)
        _ = try write("tides")
        sync.changed(slot: "tides")
        await sync.flush()
        let weather = await stored("weather"), tides = await stored("tides")
        XCTAssertNil(weather)
        XCTAssertNotNil(tides, "the sign-out's owed delete took the next login's record")
    }

    /// A write landing after the running pass's last look for more, before the loop lets go, gets
    /// a pass of its own rather than waiting on the one that has ended.
    func testAWriteAtTheEndOfAPassIsNotLeftWaiting() async throws {
        _ = try write("weather")
        _ = try write("tides")
        var landed = false
        sync.afterPass = { [unowned self] in
            guard !landed else { return }
            landed = true
            sync.changed(slot: "tides")
        }
        sync.changed(slot: "weather")
        await sync.flush()
        var tides = await stored("tides")
        for _ in 0..<200 where tides == nil {
            await Task.yield()
            tides = await stored("tides")
        }
        XCTAssertNotNil(tides, "a write at the end of a pass was left waiting for an unrelated trigger")
        XCTAssertEqual(sync.pending, [])
    }

    /// A sign-out whose deletes iCloud refused deletes them at the next sign-in, before anything
    /// of the new login is saved.
    func testARefusedDeleteIsRetriedAtSignIn() async throws {
        _ = try write("weather")
        sync.changed(slot: "weather")
        await sync.flush()
        await database.fail(saves: false, deletes: true)
        reloader.forget(store)
        await sync.flush()
        XCTAssertTrue(sync.owesForget)
        let kept = await stored("weather")
        XCTAssertNotNil(kept, "the delete was refused, so the record is still there")
        await database.fail(saves: false, deletes: false)
        await sync.flush()
        let gone = await stored("weather")
        XCTAssertNil(gone, "the owed delete was not made at the next sign-in")
        XCTAssertFalse(sync.owesForget)
    }

    /// A sign-out drops what the ended login still owed: none of its slots is saved afterwards.
    func testASignOutSavesNothingTheLoginOwed() async throws {
        await database.fail(saves: true, deletes: false)
        _ = try write("weather")
        sync.changed(slot: "weather")
        await sync.flush()
        reloader.forget(store)
        await database.fail(saves: false, deletes: false)
        await sync.flush()
        XCTAssertEqual(sync.pending, [])
        let none = await stored("weather")
        XCTAssertNil(none)
    }
}

/// Holds a save until opened; `open` is synchronous, so a test can open it and keep the main
/// actor busy while the save's answer queues.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?

    var isWaiting: Bool { lock.withLock { waiter != nil } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock { () -> Bool in
                if opened { return true }
                waiter = continuation
                return false
            }
            if now { continuation.resume() }
        }
    }

    func open() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            opened = true
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume()
    }
}

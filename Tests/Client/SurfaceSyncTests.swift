import TopoCore
import TopoCoreTesting
import XCTest

@testable import Topo

/// The in-memory store, refusing saves or deletes while told to, as iCloud does with no network.
private actor Outage: ZoneDatabase {
    let inner = InMemoryRecordDatabase()
    var saves = false
    var deletes = false

    func fail(saves: Bool, deletes: Bool) {
        self.saves = saves
        self.deletes = deletes
    }

    private func check(_ failing: Bool) throws {
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

    private func makeSync(defaults: UserDefaults) -> SurfaceSync {
        let database = database!, store = store!
        return SurfaceSync(records: { SurfaceRecords(database: database) }, store: { store }, runner: "phone-1",
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
        sync.changed(slot: "weather")
        await sync.flush()
        let gone = await stored("weather")
        XCTAssertNil(gone)
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

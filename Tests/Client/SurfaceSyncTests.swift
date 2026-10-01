import TopoCore
import TopoCoreTesting
import XCTest

@testable import Topo

/// The in-memory store, refusing saves or clears while told to, as iCloud does with no network. A
/// clear is a save of a tombstone, so `deletes` refuses those.
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

    func save(_ records: [Record]) async throws -> [Record] {
        try check(records.contains { $0.fields["cleared"] != nil } ? deletes : saves)
        return try await inner.save(records)
    }
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
                          mayOwn: @escaping @Sendable () async throws -> Bool = { true },
                          demoted: @escaping @Sendable (String) async throws -> Bool = { _ in true }) -> SurfaceSync {
        let database = database!, store = store ?? self.store!
        return SurfaceSync(records: { SurfaceRecords(database: database) }, ensureZone: { await database.makeZone() },
                           mayOwn: mayOwn, demoted: demoted, store: { store }, runner: runner,
                           defaults: defaults, reloader: reloader, now: { Date(timeIntervalSince1970: 100) })
    }

    private func write(_ slot: String, _ text: String = "Hi") throws -> Int {
        try store.write(WidgetDocument.read(#"{"families": {"default": {"kind": "text", "text": "\#(text)"}}}"#).document, slot: slot)
    }

    /// The slot's record while it holds the slot; a tombstone is no record.
    private func stored(_ slot: String) async -> Record? {
        let record = await database.inner.current(SurfaceRecord.id(slot: slot))
        return SurfaceRecords.Read(record).holds ? record : nil
    }

    /// Another phone's save, as its `SurfaceSync` makes it: over what it read.
    private func save(_ surface: SurfaceRecord) async throws {
        let records = SurfaceRecords(database: database)
        try await records.save(surface, over: records.read(slot: surface.slot))
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

    func testAClearTombstonesTheRecord() async throws {
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
    func testASaveForAGoneDocumentClearsTheRecord() async throws {
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
        for _ in 0..<10_000 where !gate.isWaiting { try await Task.sleep(for: .milliseconds(1)) }
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
        try await save(old)
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
        let role = Role()
        let a = makeSync(defaults: UserDefaults(suiteName: "surface-sync-a-\(UUID().uuidString)")!, runner: "phone-A",
                         mayOwn: { role.primary })
        let b = makeSync(defaults: UserDefaults(suiteName: "surface-sync-b-\(UUID().uuidString)")!, runner: "phone-B", store: storeB)
        _ = try write("weather")
        _ = try write("lamp")
        a.changed(slot: "weather")
        a.changed(slot: "lamp")
        await a.flush()
        role.primary = false
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
        try await save(left)
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
        try await save(other)
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

    // MARK: A takeover landing between a read and the write made from it

    /// The first save of this phone's (runner phone-1) that `matches` runs `meanwhile` before its
    /// tag is checked: another phone's write, or a takeover, landing between the read the pass
    /// made and its compare-and-set.
    private func interleave(when matches: @escaping @Sendable (Record) -> Bool,
                            _ meanwhile: @escaping @Sendable (SurfaceRecords) async -> Void) async {
        let once = Once()
        let records = SurfaceRecords(database: database.inner)
        await database.inner.setBeforeSave { saving in
            guard saving.contains(where: { $0.fields["runner"] == .string("phone-1") && matches($0) }), once.first() else { return }
            await meanwhile(records)
        }
    }

    private nonisolated static func tombstone(_ record: Record) -> Bool { record.fields["cleared"] != nil }

    /// The new primary's save, over what it read.
    private nonisolated static func primarySaves(_ slot: String, _ records: SurfaceRecords) async {
        let surface = SurfaceRecord(slot: slot, document: "{B}", revision: 1, updated: Date(), runner: "phone-B")
        _ = try? await records.save(surface, over: records.read(slot: slot))
    }

    private func assertThePrimarys(_ slot: String, file: StaticString = #filePath, line: UInt = #line) async {
        let surface = await stored(slot).flatMap(SurfaceRecord.init)
        XCTAssertEqual(surface?.runner, "phone-B", "the new primary's record did not survive", file: file, line: line)
        XCTAssertEqual(surface?.document, "{B}", file: file, line: line)
    }

    /// A sign-out read its own record, and the new primary saved the slot before the clear: the
    /// clear is refused for its tag and dropped, since the record is no longer this phone's.
    func testASignOutLeavesARecordSavedSinceItsRead() async throws {
        _ = try write("weather")
        sync.changed(slot: "weather")
        await sync.flush()
        await interleave(when: Self.tombstone) { await Self.primarySaves("weather", $0) }
        sync.forget()
        await sync.flush()
        await assertThePrimarys("weather")
        XCTAssertFalse(sync.owesForget)
    }

    /// The sweep read a leftover record and its role, and a takeover demoted this phone and the
    /// new primary saved the slot before the clear: the clear is refused, the record read again
    /// is another phone's, and the role read after it says viewer, so it is left.
    func testASweepLeavesARecordSavedSinceItsRead() async throws {
        let role = Role()
        let sync = makeSync(defaults: UserDefaults(suiteName: "surface-sync-\(UUID().uuidString)")!, mayOwn: { role.primary })
        try await save(SurfaceRecord(slot: "tides", document: "{}", revision: 3, updated: Date(), runner: "phone-0"))
        await interleave(when: Self.tombstone) {
            role.primary = false
            await Self.primarySaves("tides", $0)
        }
        sync.sweep()
        await sync.flush()
        await assertThePrimarys("tides")
    }

    /// An owed save in flight when a takeover demotes this phone and the new primary saves the
    /// slot: the save is refused for its tag, the role read again says viewer, and it is dropped.
    func testAnOwedSaveInFlightLeavesTheNewPrimarysRecord() async throws {
        let role = Role()
        let sync = makeSync(defaults: UserDefaults(suiteName: "surface-sync-\(UUID().uuidString)")!, mayOwn: { role.primary })
        _ = try write("weather")
        await interleave(when: { !Self.tombstone($0) }) {
            role.primary = false
            await Self.primarySaves("weather", $0)
        }
        sync.changed(slot: "weather")
        await sync.flush()
        await assertThePrimarys("weather")
        XCTAssertEqual(sync.pending, [], "a demoted phone kept a save owed over another phone's record")
    }

    /// An owed clear in flight when a takeover demotes this phone and the new primary saves the
    /// slot: the clear is refused for its tag and dropped.
    func testAnOwedClearInFlightLeavesTheNewPrimarysRecord() async throws {
        let role = Role()
        let sync = makeSync(defaults: UserDefaults(suiteName: "surface-sync-\(UUID().uuidString)")!, mayOwn: { role.primary })
        _ = try write("weather")
        sync.changed(slot: "weather")
        await sync.flush()
        try store.remove(slot: "weather")
        await interleave(when: Self.tombstone) {
            role.primary = false
            await Self.primarySaves("weather", $0)
        }
        sync.cleared(slot: "weather")
        await sync.flush()
        await assertThePrimarys("weather")
        XCTAssertEqual(sync.pending, [])
    }

    /// The other way round: this phone is the primary, and a demoted phone's stale save lands
    /// between the primary's read and its save. The primary's save is refused, read again and
    /// made again, and the primary's record is the one left.
    func testThePrimaryWinsOverAStaleSaveBetweenItsReadAndItsWrite() async throws {
        let revision = try write("weather")
        await interleave(when: { _ in true }) { records in
            let stale = SurfaceRecord(slot: "weather", document: "{A}", revision: 9, updated: Date(), runner: "phone-0")
            _ = try? await records.save(stale, over: records.read(slot: "weather"))
        }
        sync.changed(slot: "weather")
        await sync.flush()
        let surface = await stored("weather").flatMap(SurfaceRecord.init)
        XCTAssertEqual(surface?.runner, "phone-1")
        XCTAssertEqual(surface?.revision, revision)
        XCTAssertEqual(sync.pending, [])
    }

    /// A takeover landing between the role read and the save: the save lands, the role read after
    /// it says viewer, and the phone clears its own write under that write's tag.
    func testASaveMadeAsTheRoleFlippedIsUndone() async throws {
        let role = Role()
        let sync = makeSync(defaults: UserDefaults(suiteName: "surface-sync-\(UUID().uuidString)")!, mayOwn: { role.primary })
        _ = try write("weather")
        await interleave(when: { !Self.tombstone($0) }) { _ in role.primary = false }
        sync.changed(slot: "weather")
        await sync.flush()
        let left = await stored("weather")
        XCTAssertNil(left, "a demoted phone's save outlived the takeover")
        let cleared = await database.inner.current(SurfaceRecord.id(slot: "weather"))
        XCTAssertEqual(cleared?.fields["runner"], .string("phone-1"))
        XCTAssertEqual(sync.pending, [])
    }

    /// The same, with the new primary's save landing between that save and its undo: the undo is
    /// refused for its tag and dropped, and the new primary's record stays.
    func testAnUndoLeavesTheNewPrimarysRecord() async throws {
        let role = Role()
        let sync = makeSync(defaults: UserDefaults(suiteName: "surface-sync-\(UUID().uuidString)")!, mayOwn: { role.primary })
        _ = try write("weather")
        let once = Once(), records = SurfaceRecords(database: database.inner)
        await database.inner.setBeforeSave { saving in
            guard let mine = saving.first(where: { $0.fields["runner"] == .string("phone-1") }) else { return }
            if !Self.tombstone(mine) {
                role.primary = false
            } else if once.first() {
                await Self.primarySaves("weather", records)
            }
        }
        sync.changed(slot: "weather")
        await sync.flush()
        await assertThePrimarys("weather")
        XCTAssertEqual(sync.pending, [])
    }

    /// This phone's own newer save lands between a pass's read and its write (another pass of the
    /// same install): the write is refused, and judged again against what the server holds, which
    /// keeps the newer.
    func testASaveRefusedForItsTagIsJudgedAgainstTheServersRevision() async throws {
        let revision = try write("weather")
        await interleave(when: { _ in true }) { records in
            let newer = SurfaceRecord(slot: "weather", document: "{newer}", revision: revision + 5, updated: Date(), runner: "phone-1")
            _ = try? await records.save(newer, over: records.read(slot: "weather"))
        }
        sync.changed(slot: "weather")
        await sync.flush()
        let surface = await stored("weather").flatMap(SurfaceRecord.init)
        XCTAssertEqual(surface?.revision, revision + 5, "an older save replaced the newer one it raced")
        XCTAssertEqual(sync.pending, [])
    }

    /// An older save of its own lands between the read and the write: the write is refused, read
    /// again, and made over it.
    func testARaceWithAnOlderWriterStillSaves() async throws {
        _ = try write("weather")
        let revision = try write("weather", "later")
        await interleave(when: { _ in true }) { records in
            let older = SurfaceRecord(slot: "weather", document: "{older}", revision: revision - 1, updated: Date(), runner: "phone-1")
            _ = try? await records.save(older, over: records.read(slot: "weather"))
        }
        sync.changed(slot: "weather")
        await sync.flush()
        let surface = await stored("weather").flatMap(SurfaceRecord.init)
        XCTAssertEqual(surface?.revision, revision)
        XCTAssertEqual(sync.pending, [])
    }

    /// A save of this phone's lands across a takeover and the role read after it fails, so the
    /// undo never runs: the next pass, the role now a viewer's, clears that save under its tag
    /// rather than settling the slot with it standing.
    func testADemotedPhoneTakesBackASaveWhoseUndoNeverRan() async throws {
        let role = ScriptedRole([true, nil, false])
        let sync = makeSync(defaults: UserDefaults(suiteName: "surface-sync-\(UUID().uuidString)")!, mayOwn: { try role.next() })
        _ = try write("weather")
        sync.changed(slot: "weather")
        await sync.flush()
        XCTAssertEqual(sync.pending, ["weather"])
        await sync.flush()
        XCTAssertEqual(sync.pending, [])
        let standing = await stored("weather")
        XCTAssertNil(standing, "a demoted phone settled the slot with its own save on it")
    }

    /// The same across two phones: the new primary's sweep reads the old one's record, the old
    /// one's save lands in the gap, and the old phone reads no role again (off the network, or
    /// never run again). The sweep's refused clear is read again and made over the save.
    func testASaveLandingInTheSweepsGapIsSweptToo() async throws {
        let storeB = SurfaceStore(folder: folder.appendingPathComponent("b"))
        defer { try? FileManager.default.removeItem(at: storeB.folder) }
        let a = makeSync(defaults: UserDefaults(suiteName: "surface-sync-a-\(UUID().uuidString)")!, runner: "phone-A")
        let b = makeSync(defaults: UserDefaults(suiteName: "surface-sync-b-\(UUID().uuidString)")!, runner: "phone-B", store: storeB)
        _ = try write("weather", "A1")
        a.changed(slot: "weather")
        await a.flush()
        let role = ScriptedRole([true, nil])
        let late = makeSync(defaults: UserDefaults(suiteName: "surface-sync-a2-\(UUID().uuidString)")!, runner: "phone-A",
                            mayOwn: { try role.next() })
        _ = try write("weather", "A2")
        let once = Once()
        await database.inner.setBeforeSave { saving in
            guard saving.contains(where: { $0.fields["runner"] == .string("phone-B") && $0.fields["cleared"] != nil }),
                  once.first() else { return }
            await MainActor.run { late.changed(slot: "weather") }
            await late.flush()
        }
        b.sweep()
        await b.flush()
        await database.inner.setBeforeSave(nil)
        let swept = await stored("weather")
        XCTAssertNil(swept, "the sweep left a save that landed between its read and its clear")
        XCTAssertEqual(b.pending, [])
    }

    /// A sweep's refused clear finds a save made since by a phone that is not demoted (two
    /// devices both reading themselves primary, which no takeover should leave): it is left, not
    /// cleared on this phone's word alone.
    func testASweepLeavesASaveSinceByAPhoneNotDemoted() async throws {
        let sync = makeSync(defaults: UserDefaults(suiteName: "surface-sync-\(UUID().uuidString)")!, demoted: { _ in false })
        try await save(SurfaceRecord(slot: "tides", document: "{}", revision: 3, updated: Date(), runner: "phone-0"))
        await interleave(when: Self.tombstone) { await Self.primarySaves("tides", $0) }
        sync.sweep()
        await sync.flush()
        await assertThePrimarys("tides")
    }

    /// A demoted phone's own record that cannot be read whole just now (an asset that did not
    /// load) is still its own: the next pass clears it rather than settling the slot with it.
    func testADemotedPhoneTakesBackItsOwnUnreadableRecord() async throws {
        let role = Role()
        let sync = makeSync(defaults: UserDefaults(suiteName: "surface-sync-\(UUID().uuidString)")!, mayOwn: { role.primary })
        _ = try write("weather")
        sync.changed(slot: "weather")
        await sync.flush()
        let saved = await database.inner.current(SurfaceRecord.id(slot: "weather"))
        var record = try XCTUnwrap(saved)
        record.fields["document"] = nil
        _ = try await database.inner.save([record])
        role.primary = false
        sync.changed(slot: "weather")
        await sync.flush()
        let left = await database.inner.current(SurfaceRecord.id(slot: "weather"))
        XCTAssertFalse(SurfaceRecords.Read(left).holds, "a demoted phone left its own unreadable record on the slot")
        XCTAssertEqual(sync.pending, [])
    }

    /// The new primary saves the slot after the old phone's save and before the role read that
    /// would undo it: the undo reads a record that is not its own and leaves it.
    func testAnUndoLeavesARecordNotItsOwn() async throws {
        let calls = Counter(), inner = database.inner
        let sync = makeSync(defaults: UserDefaults(suiteName: "surface-sync-\(UUID().uuidString)")!, mayOwn: {
            let n = calls.bump()
            if n == 1 { return true }
            if n == 2 { await Self.primarySaves("weather", SurfaceRecords(database: inner)) }
            return false
        })
        _ = try write("weather")
        sync.changed(slot: "weather")
        await sync.flush()
        await assertThePrimarys("weather")
        XCTAssertEqual(sync.pending, [])
    }

    // MARK: A sign-out landing while a pass runs

    /// The sweep has read another phone's record and its role, and the login ends before the
    /// clear: no clear is sent, and the record stays.
    func testASignOutDuringASweepClearsNothingAfterIt() async throws {
        let box = SyncBox()
        let sync = makeSync(defaults: UserDefaults(suiteName: "surface-sync-\(UUID().uuidString)")!, mayOwn: {
            await MainActor.run { box.sync?.forget() }
            return true
        })
        box.sync = sync
        try await save(SurfaceRecord(slot: "tides", document: "{}", revision: 3, updated: Date(), runner: "phone-B"))
        sync.sweep()
        await sync.flush()
        let kept = await stored("tides")
        XCTAssertEqual(kept.flatMap(SurfaceRecord.init)?.runner, "phone-B", "a sweep cleared another phone's record after the sign-out")
    }

    /// One clear of the sweep in flight when the login ends: it lands, ordered before the
    /// sign-out, and the sweep sends no clear after it.
    func testASignOutDuringASweepsClearStopsTheRest() async throws {
        try await save(SurfaceRecord(slot: "alpha", document: "{}", revision: 3, updated: Date(), runner: "phone-B"))
        try await save(SurfaceRecord(slot: "beta", document: "{}", revision: 3, updated: Date(), runner: "phone-B"))
        let gate = Gate(), once = Once()
        await database.inner.setBeforeSave { saving in
            guard saving.contains(where: { $0.fields["runner"] == .string("phone-1") }), once.first() else { return }
            await gate.wait()
        }
        sync.sweep()
        let flushing = Task { await sync.flush() }
        for _ in 0..<10_000 where !gate.isWaiting { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(gate.isWaiting)
        sync.forget()
        gate.open()
        await flushing.value
        await sync.flush()
        let alpha = await stored("alpha"), beta = await stored("beta")
        XCTAssertEqual([alpha, beta].compactMap { $0 }.count, 1, "the sweep went on clearing after the sign-out")
    }

    /// An owed save whose read is answered after the login ended is not made.
    func testASignOutDuringAnOwedWriteSavesNothing() async throws {
        let box = SyncBox()
        let sync = makeSync(defaults: UserDefaults(suiteName: "surface-sync-\(UUID().uuidString)")!, mayOwn: {
            await MainActor.run { box.sync?.forget() }
            return true
        })
        box.sync = sync
        let saved = Flag()
        await database.inner.setBeforeSave { saving in
            if saving.contains(where: { $0.fields["cleared"] == nil }) { saved.set() }
        }
        _ = try write("weather")
        sync.changed(slot: "weather")
        await sync.flush()
        XCTAssertFalse(saved.isSet, "a save the ended login owed was made after its sign-out")
        let none = await stored("weather")
        XCTAssertNil(none)
        XCTAssertEqual(sync.pending, [])
    }

    /// A second sign-out landing while the first's clears run: its records are cleared too,
    /// rather than the first's finish marking the sign-out done.
    func testASecondSignOutDuringTheFirstsClearsIsNotSettledAway() async throws {
        _ = try write("weather")
        sync.changed(slot: "weather")
        await sync.flush()
        let gate = Gate(), once = Once()
        await database.inner.setBeforeSave { saving in
            guard saving.contains(where: { $0.fields["cleared"] != nil }), once.first() else { return }
            await gate.wait()
        }
        sync.forget()
        for _ in 0..<10_000 where !gate.isWaiting { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(gate.isWaiting)
        // The next login saved a slot, and has ended too.
        try await save(SurfaceRecord(slot: "tides", document: "{}", revision: 9, updated: Date(), runner: "phone-1"))
        sync.forget()
        gate.open()
        await sync.flush()
        let weather = await stored("weather"), tides = await stored("tides")
        XCTAssertNil(weather)
        XCTAssertNil(tides, "the second sign-out's clear was settled by the first's")
        XCTAssertFalse(sync.owesForget)
    }

    /// A sweep asked for again while one is running is not answered by the one running.
    func testASweepAskedDuringASweepRunsAgain() async throws {
        let box = SyncBox(), once = Once(), inner = database.inner
        let sync = makeSync(defaults: UserDefaults(suiteName: "surface-sync-\(UUID().uuidString)")!, mayOwn: {
            if once.first() {
                await MainActor.run {
                    box.sync?.sweep()
                }
                let records = SurfaceRecords(database: inner)
                _ = try? await records.save(SurfaceRecord(slot: "late", document: "{}", revision: 1, updated: Date(), runner: "phone-0"),
                                            over: records.read(slot: "late"))
            }
            return true
        })
        box.sync = sync
        try await save(SurfaceRecord(slot: "tides", document: "{}", revision: 3, updated: Date(), runner: "phone-0"))
        sync.sweep()
        await sync.flush()
        let late = await stored("late"), tides = await stored("tides")
        XCTAssertNil(tides)
        XCTAssertNil(late, "a sweep asked during a sweep was answered by the one running")
    }

    // MARK: The role gate as the app wires it

    /// `SurfaceSync` made with no role answers of a test's reads the role records itself: a
    /// viewer's sweeps nothing and a primary's sweeps.
    func testTheDefaultGateReadsThisPhonesRoleRecord() async throws {
        let roles = InMemoryRecordDatabase()
        let database = database!, store = store!
        let make = { [reloader] in
            SurfaceSync(records: { SurfaceRecords(database: database) }, ensureZone: {}, roles: { roles },
                        store: { store }, runner: "phone-A",
                        defaults: UserDefaults(suiteName: "surface-sync-\(UUID().uuidString)")!, reloader: reloader!)
        }
        try await save(SurfaceRecord(slot: "tides", document: "{}", revision: 3, updated: Date(), runner: "phone-B"))
        _ = try await roles.save(DeviceRole(device: DeviceID("phone-A"), role: .viewer, setBy: DeviceID("phone-B"), at: Date()).record(over: roles))
        let viewer = make()
        viewer.sweep()
        await viewer.flush()
        let kept = await stored("tides")
        XCTAssertNotNil(kept, "a phone whose role record says viewer swept")

        _ = try await roles.save(DeviceRole(device: DeviceID("phone-A"), role: .primary, setBy: DeviceID("phone-A"), at: Date()).record(over: roles))
        let primary = make()
        primary.sweep()
        await primary.flush()
        let swept = await stored("tides")
        XCTAssertNil(swept, "a primary's sweep left another phone's record")
    }



    /// The gate the app's `SurfaceSync` is made with, read from a store: a viewer's role record
    /// refuses, a primary's allows, and no record (a phone never taken over from) allows.
    func testTheRoleGateReadsTheDevicesRoleRecord() async throws {
        let roles = InMemoryRecordDatabase()
        let device = DeviceID("phone-A")
        let none = try await SurfaceSync.roleAllows(device: device, database: roles)
        XCTAssertTrue(none)
        _ = try await roles.save(DeviceRole(device: device, role: .viewer, setBy: DeviceID("phone-B"), at: Date()).record(over: roles))
        let viewer = try await SurfaceSync.roleAllows(device: device, database: roles)
        XCTAssertFalse(viewer, "a demoted phone's role record let it write")
        _ = try await roles.save(DeviceRole(device: device, role: .primary, setBy: device, at: Date()).record(over: roles))
        let primary = try await SurfaceSync.roleAllows(device: device, database: roles)
        XCTAssertTrue(primary)
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

/// The role a test's phone reads, flipped by the test as a takeover would.
private final class Role: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var primary: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// True the first time only.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

/// Answers a role from a script, the last answer repeating; nil is a read that fails.
private final class ScriptedRole: @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Bool?]
    init(_ script: [Bool?]) { self.script = script }
    func next() throws -> Bool {
        let answer: Bool? = lock.withLock { script.count > 1 ? script.removeFirst() : script[0] }
        guard let answer else { throw RecordDatabaseError.unavailable(underlying: URLError(.notConnectedToInternet)) }
        return answer
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() -> Int { lock.withLock { count += 1; return count } }
}

/// A test's hold on the sync its closures act on, made after them.
@MainActor
private final class SyncBox {
    var sync: SurfaceSync?
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

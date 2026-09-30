import TopoCore
import TopoCoreTesting
import XCTest

@testable import TopoWatch

/// The zone as the watch sees it: the in-memory database, with the feed able to leave a slot out
/// (as an index would) and every read able to fail (as a watch off the network does).
actor Zone: ZoneDatabase {
    let wrapped: InMemoryRecordDatabase
    private var omitted: Set<String> = []
    private var feedFails = false
    private var garbled: Set<String> = []
    private var fetchFails = false

    init(_ wrapped: InMemoryRecordDatabase) { self.wrapped = wrapped }

    func omit(_ slots: Set<String>) { omitted = slots }
    func fail(feed: Bool, fetch: Bool) { feedFails = feed; fetchFails = fetch }
    /// The next feed read hands these slots' records without their images, as a read whose
    /// assets did not load does.
    func garble(_ slots: Set<String>) { garbled = slots }

    private static let offline = RecordDatabaseError.unavailable(underlying: URLError(.notConnectedToInternet))

    func save(_ records: [Record]) async throws -> [Record] { try await wrapped.save(records) }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] {
        if fetchFails { throw Self.offline }
        return try await wrapped.fetch(ids)
    }
    func records(ofType type: String) async throws -> [Record] { try await wrapped.records(ofType: type) }
    func query(_ query: RecordQuery) async throws -> [Record] { try await wrapped.query(query) }
    func delete(_ ids: [RecordID]) async throws { try await wrapped.delete(ids) }
    func changes(ofType type: String, since token: Data?) async throws -> RecordChanges {
        if feedFails { throw Self.offline }
        var changes = try await wrapped.changes(ofType: type, since: token)
        changes.changed.removeAll { SurfaceRecord.slot(of: $0.id).map(omitted.contains) ?? false }
        for index in changes.changed.indices where SurfaceRecord.slot(of: changes.changed[index].id).map(garbled.contains) ?? false {
            changes.changed[index].fields["images"] = nil
        }
        garbled = []
        return changes
    }
}

/// Review Focus 1 and 3: the watch drops a slot only when its removal is confirmed, keeps what it
/// has through any other failure, and judges every record with its own reader.
@MainActor
final class WatchSurfaceCacheTests: XCTestCase {
    private var folder: URL!
    private var store: SurfaceStore!
    private var database: InMemoryRecordDatabase!
    private var zone: Zone!
    private var cache: WatchSurfaceCache!
    private var reloads = 0

    static func document(_ words: String) -> String {
        #"{"version": 1, "families": {"default": {"kind": "text", "text": "\#(words)"}}}"#
    }

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)")
        store = SurfaceStore(folder: folder)
        database = InMemoryRecordDatabase()
        zone = Zone(database)
        let defaults = UserDefaults(suiteName: "topo.watch.tests.\(UUID().uuidString)")!
        reloads = 0
        cache = WatchSurfaceCache(records: SurfaceRecords(database: zone), store: store, defaults: defaults,
                                  changed: { [unowned self] in reloads += 1 })
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The phone's save, as `SurfaceSync` makes it.
    private func phoneSets(_ slot: String, _ text: String, revision: Int, images: [String: Data] = [:]) async throws {
        let surface = SurfaceRecord(slot: slot, document: text, revision: revision, updated: Date(), runner: "phone-1", images: images)
        _ = try await SurfaceRecords(database: database).save(surface)
    }

    private func phoneClears(_ slot: String) async throws {
        try await SurfaceRecords(database: database).delete(slot: slot)
    }

    func testEmptyCacheListsFromTheFeed() async throws {
        try await phoneSets("weather", Self.document("rain"), revision: 3, images: ["sky": Data([0x89, 1])])
        try await phoneSets("lamp", Self.document("on"), revision: 5)
        let read = await cache.fetch()
        XCTAssertTrue(read)
        XCTAssertEqual(store.slots(), ["lamp", "weather"])
        XCTAssertEqual(store.read(slot: "weather")?.document.revision, 3, "the watch minted a revision of its own")
        XCTAssertEqual(store.read(slot: "lamp")?.document.revision, 5)
        XCTAssertEqual(store.imageData(slot: "weather", name: "sky"), Data([0x89, 1]))
        XCTAssertEqual(reloads, 1)

        // The next fetch reads only what moved since: nothing, and no reload.
        await cache.fetch()
        XCTAssertEqual(reloads, 1)
    }

    func testMissingDropsTheCache() async throws {
        // A deletion in the feed.
        try await phoneSets("weather", Self.document("rain"), revision: 3)
        try await phoneSets("lamp", Self.document("on"), revision: 5)
        await cache.fetch()
        try await phoneClears("weather")
        await cache.fetch()
        XCTAssertEqual(store.slots(), ["lamp"])
        XCTAssertTrue(store.imageNames(slot: "weather").isEmpty)

        // A slot the feed read from the start does not list, which a fetch by name finds gone.
        await database.expireChangeTokens()
        var old = WidgetDocument.read(Self.document("left over"), from: .store).document
        old.revision = 2
        try store.keep(old, slot: "old")
        await cache.fetch()
        XCTAssertEqual(store.slots(), ["lamp"], "a slot whose record is gone stayed cached")
    }

    /// The group refusing a write (full, or its folder locked): the feed's token stays, so the
    /// next fetch reads the same change again and keeps it, where a token past it never would.
    func testAFailedWriteKeepsTheToken() async throws {
        try await phoneSets("weather", Self.document("rain"), revision: 3)
        await cache.fetch()
        try await phoneSets("weather", Self.document("sun"), revision: 4)
        try await locked { await cache.fetch() }
        XCTAssertEqual(store.read(slot: "weather")?.document.revision, 3)
        await cache.fetch()
        XCTAssertEqual(store.read(slot: "weather")?.document.revision, 4, "a change whose write failed was never read again")
    }

    func testAFailedRemoveKeepsTheToken() async throws {
        try await phoneSets("weather", Self.document("rain"), revision: 3)
        await cache.fetch()
        try await phoneClears("weather")
        try await locked { await cache.fetch() }
        XCTAssertEqual(store.slots(), ["weather"])
        await cache.fetch()
        XCTAssertEqual(store.slots(), [], "a deletion whose removal failed was never read again")
    }

    /// A write failing part-way through a slot with images leaves the cached document with every
    /// image it names, so a watch off the network still draws it; the next fetch finishes it.
    func testAFailedWriteLeavesTheCachedImages() async throws {
        try await phoneSets("weather", Self.document("rain"), revision: 3, images: ["sky": Data([1]), "sun": Data([2])])
        await cache.fetch()
        try await phoneSets("weather", Self.document("snow"), revision: 4, images: ["sky": Data([3]), "moon": Data([4])])
        // A folder where moon's file goes: its write fails, after sun's removal would have been done.
        let moon = store.image(slot: "weather", name: "moon")
        try FileManager.default.createDirectory(at: moon, withIntermediateDirectories: true)
        try Data().write(to: moon.appendingPathComponent("in-the-way"))
        await cache.fetch()
        XCTAssertEqual(store.read(slot: "weather")?.document.revision, 3)
        XCTAssertEqual(store.imageData(slot: "weather", name: "sun"), Data([2]), "the cached document lost an image it names")

        try FileManager.default.removeItem(at: moon)
        await cache.fetch()
        XCTAssertEqual(store.read(slot: "weather")?.document.revision, 4)
        XCTAssertEqual(store.imageData(slot: "weather", name: "moon"), Data([4]))
        XCTAssertEqual(store.imageData(slot: "weather", name: "sky"), Data([3]))
        XCTAssertEqual(store.imageNames(slot: "weather"), ["moon", "sky"])
    }

    /// A deletion is taken whether or not the cached document can be read just now.
    func testADeletionTakesAnUnreadableSlot() async throws {
        try await phoneSets("weather", Self.document("rain"), revision: 3)
        await cache.fetch()
        let path = store.url(slot: "weather").path
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
        XCTAssertNil(store.read(slot: "weather"))
        try await phoneClears("weather")
        await cache.fetch()
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        await cache.fetch()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "a deleted slot stayed because it could not be read")
        XCTAssertEqual(store.slots(), [])
    }

    /// A record the feed hands unreadable once is not skipped for good: it is asked for by name
    /// at the next fetch, though the token has moved past it.
    func testARecordUnreadableOnceIsReadAgain() async throws {
        try await phoneSets("weather", Self.document("rain"), revision: 3, images: ["sky": Data([1])])
        await cache.fetch()
        try await phoneSets("weather", Self.document("snow"), revision: 4, images: ["sky": Data([2])])
        // Unreadable in the feed and not fetched by name either: the next fetch asks again.
        await zone.garble(["weather"])
        await zone.fail(feed: false, fetch: true)
        await cache.fetch()
        XCTAssertEqual(store.read(slot: "weather")?.document.revision, 3)
        await zone.fail(feed: false, fetch: false)
        await cache.fetch()
        XCTAssertEqual(store.read(slot: "weather")?.document.revision, 4, "a record read unreadable once was skipped for good")
        XCTAssertEqual(store.imageData(slot: "weather", name: "sky"), Data([2]))
    }

    /// Runs `body` with the store's folder read-only, so every write and removal in it fails.
    private func locked(_ body: () async -> Void) async throws {
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        await body()
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
    }

    func testQueryOmissionKeepsIt() async throws {
        try await phoneSets("weather", Self.document("rain"), revision: 3)
        await cache.fetch()
        // The feed read afresh leaves the slot out, though its record is there: asked for by
        // name, it is found, and kept.
        await database.expireChangeTokens()
        await zone.omit(["weather"])
        let read = await cache.fetch()
        XCTAssertTrue(read)
        XCTAssertEqual(store.slots(), ["weather"], "a slot the feed omitted but a fetch returns was dropped")
    }

    func testNetworkErrorKeepsIt() async throws {
        try await phoneSets("weather", Self.document("rain"), revision: 3)
        await cache.fetch()
        let before = store.read(slot: "weather")

        await zone.fail(feed: true, fetch: true)
        let read = await cache.fetch()
        XCTAssertFalse(read)
        XCTAssertEqual(store.read(slot: "weather"), before)

        // The feed read afresh, the fetch by name failing: an answer that is not "gone" keeps it,
        // though the record went before the read, which a feed from the start does not report.
        await database.expireChangeTokens()
        try await phoneClears("weather")
        await zone.fail(feed: false, fetch: true)
        await cache.fetch()
        XCTAssertEqual(store.read(slot: "weather"), before, "a failed fetch was taken for a missing record")

        // Unconfirmed, it is asked about again: the next read starts from the beginning, and once
        // the fetch by name answers, the slot goes.
        await zone.fail(feed: false, fetch: false)
        await cache.fetch()
        XCTAssertEqual(store.slots(), [], "a slot left unconfirmed was never asked about again")
    }

    func testRecordIsReadNotTrusted() async throws {
        // A document the phone should never have saved: a node the reader refuses, a colour that
        // is not a case, a gauge past its bounds.
        let text = #"""
        {"version": 1, "families": {"default": {"kind": "vstack", "children": [
          {"kind": "text", "text": "kept", "colour": "chartreuse"},
          {"kind": "blink"},
          {"kind": "gauge", "value": 12, "min": 0, "max": 10}
        ]}}}
        """#
        try await phoneSets("odd", text, revision: 7)
        await cache.fetch()
        var expected = WidgetDocument.read(text, from: .store)
        XCTAssertFalse(expected.notes.isEmpty, "the fixture is read whole, so the test cannot fail")
        expected.document.revision = 7
        XCTAssertEqual(store.read(slot: "odd")?.document, expected.document, "the watch kept the record's words unjudged")
        XCTAssertFalse(store.read(slot: "odd")?.document.text.contains("blink") ?? true)
    }
}

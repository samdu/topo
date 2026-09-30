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
    private var fetchFails = false

    init(_ wrapped: InMemoryRecordDatabase) { self.wrapped = wrapped }

    func omit(_ slots: Set<String>) { omitted = slots }
    func fail(feed: Bool, fetch: Bool) { feedFails = feed; fetchFails = fetch }

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

import TopoCore
import TopoCoreTesting
import XCTest

@testable import TopoWatch

/// Review Focus 6: a watch turn control's tap is one turn, whatever happens between the cue and
/// its removal, and a tap on a document the cache no longer holds is none.
@MainActor
final class WatchCueTests: XCTestCase {
    private var folder: URL!
    private var store: SurfaceStore!

    static let feed = #"""
    {"version": 1, "families": {"default": {"kind": "button", "id": "feed", "label": "Feed",
     "action": {"kind": "turn", "say": "feed Daphne"}}}}
    """#

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("cues-\(UUID().uuidString)")
        store = SurfaceStore(folder: folder)
        var document = WidgetDocument.read(Self.feed).document
        document.revision = 3
        try store.keep(document, slot: "dog")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func transcript(_ database: InMemoryRecordDatabase, _ defaults: UserDefaults) -> TranscriptStore {
        TranscriptStore(database: database, device: DeviceID("watch-1"), ensureZone: {}, defaults: defaults)
    }

    private func turns(_ database: InMemoryRecordDatabase) async -> [Turn] {
        let reader = transcript(database, UserDefaults(suiteName: "topo.watch.read.\(UUID().uuidString)")!)
        await reader.refresh()
        return reader.turns
    }

    func testDrainSendsOnce() async throws {
        let database = InMemoryRecordDatabase()
        let defaults = UserDefaults(suiteName: "topo.watch.cues.\(UUID().uuidString)")!
        let cue = WatchCueIntent(slot: "dog", control: "feed", revision: 3).cue(nonce: "tap-1")
        XCTAssertTrue(try store.recordCue(cue))

        await WatchCues(transcript: transcript(database, defaults), store: { self.store }).drain()
        XCTAssertTrue(store.cues().isEmpty)
        let first = await turns(database)
        XCTAssertEqual(first.map(\.text), ["widget dog: feed Daphne"])
        XCTAssertEqual(first.map(\.nonce), ["tap-1"])

        // A crash after the send and before the cue went: the cue is still there, and a relaunched
        // app drains it again.
        try store.appendCue(cue)
        await WatchCues(transcript: transcript(database, defaults), store: { self.store }).drain()
        XCTAssertTrue(store.cues().isEmpty)
        let after = await turns(database)
        XCTAssertEqual(after.filter { $0.nonce == "tap-1" }.count, 1, "one tap became two turns")
    }

    func testStaleCueSendsNothing() async throws {
        let database = InMemoryRecordDatabase()
        let defaults = UserDefaults(suiteName: "topo.watch.cues.\(UUID().uuidString)")!
        // A tap drawn from revision 2, the cache since moved to 3; and a tap on no such control.
        try store.appendCue(WatchCueIntent(slot: "dog", control: "feed", revision: 2).cue(nonce: "old"))
        try store.appendCue(WatchCueIntent(slot: "dog", control: "walk", revision: 3).cue(nonce: "none"))
        await WatchCues(transcript: transcript(database, defaults), store: { self.store }).drain()
        XCTAssertTrue(store.cues().isEmpty, "a stale cue was kept for a later drain")
        let sent = await turns(database)
        XCTAssertEqual(sent, [])
    }

    /// No read of the log, no send: the cue waits for one.
    func testNoReadKeepsTheCue() async throws {
        let defaults = UserDefaults(suiteName: "topo.watch.cues.\(UUID().uuidString)")!
        try store.appendCue(WatchCueIntent(slot: "dog", control: "feed", revision: 3).cue(nonce: "wait"))
        let unreachable = TranscriptStore(database: Unreachable(), device: DeviceID("watch-1"), ensureZone: {}, defaults: defaults)
        await WatchCues(transcript: unreachable, store: { self.store }).drain()
        XCTAssertEqual(store.cues().map(\.nonce), ["wait"])
    }
}

/// iCloud out of reach: every read and write refused.
private struct Unreachable: RecordDatabase {
    private static let offline = RecordDatabaseError.unavailable(underlying: URLError(.notConnectedToInternet))
    func save(_ records: [Record]) async throws -> [Record] { throw Self.offline }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { throw Self.offline }
    func records(ofType type: String) async throws -> [Record] { throw Self.offline }
    func query(_ query: RecordQuery) async throws -> [Record] { throw Self.offline }
}

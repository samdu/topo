import Foundation
import TopoAuth
import TopoCore
import TopoCoreTesting
import TopoTurn
import XCTest

@testable import Topo

/// Review Focus 5: one tap, one turn. A `turn` control's cue, recorded in the app group under the
/// nonce the intent minted, is put on the harness's line by `WidgetCues` and taken off the app
/// group only once that nonce is on the line or in the log. A relaunch is a new `Harness` over the
/// same log and the same defaults, which is what a crash leaves; a crash before the record's
/// removal is the record put back.
@MainActor
final class WidgetCueTests: XCTestCase {
    private let phone = DeviceID("phone")
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("widget-cues-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var store: SurfaceStore { SurfaceStore(folder: folder) }

    private func cues(_ harness: Harness) -> WidgetCues {
        let store = store
        return WidgetCues(harness: harness, store: { store },
                          reloader: SurfaceReloader(reloadKind: { _ in }, reloadEverything: {}, schedule: { _, _ in }))
    }

    /// A cue on the slot's current revision.
    private func cue() throws -> SurfaceStore.Cue {
        let revision = try store.write(WidgetDocument.read(WidgetTool.example).document, slot: "demo")
        let cue = SurfaceStore.Cue(nonce: UUID().uuidString, slot: "demo", id: "hi", revision: revision, say: "hi", time: Date())
        try store.appendCue(cue)
        return cue
    }

    func testDrainSendsOnce() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()
        let cue = try cue()
        let offline = harness(db, defaults: defaults, transport: ScriptedTransport(), ensureZone: { throw Unexpected() })
        await offline.refresh()
        await cues(offline).drain()
        XCTAssertEqual(offline.owed.map(\.nonce), [cue.nonce])
        XCTAssertEqual(store.cues(), [], "the record outlived its nonce reaching the line")

        // The crash before the removal: the record is still there, and the line survived.
        try store.appendCue(cue)
        let relaunched = harness(db, defaults: defaults, transport: ScriptedTransport(), ensureZone: { throw Unexpected() })
        await relaunched.refresh()
        await cues(relaunched).drain()
        XCTAssertEqual(relaunched.owed.map(\.nonce), [cue.nonce], "a drain run twice put a second entry on the line")
        XCTAssertEqual(relaunched.owed.map(\.text), ["widget demo: hi"])
    }

    func testDrainAfterLandedSendsNothing() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()
        let cue = try cue()
        let harness = harness(db, defaults: defaults, transport: ScriptedTransport((200, reply("Hello."))))
        await harness.refresh()
        await cues(harness).drain()
        XCTAssertEqual(harness.owed.count, 0, "the turn did not land and leave the line")
        let landed = try await log(db).filter { $0.role == .person }
        XCTAssertEqual(landed.map(\.nonce), [cue.nonce])

        try store.appendCue(cue)
        let relaunched = self.harness(db, defaults: defaults, transport: ScriptedTransport())
        await relaunched.refresh()
        await cues(relaunched).drain()
        XCTAssertEqual(relaunched.owed.count, 0, "a cue whose turn is in the log went on the line again")
        let people = try await log(db).filter { $0.role == .person }
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(store.cues(), [])
    }

    func testCueWaitsBehindRowInFlight() async throws {
        let db = InMemoryRecordDatabase()
        let offline = harness(db, defaults: makeDefaults(), transport: ScriptedTransport(), ensureZone: { throw Unexpected() })
        await offline.refresh()
        let row = NextTurn()
        row.text = "call Helen"
        row.send(via: offline)
        XCTAssertTrue(row.sending(in: offline))
        let cue = try cue()
        await cues(offline).drain()
        XCTAssertEqual(offline.owed.map(\.text), ["call Helen", "widget demo: hi"], "the cue was merged into the row's words")
        XCTAssertEqual(offline.owed.last?.nonce, cue.nonce)
        XCTAssertEqual(row.text, "call Helen", "the row took the cue's words")
    }

    func testNothingIsDrainedBeforeTheFirstRead() async throws {
        let db = InMemoryRecordDatabase()
        let harness = harness(db, defaults: makeDefaults(), transport: ScriptedTransport())
        _ = try cue()
        await cues(harness).drain()
        XCTAssertEqual(harness.owed.count, 0)
        XCTAssertEqual(store.cues().count, 1, "a cue went before the harness knew what the log holds")
    }

    func testAStaleCueIsRecordedAndDropped() async throws {
        let db = InMemoryRecordDatabase()
        let harness = harness(db, defaults: makeDefaults(), transport: ScriptedTransport(), ensureZone: { throw Unexpected() })
        await harness.refresh()
        _ = try cue()
        try store.write(WidgetDocument.read(WidgetTool.example).document, slot: "demo")
        await cues(harness).drain()
        XCTAssertEqual(harness.owed.count, 0)
        XCTAssertEqual(store.cues(), [])
        XCTAssertEqual(store.taps().map(\.status), ["stale"])
    }

    func testALinksURLIsOneCue() async throws {
        let db = InMemoryRecordDatabase()
        let harness = harness(db, defaults: makeDefaults(), transport: ScriptedTransport(), ensureZone: { throw Unexpected() })
        await harness.refresh()
        let revision = try store.write(WidgetDocument.read(WidgetTool.example).document, slot: "demo")
        await cues(harness).open(WidgetURL.cue(slot: "demo", control: "ask", revision: revision, say: "what's on"))
        XCTAssertEqual(harness.owed.map(\.text), ["widget demo: what's on"])
    }

    // MARK: -

    private func makeDefaults() -> UserDefaults {
        let name = "topo.tests.cues.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    private func harness(_ database: any RecordDatabase, defaults: UserDefaults, transport: ScriptedTransport,
                         ensureZone: @escaping @Sendable () async throws -> Void = {}) -> Harness {
        Harness(database: database, tokens: FixedToken(), device: phone, ensureZone: ensureZone,
                defaults: defaults, brain: guestBrain(over: transport), leaseSleep: parked,
                pause: { _ in throw CancellationError() })
    }

    private func log(_ database: any RecordDatabase) async throws -> [Turn] {
        try await TurnLog(database: database).read().ordered
    }
}

private final class ScriptedTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(Int, String)]

    init(_ replies: (Int, String)...) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock {
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

private struct Unexpected: Error {}

/// A heartbeat loop that never beats inside a test: the lease is renewed by the turns themselves.
private let parked: @Sendable (TimeInterval) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }

import Foundation
import TopoAuth
import TopoCore
import TopoCoreTesting
import TopoTools
import TopoTurn
import XCTest

@testable import Topo

/// Review Focus 5 and 15 of the controls' plan: a control's tap, taken by `WidgetTaps` as its
/// intent hands it over, is one turn or one run or nothing — a turn slot's cue recorded once and
/// drained onto the line with the slot's words whether or not the app comes forward, a run in the
/// background, `open` recording nothing.
@MainActor
final class ControlCueTests: XCTestCase {
    private let phone = DeviceID("phone")
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("control-cues-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var store: SurfaceStore { SurfaceStore(folder: folder) }

    private func taps(_ harness: Harness, tools: [any Tool] = []) -> WidgetTaps {
        let store = store
        let reloader = SurfaceReloader(reloadKind: { _ in }, reloadEverything: {}, reloadControlKind: { _ in },
                                       reloadEveryControl: {}, schedule: { _, _ in })
        return WidgetTaps(cues: WidgetCues(harness: harness, store: { store }, reloader: reloader),
                          actions: WidgetActions(table: ToolTable(tools), store: { store }, reloader: reloader, bound: .seconds(5)))
    }

    @discardableResult
    private func set(_ slot: String, _ json: String) throws -> Int {
        let reading = ControlDocument.read(json, slot: slot)
        XCTAssertEqual(reading.notes, [])
        return try store.writeControl(reading.document, slot: slot)
    }

    /// The button intent's handler for a turn slot, with nothing brought forward: one cue
    /// recorded, and a drain puts one entry on the line with the slot's words.
    func testBackgroundTurnRecordsAndDrains() async throws {
        let db = InMemoryRecordDatabase()
        let harness = harness(db, defaults: makeDefaults(), transport: ScriptedTransport(), ensureZone: { throw Unexpected() })
        await harness.refresh()
        let revision = try set("button-1", #"{"title": "Lights", "action": {"kind": "turn", "say": "lights please"}}"#)
        let taps = taps(harness)
        let answer = await taps.controlTapped(slot: "button-1", revision: revision, turningOn: nil)
        XCTAssertEqual(answer, .foreground)
        XCTAssertEqual(store.cues().map(\.slot), [ControlSlot.stored("button-1")], "the tap recorded no cue, or two")
        await taps.cues.drain()
        await taps.cues.drain()
        XCTAssertEqual(harness.owed.map(\.text), ["control button-1: lights please"])
        XCTAssertEqual(store.cues(), [])
    }

    /// A turn toggle says the state its intent asked for, not the opposite of the stored one.
    func testATurnToggleSaysWhatWasAsked() async throws {
        let db = InMemoryRecordDatabase()
        let harness = harness(db, defaults: makeDefaults(), transport: ScriptedTransport(), ensureZone: { throw Unexpected() })
        await harness.refresh()
        let revision = try set("toggle-1", #"{"title": "Fan", "on": true, "action": {"kind": "turn", "say": "fan"}}"#)
        let taps = taps(harness)
        _ = await taps.controlTapped(slot: "toggle-1", revision: revision, turningOn: true)
        await taps.cues.drain()
        XCTAssertEqual(harness.owed.map(\.text), ["control toggle-1: fan on"])
        XCTAssertEqual(store.readControl(slot: "toggle-1")?.document.on, true)
    }

    /// A run slot runs in the background and sends no turn; `open` comes forward recording
    /// nothing; a tap on an older revision runs nothing and cues nothing.
    func testRunAndOpenRecordNoCue() async throws {
        let db = InMemoryRecordDatabase()
        let harness = harness(db, defaults: makeDefaults(), transport: ScriptedTransport(), ensureZone: { throw Unexpected() })
        await harness.refresh()
        let taps = taps(harness)
        let run = try set("button-2", #"{"title": "Bins", "action": {"kind": "run", "topo": ["notify", "Bins"]}}"#)
        let answer = await taps.controlTapped(slot: "button-2", revision: run, turningOn: nil)
        XCTAssertEqual(answer, .background)
        XCTAssertEqual(store.taps().map(\.status), [String(ToolReply.usage)], "the run did not reach the table")
        let open = try set("button-3", #"{"title": "Topo", "action": {"kind": "open"}}"#)
        let opened = await taps.controlTapped(slot: "button-3", revision: open, turningOn: nil)
        XCTAssertEqual(opened, .foreground)
        let turn = try set("button-3", #"{"title": "Hi", "action": {"kind": "turn"}}"#)
        XCTAssertGreaterThan(turn, open)
        let stale = await taps.controlTapped(slot: "button-3", revision: open, turningOn: nil)
        XCTAssertEqual(stale, .background)
        XCTAssertEqual(store.cues(), [])
        await taps.cues.drain()
        XCTAssertEqual(harness.owed.count, 0)
        XCTAssertEqual(store.taps().map(\.status), [String(ToolReply.usage), "stale"])
    }

    // MARK: Review Focus 7

    private func defaults() -> ControlDefaults {
        let store = store
        return ControlDefaults(store: { store }, reloader: SurfaceReloader(reloadKind: { _ in }, reloadEverything: {},
                                                                           reloadControlKind: { _ in }, reloadEveryControl: {},
                                                                           schedule: { _, _ in }),
                               secrets: ControlSecrets(service: "zone.hexagon.topo.control-secret.tests.\(UUID().uuidString)"))
    }

    /// A default's tap, drained twice: one entry on the line, its words naming the slot.
    func testDefaultSlotCuesOnce() async throws {
        let db = InMemoryRecordDatabase()
        let harness = harness(db, defaults: makeDefaults(), transport: ScriptedTransport(), ensureZone: { throw Unexpected() })
        await harness.refresh()
        defaults().follow(to: .signedIn)
        let revision = try XCTUnwrap(store.readControl(slot: "button-3")?.document.revision)
        let taps = taps(harness)
        let answer = await taps.controlTapped(slot: "button-3", revision: revision, turningOn: nil)
        XCTAssertEqual(answer, .foreground)
        await taps.cues.drain()
        await taps.cues.drain()
        XCTAssertEqual(harness.owed.map(\.text), ["control button-3: tapped, not set"])
        XCTAssertEqual(store.taps().map { "\($0.kind) \($0.status)" }, ["turn cued"], "a default's tap ran something")
    }

    /// A sign-in writes all twelve above `_floor`; `clear` writes one back at the next revision.
    func testDefaultsWrittenAtSignInAndClear() async throws {
        // An earlier login's surfaces, gone at its sign-out, set the floor.
        try store.writeControl(ControlDocument.standard(slot: "button-1"), slot: "button-1")
        try store.removeEverything()
        let defaults = defaults()
        defaults.follow(to: .idle)
        XCTAssertNil(store.readControl(slot: "button-1"), "a default was written signed out")
        defaults.follow(to: .signedIn)
        for slot in ControlSlot.all {
            let document = try XCTUnwrap(store.readControl(slot: slot)?.document, slot)
            XCTAssertTrue(document.isDefault, slot)
            XCTAssertFalse(store.isEarlierLogin(document.revision), "\(slot) at \(document.revision) is at or below the floor")
        }
        let highest = ControlSlot.all.compactMap { store.readControl(slot: $0)?.document.revision }.max()!
        try ControlDefaults.write(slot: "toggle-4", store: store)
        XCTAssertEqual(store.readControl(slot: "toggle-4")?.document.revision, highest + 1)
    }

    /// A written slot and its revision survive a relaunch that follows the login again.
    func testRelaunchKeepsWrittenSlots() async throws {
        defaults().follow(to: .signedIn)
        let written = try store.writeControl(ControlDocument.read(#"{"title": "Lamp", "action": {"kind": "open"}}"#, slot: "button-2").document,
                                             slot: "button-2")
        let others = ControlSlot.all.map { store.readControl(slot: $0)?.document.revision }
        defaults().follow(to: .signedIn)
        XCTAssertEqual(store.readControl(slot: "button-2")?.document.revision, written)
        XCTAssertEqual(store.readControl(slot: "button-2")?.document.title, "Lamp")
        XCTAssertEqual(ControlSlot.all.map { store.readControl(slot: $0)?.document.revision }, others, "a relaunch rewrote a slot")
    }

    /// Signed out there are no documents: the value is "Sign in", and a tap on any revision comes
    /// forward and records and runs nothing.
    func testSignedOutTapRunsNothing() async throws {
        let db = InMemoryRecordDatabase()
        let harness = harness(db, defaults: makeDefaults(), transport: ScriptedTransport(), ensureZone: { throw Unexpected() })
        await harness.refresh()
        defaults().follow(to: .signedIn)
        let revision = try XCTUnwrap(store.readControl(slot: "button-1")?.document.revision)
        try store.removeEverything()
        XCTAssertTrue(ControlValue.read(slot: "button-1", store: store).signedOut)
        XCTAssertEqual(ControlValue.read(slot: "button-1", store: store).title, "Sign in")
        let taps = taps(harness)
        for slot in ["button-1", "toggle-1"] {
            let answer = await taps.controlTapped(slot: slot, revision: revision, turningOn: true)
            XCTAssertEqual(answer, .foreground)
        }
        await taps.cues.drain()
        XCTAssertEqual(store.cues(), [])
        XCTAssertEqual(store.taps(), [])
        XCTAssertEqual(harness.owed.count, 0)
    }

    // MARK: -

    private func makeDefaults() -> UserDefaults {
        let name = "topo.tests.control-cues.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    private func harness(_ database: any RecordDatabase, defaults: UserDefaults, transport: ScriptedTransport,
                         ensureZone: @escaping @Sendable () async throws -> Void = {}) -> Harness {
        Harness(database: database, tokens: FixedToken(), device: phone, ensureZone: ensureZone,
                defaults: defaults, brain: guestBrain(over: transport), leaseSleep: parked,
                pause: { _ in throw CancellationError() })
    }
}

private final class ScriptedTransport: Transport, @unchecked Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
    }
}

private struct FixedToken: TokenProvider {
    func accessToken() async throws -> String { "tok" }
}

private struct Unexpected: Error {}

/// A heartbeat loop that never beats inside a test: the lease is renewed by the turns themselves.
private let parked: @Sendable (TimeInterval) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }

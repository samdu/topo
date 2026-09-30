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
                                                                           schedule: { _, _ in }))
    }

    /// A default's tap, drained twice: one entry on the line, its words naming the slot.
    func testDefaultSlotCuesOnce() async throws {
        let db = InMemoryRecordDatabase()
        let harness = harness(db, defaults: makeDefaults(), transport: ScriptedTransport(), ensureZone: { throw Unexpected() })
        await harness.refresh()
        defaults().follow(from: .idle, to: .signedIn)
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
        defaults.follow(from: .idle, to: .idle)
        XCTAssertNil(store.readControl(slot: "button-1"), "a default was written signed out")
        defaults.follow(from: .exchanging, to: .signedIn)
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
        defaults().follow(from: .idle, to: .signedIn)
        let written = try store.writeControl(ControlDocument.read(#"{"title": "Lamp", "action": {"kind": "open"}}"#, slot: "button-2").document,
                                             slot: "button-2")
        let others = ControlSlot.all.map { store.readControl(slot: $0)?.document.revision }
        // A launch already signed in: the phase starts where it stands.
        defaults().follow(from: .signedIn, to: .signedIn)
        XCTAssertEqual(store.readControl(slot: "button-2")?.document.revision, written)
        XCTAssertEqual(store.readControl(slot: "button-2")?.document.title, "Lamp")
        XCTAssertEqual(ControlSlot.all.map { store.readControl(slot: $0)?.document.revision }, others, "a relaunch rewrote a slot")
    }

    /// A new login — the phase coming to signed in from anything else — keeps no slot an earlier
    /// login wrote: each is the default again, above the earlier revisions.
    func testANewLoginKeepsNoEarlierLoginsSlot() async throws {
        defaults().follow(from: .idle, to: .signedIn)
        let written = try store.writeControl(ControlDocument.read(#"{"title": "Lamp", "action": {"kind": "run", "topo": ["notify", "Lamp"]}}"#, slot: "button-2").document,
                                             slot: "button-2")
        defaults().follow(from: .approvingGuest(opening: nil, pasteHint: false), to: .signedIn)
        let document = try XCTUnwrap(store.readControl(slot: "button-2")?.document)
        XCTAssertTrue(document.isDefault, "an earlier login's slot outlived a new login")
        XCTAssertGreaterThan(document.revision, written)
    }

    /// The far end of a takeover takes the surfaces as a sign-out does: a slot the mind wrote
    /// draws "Sign in", and a tap on it at the revision it was drawn from runs nothing.
    func testATakeoverLeavesNoControlToRun() async throws {
        let db = InMemoryRecordDatabase()
        let harness = harness(db, defaults: makeDefaults(), transport: ScriptedTransport(), ensureZone: { throw Unexpected() })
        await harness.refresh()
        defaults().follow(from: .idle, to: .signedIn)
        let revision = try set("button-1", #"{"title": "Feed", "action": {"kind": "run", "topo": ["notify", "Feed"]}}"#)
        let notify = RecordingTool()
        let store = store
        let reloader = SurfaceReloader(reloadKind: { _ in }, reloadEverything: {}, reloadControlKind: { _ in },
                                       reloadEveryControl: {}, schedule: { _, _ in })
        let takeover = Takeover(demoteHarness: {}, acceptDemotion: {}, stopSpeaking: {}, forgetMemory: {},
                                forgetSurfaces: { reloader.forget(store) }, forgetConnections: {}, forgetLogin: {})
        await takeover.act()
        XCTAssertTrue(ControlValue.read(slot: "button-1", store: store).signedOut)
        XCTAssertEqual(ControlValue.read(slot: "button-1", store: store).title, "Sign in")
        let answer = await taps(harness, tools: [notify]).controlTapped(slot: "button-1", revision: revision, turningOn: nil)
        XCTAssertEqual(answer, .foreground)
        XCTAssertEqual(notify.calls, [], "a control ran after the takeover")
        XCTAssertEqual(store.taps(), [])
    }

    /// iOS 18 to 25: a turn control pressed with Topo killed launches the app in the background,
    /// where no screen has read the log. The intent's own drain reads it and sends the turn.
    func testAColdBackgroundTurnIsSent() async throws {
        let db = InMemoryRecordDatabase()
        let harness = harness(db, defaults: makeDefaults(), transport: ScriptedTransport())
        XCTAssertFalse(harness.hasRead)
        let revision = try set("button-1", #"{"title": "Lights", "action": {"kind": "turn", "say": "lights please"}}"#)
        let answer = await taps(harness).controlTapped(slot: "button-1", revision: revision, turningOn: nil)
        XCTAssertEqual(answer, .foreground)
        let words = "control button-1: lights please"
        func landed() async -> Bool {
            let log = TurnLog(database: db)
            return ((try? await log.read())?.ordered ?? []).contains { $0.role == .person && $0.text == words }
        }
        for _ in 0..<200 { if await landed() { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(harness.hasRead)
        let sent = await landed()
        XCTAssertTrue(sent, "the turn waited for a screen to read the log")
        XCTAssertEqual(store.cues(), [])
    }

    /// Signed out there are no documents: the value is "Sign in", and a tap on any revision comes
    /// forward and records and runs nothing.
    func testSignedOutTapRunsNothing() async throws {
        let db = InMemoryRecordDatabase()
        let harness = harness(db, defaults: makeDefaults(), transport: ScriptedTransport(), ensureZone: { throw Unexpected() })
        await harness.refresh()
        defaults().follow(from: .idle, to: .signedIn)
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

/// A `notify` that records each call.
private final class RecordingTool: Tool, @unchecked Sendable {
    let name = "notify"
    let summary = "a notify the test records"
    let usage = "anything"
    private let lock = NSLock()
    private var _calls: [[String]] = []
    var calls: [[String]] { lock.withLock { _calls } }
    func run(_ arguments: [String]) async -> ToolReply {
        lock.withLock { _calls.append(arguments) }
        return .ok("done\n")
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

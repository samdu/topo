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
        defaults.follow(from: .approving(.init(page: nil, pasting: false)), to: .signedIn)
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

    /// A turn tap whose intent ends while the log will not take the turn: the cue's words are in
    /// the harness's outbox under the cue's nonce (`Harness.pending`, kept in the defaults) and the
    /// cue is gone from the app group, so a later launch's harness sends them once, and the cue is
    /// not said a second time.
    func testATurnTheLogDidNotTakeBeforeTheProcessEndedIsSentOnceByTheNextLaunch() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()
        let stalled = harness(db, defaults: defaults, transport: ScriptedTransport(),
                              ensureZone: { try await Task.sleep(for: .seconds(3600)) })
        let revision = try set("button-1", #"{"title": "Lights", "action": {"kind": "turn", "say": "lights please"}}"#)
        let taps = taps(stalled)
        let answer = await taps.controlTapped(slot: "button-1", revision: revision, turningOn: nil)
        XCTAssertEqual(answer, .foreground)
        // The drain is a main-actor task the tap started, so it has not run yet.
        let cueNonce = try XCTUnwrap(store.cues().first?.nonce, "the tap recorded no cue")
        let deadline = ContinuousClock.now + .seconds(5)
        while stalled.owed.isEmpty || !store.cues().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.cues(), [], "the cue outlived its place on the line")
        let nonce = try XCTUnwrap(stalled.owed.first?.nonce, "the drain put nothing on the line")
        XCTAssertEqual(nonce, cueNonce, "the turn went on the line under a nonce that is not the cue's")

        // The process ends here; the next launch's harness reads the same defaults.
        let relaunched = harness(db, defaults: defaults, transport: ScriptedTransport())
        XCTAssertEqual(relaunched.owed.map(\.nonce), [nonce], "the outbox did not keep the turn")
        await relaunched.refresh()
        await relaunched.retry()
        await self.taps(relaunched).cues.drain()
        let said = (try await TurnLog(database: db).read()).ordered.filter { $0.role == .person }
        XCTAssertEqual(said.map(\.text), ["control button-1: lights please"], "the turn was lost or said twice")
    }

    /// A new login — the phase coming to signed in from anything else — keeps no slot an earlier
    /// login wrote: each is the default again, above the earlier revisions.
    func testANewLoginKeepsNoEarlierLoginsSlot() async throws {
        defaults().follow(from: .idle, to: .signedIn)
        let written = try store.writeControl(ControlDocument.read(#"{"title": "Lamp", "action": {"kind": "run", "topo": ["notify", "Lamp"]}}"#, slot: "button-2").document,
                                             slot: "button-2")
        defaults().follow(from: .approving(.init(page: URL(string: "https://claude.com/cai/oauth/authorize"), pasting: true)), to: .signedIn)
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
        let takeover = Takeover(moveEpoch: {}, forgetShares: {}, demoteHarness: {}, acceptDemotion: {}, stopSpeaking: {}, forgetMemory: {},
                                runTeardowns: {}, forgetSurfaces: { reloader.forget(store) }, forgetConnections: {}, forgetLogin: {})
        await takeover.act()
        XCTAssertTrue(ControlValue.read(slot: "button-1", store: store).signedOut)
        XCTAssertEqual(ControlValue.read(slot: "button-1", store: store).title, "Sign in")
        let answer = await taps(harness, tools: [notify]).controlTapped(slot: "button-1", revision: revision, turningOn: nil)
        XCTAssertEqual(answer, .foreground)
        XCTAssertEqual(notify.calls, [], "a control ran after the takeover")
        XCTAssertEqual(store.taps(), [])
    }

    /// A turn control pressed with Topo killed launches the app for the intent before any screen
    /// has read the log. The tap's own drain reads it and sends the turn.
    func testAColdBackgroundTurnIsSent() async throws {
        let db = InMemoryRecordDatabase()
        let harness = harness(db, defaults: makeDefaults(), transport: ScriptedTransport())
        XCTAssertFalse(harness.hasRead)
        let revision = try set("button-1", #"{"title": "Lights", "action": {"kind": "turn", "say": "lights please"}}"#)
        let taps = taps(harness)
        let answer = await taps.controlTapped(slot: "button-1", revision: revision, turningOn: nil)
        XCTAssertEqual(answer, .foreground)
        let draining = try XCTUnwrap(taps.draining, "the tap started no drain")
        await draining.value
        XCTAssertTrue(harness.hasRead)
        let said = (try await TurnLog(database: db).read()).ordered.filter { $0.role == .person }
        XCTAssertEqual(said.map(\.text), ["control button-1: lights please"], "the drain did not send the turn")
        XCTAssertEqual(store.cues(), [])
    }

    /// A cue whose turn is already in the log — an earlier drain sent it and its record was not
    /// removed — drained by a harness that has not read the log: the drain reads the log first,
    /// finds the cue's nonce there, and neither sets the toggle again (it was turned back off
    /// since) nor puts the turn on the line a second time.
    func testACueAlreadyInTheLogIsReadFirstAndNotActedOnAgain() async throws {
        let db = InMemoryRecordDatabase()
        let revision = try set("toggle-1", #"{"title": "Fan", "on": false, "action": {"kind": "turn", "say": "fan"}}"#)
        let nonce = UUID().uuidString
        let log = TurnLog(database: db)
        let writer = try await log.writer(for: phone)
        _ = try await writer.append(.person, "control toggle-1: fan on", continuing: try await log.read(), nonce: nonce)
        try store.appendCue(SurfaceStore.Cue(nonce: nonce, slot: ControlSlot.stored("toggle-1"), id: ControlSlot.control,
                                             revision: revision, turningOn: true, time: Date(), resolved: true))
        // The zone is not made, so nothing on the line is sent: what the drain put there stays.
        let harness = harness(db, defaults: makeDefaults(), transport: ScriptedTransport(), ensureZone: { throw Unexpected() })
        XCTAssertFalse(harness.hasRead)
        await taps(harness).cues.drain()
        XCTAssertTrue(harness.hasRead, "the drain did not read the log first")
        XCTAssertEqual(store.readControl(slot: "toggle-1")?.document.on, false, "a cue already sent set its toggle again")
        XCTAssertFalse(harness.owed.contains { $0.nonce == nonce }, "a cue already sent went on the line again")
        let said = (try await log.read()).ordered.filter { $0.role == .person }
        XCTAssertEqual(said.map(\.nonce), [nonce])
        XCTAssertEqual(store.cues(), [])
    }

    /// A cue drained by a harness that has not read the log, over a log whose read fails with
    /// something other than "no log yet": a read that failed is not an answer, so the drain acts on
    /// nothing — the cue stays in the app group and nothing goes on the line.
    func testACueIsNotActedOnWhenTheLogCannotBeRead() async throws {
        let revision = try set("button-1", #"{"title": "Lights", "action": {"kind": "turn", "say": "lights please"}}"#)
        let nonce = UUID().uuidString
        try store.appendCue(SurfaceStore.Cue(nonce: nonce, slot: ControlSlot.stored("button-1"), id: ControlSlot.control,
                                             revision: revision, turningOn: nil, time: Date()))
        let harness = harness(UnreadableDatabase(), defaults: makeDefaults(), transport: ScriptedTransport(),
                              ensureZone: { throw Unexpected() })
        XCTAssertFalse(harness.hasRead)
        await taps(harness).cues.drain()
        XCTAssertFalse(harness.hasRead, "a read that failed was taken as a read")
        XCTAssertEqual(store.cues().map(\.nonce), [nonce], "the drain dropped a cue it could not check against the log")
        XCTAssertEqual(harness.owed.count, 0, "the drain put a turn on the line without reading the log")
        XCTAssertEqual(store.taps(), [])
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
        Harness(database: database, device: phone, ensureZone: ensureZone,
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


private struct Unexpected: Error {}

/// A log that cannot be read, for a reason that is not "no log yet": every call is unavailable.
private struct UnreadableDatabase: RecordDatabase {
    private var refusal: RecordDatabaseError { .unavailable(underlying: Unexpected()) }
    func save(_ records: [Record]) async throws -> [Record] { throw refusal }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { throw refusal }
    func query(_ query: RecordQuery) async throws -> [Record] { throw refusal }
    func records(ofType type: String) async throws -> [Record] { throw refusal }
}

/// A heartbeat loop that never beats inside a test: the lease is renewed by the turns themselves.
private let parked: @Sendable (TimeInterval) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }

import Foundation
import HomeKit
import TopoTools
import XCTest

@testable import Topo

/// A tool the test scripts: what it answers, how long it takes, and whether it checks for
/// cancellation before its effect. It counts every call and every effect.
private final class CountingTool: Tool, @unchecked Sendable {
    let name: String
    let summary = "a tool the test counts"
    let usage = "anything"
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var _effects = 0
    var reply = ToolReply.ok("done\n")
    var delay: Duration?
    var calls: [[String]] { lock.withLock { _calls } }
    var effects: Int { lock.withLock { _effects } }

    init(_ name: String) { self.name = name }

    func run(_ arguments: [String]) async -> ToolReply {
        lock.withLock { _calls.append(arguments) }
        if let delay {
            try? await Task.sleep(for: delay)
            // What every phone tool does before its write (`HomeAccess.write`, `NotifyTool`).
            if Task.isCancelled { return PhoneTool.late }
        }
        lock.withLock { _effects += 1 }
        return reply
    }
}

/// `home` whose `on` is slow and `off` quick, recording each effect as it lands.
private final class EffectTool: Tool, @unchecked Sendable {
    let name = "home"
    let summary = "a home whose on is slow"
    let usage = "anything"
    private let lock = NSLock()
    private var _effects: [String] = []
    private var _failing: Set<String> = []
    var effects: [String] { lock.withLock { _effects } }
    var failing: Set<String> {
        get { lock.withLock { _failing } }
        set { lock.withLock { _failing = newValue } }
    }

    func run(_ arguments: [String]) async -> ToolReply {
        let state = arguments.last ?? ""
        try? await Task.sleep(for: state == "on" ? .milliseconds(300) : .milliseconds(10))
        if failing.contains(state) { return ToolReply(status: ToolReply.denied, text: "topo: HomeKit is not allowed\n") }
        lock.withLock { _effects.append(state) }
        return .ok("done\n")
    }
}

/// A loaded home with a lock, a scene that unlocks it and one holding an action that cannot be
/// read, recording what it was asked to do.
@MainActor
private final class LockedHome: HomeStore {
    var authorization: HMHomeManagerAuthorizationStatus = []
    var changed: (@MainActor (HomeChange) -> Void)?
    var records: [HomeRecord] = []
    private(set) var writes: [String] = []
    private(set) var scenesRun: [String] = []
    func homes() -> [HomeRecord] { records }
    func read(_ characteristic: String) async throws -> HomeValue? { nil }
    func write(_ value: HomeValue, to characteristic: String) async throws { writes.append(characteristic) }
    func run(scene: String) async throws { scenesRun.append(scene) }

    static let house = HomeRecord(id: "H", name: "Home", primary: true, accessories: [
        HomeAccessory(id: "LOCK-1", name: "Front door", room: "Hall", category: "Door Lock", reachable: true, services: [
            HomeService(name: "Front door", kind: "Lock Mechanism", characteristics: [
                HomeCharacteristic(id: "LOCK-T", name: "lock", format: "uint8", readable: true, writable: true, minimum: nil,
                                   maximum: nil, step: nil, validValues: [0, 1], maxLength: nil, units: nil, value: nil,
                                   type: HMCharacteristicTypeTargetLockMechanismState),
            ]),
        ]),
    ], scenes: [HomeScene(id: "SC-LEAVE", name: "Leave", writes: [HMCharacteristicTypeTargetLockMechanismState]),
                HomeScene(id: "SC-LIGHTS", name: "Lights", writes: [HMCharacteristicTypePowerState]),
                HomeScene(id: "SC-ODD", name: "Odd", writes: [HMCharacteristicTypePowerState, HomeScene.unknownAction])])

    /// A `home` over this home, loaded as HomeKit would load it.
    static func tool() -> (LockedHome, HomeTool) {
        let fake = LockedHome()
        let access = HomeAccess {
            Task { @MainActor in
                fake.authorization = [.determined, .authorized]
                fake.changed?(.authorization)
                fake.records = [house]
                fake.changed?(.homes)
            }
            return fake
        }
        return (fake, HomeTool(home: access, authorizer: HomeAuthorizer(home: access), broker: PermissionBroker()))
    }
}

/// Review Focus 6 and 12: a `run` control's tap goes through `ToolService.bounded` once, answers
/// at the bound, does nothing after it, records a status and never a word the tool said, and a
/// tap on an old revision runs nothing.
@MainActor
final class WidgetActionTests: XCTestCase {
    private var folder: URL!
    private var reloads: [String] = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("widget-actions-\(UUID().uuidString)")
        reloads = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var store: SurfaceStore { SurfaceStore(folder: folder) }

    private func actions(_ tools: [any Tool], bound: Duration = .seconds(5)) -> WidgetActions {
        let store = store
        let reloader = SurfaceReloader(reloadKind: { [unowned self] in reloads.append($0) }, reloadEverything: {},
                                       schedule: { _, body in body() })
        return WidgetActions(table: ToolTable(tools), store: { store }, reloader: reloader, bound: bound)
    }

    /// Writes a slot with one button running `argv`, as `topo widget set` would, and answers
    /// its revision.
    @discardableResult
    private func set(_ argv: [String], id: String = "go", kind: String = "button") throws -> Int {
        let words = argv.map { "\"\($0)\"" }.joined(separator: ", ")
        let text = #"{"families": {"systemSmall": {"kind": "\#(kind)", "id": "\#(id)", "label": "Go", "action": {"kind": "run", "topo": [\#(words)]}}}}"#
        let reading = WidgetDocument.read(text)
        XCTAssertEqual(reading.notes, [])
        return try store.write(reading.document, slot: "demo")
    }

    func testRunGoesThroughBounded() async throws {
        let notify = CountingTool("notify")
        let revision = try set(["notify", "Bins", "--in", "1h"])
        await actions([notify]).run(slot: "demo", control: "go", revision: revision, turningOn: nil)
        XCTAssertEqual(notify.calls, [["Bins", "--in", "1h"]], "the table saw another call, or it more than once")
        XCTAssertEqual(store.taps().map(\.status), ["0"])
        XCTAssertEqual(reloads, [SurfaceStore.kind])
    }

    func testAToggleRunsWithItsNewState() async throws {
        let home = CountingTool("home")
        let revision = try set(["home", "set", "LAMP", "power"], kind: "toggle")
        await actions([home]).run(slot: "demo", control: "go", revision: revision, turningOn: true)
        XCTAssertEqual(home.calls, [["set", "LAMP", "power", "on"]])
    }

    func testStalledToolAnswersAtBound() async throws {
        let notify = CountingTool("notify")
        notify.delay = .seconds(3600)
        let revision = try set(["notify", "Bins"])
        let started = ContinuousClock.now
        await actions([notify], bound: .milliseconds(200)).run(slot: "demo", control: "go", revision: revision, turningOn: nil)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "the tap waited on the tool past its bound")
        XCTAssertEqual(store.taps().map(\.status), [String(ToolReply.timedOut)])
    }

    func testLateCancelDoesNothing() async throws {
        let notify = CountingTool("notify")
        notify.delay = .milliseconds(600)
        let revision = try set(["notify", "Bins"])
        await actions([notify], bound: .milliseconds(100)).run(slot: "demo", control: "go", revision: revision, turningOn: nil)
        XCTAssertEqual(store.taps().map(\.status), [String(ToolReply.timedOut)])
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertEqual(notify.calls.count, 1)
        XCTAssertEqual(notify.effects, 0, "the tool took its effect after the bound had answered")
    }

    func testRunDeniedIsStatusNotSilence() async throws {
        let home = CountingTool("home")
        home.reply = ToolReply(status: ToolReply.denied, text: "topo: HomeKit is not allowed\n")
        let revision = try set(["home", "scene", "SC-1"])
        await actions([home]).run(slot: "demo", control: "go", revision: revision, turningOn: nil)
        XCTAssertEqual(store.taps().map(\.status), [String(ToolReply.denied)])
        guard case .drawn(_, let context, _, _) = SurfaceProvider.surface(slot: "demo", family: .systemSmall, at: Date(), store: store) else {
            return XCTFail("the slot was not drawn")
        }
        XCTAssertEqual(context.failed, ["go"], "the next timeline does not mark the failed control")
    }

    func testTapsCarryNoOutput() async throws {
        let sentinel = "SENTINEL-\(UUID().uuidString)"
        let notify = CountingTool("notify")
        notify.reply = .ok("scheduled: \(sentinel)\n")
        let revision = try set(["notify", "Bins"])
        await actions([notify]).run(slot: "demo", control: "go", revision: revision, turningOn: nil)
        let raw = try String(contentsOf: store.tapsURL, encoding: .utf8)
        XCTAssertFalse(raw.contains(sentinel), "a tool's words reached taps.jsonl")
        XCTAssertFalse(raw.contains("Bins"), "a call's argument reached taps.jsonl")
        XCTAssertEqual(store.taps().count, 1)
    }

    func testStaleRevisionRefused() async throws {
        let notify = CountingTool("notify")
        let reminders = CountingTool("reminders")
        let first = try set(["notify", "Bins"])
        // What the first render drew is a tap on `first`; the slot is set again, the id reused.
        try set(["reminders", "done", "R1"])
        await actions([notify, reminders]).run(slot: "demo", control: "go", revision: first, turningOn: nil)
        XCTAssertEqual(notify.calls, [])
        XCTAssertEqual(reminders.calls, [])
        XCTAssertEqual(store.taps().map(\.status), ["stale"])
        XCTAssertEqual(reloads, [SurfaceStore.kind], "a stale tap reloads the widget onto the slot as it is")
    }

    /// The tap judges the allowlist itself, whatever the document it is handed: here one the
    /// reader would have turned to `open`, handed past it.
    func testARunOffTheAllowlistIsRefusedAtTheTap() async throws {
        let calendar = CountingTool("calendar")
        var document = WidgetDocument()
        document.revision = 4
        document.families[.systemSmall] = .control(WidgetControl(kind: .button, id: "go", label: [], action: .run(["calendar", "add", "x"])))
        let store = store
        let actions = WidgetActions(table: ToolTable([calendar]), store: { store },
                                    reloader: SurfaceReloader(reloadKind: { _ in }, reloadEverything: {}, schedule: { _, _ in }),
                                    read: { _, _ in document })
        await actions.run(slot: "demo", control: "go", revision: 4, turningOn: nil)
        XCTAssertEqual(calendar.calls, [], "the tap ran a call off the allowlist")
        XCTAssertEqual(store.taps().map(\.status), [String(ToolReply.refused)])
    }

    /// Runs a lock's target set by id, a scene that unlocks the lock, a scene holding an action
    /// that cannot be read, and a lights scene through `table`, each from a widget's tap, and
    /// asserts the first three refused and only the lights run.
    private func assertRefusesLocks(_ table: ToolTable, _ fake: LockedHome, file: StaticString = #filePath, line: UInt = #line) async throws {
        let store = store
        let actions = WidgetActions(table: table, store: { store },
                                    reloader: SurfaceReloader(reloadKind: { _ in }, reloadEverything: {}, schedule: { _, _ in }))
        for argv in [["home", "set", "LOCK-1", "LOCK-T", "0"], ["home", "scene", "SC-LEAVE"], ["home", "scene", "SC-ODD"]] {
            let revision = try set(argv)
            await actions.run(slot: "demo", control: "go", revision: revision, turningOn: nil)
            XCTAssertEqual(store.taps().last?.status, String(ToolReply.refused), "\(argv) ran from a widget", file: file, line: line)
        }
        XCTAssertEqual(fake.writes, [], file: file, line: line)
        XCTAssertEqual(fake.scenesRun, [], file: file, line: line)
        let lights = try set(["home", "scene", "SC-LIGHTS"])
        await actions.run(slot: "demo", control: "go", revision: lights, turningOn: nil)
        XCTAssertEqual(fake.scenesRun, ["SC-LIGHTS"], "a scene that sets no lock is refused too", file: file, line: line)
    }

    /// The widgets' table (`WidgetActions.table`) refuses a lock's target named by id, a scene
    /// that unlocks it, and a scene it cannot read, at the tap: the reader passes all three,
    /// since only HomeKit's data says what they are.
    func testTheWidgetsTableRefusesALockAndASceneThatUnlocksOne() async throws {
        let (fake, home) = LockedHome.tool()
        try await assertRefusesLocks(WidgetActions.table([home]), fake)
    }

    /// The handler the running app set at launch (`TopoApp.init`, which hosts this suite) runs
    /// its taps on the widgets' table: its `home` refuses what the widgets' does. It is run here
    /// over the fake home with the app's own refusals.
    func testTheAppsHandlerRunsOnTheWidgetsTable() async throws {
        let taps = try XCTUnwrap(WidgetIntents.handler as? WidgetTaps, "the app set no widget handler at launch")
        let appHome = try XCTUnwrap(taps.actions.table.tool(named: "home") as? HomeTool, "the app's widget table has no home")
        let (fake, home) = LockedHome.tool()
        var probe = home
        probe.refusing = appHome.refusing
        try await assertRefusesLocks(ToolTable([probe]), fake)
    }

    /// A toggle turns to the opposite of its stored state as each tap is handled, not of the
    /// state the tapped entry drew: two taps before any reload, both drawn off, are on and off.
    func testTwoToggleTapsBeforeAReloadAreOnThenOff() async throws {
        let home = CountingTool("home")
        home.delay = .milliseconds(200)
        let revision = try set(["home", "set", "LAMP", "power"], kind: "toggle")
        let actions = actions([home])
        async let first: Void = actions.run(slot: "demo", control: "go", revision: revision, turningOn: true)
        async let second: Void = actions.run(slot: "demo", control: "go", revision: revision, turningOn: true)
        _ = await (first, second)
        XCTAssertEqual(home.calls, [["set", "LAMP", "power", "on"], ["set", "LAMP", "power", "off"]])
        XCTAssertEqual(store.read(slot: "demo")?.document.controls["go"]?.on, false)
    }

    /// A toggle whose run failed is drawn as it was, so the next tap asks for the same state.
    func testAFailedToggleStaysAsItWas() async throws {
        let home = CountingTool("home")
        home.reply = ToolReply(status: ToolReply.denied, text: "topo: HomeKit is not allowed\n")
        let revision = try set(["home", "set", "LAMP", "power"], kind: "toggle")
        await actions([home]).run(slot: "demo", control: "go", revision: revision, turningOn: true)
        XCTAssertEqual(store.read(slot: "demo")?.document.controls["go"]?.on, false)
        XCTAssertEqual(store.read(slot: "demo")?.document.revision, revision, "a toggle's state moved the slot's revision")
        home.reply = .ok("done\n")
        await actions([home]).run(slot: "demo", control: "go", revision: revision, turningOn: true)
        XCTAssertEqual(home.calls.map(\.last), ["on", "on"])
        XCTAssertEqual(store.read(slot: "demo")?.document.controls["go"]?.on, true)
    }

    /// The drawn document's relevance reaches WidgetKit.
    func testRelevanceReachesTheTimeline() throws {
        let text = #"{"relevance": 1, "families": {"systemSmall": {"kind": "divider"}}}"#
        try store.write(WidgetDocument.read(text).document, slot: "demo")
        try store.write(WidgetDocument.read(#"{"families": {"systemSmall": {"kind": "divider"}}}"#).document, slot: "plain")
        let timeline = SurfaceProvider.timeline(slot: "demo", family: .systemSmall, now: Date(), store: store)
        XCTAssertEqual(timeline.entries.first?.relevance?.score, 1)
        XCTAssertNil(SurfaceProvider.timeline(slot: "plain", family: .systemSmall, now: Date(), store: store).entries.first?.relevance)
    }

    /// A control's runs land in the order its taps were handled, whichever call is quicker, and a
    /// run that fails holds up none after it.
    func testAControlsRunsLandInTheOrderItsTapsWere() async throws {
        let home = EffectTool()
        let revision = try set(["home", "set", "LAMP", "power"], kind: "toggle")
        let actions = actions([home])
        // Two taps, answered within a deadline, so a chain that stalls fails rather than hangs.
        func twoTaps() async {
            let answered = expectation(description: "both taps answered")
            Task { @MainActor in
                async let first: Void = actions.run(slot: "demo", control: "go", revision: revision, turningOn: true)
                async let second: Void = actions.run(slot: "demo", control: "go", revision: revision, turningOn: true)
                _ = await (first, second)
                answered.fulfill()
            }
            await fulfillment(of: [answered], timeout: 10)
        }
        await twoTaps()
        XCTAssertEqual(home.effects, ["on", "off"], "the quicker off landed before the on tapped first")

        home.failing = ["on"]
        await twoTaps()
        XCTAssertEqual(home.effects, ["on", "off", "off"], "a failed run held up the tap after it")
        XCTAssertEqual(store.taps().suffix(2).map(\.status), [String(ToolReply.denied), "0"])
        XCTAssertEqual(store.read(slot: "demo")?.document.controls["go"]?.on, false)
    }
}

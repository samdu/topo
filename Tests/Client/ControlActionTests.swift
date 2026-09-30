import Foundation
import TopoTools
import XCTest

@testable import Topo

/// A tool the test scripts: what it answers and how long it takes, counting every call.
private final class CountingTool: Tool, @unchecked Sendable {
    let name: String
    let summary = "a tool the test counts"
    let usage = "anything"
    private let lock = NSLock()
    private var _calls: [[String]] = []
    var reply = ToolReply.ok("done\n")
    var delay: Duration?
    var calls: [[String]] { lock.withLock { _calls } }

    init(_ name: String) { self.name = name }

    func run(_ arguments: [String]) async -> ToolReply {
        lock.withLock { _calls.append(arguments) }
        if let delay {
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return PhoneTool.late }
        }
        return reply
    }
}

/// `home` answering each call in turn with its scripted delay and reply.
private final class ScriptedTool: Tool, @unchecked Sendable {
    let name = "home"
    let summary = "a home the test scripts call by call"
    let usage = "anything"
    private let lock = NSLock()
    private var script: [(Duration, ToolReply)]
    private var _calls: [[String]] = []
    var calls: [[String]] { lock.withLock { _calls } }
    init(_ script: [(Duration, ToolReply)]) { self.script = script }
    func run(_ arguments: [String]) async -> ToolReply {
        let (delay, reply) = lock.withLock { () -> (Duration, ToolReply) in
            _calls.append(arguments)
            return script.isEmpty ? (.zero, .ok("done\n")) : script.removeFirst()
        }
        try? await Task.sleep(for: delay)
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
    var effects: [String] { lock.withLock { _effects } }

    func run(_ arguments: [String]) async -> ToolReply {
        let state = arguments.last ?? ""
        try? await Task.sleep(for: state == "on" ? .milliseconds(300) : .milliseconds(10))
        lock.withLock { _effects.append(state) }
        return .ok("done\n")
    }
}

/// Review Focus 3, 5 and 6 of the controls' plan: a control's run is A's run — the revision
/// judged, `ToolService.bounded` once, the status recorded and never retried — and a toggle sets
/// the state the person asked for, going back to its confirmed one when its run fails.
@MainActor
final class ControlActionTests: XCTestCase {
    private var folder: URL!
    private var reloads: [String] = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("control-actions-\(UUID().uuidString)")
        reloads = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var store: SurfaceStore { SurfaceStore(folder: folder) }

    private func actions(_ tools: [any Tool], bound: Duration = .seconds(5)) -> WidgetActions {
        let store = store
        let reloader = SurfaceReloader(reloadKind: { [unowned self] in reloads.append($0) }, reloadEverything: {},
                                       reloadControlKind: { [unowned self] in reloads.append($0) }, reloadEveryControl: {},
                                       schedule: { _, body in body() })
        return WidgetActions(table: ToolTable(tools), store: { store }, reloader: reloader, bound: bound)
    }

    /// Writes `slot` running `argv`, as `topo control set` would, and answers its revision.
    @discardableResult
    private func set(_ slot: String, _ argv: [String], on: Bool = false) throws -> Int {
        var object: [String: Any] = ["title": "Go", "action": ["kind": "run", "topo": argv]]
        if slot.hasPrefix("toggle") { object["on"] = on }
        let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let reading = ControlDocument.read(text, slot: slot)
        XCTAssertEqual(reading.notes, [])
        return try store.writeControl(reading.document, slot: slot)
    }

    private func tap(_ actions: WidgetActions, _ slot: String, revision: Int, turningOn: Bool? = nil) async {
        await actions.run(slot: ControlSlot.stored(slot), control: ControlSlot.control, revision: revision, turningOn: turningOn)
    }

    func testRunGoesThroughBounded() async throws {
        let notify = CountingTool("notify")
        let revision = try set("button-1", ["notify", "Bins", "--in", "1h"])
        await tap(actions([notify]), "button-1", revision: revision)
        XCTAssertEqual(notify.calls, [["Bins", "--in", "1h"]])
        XCTAssertEqual(store.taps().map(\.status), ["0"])
        XCTAssertEqual(store.taps().map(\.slot), [ControlSlot.stored("button-1")])
        XCTAssertEqual(reloads, [ControlSlot.Kind.button.controlKind], "a control's run reloads its kind, not the widgets'")

        let stalled = CountingTool("notify")
        stalled.delay = .seconds(3600)
        let started = ContinuousClock.now
        await tap(actions([stalled], bound: .milliseconds(200)), "button-1", revision: revision)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "the tap waited on the tool past its bound")
        XCTAssertEqual(store.taps().last?.status, String(ToolReply.timedOut))
    }

    /// A failed or unknown result is recorded, never tried again.
    func testFailedRunIsNotRetried() async throws {
        let failing = CountingTool("home")
        failing.reply = ToolReply(status: ToolReply.failed, text: "topo: the hub did not answer\n")
        let revision = try set("button-2", ["home", "scene", "SC-TREAT"])
        await tap(actions([failing]), "button-2", revision: revision)
        XCTAssertEqual(failing.calls.count, 1)
        XCTAssertEqual(store.taps().map(\.status), ["1"])

        let unknown = CountingTool("home")
        unknown.delay = .seconds(3600)
        await tap(actions([unknown], bound: .milliseconds(150)), "button-2", revision: revision)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(unknown.calls.count, 1, "a run answered at its bound was tried again")
        XCTAssertEqual(store.taps().map(\.status), ["1", String(ToolReply.timedOut)])
    }

    /// A slot rewritten between the draw and the tap: the tap drawn from the first value runs
    /// nothing, is recorded stale, and the controls are reloaded onto the slot as it is.
    func testStaleRevisionRefused() async throws {
        let notify = CountingTool("notify")
        let reminders = CountingTool("reminders")
        try set("button-3", ["notify", "Bins"])
        let drawn = ControlValue.read(slot: "button-3", store: store)
        try set("button-3", ["reminders", "done", "R1"])
        await tap(actions([notify, reminders]), "button-3", revision: drawn.revision)
        XCTAssertEqual(notify.calls, [])
        XCTAssertEqual(reminders.calls, [])
        XCTAssertEqual(store.taps().map(\.status), ["stale"])
        XCTAssertEqual(reloads, [ControlSlot.Kind.button.controlKind])
    }

    /// The toggle's intent carries the state asked for: the stored state becomes it and the call
    /// gets it, rather than the opposite of what was stored.
    func testToggleSetsWhatWasAsked() async throws {
        let home = CountingTool("home")
        let revision = try set("toggle-1", ["home", "set", "LAMP", "power"], on: false)
        await tap(actions([home]), "toggle-1", revision: revision, turningOn: true)
        XCTAssertEqual(home.calls, [["set", "LAMP", "power", "on"]])
        XCTAssertEqual(store.readControl(slot: "toggle-1")?.document.on, true)
        XCTAssertEqual(store.readControl(slot: "toggle-1")?.document.revision, revision, "setting the state took a revision")
        // Asked for on again, which the stored state already is: on, not flipped to off.
        await tap(actions([home]), "toggle-1", revision: revision, turningOn: true)
        XCTAssertEqual(home.calls.last, ["set", "LAMP", "power", "on"])
        XCTAssertEqual(store.readControl(slot: "toggle-1")?.document.on, true)
    }

    func testFailedToggleGoesBack() async throws {
        let home = CountingTool("home")
        home.reply = ToolReply(status: ToolReply.denied, text: "topo: HomeKit is not allowed\n")
        let revision = try set("toggle-2", ["home", "set", "LAMP", "power"], on: false)
        await tap(actions([home]), "toggle-2", revision: revision, turningOn: true)
        XCTAssertEqual(store.readControl(slot: "toggle-2")?.document.on, false, "a failed run left the toggle on")
        XCTAssertEqual(store.taps().map(\.status), [String(ToolReply.denied)])
        XCTAssertTrue(reloads.contains(ControlSlot.Kind.toggle.controlKind))
    }

    /// Two quick taps, on then off, whose on is the slower call: the effects land in the order
    /// the taps were made, and the toggle ends as the last tap asked.
    func testTwoTapsLandInOrder() async throws {
        let home = EffectTool()
        let revision = try set("toggle-3", ["home", "set", "LAMP", "power"], on: false)
        let actions = actions([home])
        let slot = ControlSlot.stored("toggle-3")
        async let first: Void = actions.run(slot: slot, control: ControlSlot.control, revision: revision, turningOn: true)
        try await Task.sleep(for: .milliseconds(20))
        async let second: Void = actions.run(slot: slot, control: ControlSlot.control, revision: revision, turningOn: false)
        _ = await (first, second)
        XCTAssertEqual(home.effects, ["on", "off"])
        XCTAssertEqual(store.readControl(slot: "toggle-3")?.document.on, false)
    }

    /// On, off, on in quick succession, the first failing and the others taking: the device ends
    /// on, and so does the toggle — the first failure does not put back a state a later tap drew.
    func testAnEarlyFailureDoesNotUndoALaterSuccess() async throws {
        let home = ScriptedTool([(.milliseconds(200), ToolReply(status: ToolReply.failed, text: "no\n")),
                                 (.milliseconds(10), .ok("done\n")), (.milliseconds(10), .ok("done\n"))])
        let revision = try set("toggle-5", ["home", "set", "LAMP", "power"], on: false)
        let actions = actions([home])
        let slot = ControlSlot.stored("toggle-5")
        async let first: Void = actions.run(slot: slot, control: ControlSlot.control, revision: revision, turningOn: true)
        try await Task.sleep(for: .milliseconds(20))
        async let second: Void = actions.run(slot: slot, control: ControlSlot.control, revision: revision, turningOn: false)
        try await Task.sleep(for: .milliseconds(20))
        async let third: Void = actions.run(slot: slot, control: ControlSlot.control, revision: revision, turningOn: true)
        _ = await (first, second, third)
        XCTAssertEqual(home.calls.map { $0.last }, ["on", "off", "on"])
        XCTAssertEqual(store.readControl(slot: "toggle-5")?.document.on, true, "the toggle shows a state the device is not in")
    }

    /// On then off, the on taking and the off failing: the toggle goes back to on, the state the
    /// device is in, not to the off it started from.
    func testALastFailureGoesBackToTheLastSuccess() async throws {
        let home = ScriptedTool([(.milliseconds(100), .ok("done\n")), (.milliseconds(10), ToolReply(status: ToolReply.failed, text: "no\n"))])
        let revision = try set("toggle-6", ["home", "set", "LAMP", "power"], on: false)
        let actions = actions([home])
        let slot = ControlSlot.stored("toggle-6")
        async let first: Void = actions.run(slot: slot, control: ControlSlot.control, revision: revision, turningOn: true)
        try await Task.sleep(for: .milliseconds(20))
        async let second: Void = actions.run(slot: slot, control: ControlSlot.control, revision: revision, turningOn: false)
        _ = await (first, second)
        XCTAssertEqual(store.readControl(slot: "toggle-6")?.document.on, true)
    }

    /// A slot written anew while an older revision's run is in flight: every run failing, the new
    /// revision's taps put the toggle back to the new revision's own state, not to a tap's. (A run
    /// that outlives its revision writes nothing, succeeding or not: the rewrite's state stands.)
    func testANewRevisionsFailuresGoBackToItsOwnState() async throws {
        let home = ScriptedTool([(.milliseconds(300), ToolReply(status: ToolReply.failed, text: "no\n")),
                                 (.milliseconds(10), ToolReply(status: ToolReply.failed, text: "no\n")),
                                 (.milliseconds(10), ToolReply(status: ToolReply.failed, text: "no\n"))])
        let first = try set("toggle-1", ["home", "set", "LAMP", "power"], on: false)
        let actions = actions([home])
        let slot = ControlSlot.stored("toggle-1")
        async let old: Void = actions.run(slot: slot, control: ControlSlot.control, revision: first, turningOn: true)
        try await Task.sleep(for: .milliseconds(50))
        let second = try set("toggle-1", ["home", "set", "LAMP", "power"], on: false)
        async let on: Void = actions.run(slot: slot, control: ControlSlot.control, revision: second, turningOn: true)
        try await Task.sleep(for: .milliseconds(20))
        async let off: Void = actions.run(slot: slot, control: ControlSlot.control, revision: second, turningOn: false)
        _ = await (old, on, off)
        XCTAssertEqual(store.readControl(slot: "toggle-1")?.document.on, false, "both runs failed and the toggle shows on")
    }

    /// A second tap whose state could not be written stands as no tap: the first tap's failure
    /// still puts the toggle back.
    func testATapThatCouldNotBeWrittenDoesNotHoldUpARestore() async throws {
        let home = ScriptedTool([(.milliseconds(300), ToolReply(status: ToolReply.failed, text: "no\n"))])
        let revision = try set("toggle-2", ["home", "set", "LAMP", "power"], on: false)
        let actions = actions([home])
        let slot = ControlSlot.stored("toggle-2")
        async let first: Void = actions.run(slot: slot, control: ControlSlot.control, revision: revision, turningOn: true)
        try await Task.sleep(for: .milliseconds(50))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        await actions.run(slot: slot, control: ControlSlot.control, revision: revision, turningOn: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        await first
        XCTAssertEqual(home.calls.count, 1)
        XCTAssertEqual(store.readControl(slot: "toggle-2")?.document.on, false, "the failed run left the toggle on")
    }

    /// `topo control state` while a run is in flight, then the run takes: the toggle shows the
    /// state the run put the device in.
    func testASuccessAfterTheMindsStateShowsTheRunsState() async throws {
        let home = ScriptedTool([(.milliseconds(200), .ok("done\n"))])
        let revision = try set("toggle-3", ["home", "set", "LAMP", "power"], on: false)
        let actions = actions([home])
        let slot = ControlSlot.stored("toggle-3")
        async let tapped: Void = actions.run(slot: slot, control: ControlSlot.control, revision: revision, turningOn: true)
        try await Task.sleep(for: .milliseconds(50))
        _ = try store.setControl(false, slot: "toggle-3", revision: revision)
        actions.confirm(false, slot: slot, control: ControlSlot.control, revision: revision)
        await tapped
        XCTAssertEqual(store.readControl(slot: "toggle-3")?.document.on, true)
    }

    /// `topo control state` while a toggle's run is in flight: a failure after it goes back to
    /// what the mind said.
    func testAConfirmedStateIsWhatAFailureGoesBackTo() async throws {
        let home = CountingTool("home")
        home.delay = .milliseconds(200)
        home.reply = ToolReply(status: ToolReply.failed, text: "no\n")
        let revision = try set("toggle-4", ["home", "set", "LAMP", "power"], on: false)
        let actions = actions([home])
        let slot = ControlSlot.stored("toggle-4")
        async let tapped: Void = actions.run(slot: slot, control: ControlSlot.control, revision: revision, turningOn: true)
        try await Task.sleep(for: .milliseconds(50))
        _ = try store.setControl(true, slot: "toggle-4", revision: revision)
        actions.confirm(true, slot: slot, control: ControlSlot.control, revision: revision)
        await tapped
        XCTAssertEqual(store.readControl(slot: "toggle-4")?.document.on, true)
    }
}

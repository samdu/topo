import Foundation
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

    func testARunOffTheAllowlistIsRefusedAtTheTap() async throws {
        let calendar = CountingTool("calendar")
        // Written straight into the store, past the reader, as an older build or a hand edit could.
        var document = WidgetDocument()
        document.families[.systemSmall] = .control(WidgetControl(kind: .button, id: "go", label: [], action: .run(["calendar", "add", "x"])))
        let revision = try store.write(document, slot: "demo")
        await actions([calendar]).run(slot: "demo", control: "go", revision: revision, turningOn: nil)
        XCTAssertEqual(calendar.calls, [])
        XCTAssertEqual(store.taps().map(\.status), [String(ToolReply.refused)])
    }
}

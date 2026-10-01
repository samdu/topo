import HomeKit
import TopoTools
import XCTest

@testable import Topo

/// A loaded home for the judge, answering at once.
@MainActor
private final class LoadedHome: HomeStore {
    var authorization: HMHomeManagerAuthorizationStatus = []
    var changed: (@MainActor (HomeChange) -> Void)?
    var records: [HomeRecord] = []
    func homes() -> [HomeRecord] { records }
    func read(_ characteristic: String) async throws -> HomeValue? { nil }
    func write(_ value: HomeValue, to characteristic: String) async throws {}
    func run(scene: String) async throws {}
}

/// `topo control`: its round trip, a run judged at `set` as a widget's is, a toggle's state set
/// alone, the defaults written back, the secrets kept by name, the listing and the taps saying
/// nothing a request carried, and one reload per kind.
@MainActor
final class ControlToolTests: XCTestCase {
    private static let lampID = "6A1F0C2E-0000-4000-8000-000000000001"
    private static let lockID = "9B7E3D10-0000-4000-8000-000000000003"

    private static func characteristic(_ id: String, _ name: String, _ format: String, valid: [Decimal]? = nil) -> HomeCharacteristic {
        HomeCharacteristic(id: id, name: name, format: format, readable: true, writable: true, minimum: nil, maximum: nil,
                           step: nil, validValues: valid, maxLength: nil, units: nil, value: nil)
    }

    private static let house = HomeRecord(
        id: "H1", name: "The flat", primary: true,
        accessories: [
            HomeAccessory(id: lampID, name: "Desk lamp", room: "Office", category: "Lightbulb", reachable: true, services: [
                HomeService(name: "Desk lamp", kind: "Lightbulb", characteristics: [
                    characteristic("L-power", "power", "bool"),
                    characteristic("L-once", "wake", "bool", valid: [1]),
                ]),
            ]),
            HomeAccessory(id: lockID, name: "Front door", room: "Hall", category: "Door Lock", reachable: true, services: [
                HomeService(name: "Front door", kind: "Lock Mechanism", characteristics: [
                    characteristic("D-target", "lock", "uint8", valid: [0, 1]),
                ]),
            ]),
        ],
        scenes: [HomeScene(id: "SC-1111", name: "Good night"),
                 HomeScene(id: "SC-LEAVE", name: "Leave", writes: [HMCharacteristicTypeTargetLockMechanismState])])

    private var folder: URL!
    private var secrets: ControlSecrets!
    private var leftBehind = ConnectionsLeftBehind.isolated()
    private var reloads: [String] = []
    private var scheduled: [@MainActor () -> Void] = []
    private var confirmed: [String] = []
    private var asked: [URL] = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("control-tool-\(UUID().uuidString)")
        secrets = ControlSecrets(service: "zone.hexagon.topo.control-secret.tests.\(UUID().uuidString)")
        reloads = []
        scheduled = []
        confirmed = []
        asked = []
    }

    override func tearDown() async throws {
        try? secrets.clearAll()
        try? FileManager.default.removeItem(at: folder)
    }

    private var store: SurfaceStore { SurfaceStore(folder: folder) }

    private func tool(loaded: Bool = true) async throws -> ControlTool {
        let fake = LoadedHome()
        let access = HomeAccess {
            Task { @MainActor in
                fake.authorization = [.determined, .authorized]
                fake.changed?(.authorization)
                fake.records = [Self.house]
                fake.changed?(.homes)
            }
            return fake
        }
        if loaded {
            _ = await access.request()
            _ = try await access.homes()
        }
        let homeTool = HomeTool(home: access, authorizer: HomeAuthorizer(home: access), broker: PermissionBroker())
        let reloader = SurfaceReloader(reloadKind: { [unowned self] in reloads.append("widget " + $0) }, reloadEverything: {},
                                       reloadControlKind: { [unowned self] in reloads.append($0) }, reloadEveryControl: {},
                                       schedule: { [unowned self] _, body in scheduled.append(body) })
        let store = store
        return ControlTool(judge: WidgetRunJudge(home: homeTool, notify: nil, reminders: nil), store: { store }, reloader: { reloader },
                           secrets: secrets, leftBehind: leftBehind,
                           confirm: { [unowned self] on, slot, revision in confirmed.append("\(slot) \(on) \(revision)") },
                           askLocal: { [unowned self] in asked.append($0) }, localState: { .notAsked })
    }

    private static func run(_ argv: [String]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["title": "Go", "action": ["kind": "run", "topo": argv]]), as: UTF8.self)
    }

    private func action(_ slot: String) -> ControlAction? { store.readControl(slot: slot)?.document.action }

    // MARK: The round trip

    func testSetThenListPrintsItBack() async throws {
        let tool = try await tool(loaded: false)
        let button = await tool.run(["set", "button-1", ControlTool.button])
        XCTAssertEqual(button.status, ToolReply.ok, button.text)
        XCTAssertTrue(button.text.contains("unchecked: "), "a home not loaded is judged at the tap: \(button.text)")
        let toggle = await tool.run(["set", "toggle-1", ControlTool.toggle])
        XCTAssertEqual(toggle.status, ToolReply.ok, toggle.text)
        XCTAssertEqual(store.readControl(slot: "toggle-1")?.document,
                       { var d = ControlDocument.read(ControlTool.toggle, slot: "toggle-1").document; d.revision = store.readControl(slot: "toggle-1")!.document.revision; return d }())
        let listed = await tool.run([])
        XCTAssertTrue(listed.text.contains(#"button-1: written revision "#), listed.text)
        XCTAssertTrue(listed.text.contains(#""Feed Daphne", run topo home scene SCENE-ID"#), listed.text)
        XCTAssertTrue(listed.text.contains(#""Kitchen" off, request on: POST http://192.168.1.214/api/services/media_player/media_play headers Authorization, Content-Type with a body"#), listed.text)
        XCTAssertTrue(listed.text.contains("  unchecked: "), "the listing lost the judge's word")
        XCTAssertTrue(listed.text.contains("button-2: nothing kept"), listed.text)
        XCTAssertEqual(asked.map(\.host), ["192.168.1.214", "192.168.1.214"], "local network access was not asked for the request's host")
    }

    func testAPartialDocumentIsStatusSixAndNothingReadableTwo() async throws {
        let tool = try await tool()
        let partial = await tool.run(["set", "button-2", #"{"title": "Go", "symbol": "no.such.symbol.anywhere", "action": {"kind": "open"}}"#])
        XCTAssertEqual(partial.status, ToolReply.refused, partial.text)
        XCTAssertTrue(partial.text.contains("refused: symbol "), partial.text)
        XCTAssertEqual(action("button-2"), .open)
        let unreadable = await tool.run(["set", "button-3", "not json"])
        XCTAssertEqual(unreadable.status, ToolReply.usage)
        XCTAssertNil(store.readControl(slot: "button-3"))
        let wrongKind = await tool.run(["set", "button-3", ControlTool.toggle])
        XCTAssertEqual(wrongKind.status, ToolReply.usage, wrongKind.text)
        let noSlot = await tool.run(["set", "button-7", ControlTool.button])
        XCTAssertEqual(noSlot.status, ToolReply.refused)
    }

    /// The same judge as `topo widget set`: off the allowlist, a lock's target, a scene that
    /// unlocks, a toggle one of whose forms is refused — each refused at `set`.
    func testRunJudgedAsAWidgetsIs() async throws {
        let tool = try await tool(loaded: true)
        let cases: [(String, [String])] = [
            ("button-1", ["home", "set", Self.lockID, "lock", "1"]),
            ("button-2", ["home", "set", "Attic fan", "power", "on"]),
            ("button-3", ["home", "scene", "SC-LEAVE"]),
            ("button-4", ["calendar", "add", "Dinner"]),
            ("toggle-1", ["home", "set", Self.lampID, "wake"]),
        ]
        for (slot, argv) in cases {
            let reply = await tool.run(["set", slot, Self.run(argv)])
            XCTAssertEqual(reply.status, ToolReply.refused, "\(slot): \(reply.text)")
            XCTAssertEqual(action(slot), .turn(say: nil), "\(slot) kept its run")
        }
        let night = await tool.run(["set", "button-5", Self.run(["home", "scene", "SC-1111"])])
        XCTAssertEqual(night.status, ToolReply.ok, night.text)
        XCTAssertFalse(night.text.contains("unchecked"), night.text)
        let lamp = await tool.run(["set", "toggle-2", Self.run(["home", "set", Self.lampID, "power"])])
        XCTAssertEqual(lamp.status, ToolReply.ok, lamp.text)
        XCTAssertEqual(action("toggle-2"), .run(["home", "set", Self.lampID, "power"]))
    }

    /// `state` changes `on` alone: no new revision, the confirmed state told, the toggle kind reloaded.
    func testStateSetsOnAlone() async throws {
        let tool = try await tool()
        _ = await tool.run(["set", "toggle-3", Self.run(["home", "set", Self.lampID, "power"])])
        let before = try XCTUnwrap(store.readControl(slot: "toggle-3")?.document)
        let reply = await tool.run(["state", "toggle-3", "on"])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        var after = try XCTUnwrap(store.readControl(slot: "toggle-3")?.document)
        XCTAssertTrue(after.on)
        after.on = before.on
        XCTAssertEqual(after, before, "state changed more than on")
        XCTAssertEqual(confirmed, ["toggle-3 true \(before.revision)"])
        let button = await tool.run(["state", "button-1", "on"])
        XCTAssertEqual(button.status, ToolReply.refused)
        let bad = await tool.run(["state", "toggle-3", "maybe"])
        XCTAssertEqual(bad.status, ToolReply.usage)
    }

    /// `clear` writes a slot's default back, under a new revision; bare, all twelve.
    func testClearWritesTheDefaultBack() async throws {
        let tool = try await tool()
        _ = await tool.run(["set", "button-4", ControlTool.button])
        let written = try XCTUnwrap(store.readControl(slot: "button-4")?.document.revision)
        let reply = await tool.run(["clear", "button-4"])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        let cleared = try XCTUnwrap(store.readControl(slot: "button-4")?.document)
        XCTAssertTrue(cleared.isDefault)
        XCTAssertGreaterThan(cleared.revision, written)
        var standard = ControlDocument.standard(slot: "button-4")
        standard.revision = cleared.revision
        XCTAssertEqual(cleared, standard)
        _ = await tool.run(["clear"])
        XCTAssertEqual(ControlSlot.all.filter { store.readControl(slot: $0)?.document.isDefault == true }, ControlSlot.all)
    }

    // MARK: Secrets and what a request carried

    func testSecretsAreKeptByName() async throws {
        let tool = try await tool()
        let set = await tool.run(["secret", "set", "ha", "tok-SENTINEL-9"])
        XCTAssertEqual(set.status, ToolReply.ok)
        XCTAssertFalse(set.text.contains("SENTINEL"))
        XCTAssertEqual(try secrets.read("ha"), "tok-SENTINEL-9")
        let badName = await tool.run(["secret", "set", "bad name", "x"])
        XCTAssertEqual(badName.status, ToolReply.refused)
        let listed = await tool.run([])
        XCTAssertTrue(listed.text.contains("secrets: ha"), listed.text)
        XCTAssertFalse(listed.text.contains("SENTINEL"))
        _ = await tool.run(["secret", "clear", "ha"])
        XCTAssertNil(try secrets.read("ha"))
    }

    /// A clear of the control secrets refused at a sign-out: no secret is kept and none is listed
    /// until the app has cleared them, and the listing and the refusal say why.
    func testASecretLeftBehindRefusesANewOne() async throws {
        let tool = try await tool()
        try secrets.set("earlier", name: "ha")
        leftBehind.controlSecrets = "the controls' secrets could not be removed"
        let set = await tool.run(["secret", "set", "webhook", "tok"])
        XCTAssertEqual(set.status, ToolReply.failed)
        XCTAssertTrue(set.text.contains("could not be removed"), set.text)
        XCTAssertNil(try secrets.read("webhook"))
        let listed = await tool.run([])
        XCTAssertFalse(listed.text.contains("secrets: ha"), listed.text)
        XCTAssertTrue(listed.text.contains("could not be removed"), listed.text)
    }

    /// The listing and the taps: the URL's scheme, host and path and the headers' names, never a
    /// header's value, the query or the body.
    func testTheListingSaysNothingARequestCarried() async throws {
        let tool = try await tool()
        let document = #"{"title": "Go", "action": {"kind": "request", "url": "https://hooks.example.com/run?token=SENTINEL-QUERY", "headers": {"X-Key": "SENTINEL-HEADER", "Authorization": "${secret:ha}"}, "body": "SENTINEL-BODY"}}"#
        let set = await tool.run(["set", "button-6", document])
        XCTAssertEqual(set.status, ToolReply.ok, set.text)
        try store.appendTap(SurfaceStore.Tap(time: Date(), slot: ControlSlot.stored("button-6"), id: ControlSlot.control, revision: 3,
                                             kind: "request", status: "1", code: 503))
        let listed = await tool.run([])
        let taps = await tool.run(["taps", "button-6"])
        for text in [set.text, listed.text, taps.text] {
            XCTAssertFalse(text.contains("SENTINEL"), text)
        }
        XCTAssertTrue(listed.text.contains("request POST https://hooks.example.com/run headers Authorization, X-Key with a body"), listed.text)
        XCTAssertTrue(taps.text.contains("button-6 | revision 3 | request | 1 | HTTP 503"), taps.text)
        XCTAssertEqual(asked.map(\.host), ["hooks.example.com"], "a name, which may resolve to the home network, was not asked for")
    }

    /// A named home server (`homeassistant.lan`) is asked for at the set, as an address on the
    /// home network is; a public address never is.
    func testANamedLocalHostIsAskedForAtTheSet() async throws {
        let tool = try await tool()
        let named = await tool.run(["set", "button-4", #"{"title": "Go", "action": {"kind": "request", "url": "http://homeassistant.lan:8123/api/services/script/treat", "method": "POST"}}"#])
        XCTAssertEqual(named.status, ToolReply.ok, named.text)
        XCTAssertEqual(asked.map(\.host), ["homeassistant.lan"])
        let bare = await tool.run(["set", "button-5", #"{"title": "Go", "action": {"kind": "request", "url": "http://8.8.8.8/x"}}"#])
        XCTAssertEqual(bare.status, ToolReply.ok, bare.text)
        XCTAssertEqual(asked.map(\.host), ["homeassistant.lan"], "a public address asked for local network access")
    }

    /// Each verb lists its own taps from the one log.
    func testTapsAreSplitByVerb() async throws {
        let tool = try await tool()
        try store.appendTap(SurfaceStore.Tap(time: Date(), slot: "demo", id: "lamp", revision: 2, kind: "run", status: "0"))
        try store.appendTap(SurfaceStore.Tap(time: Date(), slot: ControlSlot.stored("toggle-1"), id: ControlSlot.control, revision: 4,
                                             kind: "run", status: "0"))
        let controls = await tool.run(["taps"])
        XCTAssertTrue(controls.text.contains("toggle-1"), controls.text)
        XCTAssertFalse(controls.text.contains("demo"), controls.text)
        let widgets = await WidgetTool(judge: WidgetRunJudge(), store: { [store] in store }).run(["taps"])
        XCTAssertTrue(widgets.text.contains("demo"), widgets.text)
        XCTAssertFalse(widgets.text.contains("control"), widgets.text)
    }

    // MARK: Review Focus 9 and 10

    func testSetReloadsItsKindOnce() async throws {
        let tool = try await tool()
        _ = await tool.run(["set", "button-1", ControlTool.button])
        _ = await tool.run(["set", "button-2", ControlTool.button])
        _ = await tool.run(["set", "toggle-1", ControlTool.toggle])
        XCTAssertEqual(reloads, [])
        XCTAssertEqual(scheduled.count, 2, "one reload per kind in the window")
        scheduled.forEach { $0() }
        XCTAssertEqual(Set(reloads), [ControlSlot.Kind.button.controlKind, ControlSlot.Kind.toggle.controlKind])
    }

    func testTheExamplesReadWhole() {
        XCTAssertEqual(ControlDocument.read(ControlTool.button, slot: "button-1").notes, [])
        XCTAssertEqual(ControlDocument.read(ControlTool.toggle, slot: "toggle-1").notes, [])
    }

    func testHelpListsControlFromTheTable() async throws {
        let table = ToolTable([try await tool(), WidgetTool(judge: WidgetRunJudge())])
        XCTAssertTrue(table.help.contains("control"))
        let help = await table.run(["help", "control"])
        for word in ["button-1", "toggle-6", "Topo Button", "Topo Toggle", "${secret:NAME}", "up to three times", "POST",
                     "iOS 18 to 25", "Face ID"] {
            XCTAssertTrue(help.text.contains(word), "help lacks \(word)")
        }
    }
}

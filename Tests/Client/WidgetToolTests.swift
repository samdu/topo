import HomeKit
import ImageIO
import TopoCore
import TopoCoreTesting
import TopoTools
import UniformTypeIdentifiers
import XCTest

@testable import Topo

/// A loaded home for the judge, answering at once; it counts whether it was ever made, which is
/// the only way HomeKit's prompt could be raised.
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

/// Review Focus 3, 4 and 9: `topo widget`'s images, its judgement of each `run` action at `set`,
/// its round trip, and its reload.
@MainActor
final class WidgetToolTests: XCTestCase {
    private static let lampID = "6A1F0C2E-0000-4000-8000-000000000001"
    private static let lockID = "9B7E3D10-0000-4000-8000-000000000003"

    private static func characteristic(_ id: String, _ name: String, _ format: String, valid: [Decimal]? = nil) -> HomeCharacteristic {
        HomeCharacteristic(id: id, name: name, format: format, readable: true, writable: true, minimum: nil, maximum: nil,
                           step: nil, validValues: valid, maxLength: nil, units: nil, value: nil)
    }

    /// A lamp, a lock, and a switch that only turns on.
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
    private var home: URL!
    private var reloads: [String] = []
    private var scheduled: [@MainActor () -> Void] = []
    private var made = 0
    /// The records the tool's writes reach, in memory.
    private var records: InMemoryRecordDatabase!
    private var sync: SurfaceSync!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("widget-tool-\(UUID().uuidString)")
        home = folder.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        reloads = []
        scheduled = []
        made = 0
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var store: SurfaceStore { SurfaceStore(folder: folder.appendingPathComponent("Surfaces")) }

    /// The tool over a store in a temporary folder, a reloader on a clock the test moves, and a
    /// home that is loaded (`loaded`) or never made.
    private func tool(loaded: Bool, iCloud: Bool = true) async throws -> WidgetTool {
        let fake = LoadedHome()
        let access = HomeAccess { [unowned self] in
            made += 1
            Task { @MainActor in
                fake.authorization = [.determined, .authorized]
                fake.changed?(.authorization)
                fake.records = [Self.house]
                fake.changed?(.homes)
            }
            return fake
        }
        if loaded {
            // What a guest call does first: asking makes the store, and the homes load after.
            _ = await access.request()
            _ = try await access.homes()
        }
        let homeTool = HomeTool(home: access, authorizer: HomeAuthorizer(home: access), broker: PermissionBroker())
        let notify = NotifyTool(scheduler: UserNotificationScheduler(), authorizer: NotificationAuthorizer(), broker: PermissionBroker())
        let reloader = SurfaceReloader(reloadKind: { [unowned self] in reloads.append($0) }, reloadEverything: {},
                                       schedule: { [unowned self] _, body in scheduled.append(body) })
        let store = store
        let home = home!
        let records = InMemoryRecordDatabase()
        self.records = records
        let sync = SurfaceSync(records: { iCloud ? SurfaceRecords(database: records) : nil }, ensureZone: {}, store: { store },
                               runner: "phone-test",
                               defaults: UserDefaults(suiteName: "widget-tool-\(UUID().uuidString)")!, reloader: reloader)
        self.sync = sync
        return WidgetTool(judge: WidgetRunJudge(home: homeTool, notify: notify, reminders: nil),
                          store: { store }, reloader: { reloader }, sync: { sync }, home: { home }, placed: { [("systemSmall", "demo")] })
    }

    private static func document(_ controls: String) -> String {
        #"{"families": {"systemSmall": {"kind": "vstack", "children": ["# + controls + "]}}}"
    }

    private static func button(_ id: String, _ argv: [String], kind: String = "button") -> String {
        let words = argv.map { "\"\($0)\"" }.joined(separator: ", ")
        return #"{"kind": "\#(kind)", "id": "\#(id)", "label": "\#(id)", "action": {"kind": "run", "topo": [\#(words)]}}"#
    }

    private func action(_ id: String, slot: String = "demo") -> WidgetAction? {
        store.read(slot: slot)?.document.controls[id]?.action
    }

    // MARK: Review Focus 4

    func testRunActionRefusedOffAllowlist() async throws {
        let tool = try await tool(loaded: true)
        let cases: [(String, [String])] = [
            ("lock-by-name", ["home", "set", Self.lockID, "lock", "1"]),
            ("lock-by-plan-name", ["home", "set", Self.lockID, "lock-target-state", "1"]),
            ("lock-by-id", ["home", "set", Self.lockID, "D-target", "1"]),
            ("calendar", ["calendar", "add", "Dinner"]),
            ("widget", ["widget", "clear"]),
        ]
        for (id, argv) in cases {
            let reply = await tool.run(["set", "demo", Self.document(Self.button(id, argv))])
            XCTAssertEqual(reply.status, ToolReply.refused, "\(id): \(reply.text)")
            XCTAssertEqual(action(id), .open, "\(id) kept its run")
        }
    }

    func testRunActionJudgedAtWrite() async throws {
        let tool = try await tool(loaded: true)
        let reply = await tool.run(["set", "demo", Self.document(Self.button("ghost", ["home", "set", "Attic fan", "power", "on"]))])
        XCTAssertEqual(reply.status, ToolReply.refused, reply.text)
        XCTAssertTrue(reply.text.contains("Attic fan"), reply.text)
        XCTAssertEqual(action("ghost"), .open)

        let good = await tool.run(["set", "demo", Self.document(Self.button("lamp", ["home", "set", Self.lampID, "power", "on"]))])
        XCTAssertEqual(good.status, ToolReply.ok, good.text)
        XCTAssertEqual(action("lamp"), .run(["home", "set", Self.lampID, "power", "on"]))
        XCTAssertFalse(good.text.contains("unchecked"), good.text)
    }

    func testRunActionUncheckedWithoutHome() async throws {
        let tool = try await tool(loaded: false)
        let reply = await tool.run(["set", "demo", Self.document(Self.button("fan", ["home", "set", "Attic fan", "power", "on"]))])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        XCTAssertTrue(reply.text.contains("unchecked: fan"), reply.text)
        XCTAssertEqual(action("fan"), .run(["home", "set", "Attic fan", "power", "on"]))
        XCTAssertEqual(made, 0, "the judge made HomeKit's store, which is what asks the person")
        let listed = await tool.run([])
        XCTAssertTrue(listed.text.contains("unchecked: fan"), listed.text)
    }

    /// A scene that sets a lock's target is refused at `set` against a loaded home, and kept as
    /// unchecked with none loaded, for the tap to judge.
    func testASceneThatUnlocksIsRefusedAtWrite() async throws {
        let loaded = try await tool(loaded: true)
        let reply = await loaded.run(["set", "demo", Self.document(Self.button("leave", ["home", "scene", "SC-LEAVE"]))])
        XCTAssertEqual(reply.status, ToolReply.refused, reply.text)
        XCTAssertEqual(action("leave"), .open)
        let night = await loaded.run(["set", "demo", Self.document(Self.button("night", ["home", "scene", "SC-1111"]))])
        XCTAssertEqual(night.status, ToolReply.ok, night.text)

        let unloaded = try await tool(loaded: false)
        let later = await unloaded.run(["set", "demo", Self.document(Self.button("leave", ["home", "scene", "SC-LEAVE"]))])
        XCTAssertEqual(later.status, ToolReply.ok, later.text)
        XCTAssertTrue(later.text.contains("unchecked: leave"), later.text)
    }

    func testToggleJudgedBothWays() async throws {
        let tool = try await tool(loaded: true)
        let reply = await tool.run(["set", "demo", Self.document(Self.button("wake", ["home", "set", Self.lampID, "wake"], kind: "toggle"))])
        XCTAssertEqual(reply.status, ToolReply.refused, reply.text)
        XCTAssertEqual(action("wake"), .open)

        let both = await tool.run(["set", "demo", Self.document(Self.button("power", ["home", "set", Self.lampID, "power"], kind: "toggle"))])
        XCTAssertEqual(both.status, ToolReply.ok, both.text)
    }

    func testLookResetAllowed() async throws {
        let tool = try await tool(loaded: true)
        let reply = await tool.run(["set", "demo", Self.document(Self.button("reset", ["look", "reset", "mascot.scale"]))])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        XCTAssertEqual(action("reset"), .run(["look", "reset", "mascot.scale"]))

        let bad = await tool.run(["set", "demo", Self.document(Self.button("bad", ["look", "set", "mascot.scale", "900"]))])
        XCTAssertEqual(bad.status, ToolReply.refused, bad.text)
        XCTAssertEqual(action("bad"), .open)
    }

    // MARK: The round trip

    func testSetThenListThenTheFileReadsBackTheSameTree() async throws {
        // No home loaded: the example's toggle names an accessory id this fake does not hold.
        let tool = try await tool(loaded: false)
        let reply = await tool.run(["set", "demo", WidgetTool.example])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        let listed = await tool.run([])
        XCTAssertTrue(listed.text.contains("slot: demo"), listed.text)
        XCTAssertTrue(listed.text.contains("systemMedium"), listed.text)
        XCTAssertTrue(listed.text.contains("placed: systemSmall"), listed.text)

        let written = try XCTUnwrap(store.read(slot: "demo"))
        XCTAssertEqual(written.notes, [])
        XCTAssertEqual(written.document.families, WidgetDocument.read(WidgetTool.example).document.families)
        XCTAssertEqual(written.document.revision, 1)
    }

    func testAPartialDocumentIsStatusSixWithWhatWasKeptWritten() async throws {
        let tool = try await tool(loaded: true)
        let text = #"{"families": {"systemSmall": {"kind": "vstack", "children": [{"kind": "text", "text": "kept"}, {"kind": "marquee"}]}}}"#
        let reply = await tool.run(["set", "demo", text])
        XCTAssertEqual(reply.status, ToolReply.refused, reply.text)
        XCTAssertTrue(reply.text.contains("marquee"), reply.text)
        let tree = try XCTUnwrap(store.read(slot: "demo")?.document.tree(for: .systemSmall))
        var words: [String] = []
        tree.walk { if case .text(let text) = $0 { words.append(text.text) } }
        XCTAssertEqual(words, ["kept"])
    }

    func testNothingReadableIsStatusTwoAndNothingWritten() async throws {
        let tool = try await tool(loaded: true)
        let reply = await tool.run(["set", "demo", "not json"])
        XCTAssertEqual(reply.status, ToolReply.usage, reply.text)
        XCTAssertNil(store.read(slot: "demo"))
    }

    func testTheDefaultIsNotTheMindsToWrite() async throws {
        let tool = try await tool(loaded: true)
        let reply = await tool.run(["set", SurfaceStore.defaultSlot, WidgetTool.example])
        XCTAssertEqual(reply.status, ToolReply.refused, reply.text)
        XCTAssertNil(store.read(slot: SurfaceStore.defaultSlot))
    }

    func testTheExampleHoldsEveryKindAndReadsWhole() {
        let reading = WidgetDocument.read(WidgetTool.example)
        XCTAssertEqual(reading.notes, [])
        var kinds: Set<String> = []
        reading.document.tree(for: .systemMedium)?.walk { kinds.insert($0.kind) }
        XCTAssertEqual(kinds, ["vstack", "hstack", "zstack", "text", "glyph", "image", "gauge", "progress", "topo",
                               "spacer", "divider", "button", "toggle", "link"])
    }

    func testClearTakesTheSlotAway() async throws {
        let tool = try await tool(loaded: true)
        _ = await tool.run(["set", "demo", WidgetTool.example])
        let reply = await tool.run(["clear", "demo"])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        XCTAssertEqual(store.slots(), [])
    }

    // MARK: The slot's record (widgets B, Review Focus 2)

    /// Each write is followed by the slot's record, and a clear by its delete; a slot whose
    /// record has not gone is one `topo widget` says is behind.
    func testTheRecordFollowsTheSlotAndIsReportedBehind() async throws {
        let offline = try await tool(loaded: true, iCloud: false)
        _ = await offline.run(["set", "demo", WidgetTool.example])
        await sync.flush()
        let behind = await offline.run([])
        XCTAssertTrue(behind.text.contains("record behind"), behind.text)

        let tool = try await tool(loaded: true)
        _ = await tool.run(["set", "demo", WidgetTool.example])
        await sync.flush()
        let current = await records.current(SurfaceRecord.id(slot: "demo"))
        let saved = try XCTUnwrap(SurfaceRecord(XCTUnwrap(current)))
        XCTAssertEqual(saved.revision, store.read(slot: "demo")?.document.revision)
        let listed = await tool.run([])
        XCTAssertFalse(listed.text.contains("record behind"), listed.text)
        _ = await tool.run(["clear", "demo"])
        await sync.flush()
        let gone = await records.current(SurfaceRecord.id(slot: "demo"))
        XCTAssertNil(gone)
    }

    /// The last slot cleared while its record's delete cannot go: the list says the watch still
    /// has it, rather than that there are no slots and nothing more.
    func testAClearedSlotsDeleteOwedIsReportedBehind() async throws {
        let offline = try await tool(loaded: true, iCloud: false)
        _ = await offline.run(["set", "demo", WidgetTool.example])
        _ = await offline.run(["clear", "demo"])
        await sync.flush()
        XCTAssertEqual(sync.owed, ["demo": .delete])
        let listed = await offline.run([])
        XCTAssertTrue(listed.text.contains("no slots"), listed.text)
        XCTAssertTrue(listed.text.contains("slot: demo, cleared; record behind"), listed.text)
    }

    /// A clear of every slot that fails part-way owes a delete for each slot whose document went
    /// before it failed, so the watch is not left with slots the phone no longer has.
    func testAClearFailingPartWayOwesWhatWent() async throws {
        let offline = try await tool(loaded: true, iCloud: false)
        _ = await offline.run(["set", "alpha", WidgetTool.example])
        _ = await offline.run(["set", "beta", WidgetTool.example])
        // beta's images folder cannot be taken away: its document goes, then the removal fails.
        let images = store.images(slot: "beta")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try Data([0x89]).write(to: images.appendingPathComponent("sky.png"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: images.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: images.path) }

        let reply = await offline.run(["clear"])
        XCTAssertNotEqual(reply.status, ToolReply.ok, reply.text)
        await sync.flush()
        XCTAssertEqual(sync.owed, ["alpha": .delete, "beta": .delete], "a slot removed before the failure owes nothing")
    }

    /// The document is written and the notes are not: the record is still owed the document.
    func testAFailedNotesWriteStillOwesTheSave() async throws {
        let offline = try await tool(loaded: true, iCloud: false)
        let notes = store.notesURL(slot: "demo")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try Data().write(to: notes.appendingPathComponent("in-the-way"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: notes.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: notes.path) }

        let reply = await offline.run(["set", "demo", WidgetTool.example])
        XCTAssertNotEqual(reply.status, ToolReply.ok, reply.text)
        XCTAssertNotNil(store.read(slot: "demo"))
        await sync.flush()
        XCTAssertEqual(sync.owed, ["demo": .save], "a written document owed its record nothing")
    }

    func testTapsSayTheStatusAndNoOutput() async throws {
        let tool = try await tool(loaded: true)
        try store.appendTap(SurfaceStore.Tap(time: Date(timeIntervalSince1970: 1_900_000_000), slot: "demo", id: "lamp",
                                             revision: 2, kind: "run", status: "0"))
        let reply = await tool.run(["taps"])
        XCTAssertTrue(reply.text.contains("demo | lamp | revision 2 | run | 0"), reply.text)
    }

    // MARK: Review Focus 9

    func testSetReloadsItsKind() async throws {
        let tool = try await tool(loaded: true)
        _ = await tool.run(["set", "demo", WidgetTool.example])
        _ = await tool.run(["set", "other", WidgetTool.example])
        XCTAssertEqual(reloads, [], "a reload before the window")
        XCTAssertEqual(scheduled.count, 1, "two writes in the window are one reload")
        scheduled.forEach { $0() }
        XCTAssertEqual(reloads, [SurfaceStore.kind])
    }

    func testHelpListsWidgetFromTheTable() async throws {
        let table = ToolTable([try await tool(loaded: false)])
        XCTAssertTrue(table.help.contains("widget"))
        let help = await table.run(["help", "widget"])
        for word in ["accessoryRectangular", "locked phone", "16 KB", "toggle"] {
            XCTAssertTrue(help.text.contains(word), "help lacks \(word)")
        }
    }

    // MARK: Review Focus 3

    private static func picture(width: Int, height: Int, type: UTType, noise: Bool = false, orientation: Int? = nil,
                                redCorner: Int = 0) -> Data {
        var bytes = [UInt8](repeating: 128, count: width * height * 4)
        if noise { for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) } }
        // A red block at the top-left of the stored pixels, which says where they were turned to.
        for y in 0..<redCorner { for x in 0..<redCorner { bytes.replaceSubrange((y * width + x) * 4..<(y * width + x) * 4 + 3, with: [255, 0, 0]) } }
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let image = context.makeImage()!
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary })
        CGImageDestinationFinalize(destination)
        return out as Data
    }

    /// A camera's JPEG, landscape pixels marked to be turned a quarter clockwise (EXIF orientation
    /// 6), is kept upright: a portrait PNG, the stored top-left corner at its top right.
    func testAnImageIsKeptUpright() async throws {
        let tool = try await tool(loaded: true)
        let turned = Self.picture(width: 40, height: 20, type: .jpeg, orientation: 6, redCorner: 8)
        let marked = try XCTUnwrap(CGImageSourceCreateWithData(turned as CFData, nil))
        let said = CGImageSourceCopyPropertiesAtIndex(marked, 0, nil) as? [CFString: Any]
        XCTAssertEqual(said?[kCGImagePropertyOrientation] as? Int, 6, "the fixture carries no orientation")
        try turned.write(to: home.appendingPathComponent("turned.jpg"))
        let reply = await tool.run(["image", "demo", "photo", "/home/topo/turned.jpg"])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        let kept = try XCTUnwrap(store.imageData(slot: "demo", name: "photo"))
        let image = try XCTUnwrap(CGImageSourceCreateWithData(kept as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual([image.width, image.height], [20, 40], "the picture was kept on its side")
        var pixels = [UInt8](repeating: 0, count: 20 * 40 * 4)
        let context = CGContext(data: &pixels, width: 20, height: 40, bitsPerComponent: 8, bytesPerRow: 20 * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 20, height: 40))
        func red(_ x: Int, _ y: Int) -> Bool {
            let at = (y * 20 + x) * 4
            return pixels[at] > 200 && pixels[at + 1] < 80 && pixels[at + 2] < 80
        }
        XCTAssertTrue(red(16, 3), "the red corner is not at the top right")
        XCTAssertFalse(red(3, 3), "the top left is red")
        XCTAssertFalse(red(16, 36), "the bottom right is red")
    }

    func testImageRefusesLinkEscapeAndOversize() async throws {
        let tool = try await tool(loaded: true)
        let fm = FileManager.default
        let outside = folder.appendingPathComponent("Documents", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = outside.appendingPathComponent("secret.png")
        try Self.picture(width: 8, height: 8, type: .png).write(to: secret)
        try fm.createSymbolicLink(at: home.appendingPathComponent("link.png"), withDestinationURL: secret)
        try fm.createSymbolicLink(at: home.appendingPathComponent("docs"), withDestinationURL: outside)
        let big = Self.picture(width: 1000, height: 1000, type: .png, noise: true)
        XCTAssertGreaterThan(big.count, 3_000_000)
        try big.write(to: home.appendingPathComponent("big.png"))
        try Self.picture(width: 4000, height: 10, type: .jpeg).write(to: home.appendingPathComponent("wide.jpg"))
        try Data("not a picture".utf8).write(to: home.appendingPathComponent("text.png"))

        let refused = ["/home/topo/link.png", "/home/topo/docs/secret.png", "/home/topo/../Documents/secret.png",
                       "/home/topo/big.png", "/home/topo/wide.jpg", "/home/topo/text.png", secret.path, "/etc/passwd"]
        for path in refused {
            let reply = await tool.run(["image", "demo", "photo", path])
            XCTAssertEqual(reply.status, ToolReply.refused, "\(path): \(reply.text)")
            XCTAssertEqual(store.imageNames(slot: "demo"), [], "\(path) was copied")
        }

        try Self.picture(width: 40, height: 20, type: .jpeg).write(to: home.appendingPathComponent("ok.jpg"))
        let reply = await tool.run(["image", "demo", "photo", "/home/topo/ok.jpg"])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        let kept = try XCTUnwrap(store.imageData(slot: "demo", name: "photo"))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(kept as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier, "kept as it came, not re-encoded")
    }

    func testImageCountIsBoundedPerSlot() async throws {
        let tool = try await tool(loaded: true)
        try Self.picture(width: 8, height: 8, type: .png).write(to: home.appendingPathComponent("a.png"))
        for index in 0..<WidgetDocument.imageLimit {
            let reply = await tool.run(["image", "demo", "p\(index)", "/home/topo/a.png"])
            XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        }
        let over = await tool.run(["image", "demo", "extra", "/home/topo/a.png"])
        XCTAssertEqual(over.status, ToolReply.refused, over.text)
        let again = await tool.run(["image", "demo", "p0", "/home/topo/a.png"])
        XCTAssertEqual(again.status, ToolReply.ok, "replacing one is not a fifth")
    }
}

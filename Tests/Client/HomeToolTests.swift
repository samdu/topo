import HomeKit
import TopoTools
import XCTest

@testable import Topo

/// A home HomeKit would report, driven by the test: what it holds, when it says so, and every
/// write and scene it was asked for.
@MainActor
private final class FakeHome: HomeStore {
    var authorization: HMHomeManagerAuthorizationStatus = []
    var changed: (@MainActor (HomeChange) -> Void)?
    var records: [HomeRecord] = []
    var values: [String: HomeValue] = [:]
    /// Characteristics whose read fails.
    var unreadable: Set<String> = []
    /// Characteristics whose read answers only after ten seconds.
    var slow: Set<String> = []
    /// Run each time the homes are read, before they are answered.
    var onHomes: (@MainActor () -> Void)?
    private(set) var writes: [(String, HomeValue)] = []
    private(set) var scenesRun: [String] = []
    private(set) var homesRead = 0

    func homes() -> [HomeRecord] {
        homesRead += 1
        onHomes?()
        return records
    }

    func read(_ characteristic: String) async throws -> HomeValue? {
        if unreadable.contains(characteristic) { throw ToolFailure("no answer") }
        if slow.contains(characteristic) {
            try await Task.sleep(for: .seconds(10))
            return .int(99)
        }
        return values[characteristic]
    }

    func write(_ value: HomeValue, to characteristic: String) async throws {
        writes.append((characteristic, value))
        values[characteristic] = value
    }

    func run(scene: String) async throws {
        scenesRun.append(scene)
    }

    /// HomeKit answering: the person allowed it (or not), then the homes loaded.
    func answer(allowed: Bool = true, homes: [HomeRecord]? = nil) {
        authorization = allowed ? [.determined, .authorized] : [.determined]
        changed?(.authorization)
        if let homes { records = homes }
        changed?(.homes)
    }
}

@MainActor
final class HomeToolTests: XCTestCase {
    private static let lampID = "6A1F0C2E-0000-4000-8000-000000000001"
    private static let stripID = "6A1F0C2E-0000-4000-8000-000000000002"
    private static let lockID = "9B7E3D10-0000-4000-8000-000000000003"

    private static func characteristic(_ id: String, _ name: String, _ format: String = "int", writable: Bool = true,
                                       min: Decimal? = nil, max: Decimal? = nil, step: Decimal? = nil,
                                       valid: [Decimal]? = nil, units: String? = nil) -> HomeCharacteristic {
        HomeCharacteristic(id: id, name: name, format: format, readable: true, writable: writable, minimum: min,
                           maximum: max, step: step, validValues: valid, maxLength: nil, units: units, value: nil)
    }

    /// A lamp, a two-outlet strip and a lock in one home, with two scenes.
    private static let house = HomeRecord(
        id: "H1", name: "The flat", primary: true,
        accessories: [
            HomeAccessory(id: lampID, name: "Desk lamp", room: "Office", category: "Lightbulb", reachable: true, services: [
                HomeService(name: "Info", kind: "Accessory Information", isInformation: true, characteristics: [
                    characteristic("L-id", "identify", "bool"),
                ]),
                HomeService(name: "Desk lamp", kind: "Lightbulb", characteristics: [
                    characteristic("L-power", "power", "bool"),
                    characteristic("L-bright", "brightness", min: 0, max: 100, step: 1, units: "%"),
                    characteristic("L-temp", "color-temperature", "uint32", min: 140, max: 500, step: 10),
                    characteristic("L-watts", "power-draw", "float", writable: false),
                    characteristic("L-name", "name", "string"),
                    characteristic("L-tlv", "transition-control", "tlv8"),
                    characteristic("L-label", "configured-name", "string"),
                    characteristic("L-level", "level", min: 0, max: 100, step: 10, valid: [0, 10, 105]),
                ]),
            ]),
            HomeAccessory(id: stripID, name: "Strip", room: "Office", category: "Outlet", reachable: true, services: [
                HomeService(name: "Left", kind: "Outlet", characteristics: [characteristic("S-left", "power", "bool")]),
                HomeService(name: "Right", kind: "Outlet", characteristics: [characteristic("S-right", "power", "bool")]),
            ]),
            HomeAccessory(id: lockID, name: "Front door", room: "Hall", category: "Door Lock", reachable: false, services: [
                HomeService(name: "Front door", kind: "Lock Mechanism", characteristics: [
                    characteristic("D-target", "lock", "uint8", valid: [0, 1]),
                    characteristic("D-state", "lock-state", "uint8", writable: false),
                ]),
            ]),
        ],
        scenes: [HomeScene(id: "SC-1111", name: "Good night"), HomeScene(id: "SC-2222", name: "Movie")])

    private var made = 0

    /// A tool over a fake home that answers at once: allowed, and `homes` loaded.
    private func tool(_ homes: [HomeRecord] = [house], allowed: Bool = true) -> (HomeTool, FakeHome) {
        let fake = FakeHome()
        fake.values = ["L-power": .bool(true), "L-bright": .int(40), "L-watts": .number(5.5), "S-left": .bool(false),
                       "S-right": .bool(true)]
        let access = HomeAccess { [unowned self] in
            made += 1
            Task { @MainActor in fake.answer(allowed: allowed, homes: homes) }
            return fake
        }
        return (HomeTool(home: access, authorizer: HomeAuthorizer(home: access), broker: PermissionBroker(),
                         readBound: .milliseconds(500)), fake)
    }

    // MARK: Review focus 1: the manager, and so the prompt, only on a call

    func testManagerIsMadeOnFirstCallOnly() async {
        let (tool, _) = tool()
        XCTAssertEqual(made, 0, "making the tool made a manager")
        for refused in [["remove", Self.lampID], ["pair"], ["set", Self.lampID, "brightness"]] {
            let reply = await tool.run(refused)
            XCTAssertEqual(reply.status, ToolReply.usage, reply.text)
        }
        XCTAssertEqual(made, 0, "a call the tool does not take made a manager")
        let first = await tool.run([])
        XCTAssertEqual(first.status, ToolReply.ok, first.text)
        _ = await tool.run(["scenes"])
        XCTAssertEqual(made, 1)
    }

    // MARK: Review focus 2: one write, one characteristic, one accessory

    func testSetWritesOneCharacteristic() async {
        let (tool, fake) = tool()
        let reply = await tool.run(["set", Self.lampID, "brightness", "60"])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        XCTAssertEqual(fake.writes.map(\.0), ["L-bright"])
        XCTAssertEqual(fake.writes.map(\.1), [.int(60)])
        XCTAssertEqual(reply.text, "Desk lamp | brightness | 60\n")
        let power = await tool.run(["set", "6a1f0c2e-0000-4000-8000-000000000001", "power", "off"])
        XCTAssertEqual(power.status, ToolReply.ok, power.text)
        XCTAssertEqual(fake.writes.map(\.1), [.int(60), .bool(false)])
    }

    /// The widgets' table refuses a lock's target however it is named: by short name and by id,
    /// resolved before the refusal, with nothing written.
    func testARefusedCharacteristicIsRefusedByNameAndByID() async {
        var (tool, fake) = tool()
        tool.refusing = HomeTool.widgetRefused
        for name in ["lock", "D-target"] {
            let reply = await tool.run(["set", Self.lockID, name, "1"])
            XCTAssertEqual(reply.status, ToolReply.refused, "\(name): \(reply.text)")
        }
        XCTAssertTrue(fake.writes.isEmpty)
        let lamp = await tool.run(["set", Self.lampID, "power", "on"])
        XCTAssertEqual(lamp.status, ToolReply.ok, lamp.text)
    }

    /// The refusal keys on HomeKit's type as well as the short name, so a lock's target or a
    /// garage door's under any name `HomeNames` might give it is still refused.
    func testARefusedCharacteristicIsRefusedByTypeUnderAnyName() async {
        for type in [HMCharacteristicTypeTargetLockMechanismState, HMCharacteristicTypeTargetDoorState] {
            var target = Self.characteristic("X-target", "bolt", "uint8", valid: [0, 1])
            target.type = type
            let gate = HomeRecord(id: "H2", name: "The gate", primary: true, accessories: [
                HomeAccessory(id: "G1", name: "Gate", room: "Yard", category: "Door", reachable: true, services: [
                    HomeService(name: "Gate", kind: "Lock Mechanism", characteristics: [target]),
                ]),
            ], scenes: [])
            var (tool, fake) = tool([gate])
            tool.refusing = HomeTool.widgetRefused
            for name in ["bolt", "X-target"] {
                let reply = await tool.run(["set", "G1", name, "1"])
                XCTAssertEqual(reply.status, ToolReply.refused, "\(type) as \(name): \(reply.text)")
            }
            XCTAssertTrue(fake.writes.isEmpty)
            XCTAssertThrowsError(try HomeTool.judge(.set("G1", characteristic: "bolt", value: "1"), in: [gate],
                                                    refusing: HomeTool.widgetRefused), "the judge at set let \(type) through")
        }
    }

    func testANameTwoServicesCarryIsRefusedAndTheIDIsTaken() async {
        let (tool, fake) = tool()
        let reply = await tool.run(["set", Self.stripID, "power", "on"])
        XCTAssertEqual(reply.status, ToolReply.usage, reply.text)
        XCTAssertTrue(reply.text.contains("S-left (Left)") && reply.text.contains("S-right (Right)"), reply.text)
        XCTAssertTrue(fake.writes.isEmpty)
        let byID = await tool.run(["set", Self.stripID, "S-left", "on"])
        XCTAssertEqual(byID.status, ToolReply.ok, byID.text)
        XCTAssertEqual(fake.writes.map(\.0), ["S-left"])
    }

    func testSceneRunsOneActionSet() async {
        let (tool, fake) = tool()
        let reply = await tool.run(["scene", "SC-2"])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        XCTAssertEqual(fake.scenesRun, ["SC-2222"])
        XCTAssertEqual(reply.text, "ran: SC-2222 | Movie\n")
        let ambiguous = await tool.run(["scene", "SC-"])
        XCTAssertEqual(ambiguous.status, ToolReply.usage, ambiguous.text)
        XCTAssertTrue(ambiguous.text.contains("Good night") && ambiguous.text.contains("Movie"), ambiguous.text)
        XCTAssertEqual(fake.scenesRun, ["SC-2222"])
    }

    func testRejectsUnknownVerb() async {
        let (tool, fake) = tool()
        for call in [["remove", Self.lampID], ["pair", Self.lampID], ["unpair", Self.lampID], ["rename", Self.lampID, "Lamp"],
                     ["set", Self.lampID, "brightness", "40", Self.stripID], ["scene", "SC-1111", "SC-2222"]] {
            let reply = await tool.run(call)
            XCTAssertEqual(reply.status, ToolReply.usage, "\(call): \(reply.text)")
            XCTAssertTrue(reply.text.contains("topo home set ID CHARACTERISTIC VALUE"), reply.text)
        }
        XCTAssertTrue(fake.writes.isEmpty)
        XCTAssertTrue(fake.scenesRun.isEmpty)
    }

    func testAnAmbiguousPrefixNamesTheMatchesAndAnUnknownIDFails() async {
        let (tool, fake) = tool()
        let ambiguous = await tool.run(["set", "6A1F", "power", "on"])
        XCTAssertEqual(ambiguous.status, ToolReply.usage, ambiguous.text)
        XCTAssertTrue(ambiguous.text.contains("\(Self.lampID) Desk lamp") && ambiguous.text.contains("\(Self.stripID) Strip"),
                      ambiguous.text)
        let unknown = await tool.run(["get", "FFFF"])
        XCTAssertEqual(unknown.status, ToolReply.failed, unknown.text)
        XCTAssertTrue(fake.writes.isEmpty)
    }

    // MARK: Review focus 3: a value judged against the characteristic before any write

    func testRefusesOutOfRange() async {
        let (tool, fake) = tool()
        for (name, value) in [("brightness", "101"), ("brightness", "-1"), ("color-temperature", "145"), ("color-temperature", "600")] {
            let reply = await tool.run(["set", Self.lampID, name, value])
            XCTAssertEqual(reply.status, ToolReply.usage, "\(name) \(value): \(reply.text)")
        }
        let reply = await tool.run(["set", Self.lampID, "brightness", "101"])
        XCTAssertTrue(reply.text.contains("takes a whole number from 0 to 100 in steps of 1 (%), not 101; nothing was written"),
                      reply.text)
        let lock = await tool.run(["set", Self.lockID, "lock", "2"])
        XCTAssertEqual(lock.status, ToolReply.usage, lock.text)
        XCTAssertTrue(lock.text.contains("from 0 to 255, and of those only 0 or 1"), lock.text)
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testRefusesReadOnly() async {
        let (tool, fake) = tool()
        for name in ["power-draw", "lock-state"] {
            let id = name == "power-draw" ? Self.lampID : Self.lockID
            let reply = await tool.run(["set", id, name, "1"])
            XCTAssertEqual(reply.status, ToolReply.usage, reply.text)
            XCTAssertTrue(reply.text.contains("is read only; nothing was written"), reply.text)
        }
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testRefusesWrongType() async {
        let (tool, fake) = tool()
        for (name, value) in [("power", "dim"), ("power", "2"), ("brightness", "40.5"), ("brightness", "bright"), ("brightness", "nan")] {
            let reply = await tool.run(["set", Self.lampID, name, value])
            XCTAssertEqual(reply.status, ToolReply.usage, "\(name) \(value): \(reply.text)")
        }
        let identify = await tool.run(["set", Self.lampID, "nothing-like-it", "1"])
        XCTAssertEqual(identify.status, ToolReply.usage, identify.text)
        XCTAssertTrue(fake.writes.isEmpty)
    }

    // MARK: Review focus 4 and 5: the wait for HomeKit, and its end

    func testWaitsForFirstUpdate() async {
        let fake = FakeHome()
        fake.values = ["L-bright": .int(40)]
        let access = HomeAccess {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                fake.answer(homes: [Self.house])
            }
            return fake
        }
        let tool = HomeTool(home: access, authorizer: HomeAuthorizer(home: access), broker: PermissionBroker(),
                            readBound: .milliseconds(500))
        let reply = await tool.run([])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        XCTAssertTrue(reply.text.hasPrefix("home: The flat (primary)\n"), reply.text)
        XCTAssertTrue(reply.text.contains("Desk lamp: power ?, brightness 40, color-temperature, level"), reply.text)
    }

    /// The authorization answered, the homes not yet: the call waits for them rather than saying
    /// there are none.
    func testTheHomesAreWaitedOnPastTheAuthorization() async throws {
        let fake = FakeHome()
        let access = HomeAccess { fake }
        let tool = HomeTool(home: access, authorizer: HomeAuthorizer(home: access), broker: PermissionBroker())
        let call = Task { await tool.run(["scenes"]) }
        for _ in 0..<200 where fake.changed == nil { try await Task.sleep(for: .milliseconds(5)) }
        fake.authorization = [.determined, .authorized]
        fake.changed?(.authorization)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fake.homesRead, 0, "the homes were read before HomeKit loaded them")
        fake.records = [Self.house]
        fake.changed?(.homes)
        let reply = await call.value
        XCTAssertEqual(reply.text, "SC-1111 | Good night\nSC-2222 | Movie\n")
    }

    func testNoHomeSaysSo() async {
        let (tool, _) = tool([])
        for call in [[], ["scenes"], ["get", Self.lampID]] {
            let reply = await tool.run(call)
            XCTAssertEqual(reply.status, ToolReply.failed, reply.text)
            XCTAssertEqual(reply.text, "topo: no home is set up on this phone; the person sets one up in the Home app\n")
        }
    }

    /// The service's bound cancels a call; one waiting for HomeKit to load the homes ends at once,
    /// though HomeKit never says another word. (A call waiting on the person's answer waits in the
    /// broker's one prompt, shared by every call, and is answered by the service at its bound;
    /// `PhoneTool.run` then does nothing, which `PhoneToolsTests` holds.)
    func testACallCancelledWhileHomeKitLoadsAnswersAtOnce() async throws {
        let fake = FakeHome()
        let access = HomeAccess { fake }
        let tool = HomeTool(home: access, authorizer: HomeAuthorizer(home: access), broker: PermissionBroker())
        let call = Task { await tool.run(["set", Self.lampID, "brightness", "10"]) }
        for _ in 0..<200 where fake.changed == nil { try await Task.sleep(for: .milliseconds(5)) }
        fake.authorization = [.determined, .authorized]
        fake.changed?(.authorization)
        try await Task.sleep(for: .milliseconds(50))
        call.cancel()
        let reply = await PhoneTool.within(.seconds(1)) { await call.value }
        XCTAssertEqual(reply?.status, ToolReply.timedOut, reply?.text ?? "no answer within 1 s")
        XCTAssertTrue(fake.writes.isEmpty)
    }

    /// A call cancelled after the homes are read and before its write or scene does neither.
    func testAWriteOrSceneCancelledAfterTheHomesAreReadIsNotMade() async throws {
        for arguments in [["set", Self.lampID, "brightness", "10"], ["scene", "SC-1111"]] {
            let (tool, fake) = tool()
            _ = await tool.run(["scenes"])
            var call: Task<ToolReply, Never>?
            fake.onHomes = { call?.cancel() }
            call = Task { await tool.run(arguments) }
            let reply = await call!.value
            XCTAssertEqual(reply.status, ToolReply.timedOut, "\(arguments): \(reply.text)")
            XCTAssertTrue(fake.writes.isEmpty, "\(arguments)")
            XCTAssertTrue(fake.scenesRun.isEmpty, "\(arguments)")
        }
    }

    /// HomeKit may say the homes loaded before it says what the person chose; that is no answer.
    func testHomesLoadedBeforeTheAnswerAreNotARefusal() async throws {
        let fake = FakeHome()
        let access = HomeAccess { fake }
        let tool = HomeTool(home: access, authorizer: HomeAuthorizer(home: access), broker: PermissionBroker())
        let call = Task { await tool.run(["scenes"]) }
        for _ in 0..<200 where fake.changed == nil { try await Task.sleep(for: .milliseconds(5)) }
        fake.records = [Self.house]
        fake.changed?(.homes)
        try await Task.sleep(for: .milliseconds(100))
        fake.authorization = [.determined, .authorized]
        fake.changed?(.authorization)
        let reply = await call.value
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        XCTAssertEqual(reply.text, "SC-1111 | Good night\nSC-2222 | Movie\n")
    }

    /// Access revoked and given back while the app lives: the homes HomeKit reported before are
    /// not taken for the ones it has now, and an empty list before its fresh update is no answer.
    func testAccessRevokedAndGivenBackWaitsForFreshHomes() async throws {
        let (tool, fake) = tool()
        let first = await tool.run(["scenes"])
        XCTAssertEqual(first.status, ToolReply.ok, first.text)
        fake.records = []
        fake.authorization = [.determined]
        fake.changed?(.authorization)
        fake.authorization = [.determined, .authorized]
        fake.changed?(.authorization)
        let call = Task { await tool.run(["scenes"]) }
        try await Task.sleep(for: .milliseconds(100))
        fake.records = [Self.house]
        fake.changed?(.homes)
        let reply = await call.value
        XCTAssertEqual(reply.text, "SC-1111 | Good night\nSC-2222 | Movie\n")
    }

    // MARK: Review focus 6: a refusal, never an empty home

    func testDeniedIsARefusalAndNoHomeIsRead() async {
        let (tool, fake) = tool(allowed: false)
        let reply = await tool.run([])
        XCTAssertEqual(reply.status, ToolReply.denied, reply.text)
        XCTAssertTrue(reply.text.contains("Privacy & Security › HomeKit › Topo"), reply.text)
        XCTAssertEqual(fake.homesRead, 0)
        let again = await tool.run(["scenes"])
        XCTAssertEqual(again.status, ToolReply.denied, again.text)
    }

    /// A restricted phone answers at once with where the restriction is lifted, rather than
    /// waiting out the service's bound for an answer the person never gives.
    func testRestrictedIsARefusalAtOnce() async {
        let fake = FakeHome()
        let access = HomeAccess {
            Task { @MainActor in
                fake.authorization = [.restricted]
                fake.changed?(.authorization)
            }
            return fake
        }
        let tool = HomeTool(home: access, authorizer: HomeAuthorizer(home: access), broker: PermissionBroker())
        let reply = await PhoneTool.within(.seconds(2)) { await tool.run([]) }
        XCTAssertEqual(reply?.status, ToolReply.denied, reply?.text ?? "no answer within 2 s")
        let again = await tool.run([])
        XCTAssertTrue(again.text.contains("HomeKit is restricted on this phone"), again.text)
        XCTAssertEqual(fake.homesRead, 0)
    }

    /// Review focus 2: HomeKit may let a name be written; `topo home` renames nothing.
    func testRefusesAName() async {
        let (tool, fake) = tool()
        for (name, id) in [("name", "name"), ("configured-name", "configured-name"), ("L-name", "L-name")] {
            let reply = await tool.run(["set", Self.lampID, id, "Bedside"])
            XCTAssertEqual(reply.status, ToolReply.usage, "\(name): \(reply.text)")
            XCTAssertTrue(reply.text.contains("renames nothing; nothing was written"), reply.text)
        }
        XCTAssertTrue(fake.writes.isEmpty)
        let list = await tool.run([])
        XCTAssertFalse(list.text.contains("name"), list.text)
    }

    /// A valid value is also held to the range and the step.
    func testAValidValueOutsideTheRangeIsRefused() async {
        let (tool, fake) = tool()
        let outside = await tool.run(["set", Self.lampID, "level", "105"])
        XCTAssertEqual(outside.status, ToolReply.usage, outside.text)
        let offList = await tool.run(["set", Self.lampID, "level", "20"])
        XCTAssertEqual(offList.status, ToolReply.usage, offList.text)
        XCTAssertTrue(fake.writes.isEmpty)
        let fine = await tool.run(["set", Self.lampID, "level", "10"])
        XCTAssertEqual(fine.status, ToolReply.ok, fine.text)
        XCTAssertEqual(fake.writes.map(\.1), [.int(10)])
    }

    /// A switch is held to its metadata like any number, as 0 and 1.
    func testASwitchIsHeldToItsValidValues() throws {
        let accessory = HomeAccessory(id: "A", name: "Fan", room: "", category: "", reachable: true, services: [])
        let offOnly = HomeCharacteristic(id: "F", name: "power", format: "bool", readable: true, writable: true, minimum: nil,
                                         maximum: nil, step: nil, validValues: [0], maxLength: nil, units: nil, value: nil)
        XCTAssertThrowsError(try HomeTool.judge("on", for: offOnly, of: accessory)) { error in
            XCTAssertTrue((error as? ToolFailure)?.text.contains("takes only off here, not on") == true, "\(error)")
        }
        XCTAssertEqual(try HomeTool.judge("off", for: offOnly, of: accessory), .bool(false))
    }

    /// Whole numbers are compared exactly: 2^53 + 1 is not 2^53, which a `Double` would say it is.
    func testWholeNumbersAreComparedExactly() throws {
        let accessory = HomeAccessory(id: "A", name: "Meter", room: "", category: "", reachable: true, services: [])
        let big = Decimal(string: "9007199254740992")!
        var counter = HomeCharacteristic(id: "C", name: "counter", format: "uint64", readable: true, writable: true, minimum: nil,
                                         maximum: nil, step: nil, validValues: [big], maxLength: nil, units: nil, value: nil)
        XCTAssertThrowsError(try HomeTool.judge("9007199254740993", for: counter, of: accessory))
        XCTAssertEqual(try HomeTool.judge("9007199254740992", for: counter, of: accessory), .int(9_007_199_254_740_992))
        counter.validValues = nil
        counter.maximum = big
        XCTAssertThrowsError(try HomeTool.judge("9007199254740993", for: counter, of: accessory))
    }

    /// A refusal says the range, the step and the valid values together, and never names the
    /// value it refused as one it takes.
    func testARefusalNeverNamesTheRefusedValueAsTaken() async {
        let (tool, _) = tool()
        let reply = await tool.run(["set", Self.lampID, "level", "105"])
        XCTAssertEqual(reply.status, ToolReply.usage, reply.text)
        XCTAssertTrue(reply.text.contains("takes a whole number from 0 to 100 in steps of 10, and of those only 0 or 10, not 105"),
                      reply.text)
    }

    /// A uint64 past `Int.max` reads as `?` and is not written, rather than being a wrong number.
    func testAUInt64PastIntMaxIsNeitherMisreadNorWritten() async {
        XCTAssertNil(HomeKitStore.value(NSNumber(value: UInt64(Int.max) + 1), format: "uint64"))
        XCTAssertEqual(HomeKitStore.value(NSNumber(value: UInt64(7)), format: "uint64"), .int(7))
        var counter = HomeCharacteristic(id: "C", name: "counter", format: "uint64", readable: true, writable: true, minimum: nil,
                                         maximum: nil, step: nil, validValues: nil, maxLength: nil, units: nil, value: nil)
        let accessory = HomeAccessory(id: "A", name: "Meter", room: "", category: "", reachable: true, services: [])
        XCTAssertThrowsError(try HomeTool.judge("9223372036854775808", for: counter, of: accessory)) { error in
            XCTAssertTrue((error as? ToolFailure)?.text.contains("which topo home does not write") == true, "\(error)")
        }
        counter.maximum = Decimal(string: "18446744073709551615")
        XCTAssertThrowsError(try HomeTool.judge("18446744073709551615", for: counter, of: accessory))
    }

    /// A read HomeKit does not answer within the bound is `?`, and the listing does not wait on it.
    func testAReadPastTheBoundIsAQuestionMark() async {
        let (base, fake) = tool()
        var tool = base
        tool.readBound = .milliseconds(50)
        fake.slow = ["L-bright"]
        let bounded = tool
        let reply = await PhoneTool.within(.seconds(2)) { await bounded.run([]) }
        XCTAssertNotNil(reply, "the listing waited on a read past its bound")
        XCTAssertTrue(reply?.text.contains("Desk lamp: power true, brightness ?, color-temperature, level") == true, reply?.text ?? "")
    }

    // MARK: Reading

    func testTheListingIsByRoomAndAFailedReadIsAQuestionMark() async {
        // The listing names as settable only what `set` writes: the lamp's TLV8 is not in it.
        let (tool, fake) = tool()
        fake.unreadable = ["L-power"]
        let reply = await tool.run([])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        XCTAssertEqual(reply.text, """
        home: The flat (primary)
        \(Self.lockID) | Hall | Front door | Door Lock | not reachable | Front door: lock ?
        \(Self.lampID) | Office | Desk lamp | Lightbulb | reachable | Desk lamp: power ?, brightness 40, color-temperature, level
        \(Self.stripID) | Office | Strip | Outlet | reachable | Left: power false | Right: power true

        """)
    }

    func testGetShowsEveryCharacteristicWithWhatItTakes() async {
        let (tool, _) = tool()
        let reply = await tool.run(["get", "6a1f0c2e-0000-4000-8000-000000000001"])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        XCTAssertTrue(reply.text.contains("  L-bright | brightness | 40 | a whole number from 0 to 100 in steps of 1 (%) | can be set\n"),
                      reply.text)
        XCTAssertTrue(reply.text.contains("  L-power | power | true | on or off (true or false) | can be set\n"), reply.text)
        XCTAssertTrue(reply.text.contains("  L-watts | power-draw | 5.5 | a number | read only\n"), reply.text)
        XCTAssertTrue(reply.text.contains("  L-tlv | transition-control | (tlv8) | a tlv8 value | a tlv8 value, which topo home does not set\n"),
                      reply.text)
        XCTAssertTrue(reply.text.contains("service: Desk lamp | Lightbulb\n"), reply.text)
    }

    func testTheToolIsInTheTableHelpLists() {
        let (tool, _) = tool()
        let help = ToolTable([tool]).help
        XCTAssertTrue(help.contains("home  the lights, locks, thermostats and scenes"), help)
    }
}

import XCTest

final class SurfaceWireTests: XCTestCase {
    func testReadsARosterRequest() {
        XCTAssertEqual(SurfaceWire.request("roster\n"), .roster)
        XCTAssertEqual(SurfaceWire.request("  roster  "), .roster)
        XCTAssertNil(SurfaceWire.request("rosters"))
        XCTAssertNil(SurfaceWire.request(""))
    }

    func testReadsARegistrationCarryingAPairingCode() {
        let line = "register topo://pair?v=1&d=mac-1&n=Sam%27s%20Mac%20mini&k=AAAA"
        guard case .register(let token)? = SurfaceWire.request(line) else {
            return XCTFail("not a registration")
        }
        XCTAssertEqual(token.device, DeviceID("mac-1"))
        XCTAssertEqual(token.name, "Sam's Mac mini")
        XCTAssertEqual(token.publicKey, "AAAA")
    }

    func testRefusesATokenItCannotTrust() {
        // No key, no version, not a pairing URL at all.
        XCTAssertNil(SurfaceWire.request("register topo://pair?v=1&d=mac-1"))
        XCTAssertNil(SurfaceWire.request("register topo://pair?v=2&d=mac-1&k=AAAA"))
        XCTAssertNil(SurfaceWire.request("register https://example.com"))
        XCTAssertNil(SurfaceWire.request("register "))
    }

    func testAnswersAreOneLineEach() {
        XCTAssertEqual(SurfaceWire.line(.roster([DeviceID("a"), DeviceID("b")])), "roster a,b")
        XCTAssertEqual(SurfaceWire.line(.roster([])), "roster ")
        XCTAssertEqual(SurfaceWire.line(.registered(DeviceID("mac-1"))), "ok mac-1")
        XCTAssertEqual(SurfaceWire.line(.waiting), "wait")
        XCTAssertEqual(SurfaceWire.line(.refused("declined")), "no declined")
    }

    func testTheTxtRecordCarriesTheNameAndTheRoster() {
        let txt = SurfaceWire.txt(name: "Drawer iPad", agents: [DeviceID("mac-1"), DeviceID("phone-2")])
        XCTAssertEqual(txt["v"], Data("1".utf8))
        XCTAssertEqual(txt["n"], Data("Drawer iPad".utf8))
        XCTAssertEqual(txt["k"], Data("womble".utf8))
        XCTAssertEqual(txt["a"], Data("mac-1,phone-2".utf8))
        XCTAssertNil(txt["a+"])
    }

    func testARosterTooLongForTxtIsCutAndSaidToBe() {
        // One TXT entry cannot exceed 255 bytes, so a long roster is asked
        // for over the socket instead.
        let agents = (0..<40).map { DeviceID("device-\($0)-0123456789") }
        let txt = SurfaceWire.txt(name: "Drawer iPad", agents: agents)
        let listed = String(decoding: txt["a"] ?? Data(), as: UTF8.self)
        XCTAssertEqual(txt["a+"], Data("1".utf8))
        XCTAssertLessThanOrEqual(listed.count + 2, SurfaceWire.entryLimit)
        XCTAssertTrue(listed.hasPrefix("device-0-0123456789,device-1-0123456789"))
        XCTAssertLessThan(listed.split(separator: ",").count, agents.count)
    }
}

final class SurfaceRosterTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "surface-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func token(_ device: String) -> PairingToken {
        PairingToken(string: "topo://pair?v=1&d=\(device)&n=Hub&k=AAAA")!
    }

    func testTheRosterIsOpenToAsk() {
        let roster = SurfaceRoster(defaults: defaults)
        XCTAssertEqual(roster.answer(to: .roster), .roster([]))
        roster.accept(DeviceID("mac-1"))
        XCTAssertEqual(roster.answer(to: .roster), .roster([DeviceID("mac-1")]))
    }

    func testRegisteringWaitsForTheRoom() {
        let roster = SurfaceRoster(defaults: defaults)
        var asked = 0
        roster.pendingChanged = { asked += 1 }

        XCTAssertEqual(roster.answer(to: .register(token("mac-1"))), .waiting)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(roster.pending.first?.device, DeviceID("mac-1"))
        XCTAssertFalse(roster.isRegistered(DeviceID("mac-1")))

        // Asking again while the screen is asking does not queue it twice.
        XCTAssertEqual(roster.answer(to: .register(token("mac-1"))), .waiting)
        XCTAssertEqual(roster.pending.count, 1)

        roster.accept(DeviceID("mac-1"))
        XCTAssertTrue(roster.pending.isEmpty)
        XCTAssertEqual(roster.answer(to: .register(token("mac-1"))), .registered(DeviceID("mac-1")))
        XCTAssertEqual(roster.answer(to: .roster), .roster([DeviceID("mac-1")]))
    }

    func testDecliningIsNotForever() {
        let roster = SurfaceRoster(defaults: defaults)
        XCTAssertEqual(roster.answer(to: .register(token("mac-1"))), .waiting)
        roster.decline(DeviceID("mac-1"))
        XCTAssertTrue(roster.pending.isEmpty)
        XCTAssertFalse(roster.isRegistered(DeviceID("mac-1")))
        // The answer to "not now" is often "later".
        XCTAssertEqual(roster.answer(to: .register(token("mac-1"))), .waiting)
        XCTAssertEqual(roster.pending.count, 1)
    }

    func testTheRosterSurvivesALaunch() {
        let roster = SurfaceRoster(defaults: defaults)
        roster.accept(DeviceID("mac-1"))
        let relaunched = SurfaceRoster(defaults: defaults)
        XCTAssertEqual(relaunched.agents, [DeviceID("mac-1")])
        XCTAssertEqual(relaunched.answer(to: .register(token("mac-1"))), .registered(DeviceID("mac-1")))
    }

    func testTheAdvertIsRewrittenWhenTheRosterChanges() {
        let roster = SurfaceRoster(defaults: defaults)
        var republished = 0
        roster.rosterChanged = { republished += 1 }
        roster.accept(DeviceID("mac-1"))
        XCTAssertEqual(republished, 1)
        roster.accept(DeviceID("mac-1"))  // already there
        XCTAssertEqual(republished, 1)
        roster.remove(DeviceID("mac-1"))
        XCTAssertEqual(republished, 2)
        XCTAssertEqual(roster.agents, [])
    }

    func testIdentityIsMadeOnceAndKept() {
        let first = SurfaceIdentity.device(defaults: defaults)
        XCTAssertTrue(first.rawValue.hasPrefix("womble-"))
        XCTAssertEqual(SurfaceIdentity.device(defaults: defaults), first)
    }
}

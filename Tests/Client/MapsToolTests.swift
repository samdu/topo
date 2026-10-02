import MapKit
import TopoTools
import XCTest

@testable import Topo

/// Location standing where the test puts it, counting every read of it and every prompt.
private final class CountedPermission: Authorizer, @unchecked Sendable {
    let name = "Location"
    private let lock = NSLock()
    private var standing: Access
    private let answer: Bool
    private var _reads = 0
    private var _prompts = 0

    init(_ standing: Access = .granted, answer: Bool = true) {
        self.standing = standing
        self.answer = answer
    }

    var reads: Int { lock.withLock { _reads } }
    var prompts: Int { lock.withLock { _prompts } }

    func access() async -> Access {
        lock.withLock {
            _reads += 1
            return standing
        }
    }

    func request() async -> Bool {
        lock.withLock {
            _prompts += 1
            standing = answer ? .granted : .denied
        }
        return answer
    }
}

/// Location never asked for, whose prompt stays up until the test answers it.
private final class HeldLocationPrompt: Authorizer, @unchecked Sendable {
    let name = "Location"
    private let lock = NSLock()
    private var standing = Access.undetermined
    private var answer: CheckedContinuation<Bool, Never>?

    var isUp: Bool { lock.withLock { answer != nil } }
    func access() async -> Access { lock.withLock { standing } }
    func request() async -> Bool {
        await withCheckedContinuation { continuation in lock.withLock { answer = continuation } }
    }

    func allow() {
        let held = lock.withLock {
            standing = .granted
            defer { answer = nil }
            return answer
        }
        held?.resume(returning: true)
    }
}

/// The phone in the Mission, counting how often it was asked where it is; `held` keeps the fix
/// from ever coming.
private final class FakeLocator: Locator, @unchecked Sendable {
    private let lock = NSLock()
    private var _asked = 0
    var precise = true
    var held = false
    var latitude = 37.7599

    var asked: Int { lock.withLock { _asked } }

    func fix() async throws -> LocationFix {
        lock.withLock { _asked += 1 }
        if held { try await Task.sleep(for: .seconds(60)) }
        return LocationFix(latitude: latitude, longitude: -122.4148, accuracy: precise ? 12 : 3000, at: Date(), precise: precise,
                           place: nil)
    }
}

/// Apple Maps answering what the test gives it, recording every request made of it.
@MainActor
private final class FakeMaps: MapsStore {
    enum Request: Equatable {
        case search(String, MapRegion?)
        case route(MapPoint, MapPoint, MapMode, Date?)
        case eta(MapPoint, MapPoint, MapMode, Date?)
    }

    private(set) var requests: [Request] = []
    var places: [MapPlace] = []
    var route = MapRoute(name: "Polk St", distance: 6145, expected: 6597, notices: [],
                         steps: [MapStep(instruction: "Start on Folsom St", distance: 80),
                                 MapStep(instruction: "Take a left onto 13th St", distance: 120)])
    var eta = MapETA(distance: 6874, expected: 2457, depart: Date(timeIntervalSince1970: 1_790_000_000),
                     arrive: Date(timeIntervalSince1970: 1_790_002_457))
    var failure: MapsFailure?

    func search(query: String, region: MapRegion?) async throws -> [MapPlace] {
        requests.append(.search(query, region))
        if let failure { throw failure }
        return places
    }

    func route(from: MapPoint, to: MapPoint, mode: MapMode, depart: Date?) async throws -> MapRoute {
        requests.append(.route(from, to, mode, depart))
        if let failure { throw failure }
        return route
    }

    func eta(from: MapPoint, to: MapPoint, mode: MapMode, depart: Date?) async throws -> MapETA {
        requests.append(.eta(from, to, mode, depart))
        if let failure { throw failure }
        return eta
    }
}

@MainActor
final class MapsToolTests: XCTestCase {
    private static let mission = MapPoint(latitude: 37.7599, longitude: -122.4148)!
    private static let wharf = MapPoint(latitude: 37.8080, longitude: -122.4177)!
    private nonisolated static let noon = Date(timeIntervalSince1970: 1_790_449_200)

    private static func place(_ index: Int, _ text: String? = nil) -> MapPlace {
        MapPlace(name: text ?? "Cafe \(index)", category: text ?? "Cafe", address: text ?? "\(index) Shotwell St, San Francisco",
                 point: MapPoint(latitude: 37.76 + Double(index) / 10_000, longitude: -122.41)!, phone: text ?? "+1 415 555 01\(index)",
                 url: text ?? "https://example.com/\(index)")
    }

    private struct Rig {
        let tool: MapsTool
        let maps: FakeMaps
        let permission: CountedPermission
        let locator: FakeLocator
    }

    private func rig(_ standing: Access = .granted, answer: Bool = true) -> Rig {
        let maps = FakeMaps(), permission = CountedPermission(standing, answer: answer), locator = FakeLocator()
        let tool = MapsTool(maps: maps, locator: locator, authorizer: permission, broker: PermissionBroker(),
                            fixBound: .milliseconds(200), now: { Self.noon })
        return Rig(tool: tool, maps: maps, permission: permission, locator: locator)
    }

    /// The lines of an answer, each as its fields.
    private func records(_ text: String) -> [[String]] {
        XCTAssertTrue(text.hasSuffix("\n"), "the answer does not end its last line")
        return text.dropLast().components(separatedBy: "\n").map { $0.components(separatedBy: " | ") }
    }

    private func assertAskedNothing(_ rig: Rig, line: UInt = #line) {
        XCTAssertEqual(rig.permission.reads, 0, "Location was read", line: line)
        XCTAssertEqual(rig.permission.prompts, 0, "Location was asked for", line: line)
        XCTAssertEqual(rig.locator.asked, 0, "the phone was asked where it is", line: line)
    }

    // MARK: Review Focus 1: a prompt only for a call that needs where the phone is

    func testAnExplicitRegionAsksNothing() async {
        let rig = rig(.undetermined)
        rig.maps.places = [Self.place(1)]
        let reply = await rig.tool.run(["search", "coffee", "--near", "37.7599,-122.4148", "--radius", "800"])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        assertAskedNothing(rig)
        XCTAssertEqual(rig.maps.requests, [.search("coffee", MapRegion(centre: Self.mission, radius: 800))])
        XCTAssertTrue(reply.text.hasPrefix("region | near | 37.75990,-122.41480 | 800 | exact | coffee\n"), reply.text)
    }

    func testAnywhereAsksNothing() async {
        let rig = rig(.denied)
        rig.maps.places = [Self.place(1)]
        let reply = await rig.tool.run(["search", "coffee", "--anywhere"])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        assertAskedNothing(rig)
        XCTAssertEqual(rig.maps.requests, [.search("coffee", nil)])
        XCTAssertEqual(reply.text, """
        region | none |  |  |  | coffee
        1 | Cafe 1 | Cafe | 1 Shotwell St, San Francisco | 37.76010,-122.41000 |  | +1 415 555 011 | https://example.com/1

        """)
    }

    func testBothEndsGivenAsksNothing() async {
        let rig = rig(.undetermined)
        for verb in ["route", "eta"] {
            let reply = await rig.tool.run([verb, "--from", "37.7599,-122.4148", "--to", "37.8080,-122.4177"])
            XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        }
        assertAskedNothing(rig)
        XCTAssertEqual(rig.maps.requests, [.route(Self.mission, Self.wharf, .walking, nil), .eta(Self.mission, Self.wharf, .walking, nil)])
    }

    // MARK: Review Focus 2: a search near here with no Location

    func testNoRegionDeniedIsARefusalAndNoSearch() async {
        let rig = rig(.denied)
        let reply = await rig.tool.run(["search", "coffee"])
        XCTAssertEqual(reply.status, ToolReply.denied, reply.text)
        XCTAssertTrue(reply.text.hasPrefix("topo: Topo is not allowed to use Location on this phone."), reply.text)
        XCTAssertTrue(reply.text.hasSuffix("\nThis search can run without it: give --near LAT,LON or --anywhere.\n"), reply.text)
        XCTAssertEqual(rig.maps.requests, [])
        XCTAssertEqual(rig.locator.asked, 0)
        XCTAssertEqual(rig.permission.prompts, 0)
    }

    func testNoRegionRestrictedIsARefusalAndNoSearch() async {
        let rig = rig(.restricted)
        let reply = await rig.tool.run(["search", "coffee"])
        XCTAssertEqual(reply.status, ToolReply.denied, reply.text)
        XCTAssertTrue(reply.text.hasPrefix("topo: Location is restricted on this phone"), reply.text)
        XCTAssertTrue(reply.text.hasSuffix("\nThis search can run without it: give --near LAT,LON or --anywhere.\n"), reply.text)
        XCTAssertEqual(rig.maps.requests, [])
        XCTAssertEqual(rig.locator.asked, 0)
    }

    func testNoRegionUndeterminedAsksOnceThenSearchesNearTheFix() async {
        let rig = rig(.undetermined)
        rig.locator.precise = false
        let reply = await rig.tool.run(["search", "coffee"])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        XCTAssertEqual(rig.permission.prompts, 1)
        XCTAssertEqual(rig.locator.asked, 1)
        XCTAssertEqual(rig.maps.requests, [.search("coffee", MapRegion(centre: Self.mission, radius: 5000))])
        XCTAssertEqual(reply.text, "region | here | 37.75990,-122.41480 | 5000 | approximate | coffee\n")
    }

    func testAPromptRefusedIsARefusalAndNoSearch() async {
        let rig = rig(.undetermined, answer: false)
        let reply = await rig.tool.run(["eta", "--to", "37.8080,-122.4177"])
        XCTAssertEqual(reply.status, ToolReply.denied, reply.text)
        XCTAssertTrue(reply.text.hasSuffix("\nThis can run without it: give each end as LAT,LON rather than here.\n"), reply.text)
        XCTAssertEqual(rig.permission.prompts, 1)
        XCTAssertEqual(rig.maps.requests, [])
        XCTAssertEqual(rig.locator.asked, 0)
    }

    func testHereIsTheFixAtEitherEnd() async {
        let rig = rig()
        let from = await rig.tool.run(["route", "--to", "37.8080,-122.4177"])
        XCTAssertEqual(from.status, ToolReply.ok, from.text)
        let to = await rig.tool.run(["eta", "--from", "37.8080,-122.4177", "--to", "here", "--by", "transit"])
        XCTAssertEqual(to.status, ToolReply.ok, to.text)
        XCTAssertEqual(rig.maps.requests, [.route(Self.mission, Self.wharf, .walking, nil), .eta(Self.wharf, Self.mission, .transit, nil)])
        XCTAssertEqual(rig.locator.asked, 2)
    }

    /// `here` at either end is what needs Location, the destination as much as the origin.
    func testHereAtEitherEndNeedsLocation() async {
        for arguments in [["route", "--to", "37.8080,-122.4177"], ["route", "--from", "37.8080,-122.4177", "--to", "here"],
                          ["eta", "--to", "37.8080,-122.4177", "--from", "here"], ["eta", "--from", "37.8080,-122.4177", "--to", "here"]] {
            let rig = rig(.denied)
            let reply = await rig.tool.run(arguments)
            XCTAssertEqual(reply.status, ToolReply.denied, "\(arguments): \(reply.text)")
            XCTAssertEqual(rig.permission.reads, 1, "\(arguments)")
            XCTAssertEqual(rig.locator.asked, 0, "\(arguments)")
            XCTAssertEqual(rig.maps.requests, [], "\(arguments)")
        }
    }

    // MARK: Review Focus 3: cancelled while the prompt is up

    func testACallCancelledWhileLocationIsAskedDoesNothing() async throws {
        let maps = FakeMaps(), prompt = HeldLocationPrompt(), locator = FakeLocator()
        let tool = MapsTool(maps: maps, locator: locator, authorizer: prompt, broker: PermissionBroker())
        let call = Task { await tool.run(["search", "coffee"]) }
        for _ in 0..<500 where !prompt.isUp { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(prompt.isUp)
        call.cancel()
        prompt.allow()
        let reply = await call.value
        XCTAssertEqual(reply, PhoneTool.late)
        XCTAssertEqual(maps.requests, [])
        XCTAssertEqual(locator.asked, 0)
    }

    // MARK: Review Focus 4: cancelled while the fix is pending

    func testCancelledWhileTheFixIsPendingMakesNoRequest() async throws {
        let maps = FakeMaps(), locator = FakeLocator()
        locator.held = true
        let tool = MapsTool(maps: maps, locator: locator, authorizer: CountedPermission(), broker: PermissionBroker())
        for arguments in [["search", "coffee"], ["route", "--to", "37.8080,-122.4177"], ["eta", "--to", "37.8080,-122.4177"]] {
            let asked = locator.asked
            let call = Task { await tool.run(arguments) }
            for _ in 0..<500 where locator.asked == asked { try await Task.sleep(for: .milliseconds(10)) }
            call.cancel()
            let reply = await PhoneTool.within(.seconds(1)) { await call.value }
            XCTAssertEqual(reply, PhoneTool.late, "\(arguments)")
        }
        XCTAssertEqual(maps.requests, [])
    }

    // MARK: Review Focus 5: a fix that never comes

    func testAFixPastItsBoundSaysSo() async {
        let rig = rig()
        rig.locator.held = true
        let reply = await PhoneTool.within(.seconds(1)) { await rig.tool.run(["search", "coffee"]) }
        XCTAssertEqual(reply, .failed("topo: no location fix within 200 ms; give --near LAT,LON (or --from LAT,LON) instead\n"))
        XCTAssertEqual(rig.maps.requests, [])
    }

    func testTheProductionFixBoundIsTenSeconds() {
        let tool = MapsTool(maps: FakeMaps(), locator: FakeLocator(), authorizer: CountedPermission(), broker: PermissionBroker())
        XCTAssertEqual(tool.fixBound, .seconds(10))
        XCTAssertEqual(MapsWait.written(tool.fixBound), "10 s")
    }

    func testAFixThatIsNoPlaceIsAFailureAndNoSearch() async {
        let rig = rig()
        rig.locator.latitude = .nan
        let reply = await rig.tool.run(["search", "coffee"])
        XCTAssertEqual(reply.status, ToolReply.failed, reply.text)
        XCTAssertEqual(rig.maps.requests, [])
    }

    func testARequestPastItsBoundSaysSo() async {
        let rig = rig()
        rig.maps.failure = .unanswered(.seconds(20))
        for arguments in [["search", "coffee", "--anywhere"], ["route", "--from", "37.7599,-122.4148", "--to", "37.8080,-122.4177"],
                          ["eta", "--from", "37.7599,-122.4148", "--to", "37.8080,-122.4177"]] {
            let reply = await rig.tool.run(arguments)
            XCTAssertEqual(reply, .failed("topo: Apple Maps did not answer within 20 s\n"), "\(arguments)")
        }
    }

    // MARK: Review Focus 6: no value taken unchecked

    /// Each call is status 2, and neither reads Location, asks for it, nor asks Apple Maps anything.
    private func assertRefused(_ calls: [[String]], saying: String? = nil, line: UInt = #line) async {
        let rig = rig(.undetermined)
        for arguments in calls {
            let reply = await rig.tool.run(arguments)
            XCTAssertEqual(reply.status, ToolReply.usage, "\(arguments): \(reply.text)", line: line)
            if let saying { XCTAssertTrue(reply.text.contains(saying), "\(arguments): \(reply.text)", line: line) }
        }
        assertAskedNothing(rig, line: line)
        XCTAssertEqual(rig.maps.requests, [], line: line)
    }

    func testRefusesEachBadCoordinate() async {
        let bad = ["nan", "nan,nan", "inf,0", "0,-inf", "1e400,0", "1e2,0", "91,0", "0,181", "-90.0001,0", "0,-180.5", "37.7",
                   "37.7,-122.4,9", "Ferry Building", "37.7,", ",-122.4", "37.7 ,-122.4", "0x1p3,0", "+37.7,-122.4", "37.,-122.4",
                   ".5,0", "٣٧,١٢٢", ""]
        await assertRefused(bad.map { ["search", "coffee", "--near=\($0)"] }, saying: "it takes LAT,LON")
        await assertRefused(bad.map { ["route", "--to=\($0)"] }, saying: "it takes LAT,LON")
        await assertRefused(bad.map { ["eta", "--to", "37.8080,-122.4177", "--from=\($0)"] }, saying: "it takes LAT,LON")
        for good in ["90,180", "-90,-180", "0,0", "37.7599,-122.4148", "-33.86,151.21"] {
            XCTAssertNotNil(MapPoint(good), good)
        }
    }

    func testRefusesLimitOutsideOneToTwentyFive() async {
        await assertRefused(["0", "26", "-1", "2.5", "ten", "1e1", "+5", "", "999999999999999999999"].map {
            ["search", "coffee", "--anywhere", "--limit=\($0)"]
        }, saying: "whole number from 1 to 25")
    }

    func testRefusesRadiusOutsideItsRange() async {
        await assertRefused(["99", "50001", "0", "-500", "1000.5", "far", ""].map {
            ["search", "coffee", "--near", "37.7599,-122.4148", "--radius=\($0)"]
        }, saying: "whole number from 100 to 50000")
        await assertRefused([["search", "coffee", "--anywhere", "--radius", "500"]], saying: "--radius means nothing with --anywhere")
        await assertRefused([["search", "coffee", "--anywhere", "--near", "37.7599,-122.4148"]],
                            saying: "--near and --anywhere cannot both be given")
    }

    func testRefusesAnUnknownMode() async {
        await assertRefused(["walk", "car", "Walking", "bike", "cycling", ""].flatMap { mode in
            ["route", "eta"].map { [$0, "--to", "37.8080,-122.4177", "--by=\(mode)"] }
        }, saying: "is not a way to travel; it takes walking")
        await assertRefused([["route", "--to", "37.8080,-122.4177", "--by", "bike"]], saying: "it takes walking or driving\n")
        await assertRefused([["eta", "--to", "37.8080,-122.4177", "--by", "bike"]], saying: "it takes walking, driving or transit\n")
    }

    func testRefusesADepartureWithNoTime() async {
        await assertRefused([["eta", "--to", "37.8080,-122.4177", "--depart", "2026-09-27"],
                             ["route", "--to", "37.8080,-122.4177", "--depart", "2026-09-27"]], saying: "--depart needs a time of day")
        await assertRefused([["eta", "--to", "37.8080,-122.4177", "--depart", "tomorrow"]], saying: "is not a date")
        let rig = rig()
        let reply = await rig.tool.run(["eta", "--to", "37.8080,-122.4177", "--from", "37.7599,-122.4148", "--depart", "2026-09-26T19:00:00Z"])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        XCTAssertEqual(rig.maps.requests, [.eta(Self.mission, Self.wharf, .walking, Self.noon)])
    }

    func testRefusesAnOptionTheFormDoesNotTake() async {
        await assertRefused([["route", "--to", "37.8080,-122.4177", "--limit", "5"]], saying: "route takes no --limit")
        await assertRefused([["search", "coffee", "--to", "37.8080,-122.4177"]], saying: "search takes no --to")
        await assertRefused([["eta", "--to", "37.8080,-122.4177", "--anywhere"], ["eta", "--to", "37.8080,-122.4177", "--radius", "500"],
                             ["search", "coffee", "--by", "walking"], ["search", "coffee", "--depart", "2026-09-27T10:00"],
                             ["search", "coffee", "--open-now"], ["route"], ["eta"], ["search"], ["search", " "],
                             ["search", "coffee", "shop"], [], ["open", "37.8080,-122.4177"], ["directions", "--to", "here"],
                             ["route", "--to", "here"], ["eta", "--to", "37.8080,-122.4177", "--from", "37.8080,-122.4177"]])
    }

    // MARK: Review Focus 7: an end is never a name

    func testANamedEndIsRefusedWithTheWayToSearch() async {
        let way = "run topo maps search NAME first and pass the result's coordinates"
        await assertRefused([["route", "--to", "Ferry Building"], ["eta", "--to", "the dentist"],
                             ["eta", "--to", "37.8080,-122.4177", "--from", "home"], ["route", "Ferry Building"],
                             ["eta", "Ferry Building", "--to", "37.8080,-122.4177"]], saying: way)
    }

    // MARK: Review Focus 8 and 9: no route, and Apple Maps failing, through the adapter and the
    // errors the spike recorded

    /// The tool over the real adapter, whose requests fail as the test says.
    private func adapted(routing: any Error, timing: any Error) -> (MapsTool, FakeRequests) {
        let requests = FakeRequests()
        requests.routing = .fail(routing)
        requests.timing = .fail(timing)
        let tool = MapsTool(maps: MapKitMaps(runner: requests), locator: FakeLocator(), authorizer: CountedPermission(),
                            broker: PermissionBroker(), now: { Self.noon })
        return (tool, requests)
    }

    private static let ocean = ["--from", "37.7599,-122.4148", "--to", "21.3069,-157.8583"]

    func testUnroutableSaysSoAndIsNotAnEmptyRoute() async {
        let (tool, requests) = adapted(routing: FakeRequests.unroutable, timing: FakeRequests.noETA)
        let route = await tool.run(["route", "--by", "driving"] + Self.ocean)
        XCTAssertEqual(route, .failed("topo: no driving route from 37.75990,-122.41480 to 21.30690,-157.85830 (Apple Maps: Directions are not available between these locations.)\n"))
        let eta = await tool.run(["eta"] + Self.ocean)
        XCTAssertEqual(eta, .failed("topo: no walking route from 37.75990,-122.41480 to 21.30690,-157.85830 (Apple Maps: A route could not be determined between these locations.)\n"))
        XCTAssertEqual(requests.starts, 2)
        // An answer that holds no route is the same failure, never a route with no steps.
        requests.routing = .answer([])
        let none = await tool.run(["route"] + Self.ocean)
        XCTAssertEqual(none, .failed("topo: no walking route from 37.75990,-122.41480 to 21.30690,-157.85830\n"))
    }

    func testThrottledSaysTryLater() async {
        let (tool, _) = adapted(routing: MKError(.loadingThrottled), timing: MKError(.loadingThrottled))
        for verb in ["route", "eta"] {
            let reply = await tool.run([verb] + Self.ocean)
            XCTAssertEqual(reply, .failed("topo: Apple Maps is turning requests away for now (too many in a short time); try again in a minute\n"))
        }
    }

    func testServerFailureSaysSo() async {
        let (tool, _) = adapted(routing: MKError(.serverFailure), timing: MKError(.serverFailure))
        for verb in ["route", "eta"] {
            let reply = await tool.run([verb] + Self.ocean)
            XCTAssertEqual(reply, .failed("topo: Apple Maps' server failed; try again later\n"))
        }
    }

    func testTransitUnavailableSaysSoAndSuggestsAnotherMode() async {
        let (tool, _) = adapted(routing: MKError(.directionsNotFound), timing: FakeRequests.noETA)
        let now = await tool.run(["eta", "--by", "transit"] + Self.ocean)
        XCTAssertEqual(now, .failed("topo: no transit route from 37.75990,-122.41480 to 21.30690,-157.85830 at \(ToolDates.write(Self.noon)) (Apple Maps: A route could not be determined between these locations.); try --by walking or --by driving\n"))
        let later = await tool.run(["eta", "--by", "transit", "--depart", "2026-09-27T03:00:00Z"] + Self.ocean)
        let three = ToolDates.write(ISO8601DateFormatter().date(from: "2026-09-27T03:00:00Z")!)
        XCTAssertTrue(later.text.contains(" at \(three) (Apple Maps: "), later.text)
        XCTAssertTrue(later.text.hasSuffix("; try --by walking or --by driving\n"), later.text)
        XCTAssertEqual(later.status, ToolReply.failed)
    }

    /// Apple Maps having no answer for now (a directions code that is not one for no route) is
    /// said in its own words by every mode, and never as "no route" with advice to try another.
    func testAppleMapsHavingNoAnswerIsNotSaidAsNoRoute() async {
        for code in [MKError.Code.serverFailure, .directionsNotFound, .placemarkNotFound] {
            let (tool, _) = adapted(routing: FakeRequests.unavailable(code), timing: FakeRequests.unavailable(code))
            for arguments in [["route"], ["route", "--by", "driving"], ["eta"], ["eta", "--by", "transit"]] {
                let reply = await tool.run(arguments + Self.ocean)
                XCTAssertEqual(reply, .failed("topo: Apple Maps could not answer: Route information is not available at this moment.\n"),
                               "\(code.rawValue) \(arguments)")
            }
        }
    }

    func testRouteByTransitIsRefusedBeforeAnyPermissionOrRequest() async {
        await assertRefused([["route", "--from", "here", "--to", "37.8080,-122.4177", "--by", "transit"],
                             ["route", "--to", "37.8080,-122.4177", "--by", "transit"],
                             ["route", "--by", "transit"] + Self.ocean],
                            saying: "Apple Maps gives apps a transit time but not transit steps; use topo maps eta --by transit")
    }

    // MARK: Review Focus 10: the caps

    func testSearchCapsAtTheLimitAndAtTwentyFive() async {
        let rig = rig()
        rig.maps.places = (1...60).map { Self.place($0) }
        let ten = records(await rig.tool.run(["search", "coffee", "--anywhere"]).text)
        XCTAssertEqual(ten.count, 12)
        XCTAssertEqual(ten[1...10].map { $0[0] }, (1...10).map(String.init))
        XCTAssertEqual(ten.last, ["… 50 more results"])
        let most = records(await rig.tool.run(["search", "coffee", "--anywhere", "--limit", "25"]).text)
        XCTAssertEqual(most.count, 27)
        XCTAssertEqual(most[25], ["25", "Cafe 25", "Cafe", "25 Shotwell St, San Francisco", "37.76250,-122.41000", "", "+1 415 555 0125",
                                  "https://example.com/25"])
        XCTAssertEqual(most.last, ["… 35 more results"])
        rig.maps.places = (1...3).map { Self.place($0) }
        let all = records(await rig.tool.run(["search", "coffee", "--anywhere", "--limit", "3"]).text)
        XCTAssertEqual(all.count, 4, "three results of three were said to be cut")
    }

    func testRouteCapsAtFortyStepsAndCountsTheRest() async {
        let rig = rig()
        rig.maps.route.steps = (1...95).map { MapStep(instruction: "Turn \($0)", distance: Double($0)) }
        let lines = records(await rig.tool.run(["route"] + Self.ocean).text)
        XCTAssertEqual(lines.count, 42)
        XCTAssertEqual(lines[1], ["1", "Turn 1", "1"])
        XCTAssertEqual(lines[40], ["40", "Turn 40", "40"])
        XCTAssertEqual(lines.last, ["… 55 more steps"])
        rig.maps.route.notices = (1...9).map { "Notice \($0)" }
        let noticed = records(await rig.tool.run(["route"] + Self.ocean).text)
        XCTAssertEqual(noticed.filter { $0[0] == "notice" }, (1...5).map { ["notice", "Notice \($0)"] })
    }

    func testEveryTextFieldIsCutAtTwoHundred() async {
        let long = String(repeating: "ab | c\nd\r\ne\u{2028}| ", count: 400)
        XCTAssertGreaterThan(long.count, 5000)
        let rig = rig()
        rig.maps.places = [Self.place(1, long)]
        rig.maps.route = MapRoute(name: long, distance: 10, expected: 10, notices: [long], steps: [MapStep(instruction: long, distance: 1)])
        let search = records(await rig.tool.run(["search", long, "--anywhere"]).text)
        XCTAssertEqual(search.map(\.count), [6, 8])
        let route = records(await rig.tool.run(["route"] + Self.ocean).text)
        XCTAssertEqual(route.map(\.count), [9, 2, 3])
        // The echoed query; the name, category, address, phone and URL; the route's name, a notice
        // and an instruction.
        let fields = [search[0][5], search[1][1], search[1][2], search[1][3], search[1][6], search[1][7], route[0][8], route[1][1], route[2][1]]
        for field in fields {
            XCTAssertEqual(field.count, 200, field)
            XCTAssertTrue(field.hasSuffix("…"), field)
            XCTAssertTrue(field.hasPrefix("ab / c d e / ab / c d e"), field)
            XCTAssertFalse(field.contains(where: \.isNewline), field)
        }
        // A field of exactly two hundred characters is whole.
        let exact = String(repeating: "x", count: 200)
        XCTAssertEqual(MapsTool.field(exact), exact)
        XCTAssertEqual(MapsTool.field(exact + "y"), String(repeating: "x", count: 199) + "…")
        XCTAssertEqual(MapsTool.field(nil), "")
    }

    func testMultibyteFieldsAreCutOnACharacterBoundary() {
        let family = "👨‍👩‍👧‍👦", accented = "e\u{301}", kanji = "東", clef = "𝄞"
        for character in [family, accented, kanji, clef] {
            XCTAssertEqual(character.count, 1)
            let field = MapsTool.field(String(repeating: character, count: 300))
            XCTAssertLessThanOrEqual(field.count, MapsTool.fieldCharacters, character)
            XCTAssertLessThanOrEqual(field.utf8.count, MapsTool.fieldBytes, character)
            XCTAssertEqual(field.last, "…", character)
            XCTAssertGreaterThan(field.count, 1, character)
            // Every character before the ellipsis is a whole one of the text's.
            XCTAssertTrue(field.dropLast().allSatisfy { String($0) == character && String($0).unicodeScalars.elementsEqual(character.unicodeScalars) },
                          field)
            XCTAssertEqual(String(decoding: Array(field.utf8), as: UTF8.self), field)
        }
        // The cut point lands inside neither a pair of regional indicators nor a base and its accent.
        let mixed = String(repeating: "x", count: 198) + "🇬🇧" + accented + "tail"
        XCTAssertEqual(MapsTool.field(mixed), String(repeating: "x", count: 198) + "🇬🇧" + "…")
        // A two-hundred-character field of four-byte characters is whole, at the byte cap exactly.
        let full = String(repeating: clef, count: 200)
        XCTAssertEqual(MapsTool.field(full), full)
        XCTAssertEqual(full.utf8.count, MapsTool.fieldBytes)
        // One character past every byte cap is said as cut, never written out.
        let zalgo = "z" + String(repeating: "\u{301}", count: 1000)
        XCTAssertEqual(zalgo.count, 1)
        XCTAssertEqual(MapsTool.field(zalgo), "…")
    }

    func testTheByteBudgetDropsWholeRecordsAndSaysHowMany() async {
        let wide = String(repeating: "𝄞", count: 200)
        let rig = rig()
        rig.maps.places = (1...25).map { Self.place($0, wide) }
        let reply = await rig.tool.run(["search", wide, "--near", "37.7599,-122.4148", "--limit", "25"])
        XCTAssertEqual(reply.status, ToolReply.ok)
        XCTAssertLessThanOrEqual(reply.text.utf8.count, 24_576)
        let lines = records(reply.text)
        let kept = lines.count - 2
        XCTAssertGreaterThan(kept, 0)
        XCTAssertLessThan(kept, 25)
        XCTAssertEqual(lines[0].count, 6)
        XCTAssertEqual(lines[0][5], wide)
        for (index, line) in lines[1...kept].enumerated() {
            XCTAssertEqual(line.count, 8)
            XCTAssertEqual(line[0], String(index + 1))
            for field in [1, 2, 3, 6, 7] { XCTAssertEqual(line[field], wide) }
        }
        XCTAssertEqual(lines.last, ["… \(25 - kept) more results, cut at 24 KB; narrow the search or lower --limit"])
        // One more record would have passed the budget: the cut is the budget's, not an early one.
        XCTAssertGreaterThan(reply.text.utf8.count + lines[1].joined(separator: " | ").utf8.count + 1, 24_576 - MapsTool.lastLineRoom)
        // With more than the limit to begin with, the last line counts both.
        rig.maps.places = (1...60).map { Self.place($0, wide) }
        let more = records(await rig.tool.run(["search", "x", "--anywhere", "--limit", "25"]).text)
        XCTAssertEqual(more.last, ["… \(60 - (more.count - 2)) more results, cut at 24 KB; narrow the search or lower --limit"])
    }

    func testTheByteBudgetDropsWholeSteps() async {
        let wide = String(repeating: "𝄞", count: 200)
        let rig = rig()
        rig.maps.route = MapRoute(name: wide, distance: 123_456, expected: 7890, notices: Array(repeating: wide, count: 5),
                                  steps: (1...40).map { _ in MapStep(instruction: wide, distance: 150) })
        let reply = await rig.tool.run(["route"] + Self.ocean)
        XCTAssertEqual(reply.status, ToolReply.ok)
        XCTAssertLessThanOrEqual(reply.text.utf8.count, 24_576)
        let lines = records(reply.text)
        XCTAssertEqual(lines[0].count, 9)
        XCTAssertEqual(lines[0][8], wide)
        XCTAssertEqual(Array(lines[1...5]), Array(repeating: ["notice", wide], count: 5))
        let kept = lines.count - 7
        XCTAssertGreaterThan(kept, 0)
        XCTAssertLessThan(kept, 40)
        for (index, line) in lines[6..<(6 + kept)].enumerated() {
            XCTAssertEqual(line, [String(index + 1), wide, "150"])
        }
        XCTAssertEqual(lines.last, ["… \(40 - kept) more steps, cut at 24 KB"])
        rig.maps.route.steps = (1...95).map { _ in MapStep(instruction: wide, distance: 150) }
        let more = records(await rig.tool.run(["route"] + Self.ocean).text)
        XCTAssertEqual(more.last, ["… \(95 - (more.count - 7)) more steps, cut at 24 KB"])
    }

    func testTheHeaderAlwaysFits() async {
        // The widest a field is written: its byte cap, whatever it holds.
        let widest = [String(repeating: "𝄞", count: 5000), String(repeating: "👨‍👩‍👧‍👦", count: 5000),
                      String(repeating: "z" + String(repeating: "\u{301}", count: 300), count: 300)]
        let room = MapsTool.budget - MapsTool.lastLineRoom
        for wide in widest {
            XCTAssertLessThanOrEqual(MapsTool.field(wide).utf8.count, MapsTool.fieldBytes)
            let rig = rig()
            let region = await rig.tool.run(["search", wide, "--near", "-89.99999,-179.99999", "--radius", "50000"])
            XCTAssertEqual(records(region.text).count, 1)
            XCTAssertLessThanOrEqual(region.text.utf8.count, room)
            rig.maps.route = MapRoute(name: wide, distance: 1e15, expected: 1e15, notices: Array(repeating: wide, count: 9), steps: [])
            let route = await rig.tool.run(["route", "--from", "-89.99999,-179.99999", "--to", "-89.99998,-179.99998", "--by", "driving"])
            XCTAssertEqual(records(route.text).count, 6)
            XCTAssertLessThanOrEqual(route.text.utf8.count, room)
        }
        // And the last line fits the room kept for it, however many it counts.
        for line in ["… \(Int.max) more results, cut at 24 KB; narrow the search or lower --limit\n", "… \(Int.max) more steps, cut at 24 KB\n"] {
            XCTAssertLessThanOrEqual(line.utf8.count, MapsTool.lastLineRoom)
        }
        XCTAssertEqual(MapsTool.fit(header: ["h"], records: ["r"], more: Int.max - 1, unit: "results", advice: ""), "h\nr\n… \(Int.max - 1) more results\n")
    }

    /// The budget at its edge: a record that ends exactly at the budget less the last line's room
    /// is kept, one a byte longer is not, and either way the answer with its last line is within
    /// the budget.
    func testTheByteBudgetIsHeldAtItsEdge() {
        let room = MapsTool.budget - MapsTool.lastLineRoom
        let advice = "; narrow the search or lower --limit"
        // "h\n" is two bytes and each record's line break one.
        let fits = String(repeating: "x", count: room - 3)
        let kept = MapsTool.fit(header: ["h"], records: [fits, "next"], more: Int.max - 2, unit: "results", advice: advice)
        XCTAssertTrue(kept.hasPrefix("h\n" + fits + "\n… \(Int.max - 1) more results, cut at 24 KB"), String(kept.suffix(100)))
        XCTAssertLessThanOrEqual(kept.utf8.count, MapsTool.budget)
        let over = MapsTool.fit(header: ["h"], records: [fits + "x"], more: 0, unit: "results", advice: advice)
        XCTAssertEqual(over, "h\n… 1 more results, cut at 24 KB; narrow the search or lower --limit\n")
        let whole = MapsTool.fit(header: ["h"], records: [fits], more: 0, unit: "results", advice: advice)
        XCTAssertEqual(whole, "h\n" + fits + "\n")
        XCTAssertEqual(whole.utf8.count, room)
    }

    /// A number too large to be a whole number of metres or seconds is written at the cap.
    func testAHugeNumberIsWrittenAndDoesNotTrap() {
        XCTAssertEqual(MapsTool.whole(1e300), "1000000000000000")
        XCTAssertEqual(MapsTool.whole(.greatestFiniteMagnitude), "1000000000000000")
        XCTAssertEqual(MapsTool.whole(6144.6), "6145")
        XCTAssertEqual(MapsTool.whole(-0.5), "")
    }

    func testAnEmptySearchIsAnAnswerWithItsRegion() async {
        let rig = rig()
        let reply = await rig.tool.run(["search", "zxqvjwkpfy", "--near", "37.7599,-122.4148"])
        XCTAssertEqual(reply, .ok("region | near | 37.75990,-122.41480 | 5000 | exact | zxqvjwkpfy\n"))
        XCTAssertEqual(rig.maps.requests.count, 1)
    }

    // MARK: Review Focus 11: lines the mind can read

    func testEveryOkAnswerIsWellFormedLines() async {
        let rig = rig()
        rig.maps.places = [Self.place(1), MapPlace(name: nil, category: nil, address: nil, point: Self.wharf, phone: nil, url: nil),
                           MapPlace(name: "A | B\nC", category: "", address: " | ", point: Self.mission, phone: "\n", url: "https://x.example/?a|b")]
        rig.maps.route = MapRoute(name: "", distance: .nan, expected: .infinity, notices: ["Tolls\nahead | maybe"],
                                  steps: [MapStep(instruction: "Go | north\nthen east", distance: -1), MapStep(instruction: "", distance: .nan)])
        rig.maps.eta = MapETA(distance: .infinity, expected: .nan, depart: Self.noon, arrive: Self.noon)
        var answers: [(String, [Int])] = []
        answers.append((await rig.tool.run(["search", "a | b\nc"]).text, [6, 8, 8, 8]))
        answers.append((await rig.tool.run(["search", "coffee", "--anywhere"]).text, [6, 8, 8, 8]))
        answers.append((await rig.tool.run(["route"] + Self.ocean).text, [9, 2, 3, 3]))
        answers.append((await rig.tool.run(["eta", "--to", "37.8080,-122.4177"]).text, [8]))
        for (text, counts) in answers {
            XCTAssertEqual(records(text).map(\.count), counts, text)
            XCTAssertFalse(text.lowercased().contains("nan"), text)
            XCTAssertFalse(text.lowercased().contains("inf"), text)
            XCTAssertFalse(text.contains("\n\n"), text)
            XCTAssertFalse(text.contains("\r"), text)
        }
        let search = records(answers[0].0)
        XCTAssertEqual(search[0], ["region", "here", "37.75990,-122.41480", "5000", "exact", "a / b c"])
        XCTAssertEqual(search[2], ["2", "", "", "", "37.80800,-122.41770", String(Int(Self.mission.metres(to: Self.wharf).rounded())), "", ""])
        XCTAssertEqual(search[3], ["3", "A / B C", "", "/", "37.75990,-122.41480", "0", "", "https://x.example/?a/b"])
        let route = records(answers[2].0)
        let left = ToolDates.write(Self.noon)
        XCTAssertEqual(route[0], ["route", "37.75990,-122.41480", "21.30690,-157.85830", "walking", "", "", left, "", ""])
        XCTAssertEqual(route[1], ["notice", "Tolls ahead / maybe"])
        XCTAssertEqual(route[2], ["1", "Go / north then east", ""])
        XCTAssertEqual(route[3], ["2", "", ""])
        XCTAssertEqual(records(answers[3].0), [["eta", "37.75990,-122.41480", "37.80800,-122.41770", "walking", "", "", left, left]])
    }

    func testARouteSaysWhenItLeavesAndArrives() async {
        let rig = rig()
        let reply = await rig.tool.run(["route", "--by", "driving", "--depart", "2026-09-26T20:00:00Z"] + Self.ocean)
        let leaves = Self.noon.addingTimeInterval(3600)
        XCTAssertEqual(reply.text, """
        route | 37.75990,-122.41480 | 21.30690,-157.85830 | driving | 6145 | 6597 | \(ToolDates.write(leaves)) | \(ToolDates.write(leaves.addingTimeInterval(6597))) | Polk St
        1 | Start on Folsom St | 80
        2 | Take a left onto 13th St | 120

        """)
        let eta = await rig.tool.run(["eta", "--by", "transit"] + Self.ocean)
        XCTAssertEqual(eta.text, "eta | 37.75990,-122.41480 | 21.30690,-157.85830 | transit | 6874 | 2457 | \(ToolDates.write(rig.maps.eta.depart)) | \(ToolDates.write(rig.maps.eta.arrive))\n")
    }

    func testCoordinatesAreFiveDecimalPlaces() async throws {
        let rig = rig()
        rig.maps.places = [MapPlace(name: "A", category: nil, address: nil, point: MapPoint(latitude: 1.0 / 3, longitude: -0.000001)!,
                                    phone: nil, url: nil)]
        let search = records(await rig.tool.run(["search", "a", "--near", "37.759912345,-122.4"]).text)
        let route = records(await rig.tool.run(["route", "--from", "90,180", "--to", "-0.0000001,7"]).text)
        let eta = records(await rig.tool.run(["eta", "--to", "12.3456789,-98.7654321"]).text)
        let written = [search[0][2], search[1][4], route[0][1], route[0][2], eta[0][1], eta[0][2]]
        XCTAssertEqual(written, ["37.75991,-122.40000", "0.33333,0.00000", "90.00000,180.00000", "0.00000,7.00000", "37.75990,-122.41480",
                                 "12.34568,-98.76543"])
        let shape = try NSRegularExpression(pattern: #"^-?[0-9]{1,2}\.[0-9]{5},-?[0-9]{1,3}\.[0-9]{5}$"#)
        for point in written {
            XCTAssertEqual(shape.numberOfMatches(in: point, range: NSRange(point.startIndex..., in: point)), 1, point)
        }
    }

    // MARK: Review Focus 14: the table

    func testTheToolIsInTheTableHelpLists() async {
        let tool = rig().tool
        let table = ToolTable([tool])
        XCTAssertTrue(table.help.contains("maps  places, routes and travel times (Apple Maps)"), table.help)
        let usage = await table.run(["help", "maps"])
        for form in ["topo maps search QUERY", "topo maps route --to LAT,LON|here", "topo maps eta --to LAT,LON|here"] {
            XCTAssertTrue(usage.text.contains(form), usage.text)
        }
    }
}

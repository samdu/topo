import Contacts
import MapKit
import TopoTools
import XCTest

@testable import Topo

/// MapKit's requests as a test drives them: each one answered, failed or held, and every start
/// and cancel counted. A held request stays held after `cancel`, as a cancelled `MKDirections`
/// does, whose handler is never called.
@MainActor
final class FakeRequests: MapRequestRunner {
    enum Behaviour<Answer> {
        case answer(Answer)
        case fail(any Error)
        case hold
    }

    var searching: Behaviour<[MKMapItem]> = .answer([])
    var routing: Behaviour<[MKRoute]> = .hold
    var timing: Behaviour<MKDirections.ETAResponse> = .hold
    private(set) var searches: [MKLocalSearch.Request] = []
    private(set) var routes: [MKDirections.Request] = []
    private(set) var etas: [MKDirections.Request] = []
    fileprivate(set) var starts = 0
    fileprivate(set) var cancels = 0

    func search(_ request: MKLocalSearch.Request) -> any MapRequest<[MKMapItem]> {
        searches.append(request)
        return FakeRequest(searching, log: self)
    }

    func directions(_ request: MKDirections.Request) -> any MapRequest<[MKRoute]> {
        routes.append(request)
        return FakeRequest(routing, log: self)
    }

    func eta(_ request: MKDirections.Request) -> any MapRequest<MKDirections.ETAResponse> {
        etas.append(request)
        return FakeRequest(timing, log: self)
    }

    /// What the spike on the simulator recorded MapKit failing with between two points nothing
    /// joins: `calculate()`'s server failure carrying a directions code.
    static let unroutable = NSError(domain: MKErrorDomain, code: Int(MKError.Code.serverFailure.rawValue), userInfo: [
        "MKDirectionsErrorCode": 16,
        NSLocalizedDescriptionKey: "Walking Directions Not Available",
        NSLocalizedFailureReasonErrorKey: "Directions are not available between these locations.",
    ])
    /// And `calculateETA()`'s, for the same two points and for transit with no service.
    static let noETA = NSError(domain: MKErrorDomain, code: Int(MKError.Code.placemarkNotFound.rawValue), userInfo: [
        "MKDirectionsErrorCode": 1,
        NSLocalizedDescriptionKey: "Directions Not Available",
        NSLocalizedFailureReasonErrorKey: "A route could not be determined between these locations.",
    ])
    /// A search that found nothing.
    static let nothingFound = NSError(domain: MKErrorDomain, code: Int(MKError.Code.placemarkNotFound.rawValue),
                                      userInfo: ["MKErrorGEOError": -8])
}

@MainActor
private final class FakeRequest<Answer>: MapRequest {
    private let behaviour: FakeRequests.Behaviour<Answer>
    private let log: FakeRequests
    private var held: UnsafeContinuation<Answer, Never>?

    init(_ behaviour: FakeRequests.Behaviour<Answer>, log: FakeRequests) {
        self.behaviour = behaviour
        self.log = log
    }

    func start() async throws -> Answer {
        log.starts += 1
        switch behaviour {
        case .answer(let answer): return answer
        case .fail(let error): throw error
        case .hold: return await withUnsafeContinuation { held = $0 }
        }
    }

    func cancel() {
        log.cancels += 1
    }
}

/// A route MapKit would give, with what the test puts in it.
final class CannedRoute: MKRoute {
    private let title: String
    private let metres: Double
    private let seconds: Double
    private let notices: [String]
    private let legs: [MKRoute.Step]

    init(name: String = "Polk St", distance: Double = 6145, expected: Double = 6597, notices: [String] = [],
         steps: [(String, Double)]) {
        title = name
        metres = distance
        seconds = expected
        self.notices = notices
        legs = steps.map { CannedStep($0.0, $0.1) }
        super.init()
    }

    override var name: String { title }
    override var distance: CLLocationDistance { metres }
    override var expectedTravelTime: TimeInterval { seconds }
    override var advisoryNotices: [String] { notices }
    override var steps: [MKRoute.Step] { legs }
}

final class CannedStep: MKRoute.Step {
    private let words: String
    private let metres: Double

    init(_ words: String, _ metres: Double) {
        self.words = words
        self.metres = metres
        super.init()
    }

    override var instructions: String { words }
    override var distance: CLLocationDistance { metres }
}

final class CannedETA: MKDirections.ETAResponse {
    private let metres: Double
    private let seconds: Double
    private let leaves: Date

    init(distance: Double, expected: Double, depart: Date) {
        metres = distance
        seconds = expected
        leaves = depart
        super.init()
    }

    override var distance: CLLocationDistance { metres }
    override var expectedTravelTime: TimeInterval { seconds }
    override var expectedDepartureDate: Date { leaves }
    override var expectedArrivalDate: Date { leaves.addingTimeInterval(seconds) }
}

/// `MapKitMaps` over `FakeRequests`: its bound, its cancel, and what it makes of MapKit's answers
/// and errors. That `MKLocalSearch` and `MKDirections` themselves stop at `cancel()` is Apple's and
/// is not shown here.
@MainActor
final class MapKitMapsTests: XCTestCase {
    private static let mission = MapPoint(latitude: 37.7599, longitude: -122.4148)!
    private static let wharf = MapPoint(latitude: 37.8080, longitude: -122.4177)!
    private let noon = ISO8601DateFormatter().date(from: "2026-09-26T19:00:00Z")!

    /// Until `condition` holds, or two seconds.
    private func wait(for condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// What `call` ended on, or nil if it had not ended a second after it was asked.
    private func ended<Value: Sendable>(_ call: Task<Value, any Error>) async -> Result<Value, any Error>? {
        await PhoneTool.within(.seconds(1)) { await call.result }
    }

    private func assertCancelled<Value: Sendable>(_ call: Task<Value, any Error>, _ requests: FakeRequests,
                                                  line: UInt = #line) async throws {
        try await wait { requests.starts == 1 }
        XCTAssertEqual(requests.starts, 1, line: line)
        call.cancel()
        guard let result = await ended(call) else {
            return XCTFail("a cancelled call was still waiting on its request a second later", line: line)
        }
        XCTAssertThrowsError(try result.get(), line: line) { XCTAssertTrue($0 is CancellationError, "\($0)", line: line) }
        XCTAssertEqual(requests.cancels, 1, "the request was not cancelled exactly once", line: line)
    }

    private func assertUnanswered<Value: Sendable>(_ call: Task<Value, any Error>, _ requests: FakeRequests,
                                                   line: UInt = #line) async {
        guard let result = await ended(call) else {
            return XCTFail("a request that never answers was still waited on a second later", line: line)
        }
        XCTAssertThrowsError(try result.get(), line: line) {
            XCTAssertEqual($0 as? MapsFailure, .unanswered(.milliseconds(200)), line: line)
        }
        XCTAssertEqual(requests.starts, 1, line: line)
        XCTAssertEqual(requests.cancels, 1, "the request was not cancelled exactly once", line: line)
    }

    // MARK: Review Focus 4: a cancelled call cancels its request

    func testACancelledSearchCancelsItsRequest() async throws {
        let requests = FakeRequests()
        requests.searching = .hold
        let maps = MapKitMaps(runner: requests)
        try await assertCancelled(Task { try await maps.search(query: "coffee", region: nil) }, requests)
    }

    func testACancelledRouteCancelsItsRequest() async throws {
        let requests = FakeRequests()
        let maps = MapKitMaps(runner: requests)
        try await assertCancelled(Task { try await maps.route(from: Self.mission, to: Self.wharf, mode: .walking, depart: nil) }, requests)
    }

    func testACancelledETACancelsItsRequest() async throws {
        let requests = FakeRequests()
        let maps = MapKitMaps(runner: requests)
        try await assertCancelled(Task { try await maps.eta(from: Self.mission, to: Self.wharf, mode: .transit, depart: nil) }, requests)
    }

    func testACallAlreadyCancelledStartsNoRequest() async {
        let requests = FakeRequests()
        let maps = MapKitMaps(runner: requests)
        let call = Task {
            try? await Task.sleep(for: .seconds(60))
            return try await maps.route(from: Self.mission, to: Self.wharf, mode: .walking, depart: nil)
        }
        call.cancel()
        let result = await call.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(requests.starts, 0)
    }

    // MARK: Review Focus 5: a request that never answers

    func testASearchPastItsBoundIsCancelledAndSaysSo() async {
        let requests = FakeRequests()
        requests.searching = .hold
        let maps = MapKitMaps(runner: requests, requestBound: .milliseconds(200))
        await assertUnanswered(Task { try await maps.search(query: "coffee", region: nil) }, requests)
    }

    func testARoutePastItsBoundIsCancelledAndSaysSo() async {
        let requests = FakeRequests()
        let maps = MapKitMaps(runner: requests, requestBound: .milliseconds(200))
        await assertUnanswered(Task { try await maps.route(from: Self.mission, to: Self.wharf, mode: .driving, depart: nil) }, requests)
    }

    func testAnETAPastItsBoundIsCancelledAndSaysSo() async {
        let requests = FakeRequests()
        let maps = MapKitMaps(runner: requests, requestBound: .milliseconds(200))
        await assertUnanswered(Task { try await maps.eta(from: Self.mission, to: Self.wharf, mode: .transit, depart: nil) }, requests)
    }

    func testTheProductionBoundIsTwentySeconds() {
        XCTAssertEqual(MapKitMaps(runner: FakeRequests()).requestBound, .seconds(20))
        XCTAssertEqual(MapsWait.written(.seconds(20)), "20 s")
        XCTAssertEqual(MapsWait.written(.milliseconds(200)), "200 ms")
    }

    /// An answer in time is given, and its request is not cancelled.
    func testAnAnswerInTimeCancelsNothing() async throws {
        let requests = FakeRequests()
        requests.timing = .answer(CannedETA(distance: 6874, expected: 2457, depart: noon))
        let eta = try await MapKitMaps(runner: requests, requestBound: .milliseconds(200))
            .eta(from: Self.mission, to: Self.wharf, mode: .transit, depart: nil)
        XCTAssertEqual(eta, MapETA(distance: 6874, expected: 2457, depart: noon, arrive: noon.addingTimeInterval(2457)))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(requests.cancels, 0)
    }

    // MARK: MapKit's own request, behind its handler

    /// `MKDirections.cancel()` never calls the handler: the wait ends at `cancel` all the same.
    func testACancelledRequestEndsItsWaitThoughMapKitNeverCallsBack() async throws {
        final class Seen {
            var begun = false
            var stops = 0
        }
        let seen = Seen()
        let request = MapKitRequest<Int>(begin: { _ in seen.begun = true }, stop: { seen.stops += 1 })
        let call = Task { try await request.start() }
        try await wait { seen.begun }
        XCTAssertTrue(seen.begun)
        request.cancel()
        request.cancel()
        let result = await PhoneTool.within(.seconds(1)) { await call.result }
        XCTAssertNotNil(result, "start was still waiting a second after cancel")
        XCTAssertThrowsError(try result?.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(seen.stops, 1)
        // One cancelled before it starts never begins.
        let unstarted = MapKitRequest<Int>(begin: { _ in XCTFail("a cancelled request began") }, stop: {})
        unstarted.cancel()
        do {
            _ = try await unstarted.start()
            XCTFail("a cancelled request answered")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testARequestGivesWhatItsHandlerIsCalledWith() async throws {
        let answered = MapKitRequest<Int>(begin: { done in done(.init(.success(7))) }, stop: {})
        let seven = try await answered.start()
        XCTAssertEqual(seven, 7)
        let failed = MapKitRequest<Int>(begin: { done in done(.init(nil, MKError(.loadingThrottled))) }, stop: {})
        do {
            _ = try await failed.start()
            XCTFail("a failed request answered")
        } catch {
            XCTAssertEqual((error as? MKError)?.code, .loadingThrottled)
        }
    }

    // MARK: What the adapter makes of MapKit's answers

    func testTheAdapterMapsAnItemAndARoute() async throws {
        let address = CNMutablePostalAddress()
        address.street = "1 Ferry Building"
        address.city = "San Francisco"
        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937),
                                                    postalAddress: address))
        item.name = "Ferry Building"
        item.phoneNumber = "+1 415 555 0100"
        item.url = URL(string: "https://example.com/ferry")
        item.pointOfInterestCategory = .cafe
        let requests = FakeRequests()
        requests.searching = .answer([item])
        requests.routing = .answer([CannedRoute(notices: ["Stairs"], steps: [("", 0), ("Take a left onto 13th St", 120), ("", 5)]),
                                    CannedRoute(name: "The other way", steps: [])])
        let maps = MapKitMaps(runner: requests)

        let places = try await maps.search(query: "ferry", region: nil)
        XCTAssertEqual(places.count, 1)
        XCTAssertEqual(places.first?.name, "Ferry Building")
        XCTAssertEqual(places.first?.category, "Cafe")
        XCTAssertEqual(places.first?.point, MapPoint(latitude: 37.7955, longitude: -122.3937))
        // MapKit writes a number its own way.
        XCTAssertEqual(places.first?.phone, "+1 (415) 555-0100")
        XCTAssertEqual(places.first?.url, "https://example.com/ferry")
        XCTAssertTrue(places.first?.address?.contains("1 Ferry Building") == true, "\(String(describing: places.first?.address))")

        let route = try await maps.route(from: Self.mission, to: Self.wharf, mode: .walking, depart: nil)
        // The first route alone, its opening step with no instruction left out and a later one kept.
        XCTAssertEqual(route, MapRoute(name: "Polk St", distance: 6145, expected: 6597, notices: ["Stairs"],
                                       steps: [MapStep(instruction: "Take a left onto 13th St", distance: 120), MapStep(instruction: "", distance: 5)]))
    }

    /// The spike: walking's first step says something ("Start on Folsom St") and is a step.
    func testAFirstStepWithWordsIsKept() {
        let route = MapKitMaps.route(CannedRoute(steps: [("Start on Folsom St", 80), ("Take a left onto 13th St", 120)]))
        XCTAssertEqual(route.steps.map(\.instruction), ["Start on Folsom St", "Take a left onto 13th St"])
    }

    func testAnItemThatIsNoPlaceOnTheMapIsLeftOut() {
        let nowhere = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: .nan, longitude: 0)))
        XCTAssertNil(MapKitMaps.place(nowhere))
        let beyond = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 91, longitude: 0)))
        XCTAssertNil(MapKitMaps.place(beyond))
    }

    func testNoRouteInTheAnswerIsNoRoute() async {
        let requests = FakeRequests()
        requests.routing = .answer([])
        do {
            _ = try await MapKitMaps(runner: requests).route(from: Self.mission, to: Self.wharf, mode: .walking, depart: nil)
            XCTFail("an answer with no route was a route")
        } catch {
            XCTAssertEqual(error as? MapsFailure, .noRoute(nil))
        }
    }

    // MARK: The requests it makes

    func testASearchCarriesItsRegionAndHoldsToIt() async throws {
        let requests = FakeRequests()
        let maps = MapKitMaps(runner: requests)
        _ = try await maps.search(query: "coffee", region: MapRegion(centre: Self.mission, radius: 5000))
        _ = try await maps.search(query: "coffee", region: nil)
        let near = try XCTUnwrap(requests.searches.first)
        XCTAssertEqual(near.naturalLanguageQuery, "coffee")
        XCTAssertEqual(near.region.center.latitude, 37.7599, accuracy: 1e-6)
        XCTAssertEqual(near.region.center.longitude, -122.4148, accuracy: 1e-6)
        // 10 km of latitude, a little under a tenth of a degree.
        XCTAssertEqual(near.region.span.latitudeDelta, 0.09, accuracy: 0.005)
        if #available(iOS 18.0, *) {
            XCTAssertEqual(near.regionPriority, .required)
            XCTAssertEqual(requests.searches.last?.regionPriority, .default)
        }
    }

    func testDirectionsCarryBothEndsTheModeAndTheDeparture() async throws {
        let requests = FakeRequests()
        requests.routing = .answer([CannedRoute(steps: [])])
        requests.timing = .answer(CannedETA(distance: 1, expected: 1, depart: noon))
        let maps = MapKitMaps(runner: requests)
        _ = try await maps.route(from: Self.mission, to: Self.wharf, mode: .driving, depart: noon)
        _ = try await maps.eta(from: Self.wharf, to: Self.mission, mode: .transit, depart: nil)
        _ = try await maps.eta(from: Self.wharf, to: Self.mission, mode: .walking, depart: nil)
        let route = try XCTUnwrap(requests.routes.first)
        XCTAssertEqual(route.source?.placemark.coordinate.latitude ?? 0, 37.7599, accuracy: 1e-6)
        XCTAssertEqual(route.destination?.placemark.coordinate.latitude ?? 0, 37.8080, accuracy: 1e-6)
        XCTAssertEqual(route.transportType, .automobile)
        XCTAssertEqual(route.departureDate, noon)
        XCTAssertFalse(route.requestsAlternateRoutes)
        XCTAssertEqual(requests.etas.map(\.transportType), [.transit, .walking])
        XCTAssertEqual(requests.etas.first?.source?.placemark.coordinate.longitude ?? 0, -122.4177, accuracy: 1e-6)
        XCTAssertNil(requests.etas.first?.departureDate)
    }

    // MARK: MapKit's errors, as the spike recorded them

    func testASearchThatFindsNothingIsNoPlaces() async throws {
        let requests = FakeRequests()
        requests.searching = .fail(FakeRequests.nothingFound)
        let places = try await MapKitMaps(runner: requests).search(query: "zxqvjwkpfy", region: nil)
        XCTAssertEqual(places, [])
    }

    func testEachErrorIsWhatMapsToolSays() {
        let apple = "Directions are not available between these locations."
        let cases: [(any Error, MapsFailure)] = [
            (FakeRequests.unroutable, .noRoute(apple)),
            (FakeRequests.noETA, .noRoute("A route could not be determined between these locations.")),
            (MKError(.directionsNotFound), .noRoute(nil)),
            (MKError(.serverFailure), .server(nil)),
            (NSError(domain: MKErrorDomain, code: Int(MKError.Code.serverFailure.rawValue),
                     userInfo: [NSLocalizedDescriptionKey: "Server Error"]), .server("Server Error")),
            (MKError(.loadingThrottled), .throttled),
            (MapsFailure.unanswered(.seconds(20)), .unanswered(.seconds(20))),
        ]
        for (error, said) in cases {
            XCTAssertEqual(MapKitMaps.failure(error) as? MapsFailure, said, "\(error)")
        }
        XCTAssertTrue(MapKitMaps.failure(CancellationError()) is CancellationError)
        guard case .other? = MapKitMaps.failure(MKError(.unknown)) as? MapsFailure else { return XCTFail("unknown was not said as itself") }
        guard case .other? = MapKitMaps.failure(URLError(.notConnectedToInternet)) as? MapsFailure else {
            return XCTFail("another framework's error was not said as itself")
        }
    }

    func testAFailedSearchIsItsFailureAndNotAnEmptyList() async {
        let requests = FakeRequests()
        requests.searching = .fail(MKError(.loadingThrottled))
        do {
            _ = try await MapKitMaps(runner: requests).search(query: "coffee", region: nil)
            XCTFail("a throttled search answered")
        } catch {
            XCTAssertEqual(error as? MapsFailure, .throttled)
        }
    }
}

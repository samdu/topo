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
    /// What MapKit gave a routable pair asked for a departure it has no data for (the year 9999),
    /// and what its own mapping makes of a directions request the server could not serve: a
    /// directions code that is not one of the two for points nothing joins.
    static func unavailable(_ code: MKError.Code) -> NSError {
        NSError(domain: MKErrorDomain, code: Int(code.rawValue), userInfo: [
            "MKDirectionsErrorCode": 3,
            NSLocalizedDescriptionKey: "Directions Not Available",
            NSLocalizedFailureReasonErrorKey: "Route information is not available at this moment.",
        ])
    }
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

    /// `MKLocalSearch.cancel()` does call its handler, with an error, after the wait has ended:
    /// that late answer reaches nothing.
    func testAHandlerCalledAfterCancelReachesNothing() async throws {
        final class Kept {
            var done: MapKitRequest<Int>.Done?
        }
        let kept = Kept()
        let request = MapKitRequest<Int>(begin: { kept.done = $0 }, stop: {})
        let call = Task { try await request.start() }
        try await wait { kept.done != nil }
        request.cancel()
        kept.done?(.init(nil, MKError(.unknown)))
        kept.done?(.init(.success(7)))
        try await Task.sleep(for: .milliseconds(100))
        let result = await call.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
    }

    func testAHandlersArgumentsAreItsAnswerOrItsError() {
        XCTAssertEqual(try MapKitRequest<Int>.Handed(7, nil).result.get(), 7)
        XCTAssertEqual(try MapKitRequest<Int>.Handed(7, MKError(.unknown)).result.get(), 7)
        XCTAssertThrowsError(try MapKitRequest<Int>.Handed(nil, MKError(.loadingThrottled)).result.get()) {
            XCTAssertEqual(($0 as? MKError)?.code, .loadingThrottled)
        }
        XCTAssertThrowsError(try MapKitRequest<Int>.Handed(nil, nil).result.get()) {
            XCTAssertEqual(($0 as? MKError)?.code, .unknown)
        }
    }

    // MARK: The wait

    /// Work that was not first is cancelled, at the bound and at the caller's cancellation: a fix
    /// nobody waits for any more is not left running.
    func testWorkThatWasNotFirstIsCancelled() async throws {
        final class Seen: @unchecked Sendable {
            private let lock = NSLock()
            private var _started = 0, _cancelled = 0
            var started: Int { lock.withLock { _started } }
            var cancelled: Int { lock.withLock { _cancelled } }
            func work() async throws -> Int {
                lock.withLock { _started += 1 }
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    lock.withLock { _cancelled += 1 }
                    throw error
                }
                return 1
            }
        }
        let seen = Seen()
        guard case .unanswered = await MapsWait.first(within: .milliseconds(100), { try await seen.work() }) else {
            return XCTFail("work that never answers was not left at the bound")
        }
        try await wait { seen.cancelled == 1 }
        XCTAssertEqual(seen.cancelled, 1, "work left at the bound ran on")
        let call = Task { await MapsWait.first(within: .seconds(60)) { try await seen.work() } }
        try await wait { seen.started == 2 }
        call.cancel()
        guard case .cancelled = await call.value else { return XCTFail("a cancelled wait did not end as cancelled") }
        try await wait { seen.cancelled == 2 }
        XCTAssertEqual(seen.cancelled, 2, "work left at the caller's cancellation ran on")
        // A caller already cancelled begins no work at all.
        let late = Task {
            try? await Task.sleep(for: .seconds(60))
            return await MapsWait.first(within: .seconds(60)) { try await seen.work() }
        }
        late.cancel()
        guard case .cancelled = await late.value else { return XCTFail("a cancelled caller's wait did not end as cancelled") }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(seen.started, 2)
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

    /// A result that is an address alone has the address for its name: it is said once.
    func testAnAddressThatIsTheNameIsNotSaidTwice() throws {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)))
        let title = try XCTUnwrap(item.placemark.title)
        item.name = title
        let place = try XCTUnwrap(MapKitMaps.place(item))
        XCTAssertEqual(place.name, title)
        XCTAssertNil(place.address)
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
        // And 10 km of longitude at this latitude.
        XCTAssertEqual(near.region.span.longitudeDelta, 0.1136, accuracy: 0.005)
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
            (MKError(.placemarkNotFound), .noRoute(nil)),
            (MKError(.serverFailure), .server(nil)),
            (NSError(domain: MKErrorDomain, code: Int(MKError.Code.serverFailure.rawValue),
                     userInfo: [NSLocalizedDescriptionKey: "Server Error"]), .server("Server Error")),
            (MKError(.loadingThrottled), .throttled),
            (MapsFailure.unanswered(.seconds(20)), .unanswered(.seconds(20))),
            // A directions code other than the two for no route is Apple's own words, whatever
            // the MKError code beside it: never "no route", never "the server failed".
            (FakeRequests.unavailable(.serverFailure), .other("Route information is not available at this moment.")),
            (FakeRequests.unavailable(.directionsNotFound), .other("Route information is not available at this moment.")),
            (FakeRequests.unavailable(.placemarkNotFound), .other("Route information is not available at this moment.")),
            (NSError(domain: MKErrorDomain, code: Int(MKError.Code.unknown.rawValue),
                     userInfo: [NSLocalizedFailureReasonErrorKey: "An internet connection is required."]),
             .other("An internet connection is required.")),
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

    /// A search that fails as a directions request with no route does is a failure in MapKit's
    /// words, not "nothing found" and not an empty list.
    func testASearchFailingAsNotFoundOfAnotherKindIsNotAnEmptyList() async {
        let requests = FakeRequests()
        requests.searching = .fail(MKError(.directionsNotFound))
        do {
            _ = try await MapKitMaps(runner: requests).search(query: "coffee", region: nil)
            XCTFail("a failed search answered")
        } catch {
            guard case .other? = error as? MapsFailure else { return XCTFail("\(error)") }
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

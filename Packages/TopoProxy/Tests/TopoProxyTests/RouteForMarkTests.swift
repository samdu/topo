import XCTest

@testable import TopoProxy

/// A request's path as a perf mark names it: routes, and nothing the guest could hide in one.
final class RouteForMarkTests: XCTestCase {
    func testARouteIsKept() {
        XCTAssertEqual(Forwarder.routeForMark("/v1/messages"), "/v1/messages")
        XCTAssertEqual(Forwarder.routeForMark("/api/hello"), "/api/hello")
        XCTAssertEqual(Forwarder.routeForMark("/v1/messages/count_tokens"), "/v1/messages/count_tokens")
    }

    func testASegmentThatCouldBeASecretOrAnIDIsNotWritten() {
        XCTAssertEqual(Forwarder.routeForMark("/v1/secret/sk-ant-api03-example"), "/v1/*/*")
        XCTAssertEqual(Forwarder.routeForMark("/v1/files/file_011cabc123"), "/v1/files/*")
        XCTAssertEqual(Forwarder.routeForMark("/v1/abcdefghijklmnopqrstuvwxyz"), "/v1/*")
        // A secret that reads like a word is no more a route than one that does not.
        XCTAssertEqual(Forwarder.routeForMark("/v1/files/password"), "/v1/files/*")
        XCTAssertEqual(Forwarder.routeForMark("/hunter/v1"), "/*/v1")
    }

    func testAQueryIsNotPartOfIt() {
        XCTAssertEqual(Forwarder.routeForMark("/v1/messages?beta=true&key=sk-ant"), "/v1/messages")
    }

    func testAPathThatCouldNotBeReadIsAQuestionMark() {
        XCTAssertEqual(Forwarder.routeForMark(nil), "?")
    }
}

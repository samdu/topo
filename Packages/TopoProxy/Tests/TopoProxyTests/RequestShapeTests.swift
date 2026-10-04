import XCTest

@testable import TopoProxy

/// What a timed run's marks say of a request and its answer: numbers and digests, no words.
final class RequestShapeTests: XCTestCase {
    private let body = Data("""
    {"model":"claude-haiku-4-5","system":[{"type":"text","text":"You are Topo."},
      {"type":"text","text":"SECRETSYSTEM","cache_control":{"type":"ephemeral","ttl":"1h"}}],
     "tools":[{"name":"Bash","description":"SECRETTOOL"},{"name":"Read","cache_control":{"type":"ephemeral"}}],
     "messages":[{"role":"user","content":[{"type":"text","text":"SECRETQUESTION"}]},
       {"role":"assistant","content":[{"type":"text","text":"SECRETREPLY"}]},
       {"role":"user","content":[{"type":"text","text":"again","cache_control":{"type":"ephemeral","ttl":"SECRETTTL"}}]}]}
    """.utf8)

    func testTheShapeCountsThePartsAndPlacesTheBreakpoints() throws {
        let shape = try XCTUnwrap(Forwarder.shapeForMark(body))
        let fields = Dictionary(uniqueKeysWithValues: shape.split(separator: " ").map { field -> (String, String) in
            let pair = field.split(separator: "=", maxSplits: 1)
            return (String(pair[0]), String(pair[1]))
        })
        XCTAssertEqual(fields["system"]?.split(separator: ",").count, 2)
        XCTAssertEqual(fields["tools"]?.split(separator: ":").first, "2")
        XCTAssertEqual(fields["messages"]?.split(separator: ":").first, "3")
        XCTAssertEqual(fields["marks"], "s1/1h,t1,m2")
    }

    func testTheShapeCarriesNoWordOfTheRequest() throws {
        let shape = try XCTUnwrap(Forwarder.shapeForMark(body))
        XCTAssertNil(shape.range(of: "SECRET"))
        XCTAssertNotNil(shape.wholeMatch(of: /[a-z]+=[0-9a-f:,\/smth\-]+( [a-z]+=[0-9a-f:,\/smth\-]+)*/), shape)
    }

    func testAPartThatChangedHasAnotherDigest() throws {
        let other = Data(String(decoding: body, as: UTF8.self).replacingOccurrences(of: "SECRETTOOL", with: "SECRETTOOK").utf8)
        let before = try XCTUnwrap(Forwarder.shapeForMark(body)).split(separator: " ")
        let after = try XCTUnwrap(Forwarder.shapeForMark(other)).split(separator: " ")
        XCTAssertEqual(before[0], after[0])
        XCTAssertNotEqual(before[1], after[1])
    }

    func testABodyThatIsNotAnObjectHasNoShape() {
        XCTAssertNil(Forwarder.shapeForMark(Data("[1]".utf8)))
    }

    func testTheUsageIsReadOnceItHasAllArrived() {
        let start = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":12,\"cache_creation_input_tokens\":340,"
        XCTAssertNil(Forwarder.usageForMark(Data(start.utf8)))
        let rest = "\"cache_read_input_tokens\":98765,\"output_tokens\":1}}}\n\n"
        XCTAssertEqual(Forwarder.usageForMark(Data((start + rest).utf8)), "in=12 cacheRead=98765 cacheWrite=340")
    }

    func testTheOutputCountIsTheStreamsLast() {
        let text = "{\"usage\":{\"output_tokens\":1}} … {\"type\":\"message_delta\",\"usage\":{\"output_tokens\": 412}}"
        XCTAssertEqual(Forwarder.count("output_tokens", in: text), 412)
    }
}

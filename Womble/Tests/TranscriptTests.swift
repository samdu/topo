import XCTest


/// Builds a turn the way a record would arrive, so the tests exercise the
/// same parse the app does.
private func turn(_ name: String, parents: [String] = [], role: String = "person",
                  text: String = "…", at: TimeInterval, file: StaticString = #file, line: UInt = #line) -> Turn {
    let fields: [String: Any] = [
        "device": String(name.split(separator: "/").dropLast().joined(separator: "/")),
        "sequence": NSNumber(value: Int64(name.split(separator: "/").last.flatMap { Int64($0) } ?? 0)),
        "parents": parents,
        "role": role,
        "text": text,
        "at": Date(timeIntervalSince1970: at),
    ]
    guard let turn = Turn(recordName: "turn/" + name, fields: fields) else {
        fatalError("test turn \(name) does not parse", file: file, line: line)
    }
    return turn
}

final class TranscriptTests: XCTestCase {
    func testEmpty() {
        let transcript = Transcript(turns: [])
        XCTAssertTrue(transcript.isEmpty)
        XCTAssertTrue(transcript.isComplete)
        XCTAssertFalse(transcript.isForked)
        XCTAssertEqual(transcript.heads, [])
    }

    func testOrdersParentsBeforeChildren() {
        // Given out of order, and with a child stamped *earlier* than its
        // parent — a clock that disagrees must not reorder the conversation.
        let a = turn("phone/1", at: 300)
        let b = turn("phone/2", parents: ["phone/1"], at: 100)
        let transcript = Transcript(turns: [b, a])
        XCTAssertEqual(transcript.ordered.map { $0.ref }, [a.ref, b.ref])
    }

    func testTiesBreakByTimeThenRef() {
        let hub = turn("hub/1", at: 200)
        let phone = turn("phone/1", at: 100)
        let watch = turn("watch/1", at: 100)
        let transcript = Transcript(turns: [hub, watch, phone])
        XCTAssertEqual(transcript.ordered.map { $0.ref.device.rawValue }, ["phone", "watch", "hub"])
    }

    func testAForkKeepsBothBranchesAndBothHeads() {
        let root = turn("phone/1", at: 100)
        let left = turn("phone/2", parents: ["phone/1"], at: 200)
        let right = turn("hub/1", parents: ["phone/1"], at: 150)
        let transcript = Transcript(turns: [root, left, right])
        XCTAssertTrue(transcript.isForked)
        XCTAssertEqual(transcript.heads, [TurnRef(device: DeviceID("hub"), sequence: 1),
                                          TurnRef(device: DeviceID("phone"), sequence: 2)])
        XCTAssertEqual(transcript.ordered.count, 3)
        XCTAssertEqual(transcript.ordered.first?.ref, root.ref)
    }

    func testAJoinedForkHasOneHead() {
        let root = turn("phone/1", at: 100)
        let left = turn("phone/2", parents: ["phone/1"], at: 200)
        let right = turn("hub/1", parents: ["phone/1"], at: 150)
        let join = turn("phone/3", parents: ["phone/2", "hub/1"], at: 300)
        let transcript = Transcript(turns: [root, left, right, join])
        XCTAssertFalse(transcript.isForked)
        XCTAssertEqual(transcript.heads, [join.ref])
        XCTAssertEqual(transcript.ordered.last?.ref, join.ref)
    }

    func testAGapInADeviceRunIsMissing() {
        let transcript = Transcript(turns: [turn("phone/1", at: 100), turn("phone/3", at: 300)])
        XCTAssertFalse(transcript.isComplete)
        XCTAssertEqual(transcript.missing, [TurnRef(device: DeviceID("phone"), sequence: 2)])
    }

    func testAnAbsentParentIsMissing() {
        let transcript = Transcript(turns: [turn("phone/1", parents: ["hub/7"], at: 100)])
        XCTAssertFalse(transcript.isComplete)
        XCTAssertEqual(transcript.missing, [TurnRef(device: DeviceID("hub"), sequence: 7)])
    }

    func testAnIncompleteReadStillShowsWhatItHas() {
        // The banner says turns are missing; the turns that were read are
        // still the transcript.
        let transcript = Transcript(turns: [turn("phone/2", parents: ["phone/1"], at: 200)])
        XCTAssertFalse(transcript.isComplete)
        XCTAssertEqual(transcript.ordered.count, 1)
    }

    func testUnreadableRecordsMakeItIncomplete() {
        let transcript = Transcript(turns: [turn("phone/1", at: 100)], unreadable: ["not-a-turn"])
        XCTAssertFalse(transcript.isComplete)
    }

    func testTurnsInAParentCycleAreStillShown() {
        // Nothing writes a cycle, but a corrupt record must not silently
        // drop turns off the end of the screen.
        let a = turn("phone/1", parents: ["phone/2"], at: 100)
        let b = turn("phone/2", parents: ["phone/1"], at: 200)
        let transcript = Transcript(turns: [a, b])
        XCTAssertEqual(Set(transcript.ordered.map { $0.ref }), [a.ref, b.ref])
    }
}

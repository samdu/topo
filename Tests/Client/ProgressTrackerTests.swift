import XCTest

@testable import Topo

/// Review Focus 1: the pane's tracker JSON read field by field, a bad field costing itself and
/// nothing else, and nothing reaching a view unchecked.
final class ProgressTrackerTests: XCTestCase {
    private func read(_ json: String) -> ProgressTracker.Reading {
        ProgressTracker.read(Data(json.utf8))
    }

    func testReadsTheWikiExampleWhole() throws {
        let reading = read(TrackerFixtures.wiki)
        XCTAssertEqual(reading.notes, [])
        let tracker = try XCTUnwrap(reading.tracker)
        XCTAssertEqual(tracker.id, "b36e250e")
        XCTAssertEqual(tracker.title, "macOS update on buddybox")
        XCTAssertEqual(tracker.steps.map(\.state), [.done, .running, .waiting])
        XCTAssertEqual(tracker.steps[0].note, "26.1 → 26.2 available")
        XCTAssertEqual(tracker.steps[0].at, Date(timeIntervalSince1970: 1_793_580_000))
        XCTAssertNil(tracker.steps[2].at)
        XCTAssertEqual(tracker.current, 1)
        XCTAssertEqual(tracker.state, .running)
        XCTAssertEqual(tracker.eta, Date(timeIntervalSince1970: 1_793_590_200))
        XCTAssertNil(tracker.ended)
        XCTAssertEqual(tracker.owner.session, "mac-update")
        XCTAssertEqual(tracker.fraction, 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(tracker.focus.label, "Download")
        XCTAssertTrue(tracker.isRunning)
    }

    func testRoundTripsThroughCodable() throws {
        let tracker = try XCTUnwrap(read(TrackerFixtures.wiki).tracker)
        let data = try ProgressTracker.encoder.encode(tracker)
        XCTAssertEqual(try ProgressTracker.decoder.decode(ProgressTracker.self, from: data), tracker)
        // The encoded form reads back through the judge too, with nothing to note.
        XCTAssertEqual(ProgressTracker.read(data).notes, [])
    }

    func testNoStepsIsUnreadable() {
        for json in [#"{"title": "x"}"#, #"{"title": "x", "steps": []}"#, #"{"title": "x", "steps": "no"}"#, "[]", "nope"] {
            let reading = read(json)
            XCTAssertNil(reading.tracker, json)
            XCTAssertFalse(reading.notes.isEmpty, json)
        }
        XCTAssertNil(read(#"{"kind": "decision", "steps": ["a"]}"#).tracker)
    }

    func testEachBadFieldCostsItself() throws {
        let json = """
        {"id": 7, "title": "\(String(repeating: "t", count: 80))\\nsecond line",
         "steps": ["Plain string", {"label": "\(String(repeating: "L", count: 50))", "state": "exploded", "note": "\(String(repeating: "n", count: 90))", "at": "yesterday"},
                   {"state": "done"}, 5, {"label": "Last", "state": "waiting", "note": "one\\ntwo"}],
         "current": 99, "state": "paused", "eta": true, "started": 1e30, "updated": null, "owner": "me"}
        """
        let reading = read(json)
        let tracker = try XCTUnwrap(reading.tracker, reading.notes.joined(separator: "; "))
        XCTAssertEqual(tracker.id, "")
        XCTAssertEqual(tracker.title.count, 70)
        XCTAssertEqual(tracker.steps.count, 3, "the step with no label and the number were dropped, the rest kept")
        XCTAssertEqual(tracker.steps[0].label, "Plain string")
        XCTAssertEqual(tracker.steps[1].label.count, 40)
        XCTAssertEqual(tracker.steps[1].state, .waiting)
        XCTAssertEqual(tracker.steps[1].note.count, 80)
        XCTAssertNil(tracker.steps[1].at)
        XCTAssertEqual(tracker.steps[2].note, "one")
        XCTAssertEqual(tracker.state, .running, "derived from the steps")
        XCTAssertEqual(tracker.current, 0, "derived: the first waiting step")
        XCTAssertNil(tracker.eta)
        XCTAssertEqual(tracker.owner, ProgressTracker.Owner())
        for field in ["id", "title", "steps[1].label", "steps[1].state", "steps[1].note", "steps[1].at", "steps[2].label", "steps[3]",
                      "steps[4].note", "current", "state", "eta", "started", "owner"] {
            XCTAssertTrue(reading.notes.contains { $0.hasPrefix("tracker.\(field) ") }, "no note for \(field): \(reading.notes)")
        }
    }

    func testCurrentOutsideStepsIsDerived() throws {
        let failed = try XCTUnwrap(read(TrackerFixtures.tracker(steps: [("a", "done"), ("b", "failed"), ("c", "waiting")], current: 7)).tracker)
        XCTAssertEqual(failed.current, 1, "the last running or failed step")
        XCTAssertEqual(failed.state, .running, "as given; the pane derives it")
        let allDone = try XCTUnwrap(read(TrackerFixtures.tracker(steps: [("a", "done"), ("b", "skipped")], current: -1, state: "done")).tracker)
        XCTAssertEqual(allDone.current, 1, "the last step when none runs or waits")
        XCTAssertEqual(allDone.fraction, 1)
        let missing = try XCTUnwrap(read(#"{"steps": [{"label": "a", "state": "done"}, {"label": "b"}]}"#).tracker)
        XCTAssertEqual(missing.current, 1)
        XCTAssertEqual(missing.state, .running)
        XCTAssertEqual(missing.title, "")
    }

    func testStateDerivedWhenMissing() throws {
        XCTAssertEqual(try XCTUnwrap(read(#"{"steps": [{"label": "a", "state": "failed"}]}"#).tracker).state, .failed)
        XCTAssertEqual(try XCTUnwrap(read(#"{"steps": [{"label": "a", "state": "done"}, {"label": "b", "state": "skipped"}]}"#).tracker).state, .done)
        XCTAssertEqual(try XCTUnwrap(read(#"{"steps": [{"label": "a", "state": "done"}, {"label": "b"}]}"#).tracker).state, .running)
    }

    func testTwentyOneStepsKeepsTwenty() throws {
        let steps = (1...21).map { ("step \($0)", "waiting") }
        let reading = read(TrackerFixtures.tracker(steps: steps))
        XCTAssertEqual(try XCTUnwrap(reading.tracker).steps.count, 20)
        XCTAssertTrue(reading.notes.contains { $0.hasPrefix("tracker.steps[20] ") })
    }

    func testTimesOutsideTheEpochRangeAreRefused() throws {
        let reading = read(#"{"steps": [{"label": "a", "at": 1793580000000}], "eta": -5, "started": 1793580000, "updated": 1793580001}"#)
        let tracker = try XCTUnwrap(reading.tracker)
        XCTAssertNil(tracker.steps[0].at, "milliseconds are not a time")
        XCTAssertNil(tracker.eta)
        XCTAssertEqual(tracker.updated, Date(timeIntervalSince1970: 1_793_580_001))
    }
}

import SwiftUI
import XCTest

@testable import Topo

/// Review Focus 2, 7 and 9: the activity's document read field by field, the payload budget judged
/// over the attributes and the state together, and no control or image in a region.
final class ActivityDocumentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_580_000)
    private var attributes: TopoActivityAttributes { TopoActivityAttributes(slot: "job", poll: nil, started: now) }

    private func read(_ json: String, update: Bool = false) -> ActivityDocument.Reading {
        ActivityDocument.read(json, now: now, update: update)
    }

    func testReadsATrackerDocumentWhole() throws {
        let reading = read(#"{"version": 1, "tracker": \#(TrackerFixtures.wiki), "tint": "primary", "until": "2026-11-02T06:00:00Z", "relevance": 50}"#)
        XCTAssertEqual(reading.notes, [])
        XCTAssertTrue(reading.readable)
        XCTAssertEqual(reading.document.tracker?.title, "macOS update on buddybox")
        XCTAssertEqual(reading.document.tint, .token(.primary))
        XCTAssertEqual(reading.document.until, Date(timeIntervalSince1970: 1_793_599_200))
        XCTAssertEqual(reading.document.relevance, 50)
    }

    func testReadsRegionsWithTheLockScreenBudget() throws {
        let long = String(repeating: "w", count: 70)
        let reading = read(#"{"families": {"lockScreen": {"kind": "text", "text": "\#(long)"}, "islandMinimal": {"kind": "glyph", "symbol": "cup.and.saucer.fill"}, "systemSmall": {"kind": "text", "text": "x"}}}"#)
        XCTAssertTrue(reading.readable)
        guard case .text(let text)? = reading.document.regions[.lockScreen] else { return XCTFail("no lock screen tree") }
        XCTAssertEqual(text.text.count, WidgetDocument.accessoryTextLimit)
        XCTAssertNotNil(reading.document.regions[.islandMinimal])
        XCTAssertTrue(reading.notes.contains { $0.hasPrefix("families.lockScreen.text ") && $0.contains("lock-screen") })
        XCTAssertTrue(reading.notes.contains { $0.hasPrefix("families.systemSmall ") && $0.contains("not a region") })
    }

    func testControlsAndImagesRefused() throws {
        let reading = read("""
        {"families": {"lockScreen": {"kind": "vstack", "children": [
            {"kind": "text", "text": "kept"},
            {"kind": "button", "id": "go", "label": "Go", "action": {"kind": "open"}},
            {"kind": "toggle", "id": "t", "label": "T", "on": true},
            {"kind": "link", "id": "l", "label": "L"},
            {"kind": "image", "name": "pic"}]}}}
        """)
        XCTAssertTrue(reading.readable)
        guard case .stack(let stack)? = reading.document.regions[.lockScreen] else { return XCTFail("no lock screen tree") }
        XCTAssertEqual(stack.children.count, 1, "the text alone is kept")
        XCTAssertEqual(reading.notes.filter { $0.contains("draws no control") }.count, 3)
        XCTAssertEqual(reading.notes.filter { $0.contains("has no images") }.count, 1)
        // Nothing of a refused control is noted twice as an unknown field.
        XCTAssertFalse(reading.notes.contains { $0.contains("is not a field of this node") }, "\(reading.notes)")
    }

    func testEachBadTopLevelFieldCostsItself() throws {
        let reading = read(#"{"tracker": \#(TrackerFixtures.wiki), "poll": "ftp://x/y", "tint": "mauve", "until": "2026-10-31T00:00:00Z", "relevance": 101, "extra": 1}"#)
        XCTAssertTrue(reading.readable)
        XCTAssertNil(reading.document.poll)
        XCTAssertNil(reading.document.tint)
        XCTAssertNil(reading.document.until)
        XCTAssertNil(reading.document.relevance)
        for field in ["poll", "tint", "until", "relevance", "extra"] {
            XCTAssertTrue(reading.notes.contains { $0.hasPrefix("\(field) ") }, "no note for \(field): \(reading.notes)")
        }
        XCTAssertTrue(reading.notes.contains { $0.hasPrefix("until ") && $0.contains("passed") })
        XCTAssertTrue(read(#"{"tracker": \#(TrackerFixtures.wiki), "until": "2026-11-02T13:00:00Z"}"#).notes.contains { $0.contains("12 hours") })
    }

    func testPollTakesHttpAndHttpsWithAHost() {
        XCTAssertEqual(read(#"{"poll": "https://pane.example.ts.net/decisions/progress/b36e250e"}"#).document.poll?.host, "pane.example.ts.net")
        XCTAssertEqual(read(#"{"poll": "http://10.0.0.5:8833/progress/x"}"#).document.poll?.port, 8833)
        XCTAssertNil(read(#"{"poll": "https:///progress/x", "tracker": \#(TrackerFixtures.wiki)}"#).document.poll)
        XCTAssertNil(read(#"{"poll": "https://h/\#(String(repeating: "p", count: 520))", "tracker": \#(TrackerFixtures.wiki)}"#).document.poll)
        XCTAssertNil(read(#"{"poll": "file:///etc/hosts", "tracker": \#(TrackerFixtures.wiki)}"#).document.poll)
    }

    func testNothingForTheLockScreenIsUnreadable() {
        for json in [#"{"version": 1}"#, #"{"families": {"islandMinimal": {"kind": "divider"}}}"#, #"{"tint": "primary"}"#] {
            let reading = read(json)
            XCTAssertFalse(reading.readable, json)
            if case .unreadable(let why) = reading.state { XCTAssertTrue(why.contains("lock screen"), why) }
        }
        XCTAssertTrue(read(#"{"families": {"islandMinimal": {"kind": "divider"}}}"#, update: true).readable, "an update stands over a state that draws")
        XCTAssertFalse(read("[]").readable)
        XCTAssertFalse(read(#"{"version": 2, "tracker": \#(TrackerFixtures.wiki)}"#).readable)
    }

    func testTheLayoutRoundTripsThroughTheState() throws {
        let reading = read(##"{"families": {"lockScreen": {"kind": "text", "text": "Tea", "style": "headline"}, "islandCompactTrailing": {"kind": "text", "date": "2026-11-01T06:00:00Z", "dateStyle": "timer"}}, "tint": ["#112233", "#445566"]}"##)
        let state = ActivityState(reading.document, tracker: nil)
        let back = ActivityLayout.read(try XCTUnwrap(state.layout))
        XCTAssertEqual(back, reading.document.layout)
        XCTAssertNil(state.card)
    }

    /// The island's small regions take no more than Apple's sizes whatever width they are offered:
    /// a timer's text, which takes all the width it is offered, laid out in a region offered the
    /// screen's whole width stays inside the compact region's 52.33 by 36.67 and the minimal's 45
    /// by 36.67, as does the tracker's ring; the lock screen keeps the width it is given.
    @MainActor
    func testTheIslandsSmallRegionsKeepToApplesSizes() throws {
        let timer = #"{"kind": "text", "text": "Tea", "date": "2026-11-02T06:00:00Z", "dateStyle": "timer"}"#
        let reading = read(#"{"families": {"lockScreen": \#(timer), "islandCompactLeading": \#(timer), "islandCompactTrailing": \#(timer), "islandMinimal": \#(timer)}}"#)
        let trees = ActivityState(reading.document, tracker: nil)
        let tracker = ActivityState(read(#"{"tracker": \#(TrackerFixtures.wiki)}"#).document,
                                    tracker: read(#"{"tracker": \#(TrackerFixtures.wiki)}"#).document.tracker)
        let offered = ProposedViewSize(width: 430, height: 200)
        for state in [trees, tracker] {
            for region in [ActivityRegion.islandCompactLeading, .islandCompactTrailing, .islandMinimal] {
                let bound = try XCTUnwrap(ActivityRegionView.bound(region))
                let renderer = ImageRenderer(content: ActivityRegionView(region: region, slot: "s", state: state))
                renderer.proposedSize = offered
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.cgImage, "\(region) drew nothing")
                let size = CGSize(width: image.width, height: image.height)
                XCTAssertLessThanOrEqual(size.width, bound.width.rounded(.up), "\(region) took \(size.width) points across")
                XCTAssertLessThanOrEqual(size.height, bound.height.rounded(.up), "\(region) took \(size.height) points down")
            }
        }
        XCTAssertNil(ActivityRegionView.bound(.lockScreen))
        XCTAssertNil(ActivityRegionView.bound(.islandExpanded))
    }

    func testAnUpdateStandsOverWhatItDoesNotCarry() throws {
        let first = ActivityState(read(#"{"tracker": \#(TrackerFixtures.wiki), "tint": "primary", "until": "2026-11-02T06:00:00Z", "relevance": 10}"#).document,
                                  tracker: read(#"{"tracker": \#(TrackerFixtures.wiki)}"#).document.tracker)
        let second = read(#"{"families": {"islandMinimal": {"kind": "divider"}}}"#, update: true).document
        let merged = ActivityState(second, tracker: second.tracker, over: first)
        XCTAssertEqual(merged.card, first.card)
        XCTAssertEqual(merged.until, first.until)
        XCTAssertEqual(merged.relevance, 10)
        XCTAssertNotEqual(merged.layout, first.layout, "the regions were replaced")
        XCTAssertEqual(ActivityLayout.read(try XCTUnwrap(merged.layout)).tint, .token(.primary), "and the tint stands")
        // A tint alone leaves the regions.
        let third = read(#"{"tint": "secondary"}"#, update: true).document
        let tinted = ActivityState(third, tracker: nil, over: merged)
        let layout = ActivityLayout.read(try XCTUnwrap(tinted.layout))
        XCTAssertEqual(layout.regions.keys.sorted { $0.rawValue < $1.rawValue }, [.islandMinimal])
        XCTAssertEqual(layout.tint, .token(.secondary))
    }

    // MARK: Review Focus 2 and 9

    func testBudgetCountsAttributesToo() throws {
        let tracker = try XCTUnwrap(read(#"{"tracker": \#(TrackerFixtures.wiki)}"#).document.tracker)
        let state = ActivityState(card: TrackerCard(tracker))
        let small = ActivityPayload.bytes(attributes, state)
        let long = TopoActivityAttributes(slot: "job", poll: URL(string: "https://h/" + String(repeating: "p", count: 500)), started: now)
        XCTAssertGreaterThan(ActivityPayload.bytes(long, state), small + 500)
        // A layout that fits beside short attributes and not beside long ones.
        var padded = state
        padded.layout = String(repeating: "x", count: ActivityDocument.payloadLimit - small - 300)
        XCTAssertNotNil(ActivityPayload.fit(padded, with: attributes).state)
        XCTAssertNil(ActivityPayload.fit(padded, with: long).state)
        XCTAssertTrue(ActivityPayload.fit(padded, with: long).note?.contains("attributes") == true)
    }

    func testEveryContractTrackerStarts() throws {
        // The contract's worst case: twenty steps, each label 40 and each note 80 three-byte characters, a 70-character title.
        let steps = (1...20).map { _ in #"{"label": "\#(String(repeating: "語", count: 40))", "state": "running", "note": "\#(String(repeating: "語", count: 80))", "at": 1793580000}"# }
        let json = #"{"id": "\#(String(repeating: "f", count: 64))", "title": "\#(String(repeating: "語", count: 70))", "steps": [\#(steps.joined(separator: ","))], "current": 19, "state": "running", "eta": 1793590200, "started": 1793580000, "updated": 1793580100, "ended": null, "owner": {"session": "\#(String(repeating: "s", count: 60))", "address": "a", "link": "https://claude.ai/code/session_0123456789abcdef0123456789"}}"#
        let tracker = try XCTUnwrap(ProgressTracker.read(Data(json.utf8)).tracker)
        let long = TopoActivityAttributes(slot: String(repeating: "s", count: 32), poll: URL(string: "https://h/" + String(repeating: "p", count: 500)), started: now)
        let asked = ActivityState(card: TrackerCard(tracker), until: now, relevance: 100)
        XCTAssertGreaterThan(ActivityPayload.bytes(long, asked), ActivityDocument.payloadLimit, "the worst case is over the budget with its labels")
        let fitted = ActivityPayload.fit(asked, with: long)
        let state = try XCTUnwrap(fitted.state, "the worst case does not start")
        XCTAssertLessThanOrEqual(ActivityPayload.bytes(long, state), ActivityDocument.payloadLimit)
        XCTAssertEqual(state.card?.steps.map(\.label), Array(repeating: "", count: 20), "the labels went, the states stayed")
        XCTAssertEqual(state.card?.steps.map(\.state), Array(repeating: .running, count: 20))
        XCTAssertEqual(state.card?.note.count, 80, "the focused note stays")
        XCTAssertTrue(fitted.note?.contains("labels") == true)
        // A typical tracker keeps its labels.
        let wiki = try XCTUnwrap(read(#"{"tracker": \#(TrackerFixtures.wiki)}"#).document.tracker)
        XCTAssertNil(ActivityPayload.fit(ActivityState(card: TrackerCard(wiki)), with: long).note)
    }

    func testCardProjectsTheTracker() throws {
        let tracker = try XCTUnwrap(ProgressTracker.read(Data(TrackerFixtures.wiki.utf8)).tracker)
        let card = TrackerCard(tracker)
        XCTAssertEqual(card.title, tracker.title)
        XCTAssertEqual(card.steps.map(\.label), ["Check for update", "Download", "Install and restart"])
        XCTAssertEqual(card.current, 1)
        XCTAssertEqual(card.note, "", "the focused step's note")
        XCTAssertEqual(card.past, 1)
        XCTAssertEqual(card.focus?.label, "Download")
        XCTAssertEqual(card.session, "mac-update")
    }
}

import CoreGraphics
import XCTest

@testable import Topo

/// A person's turn scrolling through Topo, replayed from the geometry the simulator recorded
/// (`TOPO_DEBUG_MASCOT_TRACE`, over the `full` fixture with the person's inset at 0, so a
/// person's turn spans the column and there is no room beside it, and the transcript dragged
/// slowly, in `Traces/`) and scripted: he is displaced once per crossing and never caught by the turn — one
/// glide, through it to its far side from where it is going, and no frame of him over it after
/// that glide; and a turn that lands on him still, with room above and below it, sends him below.
final class MascotCrossingTests: XCTestCase {
    /// The default look's roam: a scale of 1, a clearance of 8, 40 points a second and ten times
    /// that in a hurry, a settle of 0.6 s, a thirtieth of a second a frame.
    static let settings = MascotRoam.Settings(Look.Mascot(), reduceMotion: false)

    struct Trace: Decodable {
        /// His picture's origin as the recording's window opens.
        var standing: CGPoint
        var events: [Event]

        /// A geometry handed to the roam, or with none, a tick of its clock.
        struct Event: Decodable {
            var t: Double
            var field: MascotField?
        }
    }

    private func trace(_ name: String) throws -> Trace {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"), name)
        return try JSONDecoder().decode(Trace.self, from: Data(contentsOf: url))
    }

    /// In `full` the person's turns are the bubbles across the column, 167 points tall; of them,
    /// the one nearest `picture` up or down, as far as it can be seen.
    private static func bubbles(in field: MascotField) -> [CGRect] {
        field.obstacles.filter { $0.width > 300 && abs($0.height - 167) < 2 }
            .map { $0.intersection(field.seen) }.filter { !$0.isNull && $0.height > 0 }
    }

    /// Replays a recorded crossing and holds it to the rule: `glides` glides and no more, one a
    /// crossing; he stands under text for no more than the one frame before each decision; and
    /// no frame of him overlaps a person's turn once a glide is done, to the end of the recording.
    private func assertCrossings(_ name: String, until end: Double = .infinity, glides: Int,
                                 file: StaticString = #filePath, line: UInt = #line) throws -> (MascotRoam, MascotField) {
        let trace = try trace(name)
        var roam = MascotRoam(Self.settings, frame: 1.0 / 30, standing: trace.standing)
        var field: MascotField?
        var standingCovered = 0
        var gliding = false
        for event in trace.events where event.t <= end {
            if let next = event.field {
                roam.observe(next, at: event.t)
                field = next
                continue
            }
            roam.advance(to: event.t)
            guard field != nil else { continue }
            // He stood somewhere when the recording opened, and a crossing is never a reason to
            // stand nowhere.
            let picture = try XCTUnwrap(roam.picture, "t \(event.t): he stands nowhere", file: file, line: line)
            standingCovered = roam.covered && !roam.walking ? standingCovered + 1 : 0
            XCTAssertLessThanOrEqual(standingCovered, 1, "t \(event.t): caught under text at \(picture)", file: file, line: line)
            if gliding, !roam.walking {
                XCTAssertFalse(roam.covered, "t \(event.t): a glide ended under text at \(picture)", file: file, line: line)
            }
            gliding = roam.walking
        }
        XCTAssertEqual(roam.moves, glides, "\(name): one glide a crossing", file: file, line: line)
        XCTAssertFalse(roam.covered, "\(name): he ended under text", file: file, line: line)
        XCTAssertFalse(roam.walking, "\(name): he never arrived", file: file, line: line)
        return (roam, try XCTUnwrap(field, file: file, line: line))
    }

    /// The transcript dragged slowly up, a person's bubble rising into him from below with the
    /// glass over its foot, so there is no room under it: one glide, above it, riding the words
    /// up until the drag stops, and never caught (the crossing that, recorded before the fix,
    /// carried him up the screen in hops a few points long, forty glides in a second and a half).
    func testARisingPersonsTurnWithNoRoomUnderItIsOneGlideAboveIt() throws {
        let (roam, field) = try assertCrossings("crossing-up", until: 35, glides: 1)
        let picture = try XCTUnwrap(roam.picture)
        let below = try XCTUnwrap(Self.bubbles(in: field).filter { $0.minY >= picture.maxY }.min { $0.minY < $1.minY },
                                  "no person's turn below him")
        XCTAssertLessThanOrEqual(picture.maxY + Self.settings.clearance, below.minY + MascotRoost.epsilon)
    }

    /// The same turn dragged on up: he rides it to the top of where he may stand, and from there
    /// goes under it, once, and ends clear below it.
    func testDraggedOnUpHeGoesUnderItOnceAtTheTop() throws {
        let (roam, field) = try assertCrossings("crossing-up", glides: 3)
        let picture = try XCTUnwrap(roam.picture)
        let above = try XCTUnwrap(Self.bubbles(in: field).filter { $0.maxY <= picture.minY }.max { $0.maxY < $1.maxY },
                                  "no person's turn above him")
        XCTAssertGreaterThanOrEqual(picture.minY, above.maxY + Self.settings.clearance - MascotRoost.epsilon)
    }

    /// The transcript dragged down, a person's bubble descending onto him from above, and let go,
    /// so it springs back up past him: each way is one glide through the bubble to the side it
    /// came from — over it on the way down, under it on the way back — and never caught.
    func testADescendingPersonsTurnAndItsSpringBackAreAHopEach() throws {
        let (roam, field) = try assertCrossings("crossing-down", glides: 2)
        // The spring-back rose past him last, so he ends under it.
        let picture = try XCTUnwrap(roam.picture)
        let above = try XCTUnwrap(Self.bubbles(in: field).filter { $0.maxY <= picture.minY }.max { $0.maxY < $1.maxY },
                                  "no person's turn above him")
        XCTAssertGreaterThanOrEqual(picture.minY, above.maxY + Self.settings.clearance - MascotRoost.epsilon)
        XCTAssertFalse(Self.bubbles(in: field).contains { $0.intersects(picture) }, "he ended over a person's turn")
    }

    /// Holds a run to his room: at every tick his box is inside the room his reach leaves him
    /// (`MascotField.room`), and a tick he is not gliding on moves him no further than the words
    /// moved since the tick before — riding them, never placed somewhere with no glide.
    private func assertRoomAndNoSnap(_ roam: inout MascotRoam, events: [Trace.Event],
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        var field: MascotField?
        var scrolled: CGFloat = 0
        var last: (picture: CGRect, walking: Bool)?
        for event in events {
            if let next = event.field {
                if let field { scrolled += next.drift(since: field) }
                roam.observe(next, at: event.t)
                field = next
                continue
            }
            roam.advance(to: event.t)
            guard let field else { continue }
            let picture = try XCTUnwrap(roam.picture, "t \(event.t): he stands nowhere", file: file, line: line)
            let room = field.room(Self.settings.reach).insetBy(dx: -MascotRoost.epsilon, dy: -MascotRoost.epsilon)
            XCTAssertTrue(room.contains(picture), "t \(event.t): \(picture) left his room \(room)", file: file, line: line)
            if let last, !last.walking, !roam.walking {
                XCTAssertLessThanOrEqual(abs(picture.minY - last.picture.minY), abs(scrolled) + MascotRoost.epsilon,
                                         "t \(event.t): placed from \(last.picture.minY) to \(picture.minY) with no glide",
                                         file: file, line: line)
            }
            last = (picture, roam.walking)
            scrolled = 0
        }
    }

    /// Flung up and down the `full` fixture, 24 swipes at 1,200 to 5,000 points a second: he
    /// rides the words to the edge of his room and no further, and glides from there; never
    /// drawn out of his room, never placed with no glide.
    func testAFlingKeepsHimInHisRoomAndNeverSnaps() throws {
        let trace = try trace("fling")
        var roam = MascotRoam(Self.settings, frame: 1.0 / 30, standing: trace.standing)
        try assertRoomAndNoSnap(&roam, events: trace.events)
        XCTAssertGreaterThan(roam.moves, 10, "the fling moved him too little to hold anything")
    }

    /// A turn rising out of the glass at reading speed, a quarter of a point a geometry, until it
    /// has carried him to the top of his room: he rides it there, stops at the edge, and glides
    /// on from inside it.
    func testARideAtReadingSpeedStopsAtTheEdgeOfHisRoom() throws {
        var roam = MascotRoam(Self.settings, frame: 1.0 / 30, standing: CGPoint(x: 280, y: 440))
        var events: [Trace.Event] = []
        var time = 0.0
        for y in stride(from: 560.0, through: -200.0, by: -0.25) {
            events.append(Trace.Event(t: time, field: Self.page(CGFloat(y))))
            time += 1.0 / 30
            events.append(Trace.Event(t: time, field: nil))
        }
        for _ in 0..<120 { time += 1.0 / 30; events.append(Trace.Event(t: time, field: nil)) }
        try assertRoomAndNoSnap(&roam, events: events)
        XCTAssertFalse(roam.riding, "still riding once the words stopped")
    }

    // MARK: Scripted

    static let visible = CGRect(x: 0, y: 0, width: 402, height: 628)

    static func field(_ obstacles: [CGRect]) -> MascotField {
        MascotField(visible: visible, obstacles: obstacles, pane: CGRect(x: 41, y: 540, width: 320, height: 80),
                    well: CGRect(x: 165, y: 544, width: 72, height: 72))
    }

    /// A person's bubble across the column at `y`, 120 points tall, and a reply's lines on the
    /// left above and below it, all scrolled together.
    static func page(_ y: CGFloat) -> MascotField {
        var obstacles = [CGRect(x: 19, y: y, width: 367, height: 120)]
        for index in 0..<6 {
            let step = CGFloat(index) * 22
            obstacles.append(CGRect(x: 16, y: y - 400 + step, width: 250, height: 20))
            obstacles.append(CGRect(x: 16, y: y + 140 + step, width: 250, height: 20))
        }
        return field(obstacles)
    }

    /// Drives the roam as the canvas does: each geometry handed over at the clock of the tick
    /// before it arrived, then the tick. Returns the glides begun, and fails on a tick standing
    /// under text past the one before a decision, or a glide that ends under text.
    private func scroll(_ roam: inout MascotRoam, from start: Double, through pages: [MascotField],
                        file: StaticString = #filePath, line: UInt = #line) -> Double {
        let frame = 1.0 / 30
        var time = start
        var standingCovered = 0
        var gliding = false
        var index = 0
        while index < pages.count || roam.needsTime, time < start + 30 {
            if index < pages.count { roam.observe(pages[index], at: time) }
            index += 1
            time += frame
            roam.advance(to: time)
            standingCovered = roam.covered && !roam.walking ? standingCovered + 1 : 0
            XCTAssertLessThanOrEqual(standingCovered, 1, "t \(time): caught under text at \(roam.picture ?? .null)",
                                     file: file, line: line)
            if gliding, !roam.walking {
                XCTAssertFalse(roam.covered, "t \(time): a glide ended under text", file: file, line: line)
            }
            gliding = roam.walking
        }
        return time
    }

    /// A turn landing on him where it stands still, with room above it and below it: below wins,
    /// though above is the shorter way.
    func testATurnLandingOnHimWithRoomEitherSideSendsHimBelowIt() throws {
        var roam = MascotRoam(Self.settings, frame: 1.0 / 30, standing: CGPoint(x: 280, y: 250))
        let bubble = CGRect(x: 19, y: 300, width: 367, height: 60)
        _ = scroll(&roam, from: 0, through: [Self.field([bubble])])
        let picture = try XCTUnwrap(roam.picture)
        XCTAssertEqual(roam.moves, 1)
        XCTAssertGreaterThanOrEqual(picture.minY, bubble.maxY + Self.settings.clearance - MascotRoost.epsilon,
                                    "he did not go below the turn")
    }

    /// A person's bubble rising into him out of the glass, with no room below it until it is
    /// through: he goes above it, once, and rides the words up until they stop rather than being
    /// caught again every frame.
    func testATurnRisingOutOfTheGlassIsOneGlideAboveItRidingTheWords() throws {
        var roam = MascotRoam(Self.settings, frame: 1.0 / 30, standing: CGPoint(x: 280, y: 440))
        let pages = stride(from: 560.0, through: 300.0, by: -4.0).map { Self.page(CGFloat($0)) }
        _ = scroll(&roam, from: 0, through: pages)
        let picture = try XCTUnwrap(roam.picture)
        XCTAssertEqual(roam.moves, 1, "one glide for the crossing")
        XCTAssertLessThanOrEqual(picture.maxY + Self.settings.clearance, 300 + MascotRoost.epsilon, "he is not above the turn")
        XCTAssertFalse(roam.riding, "still riding once the words stopped")
    }

    /// A person's bubble descending onto him: one glide, over it, the side it came from, since
    /// below it is where it is going.
    func testADescendingTurnIsOneGlideOverIt() throws {
        var roam = MascotRoam(Self.settings, frame: 1.0 / 30, standing: CGPoint(x: 280, y: 250))
        let pages = stride(from: 60.0, through: 380.0, by: 4.0).map { Self.page(CGFloat($0)) }
        _ = scroll(&roam, from: 0, through: pages)
        let picture = try XCTUnwrap(roam.picture)
        XCTAssertEqual(roam.moves, 1, "one glide for the crossing")
        XCTAssertLessThanOrEqual(picture.maxY + Self.settings.clearance, 380 + MascotRoost.epsilon, "he is not above the turn")
    }

    /// A person's bubble rising past him with room below it: one glide, under it.
    func testARisingTurnWithRoomBelowIsOneGlideUnderIt() throws {
        var roam = MascotRoam(Self.settings, frame: 1.0 / 30, standing: CGPoint(x: 280, y: 150))
        let pages = stride(from: 300.0, through: 0.0, by: -4.0).map { Self.page(CGFloat($0)) }
        _ = scroll(&roam, from: 0, through: pages)
        let picture = try XCTUnwrap(roam.picture)
        XCTAssertEqual(roam.moves, 1, "one glide for the crossing")
        XCTAssertGreaterThanOrEqual(picture.minY, 120 + Self.settings.clearance - MascotRoost.epsilon, "he is not below the turn")
    }

    /// Reply lines on the left, six of them a line apart from `y`, clear of where he stands.
    static func lines(_ y: CGFloat) -> [CGRect] {
        (0..<6).map { CGRect(x: 16, y: y + CGFloat($0) * 22, width: 250, height: 20) }
    }

    /// The transcript scrolled down and stopped, and a turn landing on him before the scroll has
    /// settled: a still turn, which is under wins, whatever the scroll before it did.
    func testATurnLandingJustAfterADownwardScrollSendsHimBelowIt() throws {
        var roam = MascotRoam(Self.settings, frame: 1.0 / 30, standing: CGPoint(x: 280, y: 250))
        var pages = stride(from: 0.0, through: 40.0, by: 4.0).map { Self.field(Self.lines(CGFloat($0))) }
        let bubble = CGRect(x: 19, y: 230, width: 367, height: 60)
        pages.append(Self.field(Self.lines(40) + [bubble]))
        let end = scroll(&roam, from: 0, through: pages)
        XCTAssertLessThan(end, Double(pages.count) / 30 + Self.settings.settle + 2)
        let picture = try XCTUnwrap(roam.picture)
        XCTAssertEqual(roam.moves, 1)
        XCTAssertGreaterThanOrEqual(picture.minY, bubble.maxY + Self.settings.clearance - MascotRoost.epsilon,
                                    "the scroll before the turn landed sent him over it")
    }

    /// A glide under a bubble that lands on him, then the bubble scrolling a point at a time past
    /// a still obstacle of its own size: the still one has no say, and where he is going moves
    /// with the bubble.
    func testAStillTwinDoesNotHoldTheDestinationBack() throws {
        let twin = CGRect(x: 19, y: 20, width: 367, height: 60)
        var roam = MascotRoam(Self.settings, frame: 1.0 / 30, standing: CGPoint(x: 280, y: 250))
        roam.observe(Self.field([twin, CGRect(x: 19, y: 300, width: 367, height: 60)]), at: 0)
        roam.advance(to: 1.0 / 30)
        let glide = try XCTUnwrap(roam.move, "the landing turn started no glide")
        for step in 1...5 {
            let bubble = CGRect(x: 19, y: 300 + CGFloat(step), width: 367, height: 60)
            roam.observe(Self.field([twin, bubble]), at: 1.0 / 30)
            XCTAssertEqual(try XCTUnwrap(roam.move).to.y, glide.to.y + CGFloat(step), accuracy: 0.001,
                           "step \(step): the destination did not move with the bubble")
        }
        XCTAssertEqual(roam.moves, 1, "the glide was restarted")
    }

    /// A drag a tenth of a point a geometry, for a hundred geometries: where he is going moves
    /// the ten points the words did, rather than nothing a frame.
    func testATenthOfAPointAGeometryAddsUp() throws {
        var roam = MascotRoam(Self.settings, frame: 1.0 / 30, standing: CGPoint(x: 280, y: 250))
        roam.observe(Self.field(Self.lines(0) + [CGRect(x: 19, y: 300, width: 367, height: 60)]), at: 0)
        roam.advance(to: 1.0 / 30)
        let glide = try XCTUnwrap(roam.move, "the landing turn started no glide")
        for step in 1...100 {
            let d = CGFloat(step) / 10
            roam.observe(Self.field(Self.lines(d) + [CGRect(x: 19, y: 300 + d, width: 367, height: 60)]), at: 1.0 / 30)
        }
        XCTAssertEqual(try XCTUnwrap(roam.move).to.y, glide.to.y + 10, accuracy: 0.01)
        XCTAssertEqual(roam.moves, 1, "the glide was restarted")
    }

    /// A still page with a line added to a reply, the same size as its other lines, is no move.
    func testALineAddedToAStillPageIsNoMove() {
        let a = Self.field(Self.lines(100))
        let b = Self.field(Self.lines(100) + [CGRect(x: 16, y: 100 + 6 * 22, width: 250, height: 20)])
        XCTAssertEqual(b.drift(since: a), 0)
    }

    /// The words' move between two geometries is what their obstacles moved, and a line that
    /// does not scroll is outvoted.
    func testTheDriftIsTheWordsMove() {
        let still = CGRect(x: 60, y: 604, width: 281, height: 16)
        let a = Self.field(Self.page(300).obstacles + [still])
        let b = Self.field(Self.page(288).obstacles + [still])
        XCTAssertEqual(b.drift(since: a), -12)
        XCTAssertEqual(a.drift(since: a), 0)
        XCTAssertEqual(Self.field([]).drift(since: a), 0)
        // One bubble scrolling past a still obstacle of its size is its scroll, not a tie.
        let twin = CGRect(x: 19, y: 20, width: 367, height: 120)
        XCTAssertEqual(Self.field([twin, CGRect(x: 19, y: 300, width: 367, height: 120)])
            .drift(since: Self.field([twin, CGRect(x: 19, y: 298, width: 367, height: 120)])), 2)
        XCTAssertEqual(Self.field(Self.lines(0.1)).drift(since: Self.field(Self.lines(0))), 0.1, accuracy: 0.0001)
    }
}

import CoreGraphics
import XCTest

@testable import Topo

/// A person's turn scrolling through Topo, replayed from the geometry the simulator recorded
/// (`TOPO_DEBUG_MASCOT_TRACE`, over the `full` fixture with the transcript dragged slowly, in
/// `Traces/`) and scripted: he is displaced once per crossing and never caught by the turn — one
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
            guard let field, let picture = roam.picture else { continue }
            standingCovered = roam.covered && !roam.walking ? standingCovered + 1 : 0
            XCTAssertLessThanOrEqual(standingCovered, 1, "t \(event.t): caught under text at \(picture)", file: file, line: line)
            if gliding, !roam.walking {
                XCTAssertFalse(roam.covered, "t \(event.t): a glide ended under text at \(picture)", file: file, line: line)
            }
            gliding = roam.walking
            _ = field
        }
        XCTAssertEqual(roam.moves, glides, "\(name): one glide a crossing", file: file, line: line)
        XCTAssertFalse(roam.covered, "\(name): he ended under text", file: file, line: line)
        XCTAssertFalse(roam.walking, "\(name): he never arrived", file: file, line: line)
        return (roam, try XCTUnwrap(field, file: file, line: line))
    }

    /// The transcript dragged slowly up, a person's bubble rising into him from below (the
    /// crossing that, recorded before the fix, caught him and carried him up the screen in hops a
    /// few points long, forty glides in a second and a half): one glide, under it, and he ends
    /// clear below it.
    func testARisingPersonsTurnIsOneHopUnderItAndNeverCatchesHim() throws {
        let trace = try trace("crossing-up")
        let (roam, field) = try assertCrossings("crossing-up", until: 32.5, glides: 1)
        let picture = try XCTUnwrap(roam.picture)
        XCTAssertGreaterThan(picture.minY, trace.standing.y, "he did not go under it")
        let above = try XCTUnwrap(Self.bubbles(in: field).filter { $0.maxY <= picture.minY }.max { $0.maxY < $1.maxY },
                                  "no person's turn above him")
        XCTAssertGreaterThanOrEqual(picture.minY, above.maxY + Self.settings.clearance - MascotRoost.epsilon)
    }

    /// The same drag carried on until the next person's bubble rises into him with the glass
    /// still over its foot, so there is no room under it: one more glide, above it, riding the
    /// words until they stop, and never caught.
    func testTheNextRisingTurnWithNoRoomUnderItIsOneGlideAboveIt() throws {
        let (roam, field) = try assertCrossings("crossing-up", glides: 2)
        let picture = try XCTUnwrap(roam.picture)
        let below = try XCTUnwrap(Self.bubbles(in: field).filter { $0.minY >= picture.maxY }.min { $0.minY < $1.minY },
                                  "no person's turn below him")
        XCTAssertLessThanOrEqual(picture.maxY + Self.settings.clearance, below.minY + MascotRoost.epsilon)
    }

    /// The transcript dragged down, a person's bubble descending onto him from above, and let go,
    /// so it springs back up past him: each way is one glide through the bubble to the side it
    /// came from — over it on the way down, under it on the way back — and never caught.
    func testADescendingPersonsTurnAndItsSpringBackAreAHopEach() throws {
        _ = try assertCrossings("crossing-down", glides: 2)
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
        var roam = MascotRoam(Self.settings, frame: 1.0 / 30, standing: CGPoint(x: 301, y: 250))
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
        var roam = MascotRoam(Self.settings, frame: 1.0 / 30, standing: CGPoint(x: 301, y: 440))
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
        var roam = MascotRoam(Self.settings, frame: 1.0 / 30, standing: CGPoint(x: 301, y: 250))
        let pages = stride(from: 60.0, through: 380.0, by: 4.0).map { Self.page(CGFloat($0)) }
        _ = scroll(&roam, from: 0, through: pages)
        let picture = try XCTUnwrap(roam.picture)
        XCTAssertEqual(roam.moves, 1, "one glide for the crossing")
        XCTAssertLessThanOrEqual(picture.maxY + Self.settings.clearance, 380 + MascotRoost.epsilon, "he is not above the turn")
    }

    /// A person's bubble rising past him with room below it: one glide, under it.
    func testARisingTurnWithRoomBelowIsOneGlideUnderIt() throws {
        var roam = MascotRoam(Self.settings, frame: 1.0 / 30, standing: CGPoint(x: 301, y: 150))
        let pages = stride(from: 300.0, through: 0.0, by: -4.0).map { Self.page(CGFloat($0)) }
        _ = scroll(&roam, from: 0, through: pages)
        let picture = try XCTUnwrap(roam.picture)
        XCTAssertEqual(roam.moves, 1, "one glide for the crossing")
        XCTAssertGreaterThanOrEqual(picture.minY, 120 + Self.settings.clearance - MascotRoost.epsilon, "he is not below the turn")
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
    }
}

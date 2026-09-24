import CoreGraphics
import XCTest

@testable import Topo

/// Topo's going from roost to roost over a scripted stream of geometry and a scripted clock: the
/// decision where to go waits for the geometry to settle and is never taken mid-glide; whether
/// anything is over him is judged on every frame and every geometry, with no wait, and never
/// stops him being drawn.
final class MascotRoamTests: XCTestCase {
    static let size = MascotSprite.size(scale: 2.0 / 3)
    static let settings = MascotRoam.Settings(size: size, clearance: 8, speed: 40, settle: 0.6)
    static let frame = 1.0 / 30

    static func field(_ obstacles: [CGRect]) -> MascotField {
        MascotField(visible: CGRect(x: 0, y: 0, width: 402, height: 628), obstacles: obstacles,
                    pane: CGRect(x: 41, y: 540, width: 320, height: 80),
                    well: CGRect(x: 165, y: 544, width: 72, height: 72))
    }

    /// A roam placed over `field` and left to settle.
    private func settled(_ field: MascotField, _ settings: MascotRoam.Settings = settings) -> (MascotRoam, Double) {
        var roam = MascotRoam(settings, frame: Self.frame)
        roam.observe(field, at: 0)
        var time = 0.0
        while roam.needsTime, time < 60 {
            time += Self.frame
            roam.advance(to: time)
        }
        return (roam, time)
    }

    /// Whatever he is drawn over, frame by frame: he is covered exactly when anything he may not
    /// cover overlaps his picture where it is, and drawn either way.
    private func assertCoveredExactlyWhenOverlapped(_ roam: MascotRoam, _ label: String,
                                                    file: StaticString = #filePath, line: UInt = #line) {
        guard let picture = roam.picture, let field = roam.field else { return }
        XCTAssertEqual(roam.covered, field.covers(picture), "\(label): \(picture)", file: file, line: line)
        XCTAssertFalse(roam.hidden, "\(label): a Topo standing somewhere was not drawn", file: file, line: line)
    }

    /// The first geometry that holds still for a settle places him, with no glide; before it he
    /// stands nowhere, so a chat still laying itself out is not where he is put.
    func testTheFirstSettledGeometryPlacesHimWithNoGlide() {
        var roam = MascotRoam(Self.settings, frame: Self.frame)
        roam.observe(Self.field([]), at: 0)
        XCTAssertNil(roam.position)
        XCTAssertTrue(roam.hidden)
        roam.advance(to: 0.3)
        XCTAssertNil(roam.position, "placed before the geometry settled")
        roam.advance(to: 0.6)
        XCTAssertNotNil(roam.position)
        XCTAssertEqual(roam.moves, 0)
        XCTAssertFalse(roam.hidden)
        XCTAssertEqual(roam.roost.name, "gap")
    }

    /// Text scrolled into where he stands covers him on the geometry it arrives in, before any
    /// frame of the clock, and he is drawn over it.
    func testTextScrollingIntoHimCoversHimTheSameFrameAndHeIsStillDrawn() throws {
        let (placed, time) = settled(Self.field([]))
        var roam = placed
        let picture = try XCTUnwrap(roam.picture)
        roam.observe(Self.field([CGRect(x: 0, y: picture.midY, width: 402, height: 20)]), at: time)
        XCTAssertTrue(roam.covered, "text over him and he is not covered")
        XCTAssertFalse(roam.hidden, "text over him and he is not drawn")
        // And back as it goes, the same way.
        roam.observe(Self.field([]), at: time)
        XCTAssertFalse(roam.covered)
        XCTAssertFalse(roam.hidden)
    }

    /// A glide whose straight path crosses a turn is covered while he is over it and clear past
    /// it, he is drawn all the way, and it ends where it was going.
    func testAGlideAcrossATurnIsCoveredOnlyWhileHeIsOverIt() throws {
        // He stands low on the left, over the glass; then a turn lands over him and another lies
        // between him and the only gap, at the top, so his way up crosses both.
        let (placed, start) = settled(Self.field([]))
        var roam = placed
        let from = try XCTUnwrap(roam.position)
        let rows = [CGRect(x: 0, y: 150, width: 402, height: 170), CGRect(x: 0, y: 380, width: 402, height: 160)]
        roam.observe(Self.field(rows), at: start)
        XCTAssertTrue(roam.covered, "the turn that landed on him did not cover him")
        var time = start
        var hiddenOnTheWay = false
        var shownOnTheWay = false
        var shownAfterHidden = false
        while time < start + 60 {
            time += Self.frame
            roam.advance(to: time)
            assertCoveredExactlyWhenOverlapped(roam, "t \(time)")
            if roam.walking {
                if roam.covered { hiddenOnTheWay = true } else {
                    shownOnTheWay = true
                    if hiddenOnTheWay { shownAfterHidden = true }
                }
            }
            if roam.moves > 0, !roam.walking, !roam.needsTime { break }
        }
        XCTAssertEqual(roam.moves, 1, "one glide, never restarted")
        XCTAssertTrue(hiddenOnTheWay, "his way never crossed the turns")
        XCTAssertTrue(shownOnTheWay || shownAfterHidden, "he was never clear while gliding")
        let to = try XCTUnwrap(roam.picture)
        XCTAssertLessThanOrEqual(to.maxY, 150 - 8 + 0.001, "he did not arrive in the gap at the top")
        XCTAssertFalse(roam.hidden)
        XCTAssertNotEqual(roam.position, from)
    }

    /// The glide is at the look's speed on average and eased at both ends: it takes the distance
    /// over the speed, and it starts and ends slower than it goes in the middle.
    func testTheGlideIsAtTheLooksSpeedEasedAtBothEnds() {
        let move = MascotRoam.Move(from: .zero, to: CGPoint(x: 400, y: 0), duration: 10)
        let first = move.at(1).x - move.at(0).x
        let middle = move.at(5.5).x - move.at(4.5).x
        let last = move.at(10).x - move.at(9).x
        XCTAssertLessThan(first, middle / 4)
        XCTAssertLessThan(last, middle / 4)
        XCTAssertEqual(move.at(10), CGPoint(x: 400, y: 0))
        XCTAssertEqual(move.at(20), CGPoint(x: 400, y: 0))

        // In the roam: a glide of d points takes d / speed seconds.
        let (placed, start) = settled(Self.field([]))
        var roam = placed
        let picture = roam.picture!
        roam.observe(Self.field([CGRect(x: 0, y: picture.minY - 4, width: 402, height: 628 - picture.minY + 4)]), at: start)
        var time = start
        while roam.move == nil, time < start + 5 { time += Self.frame; roam.advance(to: time) }
        let glide = try! XCTUnwrap(roam.move)
        let distance = hypot(glide.to.x - glide.from.x, glide.to.y - glide.from.y)
        XCTAssertEqual(glide.duration, Double(distance / 40), accuracy: 1e-9)
    }

    /// While anything is over him he goes at `hurry` times the stroll, and at the stroll the frame
    /// he is clear: a glide across a turn is fast over it and slow either side of it, frame by
    /// frame, and still ends where it was going.
    func testAGlideAcrossATurnIsFastOverItAndSlowEitherSide() throws {
        // He stands low; a turn lands over him and another lies between him and the only gap, at
        // the top, so his way up starts covered, comes clear, crosses the second and comes clear.
        // A clearance of 40 makes the room between the turns too little for a roost, though his
        // picture fits in it.
        var settings = Self.settings
        settings.clearance = 40
        let (placed, start) = settled(Self.field([]), settings)
        var roam = placed
        let rows = [CGRect(x: 0, y: 170, width: 402, height: 90), CGRect(x: 0, y: 380, width: 402, height: 160)]
        roam.observe(Self.field(rows), at: start)
        var time = start
        var fast = 0
        var slow = 0
        var pace: [Bool] = []
        while time < start + 60 {
            let wasCovered = roam.covered
            let before = roam.move
            time += Self.frame
            roam.advance(to: time)
            if let before, let after = roam.move {
                let stepped = after.elapsed - before.elapsed
                XCTAssertEqual(stepped, Self.frame * (wasCovered ? 10 : 1), accuracy: 1e-9,
                               "covered \(wasCovered) at \(time)")
                if wasCovered { fast += 1 } else { slow += 1 }
                if pace.last != wasCovered { pace.append(wasCovered) }
            }
            if roam.moves > 0, !roam.walking, !roam.needsTime { break }
        }
        XCTAssertEqual(roam.moves, 1)
        XCTAssertGreaterThan(fast, 0, "never in a hurry over a turn")
        XCTAssertGreaterThan(slow, 0, "never back to the stroll")
        XCTAssertEqual(pace, [true, false, true, false], "fast over each turn and slow either side")
        let to = try XCTUnwrap(roam.picture)
        XCTAssertLessThanOrEqual(to.maxY, 170 - 40 + 0.001, "he did not arrive in the gap at the top")
        XCTAssertFalse(roam.covered)
    }

    /// The keyboard rising over him sends him out at the hurry: he is off after one quiet frame,
    /// goes at `hurry` times the stroll while any of him is under it, and is out in a tenth of the
    /// time the stroll would take for as long as it covers him.
    func testAKeyboardRisingOverHimSendsHimOutInAHurry() throws {
        let (placed, start) = settled(Self.field([]))
        var roam = placed
        let picture = try XCTUnwrap(roam.picture)
        var up = Self.field([])
        up.keyboard = CGRect(x: 0, y: picture.minY - 60, width: 402, height: 1000)
        roam.observe(up, at: start)
        XCTAssertTrue(roam.covered, "the keyboard over him did not cover him")
        // One quiet frame, with a frame's slack for the clock's rounding.
        var time = start
        for _ in 0..<2 where roam.move == nil { time += Self.frame; roam.advance(to: time) }
        let glide = try XCTUnwrap(roam.move, "a covered Topo did not go after one quiet frame")
        var covered = 0.0
        while roam.covered, roam.move != nil, time < start + 60 {
            let before = roam.move!.elapsed
            time += Self.frame
            roam.advance(to: time)
            covered += Self.frame
            if let after = roam.move {
                XCTAssertEqual(after.elapsed - before, Self.frame * 10, accuracy: 1e-9)
            }
        }
        XCTAssertFalse(roam.covered, "still under the keyboard")
        XCTAssertLessThan(covered, glide.duration, "no faster than the stroll under the keyboard")
        while roam.needsTime, time < start + 60 { time += Self.frame; roam.advance(to: time) }
        let out = try XCTUnwrap(roam.picture)
        XCTAssertLessThanOrEqual(out.maxY, up.keyboard!.minY)
    }

    /// The hurry is the look's: at 1 there is none, and he strolls out from under a turn.
    func testAHurryOfOneIsTheStroll() throws {
        var settings = Self.settings
        settings.hurry = 1
        let (placed, start) = settled(Self.field([]), settings)
        var roam = placed
        let picture = try XCTUnwrap(roam.picture)
        roam.observe(Self.field([CGRect(x: 0, y: picture.minY - 4, width: 402, height: 628 - picture.minY + 4)]), at: start)
        var time = start
        while roam.move == nil, time < start + 5 { time += Self.frame; roam.advance(to: time) }
        XCTAssertTrue(roam.covered)
        let before = try XCTUnwrap(roam.move).elapsed
        time += Self.frame
        roam.advance(to: time)
        XCTAssertEqual(try XCTUnwrap(roam.move).elapsed - before, Self.frame, accuracy: 1e-9)
    }

    /// The transcript reports its geometry on every frame of a scroll. While it streams with no
    /// pause, no glide begins, and on every frame he is covered exactly when text is over him;
    /// once it stops, a covered Topo goes after one quiet frame and ends clear of text.
    func testContinuousScrollingBeginsNoGlideUntilItPausesAndLeavesHimClearOfText() {
        // Rows of text, scrolling up past him at 300 points a second, updated at 60 Hz while the
        // clock ticks at 30.
        func rows(_ offset: CGFloat) -> [CGRect] {
            (0..<20).map { CGRect(x: 16, y: CGFloat($0) * 240 - offset, width: 370, height: 80) }
        }
        let (placed, start) = settled(Self.field(rows(0)))
        var roam = placed
        XCTAssertNotNil(roam.position)
        var time = start
        var offset: CGFloat = 0
        var hiddenSeen = false
        for step in 1...(60 * 4) {
            time = start + Double(step) / 60
            offset += 5
            roam.observe(Self.field(rows(offset)), at: time)
            assertCoveredExactlyWhenOverlapped(roam, "scroll \(offset)")
            if step.isMultiple(of: 2) { roam.advance(to: time) }
            assertCoveredExactlyWhenOverlapped(roam, "tick \(time)")
            if roam.covered { hiddenSeen = true }
            XCTAssertNotNil(roam.position)
            XCTAssertEqual(roam.moves, 0, "a glide began mid-scroll at \(time)")
        }
        XCTAssertTrue(hiddenSeen, "the scroll never passed over him, so this held nothing")
        // The scroll stops. A covered Topo waits one quiet frame; a clear one waits the settle.
        let wasHidden = roam.covered
        let stopped = time
        while roam.needsTime, time < stopped + 30 {
            time += Self.frame
            roam.advance(to: time)
            assertCoveredExactlyWhenOverlapped(roam, "after \(time)")
        }
        if wasHidden { XCTAssertEqual(roam.moves, 1, "a covered Topo did not get out of the way") }
        XCTAssertFalse(roam.covered, "he ended the scroll under text")
    }

    /// A geometry change that lands within the settle of the last one defers the decision; the
    /// decision comes a settle after the last change and not before. He sits on the glass while a
    /// chat with no gap streams, flickering between full and one with room at its top, and goes
    /// to the room only once it holds still.
    func testTheRoostWaitsForTheGeometryToSettle() throws {
        let full = Self.field([CGRect(x: 0, y: 0, width: 402, height: 628)])
        let roomy = Self.field([CGRect(x: 0, y: 200, width: 402, height: 428)])
        let (placed, start) = settled(full)
        var roam = placed
        XCTAssertEqual(roam.roost.name, "flank")
        var time = start
        for step in 0..<11 {
            time = start + Double(step) * 0.3
            roam.observe(step.isMultiple(of: 2) ? roomy : full, at: time)
            roam.advance(to: time)
            XCTAssertFalse(roam.hidden)
            XCTAssertEqual(roam.moves, 0, "decided within the settle of a change")
        }
        let last = time
        while time < last + 0.6 - Self.frame {
            time += Self.frame / 2
            roam.advance(to: time)
            XCTAssertEqual(roam.moves, 0, "decided before the settle at \(time - last)")
        }
        while roam.moves == 0, time < last + 2 { time += Self.frame; roam.advance(to: time) }
        XCTAssertEqual(roam.moves, 1)
        XCTAssertGreaterThanOrEqual(time - last, 0.6 - 1e-9)
        XCTAssertEqual(roam.roost.name, "gap")
    }

    /// A new roost within his clearance of where he stands is not a move; and a geometry change
    /// mid-glide does not restart it.
    func testASmallChangeIsNotAMoveAndAGlideIsNeverRestarted() throws {
        let (placed, start) = settled(Self.field([]))
        var roam = placed
        let picture = try XCTUnwrap(roam.picture)
        // A turn comes within 5 points of his clearance: the nearest place clear of it is 5 away.
        roam.observe(Self.field([CGRect(x: 0, y: picture.maxY + 3, width: 402, height: 20)]), at: start)
        var time = start
        while roam.needsTime, time < start + 5 { time += Self.frame; roam.advance(to: time) }
        XCTAssertEqual(roam.moves, 0, "a roost within his clearance was a move")
        XCTAssertEqual(roam.picture, picture)

        // A long glide, and geometry arriving all through it.
        roam.observe(Self.field([CGRect(x: 0, y: 200, width: 402, height: 340)]), at: time)
        while roam.move == nil, time < start + 10 { time += Self.frame; roam.advance(to: time) }
        let glide = try XCTUnwrap(roam.move)
        for step in 0..<20 {
            time += Self.frame
            roam.observe(Self.field([CGRect(x: 0, y: 200 + CGFloat(step), width: 402, height: 340)]), at: time)
            roam.advance(to: time)
            if let move = roam.move {
                XCTAssertEqual([move.from, move.to], [glide.from, glide.to], "the glide was restarted")
                XCTAssertGreaterThan(move.elapsed, glide.elapsed, "the glide was restarted")
            }
        }
        XCTAssertEqual(roam.moves, 1)
    }

    /// Nothing is left waiting on the clock once the geometry has settled and he has arrived: the
    /// link the clock runs on can stop.
    func testNothingWaitsOnTheClockOnceSettled() {
        let (roam, _) = settled(Self.field(MascotGeometryTests.rows(height: 40, personMinX: 300, topoMaxX: 380, until: 540)))
        XCTAssertFalse(roam.needsTime)
        XCTAssertNil(roam.move)
    }

    /// Under Reduce Motion he is placed with no glide.
    func testReduceMotionPlacesHimWithNoGlide() throws {
        var settings = Self.settings
        settings.reduceMotion = true
        let (placed, start) = settled(Self.field([]), settings)
        var roam = placed
        let picture = try XCTUnwrap(roam.picture)
        roam.observe(Self.field([CGRect(x: 0, y: picture.minY - 4, width: 402, height: 628 - picture.minY + 4)]), at: start)
        var time = start
        while roam.needsTime, time < start + 5 {
            time += Self.frame
            roam.advance(to: time)
            XCTAssertFalse(roam.walking, "a glide under Reduce Motion")
        }
        XCTAssertEqual(roam.moves, 0)
        XCTAssertNotEqual(roam.picture, picture)
        XCTAssertFalse(roam.hidden)
    }

    /// A chat that has nothing that holds him — no gap, no flank that fits — has no Topo, and
    /// one that holds him again places him, once it settles, with no glide from nowhere.
    func testNowhereToStandIsNoTopoAndBackIsAPlacement() {
        var field = Self.field([CGRect(x: 0, y: 0, width: 402, height: 628)])
        field.well = CGRect(x: 60, y: 544, width: 72, height: 72)
        let (placed, start) = settled(field)
        var roam = placed
        XCTAssertNil(roam.position)
        XCTAssertTrue(roam.hidden)
        XCTAssertFalse(roam.needsTime)
        roam.observe(Self.field([]), at: start)
        roam.advance(to: start + 0.6)
        XCTAssertNotNil(roam.position)
        XCTAssertEqual(roam.moves, 0)
    }
}

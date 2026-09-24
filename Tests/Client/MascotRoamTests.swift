import CoreGraphics
import XCTest

@testable import Topo

/// Topo's going from roost to roost over a scripted stream of geometry and a scripted clock: the
/// decision where to go waits for the geometry to settle and is never taken mid-glide; the
/// decision whether he may be seen is taken on every frame and every geometry, with no wait.
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

    /// Whatever he is drawn over, frame by frame: he is hidden exactly when anything he may not
    /// cover overlaps his picture where it is.
    private func assertHiddenExactlyWhenCovered(_ roam: MascotRoam, _ label: String,
                                                file: StaticString = #filePath, line: UInt = #line) {
        guard let picture = roam.picture, let field = roam.field else { return }
        XCTAssertEqual(roam.hidden, field.covers(picture), "\(label): \(picture)", file: file, line: line)
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

    /// Text scrolled into where he stands hides him on the geometry it arrives in, before any
    /// frame of the clock.
    func testTextScrollingIntoHimHidesHimTheSameFrame() throws {
        let (placed, time) = settled(Self.field([]))
        var roam = placed
        let picture = try XCTUnwrap(roam.picture)
        roam.observe(Self.field([CGRect(x: 0, y: picture.midY, width: 402, height: 20)]), at: time)
        XCTAssertTrue(roam.hidden, "text over him and he is still drawn")
        // And back as it goes, the same way.
        roam.observe(Self.field([]), at: time)
        XCTAssertFalse(roam.hidden)
    }

    /// A glide whose straight path crosses a turn hides him while he is over it and shows him
    /// again past it, and the glide goes on underneath: it ends where it was going.
    func testAGlideAcrossATurnHidesHimOnlyWhileHeIsOverIt() throws {
        // He stands low on the left, over the glass; then a turn lands over him and another lies
        // between him and the only gap, at the top, so his way up crosses both.
        let (placed, start) = settled(Self.field([]))
        var roam = placed
        let from = try XCTUnwrap(roam.position)
        let rows = [CGRect(x: 0, y: 150, width: 402, height: 170), CGRect(x: 0, y: 380, width: 402, height: 160)]
        roam.observe(Self.field(rows), at: start)
        XCTAssertTrue(roam.hidden, "the turn that landed on him did not hide him")
        var time = start
        var hiddenOnTheWay = false
        var shownOnTheWay = false
        var shownAfterHidden = false
        while time < start + 60 {
            time += Self.frame
            roam.advance(to: time)
            assertHiddenExactlyWhenCovered(roam, "t \(time)")
            if roam.walking {
                if roam.hidden { hiddenOnTheWay = true } else {
                    shownOnTheWay = true
                    if hiddenOnTheWay { shownAfterHidden = true }
                }
            }
            if roam.moves > 0, !roam.walking, !roam.needsTime { break }
        }
        XCTAssertEqual(roam.moves, 1, "one glide, never restarted")
        XCTAssertTrue(hiddenOnTheWay, "he was drawn over the turns he crossed")
        XCTAssertTrue(shownOnTheWay || shownAfterHidden, "he was never seen gliding")
        let to = try XCTUnwrap(roam.picture)
        XCTAssertLessThanOrEqual(to.maxY, 150 - 8 + 0.001, "he did not arrive in the gap at the top")
        XCTAssertFalse(roam.hidden)
        XCTAssertNotEqual(roam.position, from)
    }

    /// The glide is at the look's speed on average and eased at both ends: it takes the distance
    /// over the speed, and it starts and ends slower than it goes in the middle.
    func testTheGlideIsAtTheLooksSpeedEasedAtBothEnds() {
        let move = MascotRoam.Move(from: .zero, to: CGPoint(x: 400, y: 0), start: 0, duration: 10)
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

    /// The transcript reports its geometry on every frame of a scroll. While it streams with no
    /// pause, no glide begins, and on every frame he is hidden exactly when text is over him;
    /// once it stops, he goes.
    func testContinuousScrollingBeginsNoGlideUntilItPausesAndNeverDrawsHimOverText() {
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
            assertHiddenExactlyWhenCovered(roam, "scroll \(offset)")
            if step.isMultiple(of: 2) { roam.advance(to: time) }
            assertHiddenExactlyWhenCovered(roam, "tick \(time)")
            if roam.covered { hiddenSeen = true }
            XCTAssertNotNil(roam.position)
            XCTAssertEqual(roam.moves, 0, "a glide began mid-scroll at \(time)")
        }
        XCTAssertTrue(hiddenSeen, "the scroll never passed over him, so this held nothing")
        // The scroll stops. A hidden Topo waits one quiet frame; a seen one waits the settle.
        let wasHidden = roam.hidden
        let stopped = time
        while roam.needsTime, time < stopped + 30 {
            time += Self.frame
            roam.advance(to: time)
            assertHiddenExactlyWhenCovered(roam, "after \(time)")
        }
        if wasHidden { XCTAssertEqual(roam.moves, 1, "a covered Topo did not get out of the way") }
        XCTAssertFalse(roam.hidden, "he ended the scroll under text")
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
            if roam.move != nil { XCTAssertEqual(roam.move, glide, "the glide was restarted") }
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

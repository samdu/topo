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

    /// Until the transcript has been read he is on the flank, however empty the page: the page is
    /// about to fill, and he is not placed into it. Once it has been read, his first decision is
    /// a settle later, from the flank, and it is a glide into the room the read left.
    func testUntilTheTranscriptIsReadHeIsOnTheFlank() throws {
        var roam = MascotRoam(Self.settings, frame: Self.frame)
        roam.wait(true, at: 0)
        let empty = Self.field([])
        roam.observe(empty, at: 0)
        var time = 0.0
        while roam.needsTime, time < 5 { time += Self.frame; roam.advance(to: time) }
        XCTAssertEqual(roam.roost.name, "flank", "placed into the empty page before the read")
        // The read fills the page, leaving room at its top.
        let filled = Self.field([CGRect(x: 0, y: 200, width: 402, height: 428)])
        roam.observe(filled, at: time)
        let changed = time
        while roam.needsTime, time < changed + 5 { time += Self.frame; roam.advance(to: time) }
        XCTAssertEqual(roam.roost.name, "flank", "a geometry change before the read placed him off the flank")
        XCTAssertEqual(roam.moves, 0)
        roam.wait(false, at: time)
        let read = time
        XCTAssertTrue(roam.needsTime)
        while roam.moves == 0, time < read + 5 { time += Self.frame; roam.advance(to: time) }
        XCTAssertGreaterThanOrEqual(time - read, Self.settings.settle - 1e-9, "decided before a settle after the read")
        XCTAssertEqual(roam.moves, 1, "no glide from the flank into the room the read left")
        while roam.needsTime, time < read + 60 { time += Self.frame; roam.advance(to: time) }
        XCTAssertEqual(roam.roost.name, "gap")
    }

    /// A read that fails is not the read: while the transcript has not been read he stays on the
    /// flank through the empty page and every change to it — the error line under the transcript
    /// appearing, a retry failing again — however many settles go by, and the read that gets
    /// through is what starts his first decision, into the room it leaves and not the empty
    /// page's.
    func testAFailedReadKeepsHimOnTheFlankUntilOneGetsThrough() throws {
        var roam = MascotRoam(Self.settings, frame: Self.frame)
        roam.wait(true, at: 0)
        roam.observe(Self.field([]), at: 0)
        var time = 0.0
        // The first read fails: the error line appears under the transcript, and a retry fails
        // again a minute later.
        let errorLine = Self.field([CGRect(x: 16, y: 600, width: 370, height: 20)])
        for change in [1.0, 60.0, 61.0] {
            while time < change { time += Self.frame; roam.advance(to: time) }
            roam.observe(change == 60 ? Self.field([]) : errorLine, at: time)
        }
        while time < 120 { time += Self.frame; roam.advance(to: time) }
        XCTAssertEqual(roam.roost.name, "flank", "placed into the empty page while no read had got through")
        XCTAssertEqual(roam.moves, 0)
        // The read gets through and fills the page, leaving room at its top only.
        let filled = Self.field([CGRect(x: 0, y: 200, width: 402, height: 428)])
        roam.observe(filled, at: time)
        roam.wait(false, at: time)
        let read = time
        while roam.moves == 0, time < read + 5 { time += Self.frame; roam.advance(to: time) }
        XCTAssertEqual(roam.moves, 1)
        while roam.needsTime, time < read + 60 { time += Self.frame; roam.advance(to: time) }
        let frame = try XCTUnwrap(roam.roost.frame)
        XCTAssertEqual(roam.roost.name, "gap")
        XCTAssertLessThanOrEqual(frame.maxY, 200 - Self.settings.clearance + 0.001, "not in the room the read left")
    }

    /// On the flank with no gap, every geometry change asks for a new roost: the keyboard rising,
    /// which lifts the glass and the transcript's end, opens room above the glass and he glides
    /// off the flank into it; with the keyboard down again and the chat full he is back on the
    /// flank. A scroll that opens room does the same.
    func testOnTheFlankAGeometryChangeThatOpensAGapTakesHimOffIt() throws {
        let full = Self.field([CGRect(x: 0, y: 0, width: 402, height: 628)])
        let (placed, start) = settled(full)
        var roam = placed
        XCTAssertEqual(roam.roost.name, "flank")
        XCTAssertFalse(roam.needsTime)

        // The keyboard rises: the glass sits on it, full height, and the transcript's end rises
        // with it, leaving room between the last turn and the glass.
        var up = MascotField(visible: CGRect(x: 0, y: 0, width: 402, height: 628),
                             obstacles: [CGRect(x: 0, y: -300, width: 402, height: 480)],
                             pane: CGRect(x: 41, y: 300, width: 320, height: 80),
                             well: CGRect(x: 165, y: 304, width: 72, height: 72),
                             keyboard: CGRect(x: 0, y: 390, width: 402, height: 1000))
        roam.observe(up, at: start)
        XCTAssertTrue(roam.needsTime, "a keyboard rising asked for no new roost")
        var time = start
        while roam.needsTime, time < start + 30 { time += Self.frame; roam.advance(to: time) }
        XCTAssertEqual(roam.roost.name, "gap", "the keyboard opened room and he stayed on the flank")
        let gap = try XCTUnwrap(roam.picture)
        XCTAssertTrue(MascotRoost.holds(up, frame: gap, clearance: 8))
        XCTAssertGreaterThanOrEqual(roam.moves, 1)

        // Down again, into a full chat: nothing holds him but the flank.
        roam.observe(full, at: time)
        while roam.needsTime, time < start + 60 { time += Self.frame; roam.advance(to: time) }
        XCTAssertEqual(roam.roost.name, "flank")

        // A scroll opening room at the top of the chat takes him there.
        up.keyboard = nil
        roam.observe(Self.field([CGRect(x: 0, y: 150, width: 402, height: 478)]), at: time)
        let before = roam.moves
        while roam.needsTime, time < start + 90 { time += Self.frame; roam.advance(to: time) }
        XCTAssertEqual(roam.roost.name, "gap", "a scroll opened room and he stayed on the flank")
        XCTAssertGreaterThan(roam.moves, before, "he did not glide off the flank")
    }

    /// Where he stands lacking the clearance is not a roost, and he moves however short the move
    /// to one is; and a geometry change mid-glide does not restart a glide.
    func testAShortMoveOutOfAPlaceLackingTheClearanceIsAMoveAndAGlideIsNeverRestarted() throws {
        let (placed, start) = settled(Self.field([]))
        var roam = placed
        let picture = try XCTUnwrap(roam.picture)
        XCTAssertTrue(MascotRoost.holds(roam.field!, frame: picture, clearance: 8))
        // A turn comes within 5 points of his clearance: the nearest place clear of it is 5 away,
        // and where he stands no longer holds.
        let turn = CGRect(x: 0, y: picture.maxY + 3, width: 402, height: 20)
        roam.observe(Self.field([turn]), at: start)
        XCTAssertFalse(MascotRoost.holds(roam.field!, frame: picture, clearance: 8))
        var time = start
        while roam.needsTime, time < start + 5 { time += Self.frame; roam.advance(to: time) }
        XCTAssertEqual(roam.moves, 1, "a roost lacking his clearance was kept for being near")
        let moved = try XCTUnwrap(roam.picture)
        XCTAssertEqual(moved.maxY, turn.minY - 8, accuracy: 0.001, "\(moved) does not keep 8 points from \(turn)")
        XCTAssertEqual(hypot(moved.minX - picture.minX, moved.minY - picture.minY), 5, accuracy: 0.001)

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
        XCTAssertEqual(roam.moves, 2)
    }

    /// Nothing is left waiting on the clock once the geometry has settled and he has arrived: the
    /// link the clock runs on can stop.
    func testNothingWaitsOnTheClockOnceSettled() {
        let (roam, _) = settled(Self.field(MascotGeometryTests.rows(height: 40, personMinX: 300, topoMaxX: 380, until: 540)))
        XCTAssertFalse(roam.needsTime)
        XCTAssertNil(roam.move)
    }

    /// A look changing the clearance alone, with the chat as it was, decides his roost again: a
    /// Topo standing 8 points from a turn under a clearance of 64 is moved to where 64 holds, at
    /// once and with no glide, and the threshold that keeps small shuffles from being moves does
    /// not keep him where the new clearance refuses.
    func testAClearanceChangeAloneDecidesTheRoostAgain() throws {
        let (placed, start) = settled(Self.field([]))
        var roam = placed
        let picture = try XCTUnwrap(roam.picture)
        // A turn lands 8 points under him: at a clearance of 8 he stays.
        let turn = CGRect(x: 0, y: picture.maxY + 8, width: 402, height: 20)
        roam.observe(Self.field([turn]), at: start)
        var time = start
        while roam.needsTime, time < start + 5 { time += Self.frame; roam.advance(to: time) }
        XCTAssertEqual(roam.picture, picture)

        var wide = Self.settings
        wide.clearance = 64
        roam.use(wide)
        let moved = try XCTUnwrap(roam.picture)
        XCTAssertNotEqual(moved, picture, "a clearance of 64 left him where 8 put him")
        XCTAssertNil(roam.move, "a look change glided")
        XCTAssertFalse(moved.insetBy(dx: -64 + 0.001, dy: -64 + 0.001).intersects(turn),
                       "\(moved) is inside 64 points of \(turn)")
        XCTAssertFalse(roam.needsTime)
    }

    /// A clearance change arriving during a glide — near its end, well inside a settle of
    /// arrival — is decided on the frame it arrives: the glide under the old clearance ends there
    /// and he is placed where the new one holds, with nothing left for the clock to decide.
    func testAClearanceChangeMidGlideIsDecidedOnTheFrameItArrives() throws {
        let (placed, start) = settled(Self.field([]))
        var roam = placed
        let picture = try XCTUnwrap(roam.picture)
        let turn = CGRect(x: 0, y: picture.minY - 4, width: 402, height: 628 - picture.minY + 4)
        roam.observe(Self.field([turn]), at: start)
        var time = start
        while roam.move == nil, time < start + 5 { time += Self.frame; roam.advance(to: time) }
        // Run the glide to within a tenth of a settle of its end.
        while let move = roam.move, move.duration - move.elapsed > 0.06 { time += Self.frame; roam.advance(to: time) }
        XCTAssertNotNil(roam.move)
        var wide = Self.settings
        wide.clearance = 64
        roam.use(wide)
        XCTAssertNil(roam.move, "a glide under the old clearance went on")
        let placedNow = try XCTUnwrap(roam.picture)
        XCTAssertLessThanOrEqual(placedNow.maxY, turn.minY - 64 + 0.001, "the new clearance was not kept")
        XCTAssertTrue(MascotRoost.holds(roam.field!, frame: placedNow, clearance: 64))
        XCTAssertFalse(roam.needsTime, "the decision was left for the clock")
    }

    /// A look changing his scale during a glide from the flank is decided on that frame: at the
    /// scale's maximum no roost holds him, so nothing is drawn, and at no frame is his picture
    /// over the well or the controls before it.
    func testAScaleChangeMidGlideFromTheFlankNeverDrawsHimOverTheWell() throws {
        let full = Self.field([CGRect(x: 0, y: 0, width: 402, height: 628)])
        let (placed, start) = settled(full)
        var roam = placed
        XCTAssertEqual(roam.roost.name, "flank")
        roam.observe(Self.field([CGRect(x: 0, y: 0, width: 200, height: 628)]), at: start)
        var time = start
        while roam.move == nil, time < start + 5 { time += Self.frame; roam.advance(to: time) }
        for _ in 0..<5 { time += Self.frame; roam.advance(to: time) }
        XCTAssertNotNil(roam.move, "no glide from the flank")
        func assertClearOfTheControls(_ label: String) {
            guard let picture = roam.picture, let field = roam.field else { return }
            XCTAssertFalse(MascotRoost.overlap(picture, field.well!), "\(label): \(picture) over the well")
            XCTAssertFalse(MascotRoost.overlap(picture, field.controls!), "\(label): \(picture) over the controls")
        }
        var largest = Self.settings
        largest.size = MascotSprite.size(scale: 4)
        roam.use(largest)
        XCTAssertNil(roam.move, "the glide under the old size went on")
        XCTAssertNil(roam.picture, "at a scale of 4 no roost holds him, and he was drawn")
        XCTAssertEqual(roam.roost, .none)
        for _ in 0..<120 {
            time += Self.frame
            roam.advance(to: time)
            assertClearOfTheControls("t \(time)")
        }
        // Back to a scale that fits, he is placed where it holds.
        var middle = Self.settings
        middle.size = MascotSprite.size(scale: 1)
        roam.use(middle)
        roam.advance(to: time + 1)
        assertClearOfTheControls("scale 1")
    }

    /// Reduce Motion coming on during a glide ends it at its destination at once.
    func testReduceMotionComingOnMidGlideEndsItAtItsDestination() throws {
        let (placed, start) = settled(Self.field([]))
        var roam = placed
        let picture = try XCTUnwrap(roam.picture)
        roam.observe(Self.field([CGRect(x: 0, y: picture.minY - 4, width: 402, height: 628 - picture.minY + 4)]), at: start)
        var time = start
        while roam.move == nil, time < start + 5 { time += Self.frame; roam.advance(to: time) }
        let glide = try XCTUnwrap(roam.move)
        for _ in 0..<5 { time += Self.frame; roam.advance(to: time) }
        var still = Self.settings
        still.reduceMotion = true
        roam.use(still)
        XCTAssertNil(roam.move)
        XCTAssertFalse(roam.walking)
        XCTAssertEqual(roam.position, glide.to)
        time += 1
        roam.advance(to: time)
        XCTAssertEqual(roam.position, glide.to, "he went on moving under Reduce Motion")
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
        field.well = CGRect(x: 270, y: 544, width: 72, height: 72)
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

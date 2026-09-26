import CoreGraphics
import XCTest

@testable import Topo

/// Topo's going from roost to roost over a scripted stream of geometry and a scripted clock: the
/// decision where to go waits for the geometry to settle and is never taken mid-glide; whether
/// anything is over him is judged on every frame and every geometry, with no wait, and never
/// stops him being drawn.
final class MascotRoamTests: XCTestCase {
    static let size = MascotSprite.size(scale: 2.0 / 3)
    static let reach = MascotSprite.reach(scale: 2.0 / 3)
    static let settings = MascotRoam.Settings(size: size, clearance: 8, reach: reach, speed: 40, settle: 0.6)
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
        XCTAssertEqual(roam.covered, field.covers(picture, reach: Self.reach), "\(label): \(picture)", file: file, line: line)
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
        // He stands low on the right, just above the glass; then a turn lands over him and another lies
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

    /// The keyboard rising over him — laid out in one step, the glass riding on it past him —
    /// places him at once above it, with no glide and no quiet frame, since a glide out from
    /// under it would cross the glass.
    func testAKeyboardRisingOverHimPlacesHimAboveItAtOnce() throws {
        let (placed, start) = settled(Self.field([]))
        var roam = placed
        let picture = try XCTUnwrap(roam.picture)
        let moves = roam.moves
        var up = Self.field([])
        up.keyboard = CGRect(x: 0, y: picture.minY - 60, width: 402, height: 1000)
        up.pane = CGRect(x: 41, y: up.keyboard!.minY - 60, width: 320, height: 53)
        up.well = CGRect(x: 177, y: up.keyboard!.minY - 59, width: 48, height: 48)
        roam.observe(up, at: start)
        let out = try XCTUnwrap(roam.picture, "nowhere above the keyboard")
        XCTAssertNil(roam.move, "a glide out from under the keyboard")
        XCTAssertEqual(roam.moves, moves)
        XCTAssertLessThanOrEqual(out.maxY, up.pane!.minY - 8 + 0.001, "\(out) is not above the glass")
        XCTAssertFalse(roam.covered)
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
    /// decision comes a settle after the last change and not before. Standing clear in the room at
    /// the top of a chat that streams, flickering between two layouts that both leave him clear,
    /// he decides nothing while it streams and decides once it holds still, counted by the
    /// decisions the roam has made.
    func testTheRoostWaitsForTheGeometryToSettle() throws {
        let roomy = Self.field([CGRect(x: 0, y: 200, width: 402, height: 428)])
        let roomier = Self.field([CGRect(x: 0, y: 240, width: 402, height: 388)])
        var roam = MascotRoam(Self.settings, frame: Self.frame, standing: CGPoint(x: 100, y: 20))
        roam.observe(roomy, at: 0)
        var start = 0.0
        while roam.needsTime, start < 5 { start += Self.frame; roam.advance(to: start) }
        let decided = roam.decisions
        XCTAssertEqual(decided, 1)
        XCTAssertFalse(roam.covered)
        var time = start
        for step in 0..<11 {
            time = start + Double(step) * 0.3
            roam.observe(step.isMultiple(of: 2) ? roomier : roomy, at: time)
            roam.advance(to: time)
            XCTAssertEqual(roam.decisions, decided, "decided within the settle of a change")
        }
        let last = time
        while time < last + 0.6 - Self.frame {
            time += Self.frame / 2
            roam.advance(to: time)
            XCTAssertEqual(roam.decisions, decided, "decided before the settle at \(time - last)")
        }
        while roam.decisions == decided, time < last + 2 { time += Self.frame; roam.advance(to: time) }
        XCTAssertEqual(roam.decisions, decided + 1)
        XCTAssertGreaterThanOrEqual(time - last, 0.6 - 1e-9)
        XCTAssertEqual(roam.roost.name, "gap")
        XCTAssertFalse(roam.hidden)
    }

    /// Until the transcript has been read he is not drawn, however empty the page: the page is
    /// about to fill, and he is not placed into it. Once it has been read, his first decision is
    /// a settle later, and it places him, with no glide, in the room the read left.
    func testUntilTheTranscriptIsReadHeIsNotDrawn() throws {
        var roam = MascotRoam(Self.settings, frame: Self.frame)
        roam.wait(true, at: 0)
        let empty = Self.field([])
        roam.observe(empty, at: 0)
        var time = 0.0
        while roam.needsTime, time < 5 { time += Self.frame; roam.advance(to: time) }
        XCTAssertEqual(roam.roost.name, "none", "placed into the empty page before the read")
        XCTAssertTrue(roam.hidden)
        // The read fills the page, leaving room at its top.
        let filled = Self.field([CGRect(x: 0, y: 200, width: 402, height: 428)])
        roam.observe(filled, at: time)
        let changed = time
        while roam.needsTime, time < changed + 5 { time += Self.frame; roam.advance(to: time) }
        XCTAssertEqual(roam.roost.name, "none", "a geometry change before the read placed him")
        XCTAssertTrue(roam.hidden)
        roam.wait(false, at: time)
        let read = time
        XCTAssertTrue(roam.needsTime)
        while roam.hidden, time < read + 5 { time += Self.frame; roam.advance(to: time) }
        XCTAssertGreaterThanOrEqual(time - read, Self.settings.settle - 1e-9, "decided before a settle after the read")
        XCTAssertEqual(roam.moves, 0, "a glide from nowhere")
        XCTAssertEqual(roam.roost.name, "gap")
        let frame = try XCTUnwrap(roam.picture)
        XCTAssertLessThanOrEqual(frame.maxY, 200 - Self.settings.clearance + 0.001, "not in the room the read left")
    }

    /// A read that fails is not the read: while the transcript has not been read he is not drawn
    /// through the empty page and every change to it — the error line under the transcript
    /// appearing, a retry failing again — however many settles go by, and the read that gets
    /// through is what starts his first decision, into the room it leaves and not the empty
    /// page's.
    func testAFailedReadKeepsHimUndrawnUntilOneGetsThrough() throws {
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
        XCTAssertEqual(roam.roost.name, "none", "placed into the empty page while no read had got through")
        XCTAssertTrue(roam.hidden)
        // The read gets through and fills the page, leaving room at its top only.
        let filled = Self.field([CGRect(x: 0, y: 200, width: 402, height: 428)])
        roam.observe(filled, at: time)
        roam.wait(false, at: time)
        let read = time
        while roam.hidden, time < read + 5 { time += Self.frame; roam.advance(to: time) }
        XCTAssertEqual(roam.moves, 0, "a glide from nowhere")
        while roam.needsTime, time < read + 60 { time += Self.frame; roam.advance(to: time) }
        let frame = try XCTUnwrap(roam.roost.frame)
        XCTAssertEqual(roam.roost.name, "gap")
        XCTAssertLessThanOrEqual(frame.maxY, 200 - Self.settings.clearance + 0.001, "not in the room the read left")
    }

    /// Over words for want of a gap, every geometry change asks for a new roost: the keyboard
    /// rising, which lifts the glass and the transcript's end, opens room above the glass and he
    /// goes to it; with the keyboard down again and the chat full he stands over the words, drawn,
    /// and a scroll that opens room sends him to it.
    func testOverWordsAGeometryChangeThatOpensAGapSendsHimToIt() throws {
        let full = Self.field([CGRect(x: 0, y: 0, width: 402, height: 628)])
        let (placed, start) = settled(full)
        var roam = placed
        XCTAssertEqual(roam.roost.name, "gap")
        XCTAssertEqual(roam.decision?.choice?.clears, false)
        XCTAssertFalse(roam.hidden, "with no place clear of the words he was not drawn")
        XCTAssertTrue(roam.covered, "standing over words is not covered")
        XCTAssertFalse(roam.needsTime)

        // The keyboard rises: the glass sits on it, full height, and the transcript's end rises
        // with it, leaving room between the last turn and the glass.
        let up = MascotField(visible: CGRect(x: 0, y: 0, width: 402, height: 628),
                             obstacles: [CGRect(x: 0, y: -300, width: 402, height: 480)],
                             pane: CGRect(x: 41, y: 300, width: 320, height: 80),
                             well: CGRect(x: 165, y: 304, width: 72, height: 72),
                             keyboard: CGRect(x: 0, y: 390, width: 402, height: 1000))
        roam.observe(up, at: start)
        XCTAssertTrue(roam.needsTime, "a keyboard rising asked for no new roost")
        var time = start
        while roam.needsTime, time < start + 30 { time += Self.frame; roam.advance(to: time) }
        XCTAssertEqual(roam.roost.name, "gap", "the keyboard opened room and he was not placed in it")
        let gap = try XCTUnwrap(roam.picture)
        XCTAssertTrue(MascotRoost.holds(up, frame: gap, clearance: 8, reach: Self.reach))
        XCTAssertFalse(MascotRoost.overlap(gap, up.pane!), "\(gap) over the glass")

        // Down again, into a full chat: nothing clears, and he stands over the words, drawn —
        // where he stood, since every place is as covered as any other.
        roam.observe(full, at: time)
        while roam.needsTime, time < start + 60 { time += Self.frame; roam.advance(to: time) }
        XCTAssertFalse(roam.hidden)
        let choice = try XCTUnwrap(roam.decision?.choice)
        XCTAssertFalse(choice.clears)
        XCTAssertEqual(roam.picture, gap)
        XCTAssertEqual(MascotRoost.cost(of: gap, words: full.words), choice.cost, accuracy: 0.001)

        // A scroll opening room at the top of the chat sends him there.
        roam.observe(Self.field([CGRect(x: 0, y: 150, width: 402, height: 478)]), at: time)
        while roam.needsTime, time < start + 90 { time += Self.frame; roam.advance(to: time) }
        XCTAssertEqual(roam.decision?.choice?.clears, true, "a scroll opened room and he was not sent to it")
        let clear = try XCTUnwrap(roam.picture)
        XCTAssertTrue(MascotRoost.holds(roam.field!, frame: clear, clearance: 8, reach: Self.reach))
        XCTAssertFalse(roam.hidden)
    }

    /// Where he stands lacking the clearance is not a roost, and he moves however short the move
    /// to one is; and a geometry change mid-glide does not restart a glide.
    func testAShortMoveOutOfAPlaceLackingTheClearanceIsAMoveAndAGlideIsNeverRestarted() throws {
        let (placed, start) = settled(Self.field([]))
        var roam = placed
        let picture = try XCTUnwrap(roam.picture)
        XCTAssertTrue(MascotRoost.holds(roam.field!, frame: picture, clearance: 8, reach: Self.reach))
        // A turn comes within 5 points of his clearance: the nearest place clear of it is 5 away,
        // and where he stands no longer holds.
        let turn = CGRect(x: 0, y: picture.maxY + 3, width: 402, height: 20)
        roam.observe(Self.field([turn]), at: start)
        XCTAssertFalse(MascotRoost.holds(roam.field!, frame: picture, clearance: 8, reach: Self.reach))
        var time = start
        while roam.needsTime, time < start + 5 { time += Self.frame; roam.advance(to: time) }
        XCTAssertEqual(roam.moves, 1, "a roost lacking his clearance was kept for being near")
        let moved = try XCTUnwrap(roam.picture)
        XCTAssertEqual(moved.maxY, turn.minY - 8, accuracy: 0.001, "\(moved) does not keep 8 points from \(turn)")
        XCTAssertEqual(hypot(moved.minX - picture.minX, moved.minY - picture.minY), 5, accuracy: 0.001)

        // A long glide, and geometry arriving all through it: the words scrolling a point a frame,
        // which carries where he is going with them and restarts nothing.
        roam.observe(Self.field([CGRect(x: 0, y: 200, width: 402, height: 340)]), at: time)
        while roam.move == nil, time < start + 10 { time += Self.frame; roam.advance(to: time) }
        let glide = try XCTUnwrap(roam.move)
        for step in 0..<20 {
            time += Self.frame
            roam.observe(Self.field([CGRect(x: 0, y: 200 + CGFloat(step), width: 402, height: 340)]), at: time)
            roam.advance(to: time)
            if let move = roam.move {
                XCTAssertEqual(move.from, glide.from, "the glide was restarted")
                XCTAssertEqual(move.to.x, glide.to.x, "the glide was restarted")
                XCTAssertEqual(move.to.y, glide.to.y + CGFloat(step), accuracy: 0.001,
                               "where he is going did not move with the words")
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
        XCTAssertTrue(MascotRoost.holds(roam.field!, frame: placedNow, clearance: 64, reach: Self.reach))
        XCTAssertFalse(roam.needsTime, "the decision was left for the clock")
    }

    /// A look changing his scale during a glide is decided on that frame: at the scale's maximum
    /// no roost holds him, so nothing is drawn, and at no frame is his picture over the glass.
    func testAScaleChangeMidGlideNeverDrawsHimOverTheGlass() throws {
        // Room at the top only, then room at the bottom only: he glides down across the turn.
        let (placed, start) = settled(Self.field([CGRect(x: 0, y: 300, width: 402, height: 328)]))
        var roam = placed
        XCTAssertEqual(roam.roost.name, "gap")
        roam.observe(Self.field([CGRect(x: 0, y: 0, width: 402, height: 300)]), at: start)
        var time = start
        while roam.move == nil, time < start + 5 { time += Self.frame; roam.advance(to: time) }
        time += Self.frame
        roam.advance(to: time)
        XCTAssertNotNil(roam.move, "no glide")
        func assertClearOfTheGlass(_ label: String) {
            guard let picture = roam.picture, let field = roam.field else { return }
            let reached = roam.settings.reach.around(picture)
            XCTAssertFalse(MascotRoost.overlap(reached, field.well!), "\(label): \(reached) over the well")
            XCTAssertFalse(MascotRoost.overlap(reached, field.pane!), "\(label): \(reached) over the pane")
        }
        var largest = Self.settings
        largest.size = MascotSprite.size(scale: 4)
        largest.reach = MascotSprite.reach(scale: 4)
        roam.use(largest)
        XCTAssertNil(roam.move, "the glide under the old size went on")
        XCTAssertNil(roam.picture, "at a scale of 4 no roost holds him, and he was drawn")
        XCTAssertEqual(roam.roost, .none)
        for _ in 0..<120 {
            time += Self.frame
            roam.advance(to: time)
            assertClearOfTheGlass("t \(time)")
        }
        // Back to a scale that fits, he is placed where it holds.
        var middle = Self.settings
        middle.size = MascotSprite.size(scale: 1)
        middle.reach = MascotSprite.reach(scale: 1)
        roam.use(middle)
        roam.advance(to: time + 1)
        XCTAssertNotNil(roam.picture, "back at scale 1 he was not placed")
        assertClearOfTheGlass("scale 1")
    }

    /// The keyboard rising mid-glide, the short pane landing on where he was going: the glide is
    /// decided again on the geometry it arrives in, with no settle, and turns to a roost that
    /// holds; on no frame, before or after, is his picture over the pane, the well or the
    /// keyboard.
    func testTheKeyboardRisingOverWhereHeIsGoingTurnsTheGlide() throws {
        // Room at the top right; then turns fill the top, leaving room on the right lower down,
        // and he glides down to it.
        let (placed, start) = settled(Self.field([CGRect(x: 0, y: 150, width: 402, height: 478)]))
        var roam = placed
        roam.observe(Self.field([CGRect(x: 0, y: 0, width: 402, height: 280),
                                 CGRect(x: 0, y: 280, width: 200, height: 260)]), at: start)
        var time = start
        while roam.move == nil, time < start + 5 { time += Self.frame; roam.advance(to: time) }
        for _ in 0..<3 { time += Self.frame; roam.advance(to: time) }
        let glide = try XCTUnwrap(roam.move, "no glide down")
        XCTAssertGreaterThan(glide.to.y, 280)
        // The keyboard rises: the transcript scrolls up with it and the short pane lands across
        // where he was going.
        let up = MascotField(visible: CGRect(x: 0, y: 0, width: 402, height: 628),
                             obstacles: [CGRect(x: 0, y: -200, width: 402, height: 280),
                                         CGRect(x: 0, y: 80, width: 200, height: 260)],
                             pane: CGRect(x: 41, y: 300, width: 320, height: 53),
                             well: CGRect(x: 177, y: 301, width: 48, height: 48),
                             keyboard: CGRect(x: 0, y: 360, width: 402, height: 500))
        XCTAssertFalse(MascotRoost.holds(up, frame: CGRect(origin: glide.to, size: Self.size), clearance: 8, reach: Self.reach),
                       "the fixture's keyboard leaves where he was going a roost")
        let moves = roam.moves
        roam.observe(up, at: time)
        let turned = try XCTUnwrap(roam.roost.frame, "nowhere to turn to")
        XCTAssertNotEqual(turned.origin, glide.to, "the glide went on to where the pane is")
        XCTAssertTrue(MascotRoost.holds(up, frame: turned, clearance: 8, reach: Self.reach))
        XCTAssertTrue(roam.move == nil || roam.moves > moves, "no new decision on the geometry it arrived in")
        func assertOffLimitsClear(_ label: String) {
            guard let picture = roam.picture.map(Self.reach.around) else { return }
            for limit in up.offLimits {
                XCTAssertFalse(MascotRoost.overlap(picture, limit), "\(label): his reach \(picture) over \(limit)")
            }
        }
        assertOffLimitsClear("as the keyboard arrived")
        while roam.needsTime, time < start + 60 {
            time += Self.frame
            roam.advance(to: time)
            assertOffLimitsClear("t \(time)")
        }
        let arrived = try XCTUnwrap(roam.picture)
        XCTAssertTrue(MascotRoost.holds(up, frame: arrived, clearance: 8, reach: Self.reach), "\(arrived) is not a roost")
    }

    /// The glass rising with the keyboard onto where he stands, in the steps of its animation,
    /// places him on the geometry it arrives in with no glide and no quiet frame: on no frame is
    /// his picture over the pane or the well, and he ends in a roost above the short glass.
    func testTheGlassRisingOntoWhereHeStandsPlacesHimAtOnce() throws {
        let (placed, start) = settled(Self.field([]))
        var roam = placed
        let standing = try XCTUnwrap(roam.picture)
        var time = start
        // The keyboard and the short pane on it rise from the foot of the screen, a frame at a time.
        for step in 0...20 {
            let top = 628 - CGFloat(step) * 16
            var up = Self.field([])
            up.keyboard = CGRect(x: 0, y: top, width: 402, height: 1000)
            up.pane = CGRect(x: 41, y: top - 60, width: 320, height: 53)
            up.well = CGRect(x: 177, y: top - 59, width: 48, height: 48)
            roam.observe(up, at: time)
            if let picture = roam.picture.map(Self.reach.around) {
                XCTAssertFalse(MascotRoost.overlap(picture, up.pane!), "step \(step): his reach \(picture) over the pane")
                XCTAssertFalse(MascotRoost.overlap(picture, up.well!), "step \(step): his reach \(picture) over the well")
            }
            time += Self.frame
            roam.advance(to: time)
            if let picture = roam.picture.map(Self.reach.around) {
                XCTAssertFalse(MascotRoost.overlap(picture, up.pane!), "step \(step) tick: his reach \(picture) over the pane")
            }
        }
        while roam.needsTime, time < start + 60 { time += Self.frame; roam.advance(to: time) }
        let above = try XCTUnwrap(roam.picture, "nowhere above the short glass")
        XCTAssertNotEqual(above, standing)
        XCTAssertTrue(MascotRoost.holds(roam.field!, frame: above, clearance: 8, reach: Self.reach))
    }

    /// At no clearance his reach, not only his box, is what the glass is judged against: resting
    /// on the empty chat he stands with his reach on the pane's top edge; the pane rising by less
    /// than his reach below the box — onto his reach and not his box — covers him on the geometry
    /// it arrives in and places him clear of it at once; and a glide whose way passes the glass
    /// by less than his reach turns.
    func testAtNoClearanceTheGlassIsJudgedByHisReach() throws {
        var bare = Self.settings
        bare.clearance = 0
        let (placed, start) = settled(Self.field([]), bare)
        var roam = placed
        let standing = try XCTUnwrap(roam.picture)
        let pane = try XCTUnwrap(Self.field([]).pane)
        XCTAssertEqual(Self.reach.around(standing).maxY, pane.minY, accuracy: 0.001, "\(standing): his reach is not on the glass's edge")
        XCTAssertGreaterThan(Self.reach.bottom, 0)
        // The pane rises by half his reach below the box: it is under his reach and not his box.
        var risen = Self.field([])
        let rise = Self.reach.bottom / 2
        risen.pane = pane.offsetBy(dx: 0, dy: -rise)
        risen.well = risen.well?.offsetBy(dx: 0, dy: -rise)
        XCTAssertFalse(MascotRoost.overlap(standing, risen.pane!), "the fixture put the pane on his box")
        XCTAssertTrue(risen.covers(standing, reach: Self.reach), "the glass under his reach does not cover him")
        XCTAssertFalse(MascotRoost.holds(risen, frame: standing, clearance: 0, reach: Self.reach))
        roam.observe(risen, at: start)
        let moved = try XCTUnwrap(roam.picture, "nowhere clear of the risen glass")
        XCTAssertNil(roam.move, "a glide out from over the glass")
        XCTAssertFalse(MascotRoost.overlap(Self.reach.around(moved), risen.pane!), "\(moved): his reach is over the glass")
        XCTAssertFalse(roam.covered)
        // A glide past the glass by less than his reach turns.
        let field = Self.field([])
        let from = CGPoint(x: 0, y: pane.minY - Self.size.height - Self.reach.bottom)
        let along = CGPoint(x: 300, y: from.y)
        XCTAssertFalse(field.crossesOffLimits(from: from, to: along, size: Self.size, reach: Self.reach))
        let lower = CGPoint(x: 300, y: from.y + rise)
        XCTAssertFalse(field.crossesOffLimits(from: from, to: lower, size: Self.size),
                       "the fixture's glide crosses the glass with his box")
        XCTAssertTrue(field.crossesOffLimits(from: from, to: lower, size: Self.size, reach: Self.reach),
                      "a glide with his reach over the glass does not cross it")
    }

    /// The keyboard rising mid-glide with where he is going still a roost, and the way to it
    /// clear of the pane, the well and the keyboard, leaves the glide as it was.
    func testTheKeyboardRisingClearOfTheGlideKeepsIt() throws {
        // He glides up from the bottom right to room at the top.
        let (placed, start) = settled(Self.field([]))
        var roam = placed
        roam.observe(Self.field([CGRect(x: 0, y: 150, width: 402, height: 478)]), at: start)
        var time = start
        while roam.move == nil, time < start + 5 { time += Self.frame; roam.advance(to: time) }
        for _ in 0..<3 { time += Self.frame; roam.advance(to: time) }
        let glide = try XCTUnwrap(roam.move, "no glide up")
        let moves = roam.moves
        // The keyboard rises below him, the short pane with it, far from his way up.
        var up = Self.field([CGRect(x: 0, y: 150, width: 402, height: 478)])
        up.pane = CGRect(x: 41, y: 560, width: 320, height: 53)
        up.well = CGRect(x: 177, y: 561, width: 48, height: 48)
        up.keyboard = CGRect(x: 0, y: 620, width: 402, height: 500)
        roam.observe(up, at: time)
        let kept = try XCTUnwrap(roam.move, "the glide was dropped")
        XCTAssertEqual([kept.from, kept.to], [glide.from, glide.to], "the glide was decided again")
        XCTAssertEqual(roam.moves, moves)
        time += Self.frame
        roam.advance(to: time)
        XCTAssertGreaterThan(try XCTUnwrap(roam.move).elapsed, kept.elapsed, "the glide did not go on")
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

    /// A chat with nothing that clears him — no gap — has him over the least of its words, drawn;
    /// and one with room again sends him to it with a glide, at the hurry from its first frame,
    /// since standing on words he is covered.
    func testWithNoGapHeStandsOverWordsAndRoomIsAGlideOut() throws {
        let (placed, start) = settled(Self.field([CGRect(x: 0, y: 0, width: 402, height: 628)]))
        var roam = placed
        XCTAssertNotNil(roam.position)
        XCTAssertFalse(roam.hidden)
        XCTAssertTrue(roam.covered)
        XCTAssertEqual(roam.moves, 0, "a glide from nowhere")
        XCTAssertFalse(roam.needsTime)
        // Room opens at the top; the words are still over where he stands.
        roam.observe(Self.field([CGRect(x: 0, y: 200, width: 402, height: 428)]), at: start + Self.frame)
        XCTAssertTrue(roam.covered)
        var time = start + Self.frame
        while roam.move == nil, time < start + 5 { time += Self.frame; roam.advance(to: time) }
        let move = try XCTUnwrap(roam.move, "no glide out from over the words")
        XCTAssertEqual(roam.moves, 1)
        let first = try XCTUnwrap(roam.position)
        time += Self.frame
        roam.advance(to: time)
        let second = try XCTUnwrap(roam.position)
        // The first frame of the glide, covered, is the hurry's: ten frames' worth of the ease.
        let hurried = move.at(Self.frame * 10)
        XCTAssertEqual(second.y, hurried.y, accuracy: 0.01, "the glide out from over words did not hurry: \(first) → \(second)")
    }

    /// Rows of words the full width of the column, 20 points tall every 30 down to the glass: no
    /// gap his box fits, so every place is a fallback. `holes` are cut from the rows, each as
    /// (row index, x, width), and `grown` is added to the first row's height.
    static func rows(holes: [(row: Int, x: CGFloat, width: CGFloat)] = [], grown: CGFloat = 0) -> MascotField {
        var obstacles: [CGRect] = []
        for row in 0..<18 {
            let y = CGFloat(row * 30)
            let height = row == 0 ? 20 + grown : 20
            var x: CGFloat = 0
            for hole in holes.filter({ $0.row == row }).sorted(by: { $0.x < $1.x }) {
                obstacles.append(CGRect(x: x, y: y, width: hole.x - x, height: height))
                x = hole.x + hole.width
            }
            obstacles.append(CGRect(x: x, y: y, width: 402 - x, height: height))
        }
        return field(obstacles)
    }

    /// Standing over words because nothing clears them, a reply growing under him every frame
    /// weighs no place until it stops, and then weighs once: he is covered by choice, so he waits
    /// for the settle like a Topo standing clear, and moves at most once.
    func testAtAFallbackAGrowingReplyIsDecidedAtTheSettle() throws {
        let (placed, start) = settled(Self.rows())
        var roam = placed
        XCTAssertEqual(roam.decision?.choice?.clears, false)
        XCTAssertTrue(roam.covered)
        let decided = roam.decisions, moved = roam.moves
        var time = start
        // A line a frame for 150 frames, each geometry followed by a tick of the clock a frame on.
        for step in 1...150 {
            roam.observe(Self.rows(grown: CGFloat(step)), at: time)
            time += Self.frame
            roam.advance(to: time)
        }
        XCTAssertEqual(roam.decisions, decided, "decided while the reply grew a line a frame")
        XCTAssertEqual(roam.moves, moved)
        // Three points every tenth of a second for five seconds, the clock ticking in between.
        for step in 1...50 {
            roam.observe(Self.rows(grown: 150 + CGFloat(step * 3)), at: time)
            let next = time + 0.1
            while time < next - 1e-9 { time += Self.frame; roam.advance(to: time) }
        }
        XCTAssertEqual(roam.decisions, decided, "decided while the reply grew three points a tenth of a second")
        while roam.needsTime, time < start + 30 { time += Self.frame; roam.advance(to: time) }
        XCTAssertEqual(roam.decisions, decided + 1, "the settle after the growth did not decide once")
        XCTAssertLessThanOrEqual(roam.moves, moved + 1)
        XCTAssertFalse(roam.hidden)
    }

    /// At a fallback, a place that uncovers less than `fallbackGain` of his box beyond where he
    /// stands is weighed and not gone to; one that uncovers more is a glide.
    func testAtAFallbackOnlyAPlaceWorthTheGlideMovesHim() throws {
        let (placed, start) = settled(Self.rows())
        var roam = placed
        let standing = try XCTUnwrap(roam.picture)
        let gain = Self.size.width * Self.size.height * MascotRoost.fallbackGain
        // A hole in the third row at the far left, 10 points wide: 200 square points uncovered.
        XCTAssertLessThan(10 * 20, gain)
        roam.observe(Self.rows(holes: [(row: 2, x: 30, width: 10)]), at: start + Self.frame)
        var time = start + Self.frame
        let decided = roam.decisions, moved = roam.moves
        while roam.needsTime, time < start + 10 { time += Self.frame; roam.advance(to: time) }
        XCTAssertEqual(roam.decisions, decided + 1)
        let small = try XCTUnwrap(roam.decision?.choice)
        XCTAssertFalse(small.clears)
        XCTAssertLessThan(small.cost, MascotRoost.cost(of: standing, words: roam.field!.words) - 1,
                          "the hole was not a less covered place: \(small)")
        XCTAssertEqual(roam.moves, moved, "a place a hair less covered was a glide")
        XCTAssertEqual(roam.picture, standing)
        XCTAssertEqual(roam.roost, .gap(standing))
        // Forty points wide: 800 square points, more than the gain.
        XCTAssertGreaterThan(40 * 20, gain)
        roam.observe(Self.rows(holes: [(row: 2, x: 30, width: 40)]), at: time)
        let later = time
        while roam.needsTime, time < later + 30 { time += Self.frame; roam.advance(to: time) }
        XCTAssertEqual(roam.moves, moved + 1, "a place worth the glide was not gone to")
        XCTAssertEqual(roam.picture, roam.decision?.choice?.frame)
    }

    /// A decision says why a roaming Topo stands where he stands; placed on the glass, nothing
    /// does, and the last one made while he roamed is not kept.
    func testAPlacedTopoKeepsNoDecision() throws {
        let (placed, start) = settled(Self.rows())
        var roam = placed
        XCTAssertNotNil(roam.decision)
        var glass = Self.settings
        glass.placement = .glass
        roam.use(glass)
        var time = start
        while roam.needsTime, time < start + 10 { time += Self.frame; roam.advance(to: time) }
        XCTAssertEqual(roam.roost.name, "glass")
        XCTAssertNil(roam.decision, "a decision made roaming outlived the move to the glass")
    }
}

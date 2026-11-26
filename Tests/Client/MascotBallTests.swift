import CoreGraphics
import XCTest

@testable import Topo

/// The early scrunch and the shot from it (`MascotRoam.ball`): he balls up the moment anything
/// moves, shoots for where a gap will be on the geometry still to come, is put right once the
/// words stop, and unscrunches where nothing comes for him. Through all of it his reach stays in
/// his room and off the pane, the well and the keyboard on every frame of the real geometry.
final class MascotBallTests: XCTestCase {
    static let settings = MascotRoamTests.settings
    static let frame = 1.0 / 60

    private func settled(_ field: MascotField, _ settings: MascotRoam.Settings = settings) -> (MascotRoam, Double) {
        let settled = MascotRoamTests.settled(field, settings, frame: Self.frame)
        XCTAssertNotNil(settled.0.position)
        return settled
    }

    /// On the real geometry, where he is: his reach inside his room's width and above the pane,
    /// and nothing he may never be drawn over — the pane, the well, the keyboard — under it.
    private func assertInHisRoom(_ roam: MascotRoam, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let picture = roam.picture, let field = roam.field else { return XCTFail("\(label): nowhere", file: file, line: line) }
        let reached = Self.settings.reach.around(picture)
        XCTAssertGreaterThanOrEqual(reached.minX, field.visible.minX - 1e-6, "\(label): \(reached)", file: file, line: line)
        XCTAssertLessThanOrEqual(reached.maxX, field.visible.maxX + 1e-6, "\(label): \(reached)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(reached.minY, field.visible.minY - 1e-6, "\(label): \(reached)", file: file, line: line)
        XCTAssertLessThanOrEqual(reached.maxY, field.open.maxY + 1e-6, "\(label): \(reached) under the glass", file: file, line: line)
        XCTAssertFalse(field.offLimits.contains { MascotRoost.overlap($0, reached) }, "\(label): \(reached) on the glass",
                       file: file, line: line)
    }

    /// A turn scrolling up toward him: the moment it moves he is a ball; it has not reached him
    /// when, `scrunchMin` in, he shoots, hurried and from the shot, for a place clear of where it
    /// is going; the shot is not carried by the scroll its guess already carried, and once the turn stops he is put right
    /// and ends clear of it. His reach is in his room on every frame.
    func testHeShootsEarlyForWhereTheWordsAreGoing() throws {
        let (placed, start) = settled(MascotRoamTests.field([]))
        var roam = placed
        let standing = try XCTUnwrap(roam.picture)
        let moves = roam.moves
        // A turn 100 points under his box, rising at 400 points a second for half a second.
        var top = standing.maxY + 100
        let turn = { (top: CGFloat) in MascotRoamTests.field([CGRect(x: 0, y: top, width: 402, height: 160)]) }
        roam.observe(turn(top), at: start)
        roam.advance(to: start)
        var time = start
        var shot: MascotRoam.Move?
        var balledFor = 0.0
        var aimed: CGPoint?
        while time < start + 0.5 {
            time += Self.frame
            top -= 400 * CGFloat(Self.frame)
            roam.observe(turn(top), at: time)
            roam.advance(to: time)
            assertInHisRoom(roam, "scrolling at \(time - start)")
            if shot == nil, roam.ball != nil {
                balledFor = time - start
                XCTAssertEqual(roam.phase, .open, "a ball not worn as the scrunch")
                XCTAssertTrue(roam.swimming)
            }
            if shot == nil, let move = roam.move {
                shot = move
                XCTAssertGreaterThan(time - start, MascotRoam.scrunchMin, "shot before the scrunch")
                XCTAssertFalse(roam.covered, "the turn had reached him: nothing early about the shot")
                XCTAssertTrue(move.provisional)
                XCTAssertEqual(move.pace, Double(Self.settings.hurry))
                XCTAssertEqual(move.from, standing.origin, "shot from somewhere he was not")
            }
            // Until the moment the guess carried the words to, their drift is in the aim already.
            if let move = roam.move, move.provisional, time < move.guessed {
                if let aimed { XCTAssertEqual(move.to, aimed, "a provisional shot carried by the scroll it guessed") }
                aimed = move.to
            }
        }
        XCTAssertNotNil(shot, "never shot while the words moved")
        XCTAssertGreaterThan(balledFor, 0, "never balled up")
        let stopped = time
        while roam.needsTime, time < stopped + 10 {
            time += Self.frame
            roam.observe(turn(top), at: time)
            roam.advance(to: time)
            assertInHisRoom(roam, "after at \(time - stopped)")
            if time - stopped > MascotRoam.quietFor + 2 * Self.frame { XCTAssertFalse(roam.move?.provisional ?? false, "never put right") }
        }
        XCTAssertNil(roam.ball)
        XCTAssertFalse(roam.covered, "he ended under the turn")
        XCTAssertGreaterThan(roam.moves, moves)
    }

    /// A shot whose place the real geometry takes is a kick: once the words have been quiet, he goes
    /// again from where he is, hurried and from the shot, for the nearest place to where he was going.
    func testAProvisionalShotThatMissesIsAKickFromWhereHeIs() throws {
        let (placed, start) = settled(MascotRoamTests.field([]))
        var roam = placed
        let standing = try XCTUnwrap(roam.picture)
        var top = standing.maxY + 100
        let rows = { (top: CGFloat, extra: [CGRect]) in MascotRoamTests.field([CGRect(x: 0, y: top, width: 402, height: 160)] + extra) }
        roam.observe(rows(top, []), at: start)
        var time = start
        while roam.move == nil, time < start + 0.5 {
            time += Self.frame
            top -= 400 * CGFloat(Self.frame)
            roam.observe(rows(top, []), at: time)
            roam.advance(to: time)
        }
        let shot = try XCTUnwrap(roam.move)
        XCTAssertTrue(shot.provisional)
        // The words stop with a line where he was going.
        let target = CGRect(origin: shot.to, size: Self.settings.size)
        let line = CGRect(x: 0, y: target.minY - 10, width: 402, height: target.height + 20)
        XCTAssertFalse(MascotRoost.overlap(line, try XCTUnwrap(roam.picture)), "the line is on him already")
        roam.observe(rows(top, [line]), at: time)
        let moves = roam.moves
        let still = time
        var kick: MascotRoam.Move?
        while time < still + MascotRoam.quietFor + 4 * Self.frame {
            time += Self.frame
            roam.advance(to: time)
            if roam.moves > moves, kick == nil {
                kick = roam.move
                XCTAssertGreaterThan(time - still, MascotRoam.quietFor)
                let kicked = try XCTUnwrap(kick)
                XCTAssertFalse(kicked.provisional)
                XCTAssertEqual(kicked.pace, Double(Self.settings.hurry))
                XCTAssertEqual(kicked.swim.at(kicked.swim.elapsed).phase, .thrust, "a kick that scrunched again")
                XCTAssertEqual(kicked.from, roam.position, "kicked from somewhere he was not")
                XCTAssertGreaterThan(hypot(kicked.to.x - shot.to.x, kicked.to.y - shot.to.y), MascotRoam.correction)
            }
        }
        XCTAssertNotNil(kick, "the miss was never put right")
        while roam.needsTime, time < still + 10 { time += Self.frame; roam.advance(to: time) }
        XCTAssertFalse(roam.covered)
    }

    /// Words that move far from him ball him up, and once they are quiet, with nothing come for
    /// him, he unscrunches where he stands: no swim, no decision moved him.
    func testABallWithNothingComingUnscrunchesWhereHeIs() throws {
        let far = { (y: CGFloat) in MascotRoamTests.field([CGRect(x: 0, y: y, width: 402, height: 40)]) }
        let (placed, start) = settled(far(10))
        var roam = placed
        let standing = try XCTUnwrap(roam.position)
        let moves = roam.moves
        var time = start
        for step in 1...3 {
            time += Self.frame
            roam.observe(far(10 - CGFloat(step) * 3), at: time)
            roam.advance(to: time)
        }
        XCTAssertNotNil(roam.ball, "the words moved and he did not ball up")
        while roam.ball != nil, time < start + 5 { time += Self.frame; roam.advance(to: time) }
        XCTAssertNil(roam.ball)
        XCTAssertLessThan(time - start, MascotRoam.scrunchMin + MascotRoam.quietFor + 0.1, "held the ball past the quiet")
        XCTAssertEqual(roam.position, standing)
        XCTAssertEqual(roam.moves, moves)
        XCTAssertFalse(roam.swimming)
        // The settle after the words moved decides once more, and leaves him where he is.
        while roam.needsTime, time < start + 5 { time += Self.frame; roam.advance(to: time) }
        XCTAssertFalse(roam.needsTime, "the clock still asked for")
        XCTAssertEqual(roam.position, standing)
        XCTAssertEqual(roam.moves, moves)
    }

    /// Words that never stop, far from him, hold a ball no longer than `holdFor` at a time.
    func testABallIsNeverHeldPastItsLimit() throws {
        let far = { (y: CGFloat) in MascotRoamTests.field([CGRect(x: 0, y: y, width: 402, height: 40)]) }
        let (placed, start) = settled(far(40))
        var roam = placed
        let moves = roam.moves
        var time = start
        var y: CGFloat = 40
        var longest = 0.0
        while time < start + 4 {
            time += Self.frame
            y += y > 80 ? -40 : 0.5
            roam.observe(far(y), at: time)
            roam.advance(to: time)
            if let ball = roam.ball { longest = max(longest, time - ball) }
        }
        XCTAssertGreaterThan(longest, 0)
        XCTAssertLessThanOrEqual(longest, MascotRoam.holdFor + 2 * Self.frame)
        XCTAssertEqual(roam.moves, moves)
    }

    /// One ball a stretch of motion: words that move again once they have been quiet are a new
    /// stretch, and he balls up again.
    func testAStretchOfMotionAfterAQuietOneBallsHimUpAgain() throws {
        let far = { (y: CGFloat) in MascotRoamTests.field([CGRect(x: 0, y: y, width: 402, height: 40)]) }
        let (placed, start) = settled(far(10))
        var roam = placed
        var time = start, y: CGFloat = 10
        var balls = 0, balled = false
        for stretch in 0..<2 {
            for _ in 0..<6 {
                time += Self.frame
                y -= 1
                roam.observe(far(y), at: time)
                roam.advance(to: time)
                if roam.ball != nil, !balled { balls += 1 }
                balled = roam.ball != nil
            }
            // Quiet, past `quietFor` and the settle, before the next.
            let still = time
            while time < still + MascotRoam.quietFor + Self.settings.settle + 0.1 {
                time += Self.frame
                roam.advance(to: time)
                if roam.ball != nil, !balled { balls += 1 }
                balled = roam.ball != nil
            }
            XCTAssertNil(roam.ball, "stretch \(stretch): the ball outlived the quiet")
        }
        XCTAssertEqual(balls, 2, "two stretches of motion apart are not a ball each")
    }

    /// A provisional shot is not judged against the words, but the pane, the well or the keyboard
    /// across the rest of its way turns it: the keyboard rising over where it is going sends him
    /// somewhere it is not, and his reach is off it on every frame.
    func testTheKeyboardAcrossAProvisionalShotTurnsIt() throws {
        // A turn just under him rises, so the place on its far side is below it and the shot goes
        // down the screen, where a keyboard can come up across it and not over him.
        let rising = { (dy: CGFloat, keyboard: CGRect?) -> MascotField in
            var field = MascotRoamTests.field([CGRect(x: 0, y: 410 - dy, width: 402, height: 120)])
            field.keyboard = keyboard
            return field
        }
        let (placed, start) = settled(rising(0, nil))
        var roam = placed
        var time = start, dy: CGFloat = 0
        while roam.move == nil, time < start + 0.5 {
            time += Self.frame
            dy += 400 * CGFloat(Self.frame)
            roam.observe(rising(dy, nil), at: time)
            roam.advance(to: time)
        }
        let shot = try XCTUnwrap(roam.move)
        XCTAssertTrue(shot.provisional)
        // The keyboard comes up over where the shot is going and not over him, the words still
        // moving: its top between the foot of his reach and the foot of the reach where it ends.
        let here = Self.settings.reach.around(try XCTUnwrap(roam.picture))
        let there = Self.settings.reach.around(CGRect(origin: shot.to, size: Self.settings.size))
        guard there.maxY > here.maxY + 2 else { return XCTFail("the shot does not go down the screen: \(here.maxY) to \(there.maxY)") }
        let keyboard = CGRect(x: 0, y: (here.maxY + there.maxY) / 2, width: 402, height: 700)
        time += Self.frame
        dy += 400 * CGFloat(Self.frame)
        roam.observe(rising(dy, keyboard), at: time)
        let turned = try XCTUnwrap(roam.move, "the keyboard over its way stopped him rather than turning him")
        XCTAssertNotEqual(turned.to, shot.to, "the keyboard over its way did not turn the shot")
        for _ in 0..<120 {
            time += Self.frame
            roam.advance(to: time)
            let reach = Self.settings.reach.around(try XCTUnwrap(roam.picture))
            XCTAssertLessThanOrEqual(reach.maxY, keyboard.minY + MascotRoost.epsilon, "on the keyboard at \(time - start)")
            guard roam.needsTime else { break }
        }
    }

    /// The transcript going back to unread lets go of a ball at once: nothing is decided while it is.
    func testABallIsLetGoWhenTheTranscriptIsToBeReadAgain() throws {
        let far = { (y: CGFloat) in MascotRoamTests.field([CGRect(x: 0, y: y, width: 402, height: 40)]) }
        let (placed, start) = settled(far(10))
        var roam = placed
        roam.observe(far(7), at: start + Self.frame)
        XCTAssertNotNil(roam.ball, "the words moved and he did not ball up")
        roam.wait(true, at: start + 2 * Self.frame)
        XCTAssertNil(roam.ball, "a ball kept over a transcript to be read")
    }

    /// Under Reduce Motion there is no ball and no swim: a turn reaching him places him.
    func testReduceMotionNeverBallsHimUp() throws {
        var settings = Self.settings
        settings.reduceMotion = true
        let (placed, start) = settled(MascotRoamTests.field([]), settings)
        var roam = placed
        let standing = try XCTUnwrap(roam.picture)
        var top = standing.maxY + 100
        var time = start
        while time < start + 1.5 {
            time += Self.frame
            if time < start + 0.5 { top -= 400 * CGFloat(Self.frame) }
            roam.observe(MascotRoamTests.field([CGRect(x: 0, y: top, width: 402, height: 160)]), at: time)
            roam.advance(to: time)
            XCTAssertNil(roam.ball)
            XCTAssertNil(roam.move)
        }
        XCTAssertFalse(roam.covered)
    }
}

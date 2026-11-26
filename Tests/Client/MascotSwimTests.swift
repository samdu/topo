import CoreGraphics
import XCTest

@testable import Topo

/// The swim against the mockup Sam signed off: `Traces/swim-js.json` is samdu/experiments
/// `topo-swim/swim.js`'s `planSwim` and `swimAt`, run in node over four swims — one stroke, several,
/// a hurried one from the ball, a long hurried one — and sampled every 0.09 s. The port draws the
/// same strokes, the same way and the same poses at the same moments.
final class MascotSwimTests: XCTestCase {
    struct Case: Decodable {
        struct Point: Decodable { var x: Double; var y: Double }
        var from: Point
        var to: Point
        var pace: Double
        var scrunched: Bool
        var strokes: Int
        var duration: Double
        /// Each is the time, x, y and the phase's name.
        var samples: [[Sample]]
    }

    enum Sample: Decodable {
        case number(Double), name(String)
        init(from decoder: Decoder) throws {
            let one = try decoder.singleValueContainer()
            if let number = try? one.decode(Double.self) { self = .number(number) } else { self = .name(try one.decode(String.self)) }
        }
        var number: Double { if case let .number(n) = self { n } else { .nan } }
        var name: String { if case let .name(n) = self { n } else { "" } }
    }

    func testTheSwimIsTheMockupsNumberForNumber() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "swim-js", withExtension: "json"))
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        XCTAssertEqual(cases.count, 4)
        for (n, c) in cases.enumerated() {
            let swim = MascotSwim(from: CGPoint(x: c.from.x, y: c.from.y), to: CGPoint(x: c.to.x, y: c.to.y),
                                  stride: 93, pace: c.pace, scrunched: c.scrunched)
            XCTAssertEqual(swim.strokes, c.strokes, "swim \(n)")
            XCTAssertEqual(swim.duration, c.duration, accuracy: 1e-5, "swim \(n)")
            XCTAssertGreaterThan(c.samples.count, 10)
            for sample in c.samples {
                let t = sample[0].number
                let at = swim.at(t)
                XCTAssertEqual(Double(at.point.x), sample[1].number, accuracy: 1e-3, "swim \(n) at \(t)")
                XCTAssertEqual(Double(at.point.y), sample[2].number, accuracy: 1e-3, "swim \(n) at \(t)")
                XCTAssertEqual(at.phase.rawValue, sample[3].name, "swim \(n) at \(t)")
            }
        }
    }

    /// A swim begun from the ball starts at the shot, from where he is, and a hurried one covers
    /// the same ground in the cruise's time over the pace.
    func testASwimFromTheBallStartsAtTheShotWhereHeIs() {
        let from = CGPoint(x: 10, y: 300), to = CGPoint(x: 200, y: 20)
        let balled = MascotSwim(from: from, to: to, stride: 93, pace: 1.7, scrunched: true)
        XCTAssertEqual(balled.point, from)
        XCTAssertEqual(balled.phase, .thrust)
        let cruise = MascotSwim(from: from, to: to, stride: 93)
        XCTAssertEqual(cruise.phase, .open)
        XCTAssertEqual(cruise.duration / 1.7, MascotSwim(from: from, to: to, stride: 93, pace: 1.7).duration, accuracy: 1e-9)
        XCTAssertEqual(cruise.at(cruise.duration).point, to)
        var done = cruise
        done.elapsed = cruise.duration
        XCTAssertTrue(done.done)
    }

    /// Bent to a new end, the swim leaves him where he is drawn — not where the old swim had him
    /// — and every point of the rest of it is on the way from there to the new end; in its coast,
    /// with no stroke left, it is a stroke from the shot, from where he is.
    func testARetargetedSwimKeepsHimWhereHeIs() {
        for elapsed in [0.4, 1.5, 3.4] {
            var move = MascotRoam.Move(from: .zero, to: CGPoint(x: 0, y: 300), stride: 93)
            move.swim.elapsed = elapsed
            let here = CGPoint(x: move.point.x + 3, y: move.point.y - 7), end = CGPoint(x: 40, y: 310)
            move.retarget(end, from: here)
            XCTAssertEqual(move.point.x, here.x, accuracy: 1e-6, "at \(elapsed)")
            XCTAssertEqual(move.point.y, here.y, accuracy: 1e-6, "at \(elapsed)")
            XCTAssertEqual(move.at(move.duration), end, "at \(elapsed)")
            var t = move.elapsed
            while t <= move.duration {
                let p = move.at(t)
                // On the segment from here to the end: no point outside the box the two make.
                XCTAssertTrue(p.x >= min(here.x, end.x) - 1e-6 && p.x <= max(here.x, end.x) + 1e-6
                              && p.y >= min(here.y, end.y) - 1e-6 && p.y <= max(here.y, end.y) + 1e-6,
                              "at \(elapsed): \(p) off the way from \(here) to \(end)")
                t += 1.0 / 60
            }
        }
    }

    /// His head leads: the lean closes on the way he goes, the short way round, at 16 a second, and
    /// back upright at 9 once he has none; his arms trail the other way in his own picture.
    func testTheHeadLeadsAndHeRightsHimself() {
        var lean = MascotLean()
        let up = CGVector(dx: 0, dy: -100), right = CGVector(dx: 100, dy: 0)
        lean.step(1, heading: up)
        XCTAssertEqual(lean.angle, 0, accuracy: 1e-9, "swimming up the screen is upright")
        XCTAssertEqual(lean.trail(up), 90, accuracy: 1e-9, "arms not streamed down")
        for _ in 0..<60 { lean.step(1.0 / 60, heading: right) }
        XCTAssertEqual(lean.angle, .pi / 2, accuracy: 0.01, "not turned to the right in a second")
        XCTAssertEqual(lean.trail(right), 90, accuracy: 1, "arms not streamed behind him in his own picture")
        var one = MascotLean()
        one.step(1.0 / 60, heading: right)
        XCTAssertEqual(one.angle, .pi / 2 * 16 / 60, accuracy: 1e-9)
        for _ in 0..<120 { lean.step(1.0 / 60, heading: nil) }
        XCTAssertEqual(lean.angle, 0, "not upright two seconds after arriving")
        // Down the screen he turns three-quarters over and no further, his arms still streamed
        // straight up the screen.
        let down = CGVector(dx: 0, dy: 100)
        for _ in 0..<120 { lean.step(1.0 / 60, heading: down) }
        XCTAssertEqual(abs(lean.angle), MascotLean.most, accuracy: 1e-9, "turned past three-quarters over")
        XCTAssertEqual(lean.angle + lean.trail(down) * .pi / 180, lean.angle > 0 ? -.pi / 2 + 2 * .pi : -.pi / 2,
                       accuracy: 1e-9, "arms not streamed up the screen")
        // From three-quarters over one way, a swim the other way turns him to it, through upright,
        // rather than holding him at the limit.
        let leftward = CGVector(dx: -100, dy: 0)
        for _ in 0..<120 { lean.step(1.0 / 60, heading: leftward) }
        XCTAssertEqual(lean.angle, -.pi / 2, accuracy: 0.01, "held at the limit swimming the other way")
        var left = MascotLean()
        left.step(1.0 / 60, heading: CGVector(dx: -1, dy: 0))
        XCTAssertLessThan(left.angle, 0, "turned the long way round")
    }
}

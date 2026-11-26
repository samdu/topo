#if os(iOS)
import CoreGraphics
import Foundation

/// One swim from one picture origin to another: how Topo goes from place to place, as the swim
/// Sam signed off in samdu/experiments `topo-swim` (`swim.js`) has it, number for number.
///
/// A swim is whole strokes of a jet. Each stroke is the scrunch (`open`, his arms curled into a
/// ball under him and all but still), the shot (`thrust`, a spike of speed with his arms thrown
/// straight behind) and the glide (`trail`, a decaying coast with his arms streamed behind), and
/// at the cruise one stroke carries him `stride` points. A short swim is one stroke, a long one
/// several; the first and the last carry 0.6 of a middle one, so he eases in and coasts into the
/// place, and the swim ends on a coast of a third of a second past its last stroke. A hurried swim
/// runs its strokes `pace` times faster and covers the same ground. A swim that starts `scrunched`
/// is one whose scrunch has already been seen — he balled up before he knew where he was going,
/// or he is mid-stroke and turning — so it starts at the shot.
struct MascotSwim: Equatable, Sendable {
    /// The three poses of a stroke, as the engine names them.
    enum Phase: String, Equatable, Sendable {
        case open = "swimOpen", thrust = "swimThrust", trail = "swimTrail"
    }

    /// The length of each phase of a stroke at the cruise, in seconds.
    static let open = 0.32, thrust = 0.2, trail = 0.55
    static let stroke = open + thrust + trail
    /// The coast past the last stroke, at the cruise, in seconds.
    static let coast = 0.35
    /// What the first and the last of several strokes carry, as a share of a middle one.
    static let endStroke = 0.6

    var from: CGPoint
    var to: CGPoint
    /// The points one stroke carries him at the cruise, which a swim bent in its coast is planned at.
    var stride: CGFloat
    var strokes: Int
    /// What each stroke carries, as a share of the whole way.
    var shares: [Double]
    /// How many times the cruise the strokes come.
    var pace: Double
    /// How far along the whole way he is when the swim begins: none, or the scrunch's share of the
    /// first stroke for one that starts at the shot, which the rest of the way is rescaled over.
    var start: Double
    /// Seconds into the swim, of real time.
    var elapsed: Double

    /// A swim from `from` to `to` carrying `stride` points a stroke at the cruise.
    init(from: CGPoint, to: CGPoint, stride: CGFloat, pace: Double = 1, scrunched: Bool = false) {
        self.from = from
        self.to = to
        self.stride = stride
        let distance = Double(hypot(to.x - from.x, to.y - from.y))
        let strokes = max(1, Int((distance / Double(max(stride, 1))).rounded(.toNearestOrAwayFromZero)))
        self.strokes = strokes
        let weights = (0..<strokes).map { i in strokes == 1 ? 1 : (i == 0 || i == strokes - 1) ? Self.endStroke : 1 }
        let sum = weights.reduce(0, +)
        shares = weights.map { $0 / sum }
        self.pace = max(pace, 1)
        elapsed = scrunched ? Self.open / self.pace : 0
        start = scrunched ? shares[0] * Self.profile(Self.open / Self.stroke) : 0
    }

    /// One stroke's length in time at this swim's pace.
    var strokeLength: Double { Self.stroke / pace }
    /// The whole swim's length in time, its coast included.
    var duration: Double { Double(strokes) * strokeLength + Self.coast / pace }
    var done: Bool { elapsed >= duration }

    /// How far through the strokes' whole way he is `elapsed` seconds into the swim, 0 to 1, as the
    /// strokes carry him, before any of it was spent before the swim began.
    func carried(at elapsed: Double) -> Double {
        let k = min(Double(strokes), max(elapsed, 0) / strokeLength)
        let i = min(strokes - 1, Int(k.rounded(.down)))
        return k >= Double(strokes) ? 1 : shares[..<i].reduce(0, +) + shares[i] * Self.profile(k - Double(i))
    }

    /// How far along the way from `from` to `to` he is `elapsed` seconds into the swim, 0 to 1.
    /// The scrunch's speed dips a little below nothing just before the shot, as the mockup's has
    /// it, so a swim bent there would carry him back past where it was bent: he is held there
    /// until the stroke carries him on, and goes nowhere off the way.
    func fraction(at elapsed: Double) -> Double {
        (max(carried(at: elapsed), start) - start) / (1 - start)
    }

    /// The same swim from `here`, where he is drawn, to `to`: what is left of its strokes carries
    /// him the rest of the way, so every point it passes is between the two and he moves nowhere
    /// at the bend. In the coast, with no stroke left, it is a stroke from the shot.
    mutating func bend(from here: CGPoint, to: CGPoint) {
        let raw = carried(at: elapsed)
        guard raw < 1 - 1e-6 else {
            self = MascotSwim(from: here, to: to, stride: stride, pace: pace, scrunched: true)
            return
        }
        start = raw
        from = here
        self.to = to
    }

    /// Where he is and which pose the stroke is in, `elapsed` seconds into the swim.
    func at(_ elapsed: Double) -> (point: CGPoint, phase: Phase) {
        let k = min(Double(strokes), max(elapsed, 0) / strokeLength)
        let u = k - Double(min(strokes - 1, Int(k.rounded(.down))))
        let f = fraction(at: elapsed)
        let point = CGPoint(x: from.x + (to.x - from.x) * CGFloat(f), y: from.y + (to.y - from.y) * CGFloat(f))
        let t = u * Self.stroke
        let phase: Phase = k >= Double(strokes) ? .trail : t < Self.open ? .open : t < Self.open + Self.thrust ? .thrust : .trail
        return (point, phase)
    }

    var point: CGPoint { at(elapsed).point }
    var phase: Phase { at(elapsed).phase }

    /// Whether his head leads yet: not through the scrunch a swim starts at, which he balls up into
    /// upright as he does from a standstill, and from the shot on, bent or not. A swim that starts
    /// at the shot starts past its scrunch, so leads from its first frame.
    var leads: Bool { elapsed >= Self.open / pace }

    /// The way he goes, as a vector, which his head leads along.
    var heading: CGVector { CGVector(dx: to.x - from.x, dy: to.y - from.y) }

    /// Speed through one stroke as a share of the stroke's mean, `u` from 0 to 1 through it: all
    /// but still as he scrunches, a spike on the shot, a decaying coast.
    static func speed(_ u: Double) -> Double {
        let a = open / stroke, b = (open + thrust) / stroke
        if u < a { return 0.1 + 0.12 * cos(.pi * u / a) }
        if u < b { let v = (u - a) / (b - a); return 0.1 + 3.2 * sin(.pi * v * 0.5 + 0.2) }
        let v = (u - b) / (1 - b)
        return 3.2 * exp(-3.2 * v) + 0.2
    }

    private static let samples = 400
    /// How far through one stroke he has gone by `u` of it, 0 to 1: the speed summed in four
    /// hundred steps and read between them.
    private static let table: [Double] = {
        var out = [Double](repeating: 0, count: samples + 1)
        var sum = 0.0
        for i in 0..<samples {
            sum += speed((Double(i) + 0.5) / Double(samples))
            out[i + 1] = sum
        }
        return out.map { $0 / sum }
    }()

    static func profile(_ u: Double) -> Double {
        let f = min(Double(samples), max(0, u * Double(samples)))
        let i = Int(f.rounded(.down))
        guard i < samples else { return 1 }
        return table[i] + (table[i + 1] - table[i]) * (f - Double(i))
    }
}

/// Which way his picture is turned: his head leads where he swims. It turns toward the way he
/// goes quickly, from the shot on (`MascotSwim.leads`), and back upright more slowly once he has
/// arrived; the short way round, in radians, clockwise on the screen, 0 upright. It turns no
/// further than `most` either way, so on a swim down the screen he goes three-quarters over
/// rather than head down: head down his crown would fall 9 pixels past his reach's foot, at
/// `most` it falls 2 (`MascotSprite.reach`).
struct MascotLean: Equatable, Sendable {
    /// How fast the turn closes, a share of what is left each second: toward the way he goes,
    /// and back upright.
    static let toward = 16.0, upright = 9.0
    /// The furthest he turns from upright, either way.
    static let most = 0.75 * Double.pi

    private(set) var angle = 0.0

    /// `dt` seconds on, swimming along `heading`, or with none, righting himself. A way further
    /// over than `most` is aimed at `most` on the side he already leans to, and every turn is
    /// within `most` either side, so none goes the long way round through head down.
    mutating func step(_ dt: Double, heading: CGVector?) {
        var want = heading.map { atan2(Double($0.dx), -Double($0.dy)) } ?? 0
        if abs(want) > Self.most { want = (angle == 0 ? (want < 0 ? -1 : 1) : (angle < 0 ? -1 : 1)) * Self.most }
        angle += (want - angle) * min(1, max(dt, 0) * (heading == nil ? Self.upright : Self.toward))
        angle = min(max(angle, -Self.most), Self.most)
        if heading == nil, abs(angle) < 0.002 { angle = 0 }
    }

    /// Where his arms stream in his own picture once he is upright: straight behind him, in
    /// degrees as `trail` gives them.
    static let behind = 90.0

    /// His arms `dt` seconds on as he rights himself, from `trail` toward `behind` at the rate he
    /// comes upright, the short way round, so what he takes up once upright starts from them there.
    static func righting(_ trail: Double, _ dt: Double) -> Double {
        let left = (behind - trail) * .pi / 180
        let way = trail + atan2(sin(left), cos(left)) * 180 / .pi * min(1, max(dt, 0) * upright)
        return atan2(sin(way * .pi / 180), cos(way * .pi / 180)) * 180 / .pi
    }

    /// Upright at once: Reduce Motion, or he stands nowhere.
    mutating func reset() { angle = 0 }

    /// The way his arms stream for a swim along `heading`, in degrees in his own picture as the
    /// engine takes it (`TopoInput.trail`): away from the way he goes, less the turn of his picture,
    /// the short way round, so within a half turn either side of 0.
    func trail(_ heading: CGVector) -> Double {
        let way = atan2(-Double(heading.dy), -Double(heading.dx)) - angle
        return atan2(sin(way), cos(way)) * 180 / .pi
    }
}
#endif

// Topo mascot engine, ported from topo-engine.js. Agent state in, pixels out.
//
//   let topo = Topo()
//   topo.update(dt, TopoInput(model: "claude-fable-5-1", tokens: 120_000, activity: "searching", facing: "left"))
//   topo.draw(into: rgba)            // W × H × 4 bytes; move the sprite by topo.x
//
// Everything is drawn into an indexed buffer at one entry per art pixel and only becomes colour at the
// end, so a palette change is a lookup and a load transition is an ordered dither between two palettes.
// The port follows the JavaScript expression for expression, down to which values are kept as
// Float32, because it is checked against it pixel for pixel (oracle/).

import Foundation

/// What the host tells him, a frame at a time; anything left nil keeps its last value.
public struct TopoInput: Codable, Sendable {
    public var model: String?, tokens: Double?, level: Double?, load: String?
    public var activity: String?, sign: String?, corner: Double?, facing: String?
    public var style: String?, shading: String?, relief: Double?
    public init(model: String? = nil, tokens: Double? = nil, level: Double? = nil, load: String? = nil, activity: String? = nil,
                sign: String? = nil, corner: Double? = nil, facing: String? = nil, style: String? = nil, shading: String? = nil, relief: Double? = nil) {
        self.model = model; self.tokens = tokens; self.level = level; self.load = load; self.activity = activity
        self.sign = sign; self.corner = corner; self.facing = facing; self.style = style; self.shading = shading; self.relief = relief
    }
}

public struct TopoState: Sendable {
    public var level = 2.0, load = Load.default, activity = "idle", style = "lineless", shading = "soft"
    public var corner = -40.0, sign = "updating memory", relief: Double? = nil
    /// The side of the screen he stands on, "left" or "right"; anything else is "left".
    public var facing = "left"
}

public final class Topo {
    public static let width = W, height = H, scale = S
    public static let bodyX = BX, shelfY = SHELF_Y
    /// The idle cycle's waits, in seconds from his arrival, and how many yoga excursions he takes for every corner one.
    public static let firstRest = FIRST_REST, rest = REST, cornerStay = CORNER_STAY, yogaStay = YOGA_STAY
    public static let yogaPerCorner = YOGA_PER_CORNER
    /// The facings he knows, the first the one he is drawn in; and how near the shelf pose his arms must be before he turns.
    public static let facings = FACINGS, turnSettle = TURN_SETTLE

    // A part is rasterised into planes before it is composited: `mask` is its silhouette, `nX`/`nY` the
    // surface normal's lean in the picture plane, and `open` the share of it that takes an outline.
    private let idx = UnsafeMutablePointer<UInt8>.allocate(capacity: W * H)
    private let mask = UnsafeMutablePointer<UInt8>.allocate(capacity: W * H)
    private let open = UnsafeMutablePointer<UInt8>.allocate(capacity: W * H)
    private let nX = UnsafeMutablePointer<Float>.allocate(capacity: W * H)
    private let nY = UnsafeMutablePointer<Float>.allocate(capacity: W * H)
    private let near = UnsafeMutablePointer<Float>.allocate(capacity: W * H)
    private let rampAt = UnsafeMutablePointer<UInt8>.allocate(capacity: W * H)
    private let liftAt = UnsafeMutablePointer<Int8>.allocate(capacity: W * H)
    private var arms = POSES["shelf"]!.params
    private var tips = [Float](repeating: 0, count: 16)
    private var path = [Float](repeating: 0, count: 300)

    private var t = 0.0, level = 2.0, headY = 0.0, headV = 0.0
    private var blinkAt = 2.0, wander = (1, 0), wanderAt = 3.0
    private var loadFrom = Load.default, loadTo = Load.default, loadMix = 1.0
    private var poseKey = "shelf", pose = POSES["shelf"]!, since = 0.0     // the pose in force, and for how long
    private var targets = POSES["shelf"]!.params
    private var lift = 0.0                                                    // how far he has stood up off the shelf
    private var rest = 1.0                                                    // how far the drift at rest has taken over from the wave of work
    private var x_ = 0.0, goal = 0.0                                          // where he is along the shelf, in art pixels from home, and where he is going
    private var outing_: String? = nil, dueAt: Double? = FIRST_REST           // the excursion he is on, and when the wait where he is ends; nil until he arrives
    private var faced = "left"                                                // the facing in force, which follows state.facing only at home (see "facing")
    private var mirrored: Bool { faced == "right" }
    public private(set) var state = TopoState()

    private let lettering: ((String) -> Lettering?)?
    private var random: () -> Double
    private let props = makeProps()
    private var signs: [String: PropSpec] = [:]
    private let palettes: [Load: [UInt8]] = Dictionary(uniqueKeysWithValues: Load.allCases.map { ($0, palette($0)) })

    /// `lettering` sets a sign's words in a face of the host's own; `random` is Math.random, replaceable so a run can be repeated.
    public init(lettering: ((String) -> Lettering?)? = nil, random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.lettering = lettering
        self.random = random
        for p in [idx, mask, open, rampAt] { p.initialize(repeating: 0, count: W * H) }
        for p in [nX, nY, near] { p.initialize(repeating: 0, count: W * H) }
        liftAt.initialize(repeating: 0, count: W * H)
    }

    deinit {
        for p in [idx, mask, open, rampAt] { p.deallocate() }
        for p in [nX, nY, near] { p.deallocate() }
        liftAt.deallocate()
    }

    /// How far along the shelf he has walked, in art pixels: the host moves the sprite by it.
    public var x: Double { x_ }
    public var poseName: String { poseKey }
    /// The excursion he is on, "corner" or "yoga", or nil at home.
    public var outing: String? { outing_ }
    /// The facing in force, which lags `state.facing` until he is home.
    public var facing: String { faced }

    public func update(_ dt: Double, _ next: TopoInput = TopoInput()) {
        if let v = next.level { state.level = v }
        if let v = next.load, let l = Load(rawValue: v) { state.load = l }
        if let v = next.activity { state.activity = v }
        if let v = next.sign { state.sign = v }
        if let v = next.corner { state.corner = v }
        if let v = next.facing { state.facing = v == "right" ? "right" : "left" }
        if let v = next.style { state.style = v }
        if let v = next.shading { state.shading = v }
        if let v = next.relief { state.relief = v }
        if let m = next.model, !m.isEmpty { state.level = levelForModel(m) }
        if let tk = next.tokens { state.load = loadForTokens(tk) }
        t += dt
        level += (state.level - level) * (1 - exp(-dt * 6))
        if abs(state.level - level) < 0.01 { level = state.level }
        if state.load != loadTo { loadFrom = loadTo; loadTo = state.load; loadMix = 0 }
        loadMix = jmin(1, loadMix + dt / 0.7)

        // The idle cycle (see "at rest"). Any work calls him home first, since the props stand where home is,
        // and abandons the excursion: back at rest he starts a fresh wait on the shelf rather than resuming it.
        let idle = state.activity == "idle"
        func span(_ r: (Double, Double)) -> Double { r.0 + random() * (r.1 - r.0) }
        if !idle { outing_ = nil; goal = 0; dueAt = nil }
        else if let due = dueAt, t > due {
            if outing_ == nil {
                outing_ = random() < YOGA_PER_CORNER / (1 + YOGA_PER_CORNER) ? "yoga" : "corner"
                if outing_ == "yoga" { dueAt = t + span(YOGA_STAY) }         // on his mat where he sits: he has arrived
                else { goal = mirrored ? -state.corner : state.corner; dueAt = nil }   // the corner is on his outer side
            } else {
                if outing_ == "yoga" { dueAt = t + span(REST) }
                else { goal = 0; dueAt = nil }
                outing_ = nil
            }
        }
        let gap = goal - x_, step = (idle ? 9 : 22) * dt
        x_ = abs(gap) <= step ? goal : x_ + (gap > 0 ? 1 : gap < 0 ? -1 : gap) * step
        if idle && dueAt == nil && x_ == goal { dueAt = t + span(outing_ == "corner" ? CORNER_STAY : REST) }   // arrived: the wait starts now
        let work = POSES[state.activity] != nil && !CYCLE_ONLY.contains(state.activity) ? state.activity : "shelf"
        let want = abs(goal - x_) > 0.5 ? "walk" : idle ? outing_ ?? "shelf" : work
        if want != poseKey { poseKey = want; pose = POSES[want]!; targets = pose.params; since = 0 }
        since += dt
        let poseLift = pose.lift ?? 0
        lift += ((poseLift + (poseLift != 0 ? sin(t * 1.1) : 0)) * S - lift) * (1 - exp(-dt * 5))
        rest += ((poseKey == "shelf" ? 1 : 0) - rest) * (1 - exp(-dt * REST_EASE))

        for i in 0..<8 {
            let rate = 1 - exp(-dt * (4 + Double(i * 5 % 8) * 0.6))   // staggered, so arms never land together
            for j in 0..<9 {
                let k = i * 9 + j, a = Double(arms[k])
                arms[k] = Float(a + (Double(targets[k]) - a) * rate)
            }
        }
        if state.facing != faced && poseKey == "shelf" && x_ == 0
            && (0..<arms.count).allSatisfy({ abs(Double(targets[$0]) - Double(arms[$0])) <= TURN_SETTLE }) { faced = state.facing }
        // The head rides the body on a spring, which is what ties two animations into one creature.
        let breathe = sin(t * 1.7) * 0.9 + (pose.head?.1 ?? 0) + (poseKey == "walk" ? abs(sin(t * 5)) : 0)
        headV += ((breathe - headY) * 40 - headV * 7) * dt
        headY += headV * dt
        if t > blinkAt { blinkAt = t + 2.5 + random() * 3 }
        if t > wanderAt {
            wanderAt = t + 1.5 + random() * 3
            wander = [(1, 0), (1, 0), (0, 0), (-1, 0), (1, 1)][Int(random() * 5)]
        }
    }

    // ── rasterising ─────────────────────────────────────────────────────────────
    private var lineless: Bool { state.style == "lineless" }

    // what has been rasterised since the last composite: only that box, and its shadow's reach, is composited
    private var bx0 = W, by0 = H, bx1 = 0, by1 = 0
    @inline(__always) private func touch(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
        bx0 = min(bx0, x0); by0 = min(by0, y0); bx1 = max(bx1, x1); by1 = max(by1, y1)
    }

    private func disc(_ cx: Double, _ cy: Double, _ r0: Double, _ isOpen: Bool) {
        let r = lineless ? r0 + 1 : r0
        let x0 = max(0, Int((cx - r).rounded(.down))), x1 = min(W - 1, Int((cx + r).rounded(.up)))
        let y0 = max(0, Int((cy - r).rounded(.down))), y1 = min(H - 1, Int((cy + r).rounded(.up)))
        touch(x0, y0, x1, y1)
        let rr = r * r
        var y = y0
        while y <= y1 {
            var x = x0
            while x <= x1 {
                let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy, d = (dx * dx + dy * dy) / rr, p = y * W + x
                if d <= 1 {
                    if mask[p] == 0 || d < Double(near[p]) {
                        near[p] = Float(d); nX[p] = isOpen ? Float(dx / r) : 0; nY[p] = isOpen ? Float(dy / r) : 0
                    }
                    mask[p] = 1
                    if isOpen { open[p] = 1 }
                }
                x += 1
            }
            y += 1
        }
    }

    // banded: four flat tones by how far the edge leans to the light; soft: round, held back by `relief`;
    // round: the normal stood up into three dimensions and lit across all ten tones
    @inline(__always) private func tone(_ p: Int, _ x: Int, _ y: Int, _ dither: Bool, _ hard: Double?) -> Int {
        let nx = Double(nX[p]), ny = Double(nY[p]), len = jhypot(nx, ny)
        if state.shading == "banded" {
            let l = (nx * LX + ny * LY) * (dither ? len * 1.15 : 1) + (dither ? (BAYER[(y & 3) * 4 + (x & 3)] - 0.5) * 0.22 : 0)
            return l > 0.42 ? LIGHT : l < -0.72 ? DEEP : l < -0.28 ? SHADE : BASE
        }
        let relief = hard ?? state.relief ?? (state.shading == "round" ? 1 : 0.55)
        let k = len > 0.98 ? 0.98 / len : 1, x3 = nx * k, y3 = ny * k, z3 = (1 - x3 * x3 - y3 * y3).squareRoot()
        let v = x3 * L3.0 + y3 * L3.1 + z3 * L3.2, spec = pow(jmax(0, x3 * H3.0 + y3 * H3.1 + z3 * H3.2), 30)
        var rise = (v - L3.2) * (v > L3.2 ? 6.5 : 4.6) + spec * 2.2
        if v < -0.25 && z3 < 0.45 { rise += 1.2 }                  // bounce light under the far edge
        rise *= relief
        if abs(rise) < (1 - relief) * 1.4 { rise = 0 }
        let out = Double(BASE) + rise
        return Int(jmax(1, jmin(Double(TONES), jround(out))))
    }

    @inline(__always) private func inRamp(_ i: UInt8) -> Bool { i > 0 && (Int(i) <= TONES || i > 20) }

    // lineless: no line; the part takes the line's pixels and drops a soft contact shadow down and right.
    // thin / thick: a one-pixel line round every part. A negative `ramp` is a prop: material and lift come
    // pixel by pixel, and `hard` is its relief.
    private func composite(_ dither: Bool, _ ramp: Int = 0, _ lift: Int = 0, _ fade: Double = 1, _ hard: Double? = nil) {
        let bare = lineless
        let xa = max(2, bx0), xb = min(W - 3, bx1 + 2), ya = max(2, by0), yb = min(H - 3, by1 + 2)
        var y = ya
        while y <= yb {
            var x = xa
            while x <= xb {
                let p = y * W + x
                if fade < 1 && fade <= BAYER[(y & 3) * 4 + (x & 3)] { x += 1; continue }
                if mask[p] != 0 {
                    let base = ramp < 0 ? Int(rampAt[p]) : ramp, l = ramp < 0 ? Int(liftAt[p]) : lift
                    idx[p] = UInt8(base + max(1, min(TONES, tone(p, x, y, dither, hard) + l)))
                } else if bare {
                    let drop = open[p - 1] != 0 || open[p - W] != 0 || open[p - W - 1] != 0 ? 2
                        : open[p - 2] != 0 || open[p - 2 * W] != 0 || open[p - W - 2] != 0 || open[p - 2 * W - 1] != 0 ? 1 : 0
                    if drop != 0 && inRamp(idx[p]) { idx[p] -= UInt8(min(drop, (Int(idx[p]) - 1) % 10)) }
                } else if open[p - 1] != 0 || open[p + 1] != 0 || open[p - W] != 0 || open[p + W] != 0 {
                    idx[p] = UInt8(OUTLINE)
                }
                x += 1
            }
            y += 1
        }
        var row = max(0, by0)
        while row <= min(H - 1, by1) {
            let a = row * W + max(0, bx0), b = row * W + min(W - 1, bx1) + 1
            if b > a { (mask + a).update(repeating: 0, count: b - a); (open + a).update(repeating: 0, count: b - a) }
            row += 1
        }
        bx0 = W; by0 = H; bx1 = 0; by1 = 0
    }

    private func thicken() {
        for y in 1..<(H - 1) {
            for x in 1..<(W - 1) {
                let p = y * W + x, o = UInt8(OUTLINE)
                if idx[p] == 0 && (idx[p - 1] == o || idx[p + 1] == o || idx[p - W] == o || idx[p + W] == o) { mask[p] = 1 }
            }
        }
        for p in 0..<(W * H) where mask[p] != 0 { idx[p] = UInt8(OUTLINE); mask[p] = 0 }
    }

    // A prop at (ox, oy), turned `roll` degrees clockwise in the picture. A ray goes in from each pixel until
    // it meets the prop's surface; what it meets is lit like his own body, a little harder because it is hard.
    // It dithers in once the pose is called.
    private let RELIEF = 0.85
    private var room = 1e3, stick = 14.0          // how far the sign's board must stand above the grip to clear his head

    private func signSpec() -> PropSpec {
        let key = "\(stick)|\(room)|\(lettering != nil ? "set" : "cut")|\(mirrored ? "mirror|" : "")\(state.sign)"
        if let s = signs[key] { return s }
        if signs.count > 60 { signs.removeAll() }
        let s = makeSign(state.sign, stick: stick, room: room, lettering: lettering, mirror: mirrored)
        signs[key] = s
        return s
    }

    private func prop(_ name: String, _ ox: Double, _ oy: Double, _ roll: Double = 0) {
        let spec = name == "sign" ? signSpec() : props[name]!, solids = spec.solids
        let k = spec.scale * (spec.pixels ? 1 : S), reach = spec.reach * (spec.pixels ? 1 : S)
        let r = rotation(spec.yaw, spec.pitch, roll).m, fade = jmin(1, since / 0.35)
        var which = 0
        @inline(__always) func field(_ x: Double, _ y: Double, _ z: Double) -> Double {
            var best = 1e9
            for i in 0..<solids.count { let d = solids[i].sdf(x, y, z); if d < best { best = d; which = i } }
            return best
        }
        // A prop that is not turned in the picture looks the same wherever it stands, to the fraction of a
        // pixel it stands on: its surface is found once for that fraction and kept.
        let ixD = ox.rounded(.down), iyD = oy.rounded(.down), ix = Int(ixD), iy = Int(iyD)
        let keep = roll == 0
        let tag = keep ? fixed2(ox - ixD) * 1000 + fixed2(oy - iyD) : 0
        let fresh = keep && spec.raster?.tag != tag
        var found: [Hit] = []
        let x0 = Int((ox - reach).rounded(.down)), x1 = Int((ox + reach).rounded(.up))
        let y0 = Int((oy - reach).rounded(.down)), y1 = Int((oy + reach).rounded(.up))
        touch(max(2, x0), max(2, y0), min(W - 3, x1), min(H - 3, y1))
        @inline(__always) func set(_ x: Int, _ y: Int, _ nx: Float, _ ny: Float, _ ramp: UInt8, _ lift: Int8) {
            if x < 2 || x > W - 3 || y < 2 || y > H - 3 { return }
            let p = y * W + x
            mask[p] = 1; open[p] = 1; nX[p] = nx; nY[p] = ny; rampAt[p] = ramp; liftAt[p] = lift
        }
        if keep && !fresh {
            for h in spec.raster!.hits { set(ix + Int(h.dx), iy + Int(h.dy), h.nx, h.ny, h.ramp, h.lift) }
        } else {
            let far = reach / k
            for y in y0...y1 {
                for x in x0...x1 {
                    if !keep && (x < 2 || x > W - 3 || y < 2 || y > H - 3) { continue }
                    let wx = (Double(x) + 0.5 - ox) * 1 / k, wy = (Double(y) + 0.5 - oy) / k
                    if wx * wx + wy * wy > far * far { continue }
                    // the ray in the prop's own space: it starts `reach` towards us and runs straight in
                    var px = r.0 * wx + r.3 * wy + r.6 * far, py = r.1 * wx + r.4 * wy + r.7 * far, pz = r.2 * wx + r.5 * wy + r.8 * far
                    var gone = 0.0, d = field(px, py, pz), step = 0
                    while step < 48 && d > 0.05 && gone < 2 * far {
                        gone += d; px -= r.6 * d; py -= r.7 * d; pz -= r.8 * d; d = field(px, py, pz); step += 1
                    }
                    if d > 0.05 { continue }
                    let solid = solids[which], e = 0.35
                    let gx = field(px + e, py, pz) - field(px - e, py, pz), gy = field(px, py + e, pz) - field(px, py - e, pz), gz = field(px, py, pz + e) - field(px, py, pz - e)
                    let g = jhypot(gx, gy, gz), gl = g == 0 || g.isNaN ? 1 : g, paint = solid.paint?(px, py, pz)
                    let hit = Hit(dx: Int32(x - ix), dy: Int32(y - iy),
                                  nx: Float((r.0 * gx + r.1 * gy + r.2 * gz) / gl * 1), ny: Float((r.3 * gx + r.4 * gy + r.5 * gz) / gl),
                                  ramp: UInt8((paint?.0 ?? solid.mat).ramp), lift: Int8(paint?.1 ?? solid.lift))
                    set(x, y, hit.nx, hit.ny, hit.ramp, hit.lift)
                    if fresh { found.append(hit) }
                }
            }
        }
        if fresh { spec.raster = (tag, found) }
        composite(false, -1, 0, fade, RELIEF)
    }

    private func drawArm(_ i: Int) {
        let o = i * 9, side: Double = i < 4 ? 1 : -1, settle = jmin(1, since / 0.6)
        let L = Double(arms[o + 3]) * S, n = Int(jmin(99, (L / 0.5).rounded(.up))), phase = Double(i) * 2.4
        let sway = (pose.rigid.contains(i) ? 0 : (pose.still.contains(i) ? 12 : pose.sway ?? 70) + (poseKey == "walk" ? 60 : 0)) * (1 - rest)
        // at rest, each key drifts at this arm's own rate and phase
        let drift = (0..<4).map { j in rest * WIGGLE_DEG * WIGGLE_KEYS[j] * sin(t * WIGGLE_HZ * 2 * Double.pi * (0.7 + Double(i * 3 % 8) * 0.09) + Double(i) * 2.4 + Double(j) * 1.3) }
        let motion = pose.motion.filter { $0.arm == i }
        func swing(_ param: Int) -> Double {
            var sum = 0.0
            for m in motion where m.param == param { sum = sum + m.amp * settle * sin(t * m.hz * 2 * Double.pi) }
            return sum
        }
        // an arm behind the head is no use behind a bigger head: it starts further out by the difference
        let clear = arms[o + 8] < -0.5 ? jmax(0, levelParams(level).rx - 14.5 * S) : 0
        var ax = BX + side * (Double(arms[o]) * S + clear), ay = BY - lift + Double(arms[o + 1]) * S, th = Double(arms[o + 2]) + swing(2)
        if poseKey == "walk" { th += 20 * sin(t * 5 + Double(i) * 0.8) }                       // reach and pull
        let swings = motion.isEmpty ? [0, 0, 0, 0] : (4...7).map { swing($0) }
        let nD = Double(n)
        for s in 0...n {
            let u = Double(s) / nD, f = u * 3, a = Int(jmin(2, f.rounded(.down)))
            var k = Double(arms[o + 4 + a]) + (Double(arms[o + 5 + a]) - Double(arms[o + 4 + a])) * (f - Double(a)) + swings[Int(jround(f))]
                + drift[a] + (drift[a + 1] - drift[a]) * (f - Double(a))
            k += sway * u * sin(t * 1.3 + phase - u * 3)            // a wave travelling down the arm
            th += k / nD
            let rad = th * Double.pi / 180
            ax += side * cos(rad) * L / nD; ay += sin(rad) * L / nD
            path[s * 3] = Float(ax); path[s * 3 + 1] = Float(ay); path[s * 3 + 2] = Float((2.9 - 0.7 * u) * S)
        }
        tips[i * 2] = Float(ax); tips[i * 2 + 1] = Float(ay)
        // what the tip carries turns with the last of the arm, unless it has an angle of its own
        let held = settle > 0.5 ? pose.held[i] : nil, back = max(0, n - 6) * 3
        // the board comes down over the top corner of his head, as low as leaves his eyes clear
        if held == "sign" {
            let p = levelParams(level)
            stick = jmax(8, jround(ay - (BY - lift - jmax(22, (p.up + p.ry) * 0.55))))
            // and its room runs to the edge of the picture on that side: in the mirror, the column that lands on the left edge
            room = (mirrored ? 2 * BX - 3 : Double(W - 3)) - jround(ax)
        }
        let spec = held.map { $0 == "sign" ? signSpec() : props[$0]! }
        let hx = spec?.snap == true ? jround(ax) : ax, hy = spec?.snap == true ? jround(ay) : ay   // on whole pixels, so its kept surface serves
        let turn = spec.map { $0.angle ?? atan2(ay - Double(path[back + 1]), ax - Double(path[back])) * 180 / Double.pi + 90 } ?? 0
        if let held, let spec, !spec.over { prop(held, hx, hy, turn) }             // a handle goes under the tip that grips it
        for s in 0...n { disc(Double(path[s * 3]), Double(path[s * 3 + 1]), Double(path[s * 3 + 2]), Double(s) / nD * L > 3 * S) }
        composite(false)
        if let held, let spec, spec.over { prop(held, hx, hy, turn) }              // a pencil goes over it, or it would vanish
    }

    // Signed distance to the head. `chin` is how far the jaw runs below the base: the silhouette stops at
    // it, the shading pretends it doesn't, so the chin has no shadow line and the arms' roots flow out of it.
    @inline(__always) private func headSDF(_ p: HeadParams, _ c: Double, _ s: Double, _ x: Double, _ y: Double, _ chin: Double, _ blend: Double = 2.5 * S) -> Double {
        let hw = p.jawW / 2, r = 3.8 * S, top = -p.jawH - 5 * S
        let qx = abs(x) - (hw - r), qy = abs(y - (top + chin) / 2) - ((chin - top) / 2 - r)
        let jaw = jhypot(jmax(qx, 0), jmax(qy, 0)) + jmin(jmax(qx, qy), 0) - r
        let dx = x - p.lean, dy = y + p.up
        let ey = (-dx * s + dy * c) / p.ry, ex = (dx * c + dy * s) / p.rx / (1 + p.egg * ey)   // an egg: narrower towards the crown
        // lobes: scallops that only ever push outward; with no bumps the factor is exactly one
        let lump = p.bumps == 0 ? 1 : 1 + p.bumps * 0.05 * abs(sin(2.5 * atan2(ey, ex) + 0.3))
        let dome = (jhypot(ex, ey) / lump - 1) * jmin(p.rx, p.ry)
        let h = jmax(blend - abs(jaw - dome), 0) / blend   // smooth union
        return jmin(jaw, dome) - h * h * blend / 4
    }

    @inline(__always) private func put(_ x: Int, _ y: Int, _ c: Int) {
        if x >= 0 && x < W && y >= 0 && y < H { idx[y * W + x] = UInt8(c) }
    }

    private func drawHead(_ hx: Int, _ hy: Int) {
        let p = levelParams(level), round = (state.shading == "banded" ? 7 : 11) * S, grow: Double = lineless ? 1 : 0
        let c = cos(p.tilt), s = sin(p.tilt), melt = 14 * S, chin = 20 * S
        touch(max(0, hx - 40), 0, min(W, hx + 42) - 1, H - 1)
        for y in 0..<H {
            var x = max(0, hx - 40)
            while x < min(W, hx + 42) {
                defer { x += 1 }
                let u = Double(x) + 0.5 - Double(hx), v = Double(y) + 0.5 - Double(hy)
                if headSDF(p, c, s, u, v, 0) >= grow { continue }
                // lit from a field where jaw and dome melt together over a wide band: lit from the
                // silhouette's own field, their seam shows as a ridge across the face, behind the eyes
                let q = y * W + x, d = headSDF(p, c, s, u, v, chin, melt) - grow
                let gx = headSDF(p, c, s, u + 0.5, v, chin, melt) - headSDF(p, c, s, u - 0.5, v, chin, melt)
                let gy = headSDF(p, c, s, u, v + 0.5, chin, melt) - headSDF(p, c, s, u, v - 0.5, chin, melt)
                let g = jhypot(gx, gy), gl = g == 0 || g.isNaN ? 1 : g, rim = jmax(0, 1 + d / round)   // 1 at the edge, 0 well inside
                mask[q] = 1; open[q] = y < hy - 2 ? 1 : 0
                nX[q] = Float(gx / gl * rim); nY[q] = Float(gy / gl * rim)
            }
        }
        composite(true)
        let hxD = Double(hx), hyD = Double(hy)
        func dome(_ u: Double, _ v: Double) -> (Double, Double) {
            (hxD + p.lean + u * p.rx * c - v * p.ry * s, hyD - p.up + u * p.rx * s + v * p.ry * c)
        }
        near.update(repeating: 0, count: W * H)          // the grooves' own plane: where one has already run
        if p.bumps > 0.5 {
            for fold in FOLDS {
                var pts = fold
                for _ in 0..<2 {
                    var next: [(Double, Double)] = []
                    for (i, a) in pts.enumerated() {
                        if i == pts.count - 1 { next.append(a); continue }
                        let b = pts[i + 1]
                        next.append((a.0 * 0.75 + b.0 * 0.25, a.1 * 0.75 + b.1 * 0.25))
                        next.append((a.0 * 0.25 + b.0 * 0.75, a.1 * 0.25 + b.1 * 0.75))
                    }
                    pts = next
                }
                for i in 1..<pts.count {
                    let (x0, y0) = dome(pts[i - 1].0, pts[i - 1].1), (x1, y1) = dome(pts[i].0, pts[i].1)
                    let n = (jmax(abs(x1 - x0), abs(y1 - y0)) * 2).rounded(.up)
                    if n == 0 { continue }
                    for j in 0...Int(n) {
                        let x = Int(jround(x0 + (x1 - x0) * Double(j) / n)), y = Int(jround(y0 + (y1 - y0) * Double(j) / n))
                        // a groove: two tones down where it runs, one up on the lip that faces the light
                        let at = y * W + x, lip = at - W - 1
                        if at >= 0 && at < W * H && Int(idx[at]) <= TONES && near[at] == 0 { idx[at] = UInt8(max(1, Int(idx[at]) - 2)); near[at] = 1 }
                        if lip >= 0 && lip < W * H && Int(idx[lip]) <= TONES && near[lip] == 0 { idx[lip] = UInt8(min(TONES, Int(idx[lip]) + 1)); near[lip] = 1 }
                    }
                }
            }
        }
        // the sheet's three glints, upper right of the dome
        let (gx, gy) = dome(0.25, -0.6), ix = Int(jround(gx)), iy = Int(jround(gy))
        for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] { put(ix + dx, iy + dy, HI_A) }
        put(ix - 2, iy + 1, HI_B); put(ix - 1, iy + 3, HI_B)
    }

    // The face is written in pixels, at the size SCALE makes him: features this small are placed, not scaled.
    private static let EYE: [Double] = (0..<90).map { (i: Int) -> Double in
        let x = Double(i % 9 - 4), y = Double(i / 9 - 4)
        return jhypot(x / 4.3, (y - 0.5) / 5)
    }
    @inline(__always) private func inEye(_ x: Int, _ y: Int) -> Double { Topo.EYE[(y + 4) * 9 + x + 4] }

    private func drawFace(_ fx: Int, _ fy: Int) {
        let load = state.load, face = pose.face ?? Face(), blink = blinkAt - t < 0.12 && blinkAt - t > 0
        let worried = load == .warning || load == .reset, wary = load == .untrusted, gaze = face.gaze ?? wander
        func arc(_ x: Int) -> Int { abs(x) == 4 ? 2 : abs(x) == 3 ? 1 : 0 }
        if face.goggles { prop("goggles", Double(fx), Double(fy) - 10.5) }       // his eyes are drawn on the glass, so they show through it
        for side in [-1, 1] {
            let ex = fx + side * 7 + (side < 0 ? -1 : 0), ey = fy - 11, lidded = wary && side > 0
            if face.eyes == "happy" && !wary { for x in -4...4 { put(ex + x, ey + arc(x), PUPIL) } }
            else if blink { for x in -4...4 { put(ex + x, ey + 1, PUPIL) } }
            else {
                for y in -4...5 { for x in -4...4 where inEye(x, y) <= 1 { put(ex + x, ey + y, inEye(x, y) > 0.76 ? PUPIL : WHITE) } }
                let px = ex + gaze.0, py = ey + gaze.1
                for y in -1...3 { for x in 0...3 { put(px + x, py + y, PUPIL) } }
                put(px, py - 1, WHITE); put(px + 1, py - 1, WHITE); put(px, py, WHITE)
                if lidded { for y in -4...0 { for x in -4...4 where inEye(x, y) <= 1 { put(ex + x, ey + y, y == 0 ? PUPIL : BASE) } } }
            }
            // brows: inner end up when worried, down over the wary eye, one hitched when he is thinking
            let inner: Double = worried ? -1 : lidded ? 1 : 0
            let by = ey - (face.goggles ? 9 : 6) - (face.brow == "cocked" && side > 0 ? 2 : 0)
            for j in 0..<4 { put(ex + side * (j - 1), by + (j == 3 ? 1 : 0) + Int(jround(inner * (1.5 - Double(j)) * 0.7)), PUPIL) }
            put(ex + side * 6, fy - 5, CHEEK)
            put(ex + side * 5, fy - 3, CHEEK)
        }
        // the load's mouth wins over the pose's: a worried octopus does not grin at his laptop
        let my = fy - 4, shape = load != .default ? (load == .reset ? "flat" : "frown") : face.mouth ?? "smile"
        if shape == "open" {
            for x in -2...2 { put(fx + x, my, PUPIL); put(fx + x, my + 1, abs(x) == 2 ? PUPIL : PINK) }
            for x in -1...1 { put(fx + x, my + 2, PUPIL) }
        } else if shape == "o" { for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] { put(fx + dx, my + dy, PUPIL) } }
        else {
            let bend = shape == "smile" ? 1 : shape == "frown" ? -1 : 0
            put(fx - 2, my, PUPIL); put(fx + 2, my, PUPIL); for x in -1...1 { put(fx + x, my + bend, PUPIL) }
        }
        if load == .warning {
            for (dx, dy) in [(0, -2), (0, -1), (-1, 0), (0, 0), (1, 0), (0, 1)] { put(fx + 11 + dx, fy - 18 + dy, dy == -2 || dx == -1 ? WHITE : SWEAT) }
        }
    }

    /// W × H × 4 bytes of RGBA. A clear pixel has only its alpha written.
    public func draw(into rgba: UnsafeMutablePointer<UInt8>) {
        idx.update(repeating: 0, count: W * H)
        let props = since > 0.25 ? pose.props : []
        func layer(_ i: Int) -> Float { arms[i * 9 + 8] }
        for pr in props where !pr.over { prop(pr.name, BX + pr.x * S, SHELF_Y + pr.y * S) }
        for i in 0..<8 where layer(i) < -0.5 { drawArm(i) }
        let hx = Int(jround(BX + (pose.head?.0 ?? 0) * S)), hy = Int(jround(BY - lift + headY * S))
        // the mantle's skirt, which the arms' roots gather under
        for a in 0..<40 { disc(BX + cos(Double(a) * 0.157) * 6.5 * S, BY - lift + (1 + sin(Double(a) * 0.157) * 1.2) * S, 2.6 * S, true) }
        composite(false)
        // the head goes down before the front arms so their closed roots flow out of its chin
        drawHead(hx, hy)
        let front = [1, 5, 2, 6, 3, 7, 0, 4]
        for i in front where layer(i) >= -0.5 && layer(i) <= 0.5 { drawArm(i) }
        for pr in props where pr.over { prop(pr.name, BX + pr.x * S, SHELF_Y + pr.y * S) }
        drawFace(hx + 1, hy)                                       // over the roots, so none creeps across the mouth
        for i in front where layer(i) > 0.5 { drawArm(i) }
        if state.style == "thick" { thicken() }
        toRGBA(rgba)
    }

    public func draw(_ rgba: inout [UInt8]) {
        precondition(rgba.count >= W * H * 4)
        rgba.withUnsafeMutableBufferPointer { draw(into: $0.baseAddress!) }
    }

    // Facing right, column x of the picture is column 2·BX − 1 − x of what was drawn, the reflection about the
    // body's axis; the columns past the reflection of the left edge are clear. The dither follows the drawing.
    private func toRGBA(_ rgba: UnsafeMutablePointer<UInt8>) {
        let m = mirrored, axis = Int(2 * BX) - 1
        palettes[loadFrom]!.withUnsafeBufferPointer { from in
            palettes[loadTo]!.withUnsafeBufferPointer { to in
                for y in 0..<H {
                    for x in 0..<W {
                        let at = y * W + x, sx = m ? axis - x : x
                        if sx < 0 { rgba[at * 4 + 3] = 0; continue }
                        let p = y * W + sx, i = Int(idx[p])
                        if i == 0 { rgba[at * 4 + 3] = 0; continue }
                        let c = loadMix > BAYER[(y & 3) * 4 + (sx & 3)] ? to : from
                        rgba[at * 4] = c[i * 3]; rgba[at * 4 + 1] = c[i * 3 + 1]; rgba[at * 4 + 2] = c[i * 3 + 2]; rgba[at * 4 + 3] = 255
                    }
                }
            }
        }
    }
}

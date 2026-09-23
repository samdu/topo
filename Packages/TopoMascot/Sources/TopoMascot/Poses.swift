// Poses, heads and palettes, ported from topo-engine.js as data.

// Heads, arms, poses and props are written in design units, and SCALE is how many art pixels one of
// them is: his size is this number. The face and the sign are written in pixels.
let S = 1.2
let W = 184, H = 160
let BX = 80.0, BY = 128.0          // where the body sits: the head's base, centre
let SHELF_Y = BY + 7                // the top edge of the glass he perches on

// ── palette ─────────────────────────────────────────────────────────────────────
// A ten-tone ramp per load state, darkest first, then the fixed colours, then every material's ramp
// at a multiple of ten, so (index - 1) % 10 is the tone in any ramp.
public enum Load: String, Sendable, CaseIterable { case `default`, warning, reset, untrusted }

let TONES = 10
let DEEP = 3, SHADE = 5, BASE = 7, LIGHT = 9            // the banded look's four tones, as ramp indices
let OUTLINE = 11, HI_A = 12, HI_B = 13, CHEEK = 14, WHITE = 15, PUPIL = 16, SWEAT = 17, PINK = 18

private func loadColours(_ load: Load) -> [String: String] {
    switch load {
    case .default, .warning: ["outline": "#04202e", "abyss": "#00324e", "deep": "#005873", "shade": "#007687", "base": "#00A4BB", "light": "#45d2d8", "glow": "#a6f2ea", "hiA": "#e2fffb", "hiB": "#86e8ee", "cheek": "#7ae4ea"]
    case .reset: ["outline": "#1e1600", "abyss": "#382600", "deep": "#5c4300", "shade": "#796000", "base": "#BDA24D", "light": "#dcc772", "glow": "#f6e9a8", "hiA": "#fffbe2", "hiB": "#f0dc94", "cheek": "#ecd588"]
    case .untrusted: ["outline": "#200f24", "abyss": "#43244c", "deep": "#6b3f6c", "shade": "#8D5B86", "base": "#CD96C4", "light": "#e6bbe0", "glow": "#f9def4", "hiA": "#fff4fd", "hiB": "#f4d2ee", "cheek": "#f2cbea"]
    }
}

private func rgb(_ hex: String) -> [Double] {
    let v = Int(hex.dropFirst(), radix: 16)!
    return [Double(v >> 16 & 255), Double(v >> 8 & 255), Double(v & 255)]
}

/// index → r, g, b for one load state, 256 entries of three bytes
func palette(_ load: Load) -> [UInt8] {
    let c = loadColours(load)
    var out = [UInt8](repeating: 0, count: 256 * 3)
    func put(_ i: Int, _ v: [Double]) { for k in 0..<3 { out[i * 3 + k] = UInt8(v[k]) } }
    func mix(_ a: [Double], _ b: [Double], _ f: Double) -> [Double] { (0..<3).map { jround(a[$0] + (b[$0] - a[$0]) * f) } }
    let anchors: [(String, Int)] = [("abyss", 0), ("deep", 2), ("shade", 4), ("base", 6), ("light", 8), ("glow", 9)]
    for tone in 0..<TONES {
        let hi = anchors.firstIndex { $0.1 >= tone }!, (a, a0) = anchors[max(0, hi - 1)], (b, b0) = anchors[hi]
        let f = b0 == a0 ? 0 : Double(tone - a0) / Double(b0 - a0)
        put(1 + tone, mix(rgb(c[a]!), rgb(c[b]!), f))
    }
    put(OUTLINE, rgb(c["outline"]!)); put(HI_A, rgb(c["hiA"]!)); put(HI_B, rgb(c["hiB"]!)); put(CHEEK, rgb(c["cheek"]!))
    put(WHITE, rgb("#ffffff")); put(PUPIL, rgb("#0a1626")); put(SWEAT, rgb("#a8ecff")); put(PINK, rgb("#e0608e"))
    for m in Material.allCases {
        for tone in 0..<TONES {
            let at = [0, 3, 6, 8, 9], hi = at.firstIndex { $0 >= tone }!, lo = max(0, hi - 1)
            let f = at[hi] == at[lo] ? 0 : Double(tone - at[lo]) / Double(at[hi] - at[lo])
            put(m.ramp + 1 + tone, mix(rgb(m.anchors[lo]), rgb(m.anchors[hi]), f))
        }
    }
    return out
}

let BAYER: [Double] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map { ($0 + 0.5) / 16 }
let LX = -0.6, LY = -0.8                // towards the light, in the picture plane
let L3 = (-0.45, -0.6, 0.66)            // and in the round, where z is out of the screen
let H3: (Double, Double, Double) = {    // half-vector to the viewer
    let n = jhypot(L3.0, L3.1, L3.2 + 1)
    return (L3.0 / n, L3.1 / n, (L3.2 + 1) / n)
}()

// ── heads: one per intelligence level ──────────────────────────────────────────
// A jaw (rounded box, where the face lives) smooth-unioned with a tilted egg.
struct HeadParams { var jawW, jawH, rx, ry, up, lean, tilt, egg, bumps: Double }
let LEVELS: [HeadParams] = [
    HeadParams(jawW: 26, jawH: 10, rx: 13.0, ry: 12.5, up: 13.0, lean: 0.5, tilt: 0.14, egg: 0.10, bumps: 0),
    HeadParams(jawW: 26, jawH: 10, rx: 13.8, ry: 18.0, up: 18.8, lean: 1.0, tilt: 0.24, egg: 0.16, bumps: 0),
    HeadParams(jawW: 27, jawH: 11, rx: 15.6, ry: 22.5, up: 23.8, lean: 2.0, tilt: 0.28, egg: 0.18, bumps: 0),
    HeadParams(jawW: 25, jawH: 10, rx: 23.1, ry: 19.6, up: 27.3, lean: 0.5, tilt: 0.08, egg: 0.05, bumps: 1),
]
// Level 4's folds, in dome-normalised coordinates (unit circle = the dome's edge).
let FOLDS: [[(Double, Double)]] = [
    [(-0.8, 0.0), (-0.5, -0.2), (-0.55, -0.55), (-0.25, -0.7)],
    [(-0.35, 0.55), (-0.1, 0.2), (-0.3, -0.1), (0.05, -0.35), (-0.05, -0.8)],
    [(0.2, 0.6), (0.35, 0.2), (0.15, -0.05), (0.45, -0.3)],
    [(0.6, 0.4), (0.75, 0.05), (0.6, -0.25)],
]

/// A model's family picks the head; the context window's fill picks the load.
public func levelForModel(_ model: String) -> Double {
    Double(1 + max(0, ["haiku", "sonnet", "opus", "fable"].firstIndex { model.lowercased().contains($0) } ?? -1))
}
public func loadForTokens(_ tokens: Double) -> Load {
    tokens > 300_000 ? .untrusted : tokens >= 250_000 ? .reset : tokens >= 200_000 ? .warning : .default
}

func levelParams(_ level: Double) -> HeadParams {
    let lo = Int(jmax(1, jmin(4, level.rounded(.down)))), hi = min(4, lo + 1), f = level - Double(lo)
    let a = LEVELS[lo - 1], b = LEVELS[hi - 1]
    func sized(_ a: Double, _ b: Double) -> Double { (a + (b - a) * f) * S }
    func plain(_ a: Double, _ b: Double) -> Double { (a + (b - a) * f) * 1 }
    return HeadParams(jawW: sized(a.jawW, b.jawW), jawH: sized(a.jawH, b.jawH), rx: sized(a.rx, b.rx), ry: sized(a.ry, b.ry),
                      up: sized(a.up, b.up), lean: sized(a.lean, b.lean), tilt: plain(a.tilt, b.tilt), egg: plain(a.egg, b.egg), bumps: plain(a.bumps, b.bumps))
}

// ── poses: eight arms, each a heading, a length and a curvature profile ────────
// arm = [rootX, rootY, heading°, length, k0, k1, k2, k3, layer]. Heading 0 is outward, 90 is down;
// k is degrees of turn per whole length at 0, 1/3, 2/3 and the tip. The left side is written mirrored.
// Layer is -1 behind the head, 0 in front of it, 1 in front of the props as well.
// Arms are numbered 0-3 down the right side and 4-7 down the left.
struct Face {
    var eyes: String? = nil, gaze: (Int, Int)? = nil, mouth: String? = nil, brow: String? = nil, goggles = false
}
struct Pose {
    var R: [[Double]], L: [[Double]]
    var face: Face? = nil
    var props: [(name: String, x: Double, y: Double, over: Bool)] = []
    var held: [Int: String] = [:]
    var motion: [(arm: Int, param: Int, amp: Double, hz: Double)] = []
    var still: [Int] = [], rigid: [Int] = []
    var lift: Double? = nil, sway: Double? = nil, head: (Double, Double)? = nil
    var params: [Float] { (R + L).flatMap { $0.map { Float($0) } } }
}
private func A(_ x: Double, _ y: Double, _ th: Double, _ L: Double, _ k0: Double, _ k1: Double, _ k2: Double, _ k3: Double, _ layer: Double = 0) -> [Double] {
    [x, y, th, L, k0, k1, k2, k3, layer]
}
private let REST_R = [A(8, 0, 4, 19, 0, 20, -120, -300, -1), A(7, 1, 12, 22, 20, 190, 40, -300), A(5, 2, 50, 17, 110, 10, -80, -280), A(2, 2, 80, 14, 20, 20, -60, -260)]
private let REST_L = [A(8, 0, 6, 17, 0, 10, -100, -320, -1), A(7, 1, 16, 20, 30, 210, 30, -280), A(5, 2, 54, 19, 90, 20, -60, -300), A(2, 2, 84, 13, 0, 30, -40, -250)]

let POSE_ORDER = ["front", "shelf", "walk", "corner", "yoga", "sign", "building", "writing", "calendar", "searching", "thinking"]
let POSES: [String: Pose] = [
    "front": Pose(
        R: [A(7, -2, -42, 22, 60, 30, -150, -400, -1), A(8, 1, -5, 22, -40, 10, 120, 360, -1), A(6, 2, 48, 21, -50, 0, 60, -360), A(2, 3, 78, 20, 60, -80, -40, -340)],
        L: [A(7, -2, -38, 20, 60, 30, -150, -400, -1), A(8, 1, -2, 23, -40, 10, 120, 360, -1), A(6, 2, 52, 19, -50, 0, 60, -360), A(2, 3, 80, 22, 60, -80, -40, -340)]),
    "shelf": Pose(R: REST_R, L: REST_L),
    "walk": Pose(
        R: [A(8, 0, -10, 18, 40, 60, -60, -260, -1), A(7, 1, 20, 18, 60, 120, 0, -260), A(5, 2, 55, 15, 60, 20, -60, -260), A(2, 2, 80, 13, 20, 20, -60, -260)],
        L: [A(8, 0, -10, 18, 40, 60, -60, -260, -1), A(7, 1, 20, 18, 60, 120, 0, -260), A(5, 2, 55, 15, 60, 20, -60, -260), A(2, 2, 80, 13, 20, 20, -60, -260)]),
    "corner": Pose(
        R: REST_R,
        L: [A(8, 0, 30, 20, 120, 120, -40, -300, -1), A(7, 1, 50, 24, 120, 40, -20, -280), A(5, 2, 70, 21, 40, 0, -60, -300), A(2, 2, 86, 15, 0, 30, -40, -250)],
        face: Face(gaze: (-1, 1))),
    // standing tall on two arms, the other six fanned in pairs: raised and hooked, elbows up, palms turned up
    "yoga": Pose(
        R: [A(9, -1, -35, 30, -110, -60, 60, 320, -1), A(9, 0, -5, 25, 0, -40, -230, -90, -1), A(6, 2, 50, 22, -30, -60, -160, -300), A(3, 3, 86, 22, 0, 0, -20, -300)],
        L: [A(9, -1, -35, 30, -110, -60, 60, 320, -1), A(9, 0, -5, 25, 0, -40, -230, -90, -1), A(6, 2, 50, 22, -30, -60, -160, -300), A(3, 3, 86, 22, 0, 0, -20, -300)],
        face: Face(eyes: "happy"), props: [("mat", 0, 0, false)],
        motion: [(0, 2, 3, 0.18), (4, 2, 3, 0.18)], still: [0, 1, 2, 3, 4, 5, 6, 7], lift: 16, sway: 10),
    // held out at arm's length, the arm square to the stick and its tip curled round it
    "sign": Pose(
        R: [REST_R[0], A(8, 1, 5, 33, 10, -10, -30, -260), REST_R[2], REST_R[3]],
        L: REST_L,
        face: Face(gaze: (1, -1)), held: [1: "sign"], rigid: [1]),
    // hammer and square held up out of the way; the drill in the two front arms, under his chin
    "building": Pose(
        R: [A(8, -1, -10, 26, -120, -120, -20, 0, -1), REST_R[1], A(6, 2, 20, 19, 160, 240, 160, 60, 1), REST_R[3]],
        L: [A(8, 0, -5, 28, -100, -160, -60, 0, -1), REST_L[1], A(7, 2, 30, 15, 40, 100, -100, -300), REST_L[3]],
        face: Face(gaze: (-1, 1), goggles: true), held: [4: "hammer", 0: "square", 2: "drill"],
        motion: [(4, 2, 5, 0.8), (0, 2, 5, 0.9), (2, 2, 1.2, 11)], still: [0, 4, 2, 6]),
    "writing": Pose(
        R: REST_R,
        L: [REST_L[0], A(9, -3, -70, 21, 160, 360, 300, 40, 1), REST_L[2], REST_L[3]],
        face: Face(gaze: (-1, 1)), props: [("book", 0, 0, true)], held: [5: "pencil"],
        motion: [(5, 5, 40, 4.5), (5, 2, 4, 1.3)], still: [5], head: (0, 1)),
    "calendar": Pose(
        R: [A(9, -1, -25, 16, -60, -60, -40, 0, -1), A(8, 1, 15, 18, -60, -80, -40, 0, 1), REST_R[2], REST_R[3]],
        L: REST_L,
        face: Face(gaze: (1, 0)), props: [("calendar", 26, 0, false)], motion: [(1, 2, 5, 1.1)], still: [0, 1]),
    // one arm holds the glass up; the next two rise, come over, and bend back at the wrist to lie along the keys
    "searching": Pose(
        R: REST_R,
        L: [A(8, 0, -50, 24, -60, -60, 20, 40, -1), A(7, 1, -90, 31, 140, 340, -40, -380), A(5, 2, -65, 20, 120, 320, -80, -320), REST_L[3]],
        face: Face(gaze: (-1, 1), mouth: "open"), props: [("laptop", -30, 0, false)], held: [4: "magnifier"],
        // keys at a typist's pace; the other arm only strokes the trackpad
        motion: [(4, 2, 6, 0.5), (5, 6, 45, 3.1), (6, 6, 22, 0.8), (6, 2, 4, 0.55)], still: [4, 5, 6]),
    "thinking": Pose(
        R: [A(8, 0, 10, 16, 40, 120, -200, -420, -1), A(7, 1, 30, 17, 60, 200, -100, -400), A(5, 2, 60, 14, 100, 0, -200, -380), A(2, 2, 84, 12, 20, 20, -160, -360)],
        L: [A(8, 0, 12, 15, 40, 120, -200, -420, -1), A(7, 1, 34, 16, 60, 200, -100, -400), A(5, 2, 62, 13, 100, 0, -200, -380), A(5, 3, 100, 20, 200, 330, 300, 120, 1)],
        face: Face(gaze: (-1, -1), mouth: "flat", brow: "cocked"), motion: [(7, 6, 40, 0.7)], still: [7], sway: 35, head: (1, 0)),
]

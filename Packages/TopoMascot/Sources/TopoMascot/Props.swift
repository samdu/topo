// The things Topo works with, ported from props.js: solids, not drawings. Each prop is a handful of
// signed distance shapes in three dimensions, turned to the three-quarter view, ray-marched a pixel at
// a time and lit through his own ramps. A prop's own space is x right, y down, z towards us.

import Foundation

enum Material: Int, CaseIterable {
    case wood, steel, red, yellow, pink, paper, mauve, gold, blue, ink, letter, glass
    /// where its ten-tone ramp starts in the palette
    var ramp: Int { 20 + rawValue * 10 }
    /// dark, shade, base, light, glow
    var anchors: [String] {
        switch self {
        case .wood: ["#3d2a14", "#8a6232", "#b98a4e", "#dcb271", "#f3d9a4"]
        case .steel: ["#2c353b", "#6d7a83", "#a3afb7", "#d3dbe0", "#f4f8fa"]
        case .red: ["#4d0f14", "#9a2a26", "#d8453c", "#f07a68", "#ffc0b0"]
        case .yellow: ["#5e4206", "#c9961a", "#f2c230", "#ffe07a", "#fff4c4"]
        case .pink: ["#7a3550", "#c9708a", "#f09ab0", "#ffc4d2", "#ffe6ec"]
        case .paper: ["#6e6650", "#c2b99e", "#f0ead8", "#fbf8ee", "#ffffff"]
        case .mauve: ["#43244c", "#8D5B86", "#CD96C4", "#e6bbe0", "#f9def4"]
        case .gold: ["#382600", "#796000", "#BDA24D", "#dcc772", "#f6e9a8"]
        case .blue: ["#0a2a4a", "#1679AF", "#4aa3e0", "#6AC1FB", "#c4e8ff"]
        case .ink: ["#0c0a08", "#1c1814", "#2a241e", "#3a322a", "#4a4036"]
        case .letter: ["#1c1814", "#635e55", "#a9a497", "#d8d3c2", "#f0ead8"]
        case .glass: ["#3a7fb8", "#6AC1FB", "#9ad6fc", "#c4e8ff", "#ffffff"]
        }
    }
}

typealias SDF = (Double, Double, Double) -> Double
typealias Paint = (Double, Double, Double) -> (Material, Int)?

struct Solid {
    var sdf: SDF
    var mat: Material
    var lift: Int = 0
    var paint: Paint? = nil
}

/// A ray-marched prop: its reach on screen, its size against its numbers, how it is turned to us,
/// and for a held one whether it keeps to whole pixels, has a fixed angle, or goes over the tip.
final class PropSpec {
    let reach: Double, scale: Double, yaw: Double, pitch: Double
    let angle: Double?, snap: Bool, pixels: Bool, over: Bool
    let solids: [Solid]
    /// a surface found once and kept, for a prop not turned in the picture: the fraction of a pixel it stood on, as toFixed(2) hundredths
    var raster: (tag: Int, hits: [Hit])?
    init(reach: Double, scale: Double = 1, yaw: Double = 0, pitch: Double = 0, angle: Double? = nil, snap: Bool = false, pixels: Bool = false, over: Bool = false, _ solids: [Solid]) {
        self.reach = reach; self.scale = scale; self.yaw = yaw; self.pitch = pitch
        self.angle = angle; self.snap = snap; self.pixels = pixels; self.over = over; self.solids = solids
    }
}

struct Hit { var dx: Int32, dy: Int32, nx: Float, ny: Float, ramp: UInt8, lift: Int8 }

/// world = R · own, by row: yaw about the upright, then pitch, then the turn in the picture
struct Mat3 { var m: (Double, Double, Double, Double, Double, Double, Double, Double, Double) }

func rotation(_ yaw: Double = 0, _ pitch: Double = 0, _ roll: Double = 0) -> Mat3 {
    let a = yaw * Double.pi / 180, b = pitch * Double.pi / 180, r = roll * Double.pi / 180
    let c = cos(a), s = sin(a), cb = cos(b), sb = sin(b), cr = cos(r), sr = sin(r)
    let m0 = (c, 0.0, s), m1 = (-s * sb, cb, c * sb), m2 = (-s * cb, -sb, c * cb)
    return Mat3(m: (cr * m0.0 - sr * m1.0, cr * m0.1 - sr * m1.1, cr * m0.2 - sr * m1.2,
                    sr * m0.0 + cr * m1.0, sr * m0.1 + cr * m1.1, sr * m0.2 + cr * m1.2,
                    m2.0, m2.1, m2.2))
}

// ── shapes ──────────────────────────────────────────────────────────────────────

func box(_ cx: Double, _ cy: Double, _ cz: Double, _ hx: Double, _ hy: Double, _ hz: Double, _ r: Double = 0.7) -> SDF {
    { x, y, z in
        let qx = abs(x - cx) - hx + r, qy = abs(y - cy) - hy + r, qz = abs(z - cz) - hz + r
        return jhypot(jmax(qx, 0), jmax(qy, 0), jmax(qz, 0)) + jmin(jmax(jmax(qx, qy), qz), 0) - r
    }
}

/// a rod from a to b; a second radius tapers it
func rod(_ ax: Double, _ ay: Double, _ az: Double, _ bx: Double, _ by: Double, _ bz: Double, _ r: Double, _ r2: Double? = nil) -> SDF {
    let r2 = r2 ?? r, dx = bx - ax, dy = by - ay, dz = bz - az
    return { x, y, z in
        let px = x - ax, py = y - ay, pz = z - az
        let h = jmax(0, jmin(1, (px * dx + py * dy + pz * dz) / (dx * dx + dy * dy + dz * dz)))
        return jhypot(px - dx * h, py - dy * h, pz - dz * h) - (r + (r2 - r) * h)
    }
}

/// a flat plate: a convex outline, corners clockwise on screen, given a thickness
func plate(_ h: Double, _ pts: [(Double, Double)]) -> SDF {
    let edges = pts.indices.map { i -> (Double, Double, Double, Double, Double) in
        let (ax, ay) = pts[i], (bx, by) = pts[(i + 1) % pts.count], ex = bx - ax, ey = by - ay
        return (ax, ay, ex, ey, jhypot(ex, ey))
    }
    return { x, y, z in
        var d = abs(z) - h
        for (ax, ay, ex, ey, len) in edges { d = jmax(d, ((x - ax) * ey - (y - ay) * ex) / len) }
        return d
    }
}

/// a ring facing z
func torus(_ cx: Double, _ cy: Double, _ cz: Double, _ R: Double, _ r: Double) -> SDF {
    { x, y, z in jhypot(jhypot(x - cx, y - cy) - R, z - cz) - r }
}

func lens(_ cx: Double, _ cy: Double, _ cz: Double, _ R: Double, _ h: Double) -> SDF {
    { x, y, z in (jhypot(x - cx, y - cy, (z - cz) * R / h) - R) * h / R }
}

/// A band bent round an upright cylinder behind the picture: `wide` and `high` are its half-size
/// along the surface, `corner` rounds it, and `thick` is how far it stands off.
let WRAP = 14.8
func slab(_ a: Double, _ y: Double, _ wide: Double, _ high: Double, _ corner: Double) -> Double {
    let qx = abs(a) - wide + corner, qy = abs(y) - high + corner
    return jhypot(jmax(qx, 0), jmax(qy, 0)) + jmin(jmax(qx, qy), 0) - corner
}
func wrapped(_ wide: Double, _ high: Double, _ corner: Double, _ thick: Double) -> SDF {
    let w = jmin(wide, WRAP * 1.57), c = jmin(corner, high)
    return { x, y, z in
        jmax(jmax(slab(WRAP * atan2(x, z + WRAP), y, w, high, c), abs(jhypot(x, z + WRAP) - WRAP) - thick), -(z + WRAP))
    }
}

/// a solid, or several, set down somewhere in the prop at its own angle
func place(_ px: Double, _ py: Double, _ pz: Double, _ yaw: Double, _ pitch: Double, _ roll: Double, _ solids: [Solid]) -> [Solid] {
    let m = rotation(yaw, pitch, roll).m
    func own<T>(_ f: @escaping (Double, Double, Double) -> T) -> (Double, Double, Double) -> T {
        { x, y, z in
            let x = x - px, y = y - py, z = z - pz
            return f(m.0 * x + m.3 * y + m.6 * z, m.1 * x + m.4 * y + m.7 * z, m.2 * x + m.5 * y + m.8 * z)
        }
    }
    return solids.map { s in Solid(sdf: own(s.sdf), mat: s.mat, lift: s.lift, paint: s.paint.map { own($0) }) }
}

@inline(__always) func every(_ n: Double, _ step: Double, _ width: Double) -> Bool {
    (n.truncatingRemainder(dividingBy: step) + step).truncatingRemainder(dividingBy: step) < width
}

// ── what is printed on them ─────────────────────────────────────────────────────

func keys(_ x: Double, _ y: Double, _ z: Double) -> (Material, Int)? {
    y > -1.6 ? nil
        : abs(x) < 9.5 && z > -6.2 && z < 1 ? (.steel, every(x, 1.9, 0.5) || every(z, 1.9, 0.5) ? -2 : -4)
        : abs(x) < 3.2 && z > 2.6 && z < 6.2 ? (.steel, -1) : nil
}
func globe(_ x: Double, _ y: Double, _ z: Double) -> (Material, Int)? {
    if z < 0.3 || abs(x) > 9.6 || y > -1.4 || y < -14.8 { return nil }
    let gy = y + 8.2, r = jhypot(x, gy)
    return abs(r - 4.4) < 0.65 || (r < 4.4 && (abs(gy) < 0.5 || abs(jhypot(x * 2.2, gy) - 4.4) < 0.9)) ? (.paper, 2) : (.glass, -1)
}
func leaf(_ x: Double, _ y: Double, _ z: Double) -> (Material, Int)? {
    y < -1.6 && abs(z) < 4.8 && abs(x) > 1.8 && abs(x) < 12 && every(z + 5, 2.3, 0.9) ? (.paper, -4) : nil
}
func month(_ x: Double, _ y: Double, _ z: Double) -> (Material, Int)? {
    z < 0.4 ? nil
        : y < -16.2 ? (.blue, 0)
        : x > 0.1 && x < 4.4 && y > -11 && y < -6.6 ? (.mauve, 0)
        : y > -15.6 && (every(x + 9, 4.5, 0.8) || every(y + 15.4, 4.4, 0.8)) ? (.paper, -4) : nil
}

func makeProps() -> [String: PropSpec] {
    let hammer = PropSpec(reach: 22, yaw: 40, pitch: 12, [
        Solid(sdf: rod(0, 4, 0, 0, -12, 0, 1.6), mat: .wood),
        Solid(sdf: box(0, -14.5, 0, 7, 3.3, 3.3, 1.1), mat: .steel),
        Solid(sdf: box(-6.2, -14.5, 0, 1.4, 4, 4, 0.9), mat: .steel),
    ])
    // a carpenter's square: a plate with a window cut in it and a fence down one leg
    let outer = plate(0.7, [(-4, 3), (-4, -15), (14, 3)]), window = plate(2, [(-0.5, -0.5), (-0.5, -7), (6, -0.5)])
    let square = PropSpec(reach: 22, yaw: 28, pitch: 8, [
        Solid(sdf: { x, y, z in jmax(outer(x, y, z), -window(x, y, z)) }, mat: .steel, lift: 1,
              paint: { x, y, _ in y > 1.4 && every(x + 4, 2, 0.7) ? (.steel, -3) : nil }),
        Solid(sdf: box(-4, -6, 0, 1.1, 9.4, 1.8, 0.6), mat: .steel, lift: -1),
    ])
    // a cordless drill, pointing to our left and a little towards us
    let drill = PropSpec(reach: 32, scale: 1.35, yaw: 30, pitch: 10, angle: 0, snap: true, [
        Solid(sdf: rod(-12, -7, 0, -19, -7, 0, 0.7), mat: .steel),
        Solid(sdf: rod(-8, -7, 0, -12, -7, 0, 2.7, 1.7), mat: .ink, lift: 3),
        Solid(sdf: rod(-6, -7, 0, 4, -7, 0, 3.5), mat: .yellow, paint: { x, _, _ in x > 1 && x < 3 ? (.ink, 3) : nil }),
        Solid(sdf: rod(1.5, -4, 0, 3, 4, 0, 2.3), mat: .ink, lift: 3),
        Solid(sdf: box(-0.6, -2.4, 0, 1.2, 1.4, 1, 0.5), mat: .red),
        Solid(sdf: box(3.5, 6.8, 0, 5.2, 2.3, 3.6, 1), mat: .ink, lift: 2, paint: { _, y, _ in y < 5.6 ? (.yellow, 0) : nil }),
    ])
    // held over the tip that grips it, and at the angle of writing whatever the arm is doing
    let pencil = PropSpec(reach: 12, angle: 148, over: true, [
        Solid(sdf: rod(0, 6.5, 0, 0, 7.5, 0, 1.6), mat: .pink),
        Solid(sdf: rod(0, 4.6, 0, 0, 5.4, 0, 1.7), mat: .steel),
        Solid(sdf: rod(0, 3.5, 0, 0, -5, 0, 1.6), mat: .yellow),
        Solid(sdf: rod(0, -5.4, 0, 0, -9, 0, 1.5, 0.2), mat: .wood, paint: { _, y, _ in y < -7.8 ? (.ink, 1) : nil }),
    ])
    let magnifier = PropSpec(reach: 22, yaw: 38, [
        Solid(sdf: rod(0, 4, 0, 0, -5.5, 0, 1.6), mat: .wood),
        Solid(sdf: torus(0, -12, 0, 6, 1.3), mat: .gold),
        Solid(sdf: lens(0, -12, 0, 5.6, 1.1), mat: .glass, lift: 1, paint: { x, y, _ in x < -1 && y < -13 && x + y > -19.5 ? (.glass, 3) : nil }),
    ])
    // open on the shelf, its leaves rising a little to their outer edges
    let book = PropSpec(reach: 20, pitch: 38, [Solid(sdf: box(0, -0.5, 0, 15, 0.6, 6.6, 0.4), mat: .mauve)]
        + place(0, -1, 0, 0, 0, 4, [Solid(sdf: box(-7, -1, 0, 7, 1, 5.8, 0.8), mat: .paper, lift: 1, paint: leaf)])
        + place(0, -1, 0, 0, 0, -4, [Solid(sdf: box(7, -1, 0, 7, 1, 5.8, 0.8), mat: .paper, lift: 1, paint: leaf)]))
    let mat = PropSpec(reach: 40, pitch: 32, [
        Solid(sdf: box(-2, -0.7, 0, 33, 0.7, 7, 0.5), mat: .mauve,
              paint: { x, y, z in y < -1.2 && abs(x + 2) < 31 && abs(z) < 5.2 && !(abs(x + 2) < 29.6 && abs(z) < 3.8) ? (.mauve, 2) : nil }),
        Solid(sdf: rod(33, -2.5, -6, 33, -2.5, 6, 2.5), mat: .mauve, lift: -1),
    ])
    let calendar = PropSpec(reach: 32, scale: 1.2, yaw: -32, pitch: 14,
        place(0, 0, 0, 0, -12, 0, [Solid(sdf: box(0, -10.5, 0, 9, 10.5, 0.8, 0.6), mat: .paper, lift: 1, paint: month)]
            + [-6.75, -2.25, 2.25, 6.75].map { x in Solid(sdf: rod(x, -22.4, 0.6, x, -19.4, 0.6, 0.9), mat: .gold) })
        + place(0, -20, -6, 0, 20, 0, [Solid(sdf: box(0, 10.5, 0, 7, 10.5, 0.5, 0.4), mat: .wood, lift: -1)]))
    // side-on to us, open towards him: the keys and the screen are both ours to see
    let laptop = PropSpec(reach: 34, scale: 1.45, yaw: 58, pitch: 26,
        [Solid(sdf: box(0, -0.9, 0, 11, 0.9, 7.5, 0.6), mat: .steel, lift: 1, paint: keys)]
        + place(0, -1.8, -7.5, 0, -14, 0, [Solid(sdf: box(0, -8, 0, 11, 8, 0.6, 0.6), mat: .steel, paint: globe)]))
    // safety goggles: one visor bent round the front of his head, and a strap that runs on round it out of sight
    let goggles = PropSpec(reach: 17, [
        Solid(sdf: wrapped(40, 1.7, 1.2, 0.6), mat: .ink, lift: 4),
        Solid(sdf: wrapped(13.2, 5.4, 3.6, 1.5), mat: .steel, lift: 1, paint: { x, y, z in
            let a = WRAP * atan2(x, z + WRAP)
            return slab(a, y, 11.8, 4, 2.6) < 0 ? (.glass, abs(a + y * 0.9 + 3) < 0.9 ? 3 : 0) : nil
        }),
    ])
    return ["hammer": hammer, "square": square, "drill": drill, "pencil": pencil, "magnifier": magnifier,
            "book": book, "mat": mat, "calendar": calendar, "laptop": laptop, "goggles": goggles]
}

// ── the sign ────────────────────────────────────────────────────────────────────

/// A host's own typeface for a sign's words: a byte of cover a pixel.
public struct Lettering: Sendable {
    public var width: Int, height: Int, alpha: [UInt8]
    public init(width: Int, height: Int, alpha: [UInt8]) { self.width = width; self.height = height; self.alpha = alpha }
}

// five by seven, a row to a number
private let FONT: [Character: [Int]] = [
    "A": [14, 17, 17, 31, 17, 17, 17], "B": [30, 17, 17, 30, 17, 17, 30], "C": [14, 17, 16, 16, 16, 17, 14], "D": [30, 17, 17, 17, 17, 17, 30],
    "E": [31, 16, 16, 30, 16, 16, 31], "F": [31, 16, 16, 30, 16, 16, 16], "G": [14, 17, 16, 23, 17, 17, 15], "H": [17, 17, 17, 31, 17, 17, 17],
    "I": [14, 4, 4, 4, 4, 4, 14], "J": [7, 2, 2, 2, 2, 18, 12], "K": [17, 18, 20, 24, 20, 18, 17], "L": [16, 16, 16, 16, 16, 16, 31],
    "M": [17, 27, 21, 21, 17, 17, 17], "N": [17, 25, 21, 19, 17, 17, 17], "O": [14, 17, 17, 17, 17, 17, 14], "P": [30, 17, 17, 30, 16, 16, 16],
    "Q": [14, 17, 17, 17, 21, 18, 13], "R": [30, 17, 17, 30, 20, 18, 17], "S": [15, 16, 16, 14, 1, 1, 30], "T": [31, 4, 4, 4, 4, 4, 4],
    "U": [17, 17, 17, 17, 17, 17, 14], "V": [17, 17, 17, 17, 17, 10, 4], "W": [17, 17, 17, 21, 21, 21, 10], "X": [17, 17, 10, 4, 10, 17, 17],
    "Y": [17, 17, 10, 4, 4, 4, 4], "Z": [31, 1, 2, 4, 8, 16, 31], "0": [14, 17, 19, 21, 25, 17, 14], "1": [4, 12, 4, 4, 4, 4, 14],
    "2": [14, 17, 1, 2, 4, 8, 31], "3": [31, 2, 4, 2, 1, 17, 14], "4": [2, 6, 10, 18, 31, 2, 2], "5": [31, 16, 30, 1, 1, 17, 14],
    "6": [6, 8, 16, 30, 17, 17, 14], "7": [31, 1, 2, 4, 8, 8, 8], "8": [14, 17, 17, 14, 17, 17, 14], "9": [14, 17, 17, 15, 1, 2, 12],
    ".": [0, 0, 0, 0, 0, 12, 12], ",": [0, 0, 0, 0, 12, 4, 8], "!": [4, 4, 4, 4, 4, 0, 4], "?": [14, 17, 1, 2, 4, 0, 4], "-": [0, 0, 0, 31, 0, 0, 0],
    "'": [4, 4, 8, 0, 0, 0, 0], ":": [0, 12, 12, 0, 12, 12, 0], "/": [0, 1, 2, 4, 8, 16, 0], "+": [0, 4, 4, 31, 4, 4, 0], "%": [24, 25, 2, 4, 8, 19, 3],
]
// Stretched to seven by ten by repeating the columns and rows that hold no crossbar, so every stroke
// stays one pixel thick; N and M, whose diagonals do not survive the stretch, are drawn at the size.
private let COLS = [0, 1, 1, 2, 3, 3, 4], ROWS = [0, 1, 1, 2, 3, 4, 4, 5, 5, 6]
private let DRAWN: [Character: [String]] = [
    "N": ["1000001", "1100001", "1010001", "1010001", "1001001", "1001001", "1000101", "1000101", "1000011", "1000001"],
    "M": ["1000001", "1100011", "1010101", "1010101", "1001001", "1001001", "1000001", "1000001", "1000001", "1000001"],
]
/// seventy bits a glyph, ten rows of seven, by UTF-16 unit; absent where the font has no letter
let GLYPHS: [UInt16: [[Bool]]] = {
    var out: [UInt16: [[Bool]]] = [:]
    for (ch, rows) in FONT { out[ch.utf16.first!] = ROWS.map { y in COLS.map { x in (rows[y] >> (4 - x) & 1) == 1 } } }
    for (ch, rows) in DRAWN { out[ch.utf16.first!] = rows.map { $0.map { $0 == "1" } } }
    return out
}()

private func jsTrim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

/// The sign: a board on a stick, as big as its words, written in pixels rather than design units.
/// It faces us square and stands upright whatever the arm does. `stick` is how far the board stands
/// above the grip, and `room` how far the picture runs to the right of it.
func makeSign(_ text: String, stick: Double, room: Double, lettering: ((String) -> Lettering?)?) -> PropSpec {
    let upper = jsTrim(text.uppercased()), words = upper.isEmpty ? "..." : upper
    // lines by UTF-16 unit, as the JavaScript counts them
    var lines: [[UInt16]] = []
    for word in words.split(whereSeparator: { $0.isWhitespace }).map({ Array(String($0).utf16) }) {
        if let last = lines.last, last.count + 1 + word.count <= 11 { lines[lines.count - 1] = last + [32] + word }
        else { lines.append(Array(word.prefix(11))) }
    }
    lines = Array(lines.prefix(3))
    let trimmed = jsTrim(text), set = lettering?(trimmed.isEmpty ? "..." : trimmed)
    let cols = Double(lines.map(\.count).max() ?? 0)
    let hw = ((set.map { Double($0.width) } ?? cols * 8 - 1) / 2).rounded(.up) + 7
    let hh = (set.map { Double($0.height) } ?? Double(lines.count) * 13 - 3) / 2 + 7
    let cx = jmin(0, (room - hw).rounded(.down)), cy = -stick - hh, top = cy - hh + 7
    let ink: (Double, Double) -> Double = { x, y in
        if let set {
            let u = Int((x - cx + Double(set.width) / 2).rounded(.down)), v = Int((y - top).rounded(.down))
            return u >= 0 && u < set.width && v >= 0 && v < set.height ? Double(set.alpha[v * set.width + u]) / 255 : 0
        }
        let row = Int(((y - top) / 13).rounded(.down)), v = Int((y - top).rounded(.down)) - row * 13
        guard row >= 0, row < lines.count, v <= 9 else { return 0 }
        let line = lines[row], u = Int((x - cx + (Double(line.count) * 8 - 1) / 2 + 0.5).rounded(.down))
        guard u >= 0, u % 8 < 7, u / 8 < line.count, let g = GLYPHS[line[u / 8]] else { return 0 }
        return g[v][u % 8] ? 1 : 0
    }
    // the board faces us flat, so it lights to the ramp's seventh tone and the lift picks the cover's
    let face: Paint = { x, y, z in
        z < 2.2 ? (.wood, -1)
            : abs(x - cx) > hw - 3 || abs(y - cy) > hh - 3 ? (.wood, 0)
            : (.letter, Int(jround((1 - ink(x, y)) * 9)) - 6)
    }
    return PropSpec(reach: (jhypot(hw - cx, stick + 2 * hh)).rounded(.up) + 2, angle: 0, snap: true, pixels: true, [
        Solid(sdf: rod(0, 9, 0, 0, cy, 0, 1.8), mat: .wood),
        Solid(sdf: box(cx, cy, 1.8, hw, hh, 1.6, 1.4), mat: .paper, paint: face),
    ])
}

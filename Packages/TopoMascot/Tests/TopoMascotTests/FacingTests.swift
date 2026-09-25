import Testing
import TopoMascot

/// Facing, as `topo-mascot-engine/faces.mjs` holds it in the JavaScript: the mirror is a reflection about
/// his body's axis and not a move, the sign stays inside the picture and its lettering reads the same both
/// ways, and a facing asked for mid-stroll, mid-yoga, mid-sign or mid-work is held until he is home and
/// taken once he is.
@Suite struct FacingTests {
    static let dt = 1.0 / 30, W = Topo.width, H = Topo.height, BX = Int(Topo.bodyX)

    /// One engine with a random of its own, stepped and drawn a frame at a time.
    final class Run {
        var rng: Mulberry32
        lazy var topo = Topo(random: { [unowned self] in self.rng.next() })
        var rgba = [UInt8](repeating: 0, count: Topo.width * Topo.height * 4)
        init(seed: UInt32) { rng = Mulberry32(seed: seed) }
        @discardableResult func step(_ input: TopoInput) -> [UInt8] { topo.update(FacingTests.dt, input); topo.draw(&rgba); return rgba }
    }

    /// A pixel as a value, every clear pixel alike (a clear pixel has only its alpha written).
    static func px(_ rgba: [UInt8], _ x: Int, _ y: Int) -> UInt32 {
        guard x >= 0, x < W else { return 1 << 31 }
        let p = (y * W + x) * 4
        return rgba[p + 3] == 0 ? 1 << 31 : UInt32(rgba[p]) << 16 | UInt32(rgba[p + 1]) << 8 | UInt32(rgba[p + 2])
    }
    static func same(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        for y in 0..<H { for x in 0..<W where px(a, x, y) != px(b, x, y) { return false } }
        return true
    }
    /// b is a reflected about the body's axis: column x of one is column 2·BX − 1 − x of the other, and
    /// what would come from outside the picture is clear.
    static func reflected(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        for y in 0..<H { for x in 0..<W where px(b, x, y) != px(a, 2 * BX - 1 - x, y) { return false } }
        return true
    }
    static func settled(_ input: TopoInput, facing: String, frames: Int = 66) -> Run {
        let run = Run(seed: 1)
        var input = input
        input.facing = facing
        run.step(TopoInput(activity: "idle", facing: facing))          // he turns at rest at home, which a new one is
        for _ in 0..<frames { run.step(input) }
        return run
    }

    @Test func facingLeftIsTheDrawingWithNoFacingGiven() {
        let a = Run(seed: 7), b = Run(seed: 7)
        for f in 0..<900 {
            let activity = f < 300 ? "idle" : f < 600 ? "sign" : "searching"
            let pa = a.step(TopoInput(activity: activity, corner: -33)), pb = b.step(TopoInput(activity: activity, corner: -33, facing: "left"))
            #expect(Self.same(pa, pb), "frame \(f)")
            if !Self.same(pa, pb) { return }
        }
    }

    @Test(arguments: ["haiku", "sonnet", "opus", "fable"])
    func theMirroredIdleFrameIsTheReflectionAboutTheBodysAxis(_ model: String) {
        let left = Self.settled(TopoInput(model: model, activity: "idle"), facing: "left")
        let right = Self.settled(TopoInput(model: model, activity: "idle"), facing: "right")
        #expect(right.topo.facing == "right")
        #expect(Self.reflected(left.rgba, right.rgba), "not the reflection about x = \(Self.BX)")
        #expect(!Self.same(left.rgba, right.rgba), "the same picture both ways")
    }

    /// The letters are the letter ramp's darkest tone, the board's face its lightest.
    static let ink: UInt32 = 0x1c1814, face: UInt32 = 0xf0ead8
    static func pixels(_ rgba: [UInt8], _ colour: UInt32) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for y in 0..<H { for x in 0..<W where px(rgba, x, y) == colour { out.append((x, y)) } }
        return out
    }

    @Test(arguments: [("updating memory", "sonnet"), ("hi", "sonnet"), ("reading twelve files at once", "sonnet"),
                      ("mmmmmmmmmmm wwwwwwwwwww nnnnnnnnnnn", "fable"), ("Straße? 100%", "opus")])
    func theSignIsInsideAndItsLetteringIsNotMirrored(_ sign: String, _ model: String) {
        let left = Self.settled(TopoInput(model: model, activity: "sign", sign: sign), facing: "left")
        let right = Self.settled(TopoInput(model: model, activity: "sign", sign: sign), facing: "right")
        let inkL = Self.pixels(left.rgba, Self.ink), inkR = Self.pixels(right.rgba, Self.ink)
        #expect(!inkL.isEmpty && inkL.count == inkR.count, "\(inkL.count) letter pixels facing left, \(inkR.count) facing right")
        #expect(Self.pixels(left.rgba, Self.face).count == Self.pixels(right.rgba, Self.face).count, "the board's face clipped")
        var margin = 0
        for y in 0..<Self.H { for x in 0..<Self.W where (x < 2 || x > Self.W - 3) && Self.px(right.rgba, x, y) != 1 << 31 { margin += 1 } }
        #expect(margin == 0, "\(margin) pixels drawn in the margin facing right")
        // the same rows of letters, moved and not mirrored
        let dx = inkR.map(\.0).min()! - inkL.map(\.0).min()!
        let key = { (list: [(Int, Int)]) in Set(list.map { "\($0.0),\($0.1)" }) }
        #expect(key(inkL.map { ($0.0 + dx, $0.1) }) == key(inkR), "the lettering facing right is not the lettering facing left, moved")
        // held out on his other side
        let middle = { (list: [(Int, Int)]) in Double(list.map(\.0).reduce(0, +)) / Double(list.count) }
        #expect(middle(inkL) > Double(Self.BX) && middle(inkR) < Double(Self.BX), "not held out on the other side")
    }

    /// Two engines on the same seed and the same inputs, one asked to face right in the middle of the part
    /// named. Until it is home and settled it draws what the other draws, frame for frame; once it is, it
    /// draws the other's frame reflected, and it gets there within two seconds of being home.
    @Test(arguments: ["mid-stroll", "mid-yoga", "mid-sign", "mid-work"])
    func aFacingAskedMidwayIsTakenAtHome(_ part: String) throws {
        var seen = 0
        let (seed, seconds): (UInt32, Double) = switch part { case "mid-stroll": (50, 45); case "mid-yoga": (1, 40); default: (1, 9) }
        let into: (Topo) -> Bool = switch part {
        case "mid-stroll": { if $0.outing == "corner" && $0.poseName == "walk" { seen += 1 }; return seen > 4 }
        case "mid-yoga": { if $0.poseName == "yoga" { seen += 1 }; return seen > 16 }
        case "mid-sign": { $0.poseName == "sign" }
        default: { $0.poseName == "building" }
        }
        let script: (Double) -> TopoInput = switch part {
        case "mid-sign": { TopoInput(activity: $0 < 5 ? "sign" : "idle", sign: "updating memory") }
        case "mid-work": { TopoInput(activity: $0 < 5 ? "building" : "idle") }
        default: { _ in TopoInput(activity: "idle", corner: -33) }
        }
        let plain = Run(seed: seed), asked = Run(seed: seed)
        var at: Int?, home: Int?, turned: Int?
        for f in 0..<Int(seconds * 30) {
            var input = script(Double(f) * Self.dt)
            let a = plain.step(input)
            if at == nil && into(asked.topo) { at = f }
            if at != nil { input.facing = "right" }
            let b = asked.step(input)
            guard let at else { continue }
            let atHome = asked.topo.poseName == "shelf" && asked.topo.x == 0
            if home == nil && atHome && f > at { home = f }
            if turned == nil {
                if Self.same(a, b) { continue }
                turned = f
                #expect(atHome && home != nil, "\(part): the picture flipped at frame \(f), before he was home")
                #expect(Self.reflected(a, b), "\(part): the first frame that differs is not the reflection")
            } else if !Self.reflected(a, b) {
                Issue.record("\(part): frame \(f), after the turn, is not the reflection"); return
            }
        }
        _ = try #require(at, "\(part) never reached")
        let back = try #require(home, "\(part): never home")
        let flip = try #require(turned, "\(part): never turned, home at frame \(back)")
        #expect(flip - back <= 60, "\(part): home at frame \(back), turned only at \(flip)")
        #expect(asked.topo.facing == "right")
    }
}

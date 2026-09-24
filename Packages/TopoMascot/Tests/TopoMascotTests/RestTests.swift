import Testing
import TopoMascot

/// The idle cycle, as `topo-mascot-engine/rest.mjs` holds it in the JavaScript: a long run at rest
/// under a seeded random, counted, and work asked for in the middle of each part of an excursion.
/// Update only, no drawing, so hours of him take seconds.
@Suite struct RestTests {
    static let dt = 0.25, slack = 2 * dt          // a pose is seen a frame late at most, at either end

    /// One stretch of a pose: which, and from when to when.
    struct Span { let pose: String; let from: Double; var to: Double; var took: Double { to - from } }

    /// A run of him, frame by frame, keeping every stretch of one pose.
    static func run(seed: UInt32, seconds: Double, _ script: (Double, Topo) -> String) -> [Span] {
        var rng = Mulberry32(seed: seed)
        let topo = Topo(random: { rng.next() })
        var spans: [Span] = [], t = 0.0
        while t < seconds {
            topo.update(dt, TopoInput(activity: script(t, topo), corner: -33))
            t += dt
            if spans.last?.pose == topo.poseName { spans[spans.count - 1].to = t } else { spans.append(Span(pose: topo.poseName, from: t, to: t)) }
        }
        return spans
    }

    static func within(_ v: Double, _ r: (Double, Double)) -> Bool { v >= r.0 - slack && v <= r.1 + slack }

    @Test func tenCornersToEveryYogaAndEveryWaitInItsRange() {
        let spans = Self.run(seed: 1, seconds: 1_000_000) { _, _ in "idle" }
        let corners = spans.filter { $0.pose == "corner" }, yogas = spans.filter { $0.pose == "yoga" }
        // every stretch on the shelf ends in an excursion, except the one the run stops in
        let shelves = spans.dropLast().filter { $0.pose == "shelf" }
        let ratio = Double(corners.count) / Double(yogas.count)
        #expect(abs(ratio - 1 / Topo.yogaPerCorner) <= 1, "\(corners.count) corners to \(yogas.count) yogas")
        #expect(Self.within(shelves[0].took, (Topo.firstRest, Topo.firstRest)), "first wait \(shelves[0].took)")
        #expect(shelves.dropFirst().allSatisfy { Self.within($0.took, Topo.rest) })
        #expect(corners.allSatisfy { Self.within($0.took, Topo.cornerStay) })
        #expect(yogas.allSatisfy { Self.within($0.took, Topo.yogaStay) })
    }

    /// Idle until he is into the part named, then five seconds of work, then idle again: he comes
    /// home, wears the work, and back at rest waits a whole fresh shelf wait before going anywhere.
    @Test(arguments: ["mid-stroll", "mid-corner", "mid-yoga"])
    func workAbandonsTheExcursion(_ part: String) throws {
        var seen = 0, asked: Double?
        let into: (Topo) -> Bool = switch part {
        case "mid-stroll": { $0.outing == "corner" && $0.poseName == "walk" }
        case "mid-corner": { $0.poseName == "corner" }
        default: { $0.poseName == "yoga" }
        }
        let enough = ["mid-stroll": 4, "mid-corner": 12, "mid-yoga": 16][part]!
        let spans = Self.run(seed: 3, seconds: 600) { t, topo in
            if asked == nil, into(topo) { seen += 1; if seen > enough { asked = t } }
            if let a = asked, t < a + 5 { return "searching" }
            return "idle"
        }
        let at = try #require(asked, "\(part) never reached")
        let after = spans.filter { $0.to > at }
        let work = try #require(after.first { $0.pose == "searching" }, "\(part): never wore the work")
        #expect(work.to >= at + 5 - Self.slack, "\(part): did not come home and wear the work")
        let home = at + 5
        let next = try #require(after.first { $0.from > home && $0.pose != "shelf" }, "\(part): never went out again")
        #expect(Self.within(next.from - home, Topo.rest), "\(part): out again \(next.from - home) s after the work")
    }

    /// Yoga is the idle cycle's: a host asking for it gets him sitting on the shelf.
    @Test func yogaAskedForIsNotTaken() {
        let spans = Self.run(seed: 5, seconds: 120) { _, _ in "yoga" }
        #expect(spans.allSatisfy { $0.pose == "shelf" }, "\(spans.map(\.pose))")
    }
}

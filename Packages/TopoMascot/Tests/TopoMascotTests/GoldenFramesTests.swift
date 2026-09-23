import CryptoKit
import Foundation
import Testing
import TopoMascot

/// The engine against the pinned JavaScript it was ported from, frame for frame.
///
/// `golden.json` is what the reference rendered, made in samdu/experiments by
/// `topo-mascot-swift/oracle/golden.mjs` from `topo-mascot-engine/topo-engine.js` at e93fe1f: the
/// eighteen cells of the engine's own sheet — the four heads idle, the four loads idle, and every
/// pose but the shelf he rests on (front, walk, corner, yoga, sign, building, writing, calendar,
/// searching, thinking) — each at frames 10, 40 and 65 of the 2.2 s it settles for, which catches
/// the arms on their way and settled; and two films of what the app actually hands over, the four
/// model names one a second and four token counts across the load thresholds while writing, at
/// four frames each. Each is the SHA-256 of the whole buffer after that frame's draw, the buffer
/// carried from one frame to the next as the host carries it.
///
/// A frame of the port that differs from the reference by one pixel fails here. The stroll (idle
/// for eight seconds before he first walks) and the sign's words beyond its default are not in
/// the set, to keep the suite to seconds; the experiment's own oracle covers them on 5,880 frames.
@Suite struct GoldenFramesTests {
    struct Golden: Decodable {
        let width: Int, height: Int
        let scenarios: [Scenario]
    }

    struct Scenario: Decodable {
        let name: String, fps: Double, seed: UInt32, frames: Int
        let script: [Step]
        let digests: [String: String]
    }

    struct Step: Decodable {
        let at: Double, input: TopoInput
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            at = try c.decode(Double.self)
            input = try c.decode(TopoInput.self)
        }
    }

    static let golden: Golden = {
        let url = Bundle.module.url(forResource: "golden", withExtension: "json")!
        return try! JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }()

    @Test func theSetIsTheOneTheReferenceRendered() {
        #expect(Self.golden.width == Topo.width && Self.golden.height == Topo.height)
        #expect(Self.golden.scenarios.count == 20)
        #expect(Self.golden.scenarios.reduce(0) { $0 + $1.digests.count } == 62)
    }

    @Test(arguments: golden.scenarios.map(\.name))
    func everyGoldenFrameIsTheReferencesPixelForPixel(_ name: String) throws {
        let scenario = try #require(Self.golden.scenarios.first { $0.name == name })
        // topo-oracle's loop exactly: seeded, one buffer, the step in force at the frame's start.
        var rng = Mulberry32(seed: scenario.seed)
        let topo = Topo(random: { rng.next() })
        var rgba = [UInt8](repeating: 0, count: Topo.width * Topo.height * 4)
        var now = 0.0
        var checked = 0
        for frame in 0..<scenario.frames {
            let dt = 1 / scenario.fps
            let step = scenario.script.last { $0.at <= now }?.input ?? TopoInput()
            topo.update(dt, step)
            topo.draw(&rgba)
            if let want = scenario.digests[String(frame)] {
                let got = SHA256.hash(data: Data(rgba)).map { String(format: "%02x", $0) }.joined()
                #expect(got == want, "\(name) frame \(frame) differs from the reference")
                checked += 1
            }
            now += dt
        }
        #expect(checked == scenario.digests.count, "a golden frame lies past the scenario's end")
    }
}

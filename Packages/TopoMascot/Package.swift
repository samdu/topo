// swift-tools-version: 6.0
import PackageDescription

// Topo the octopus, drawn in pixels from the agent's state: the model picks his head, the
// context's fill his colour and face, the tool in use his pose. The engine is Sam's own, from
// samdu/experiments `topo-mascot-swift` at 534556a (the Swift port of `topo-mascot-engine`'s
// JavaScript at f139be1), copied here unchanged with its idle-cycle and facing tests (RestTests.swift,
// FacingTests.swift); the suite holds it to golden frames that JavaScript rendered
// (Tests/TopoMascotTests/golden.json, made by that experiment's `oracle/golden.mjs`). Foundation
// only; the iOS app draws him on the composer's glass.
let package = Package(
    name: "TopoMascot",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TopoMascot", targets: ["TopoMascot"]),
    ],
    targets: [
        // Optimised in every configuration: at -Onone a frame costs three times what it does at -O
        // (6.6 ms mean against 2.0 in a simulator), and a debug build is what a device run is.
        .target(name: "TopoMascot", swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        .testTarget(name: "TopoMascotTests", dependencies: ["TopoMascot"],
                    resources: [.copy("golden.json")]),
    ]
)

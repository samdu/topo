// swift-tools-version: 6.0
import PackageDescription

// The guest: the iSH kernel and emulator of OpenMinis/ish-arm64 (TopoIsh, built from source by
// scripts/build-ish.sh into Frameworks/, which is not committed), and the Swift over it. iOS
// only — the framework has a device slice and an arm64 simulator slice and nothing else — so
// `swift test` on a Mac cannot run this package: its tests are the TopoUserlandTests bundle in
// project.yml, which the Topo scheme's test action runs on the simulator.
let package = Package(
    name: "TopoUserland",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "TopoUserland", targets: ["TopoUserland"]),
    ],
    targets: [
        .binaryTarget(name: "TopoIsh", path: "Frameworks/TopoIsh.xcframework"),
        .target(name: "TopoUserland", dependencies: ["TopoIsh"]),
    ]
)

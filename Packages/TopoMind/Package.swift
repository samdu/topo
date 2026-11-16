// swift-tools-version: 6.0
import PackageDescription

// The mind on a Mac: a `Brain` that answers through a resident native Claude Code process, and
// the hub's answering loop over it (`HubMind`). macOS only, since it spawns `claude` and holds its
// process group.
let package = Package(
    name: "TopoMind",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TopoMind", targets: ["TopoMind"]),
    ],
    dependencies: [
        .package(path: "../TopoCore"),
        .package(path: "../TopoTurn"),
        .package(path: "../TopoAuth"),
    ],
    targets: [
        .target(name: "TopoMind", dependencies: [
            .product(name: "TopoCore", package: "TopoCore"),
            .product(name: "TopoTurn", package: "TopoTurn"),
            .product(name: "TopoAuth", package: "TopoAuth"),
        ]),
        .testTarget(name: "TopoMindTests", dependencies: [
            "TopoMind",
            .product(name: "TopoCoreTesting", package: "TopoCore"),
        ], resources: [.copy("Fixtures")]),
    ]
)

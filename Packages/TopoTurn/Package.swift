// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TopoTurn",
    platforms: [.macOS(.v14), .iOS(.v17), .watchOS(.v10), .tvOS(.v17)],
    products: [
        .library(name: "TopoTurn", targets: ["TopoTurn"]),
    ],
    dependencies: [
        .package(path: "../TopoCore"),
        .package(path: "../TopoAuth"),
    ],
    targets: [
        .target(name: "TopoTurn", dependencies: [
            .product(name: "TopoCore", package: "TopoCore"),
            .product(name: "TopoAuth", package: "TopoAuth"),
        ]),
        .testTarget(name: "TopoTurnTests", dependencies: [
            "TopoTurn",
            .product(name: "TopoCoreTesting", package: "TopoCore"),
        ]),
    ]
)

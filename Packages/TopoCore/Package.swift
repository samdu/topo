// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TopoCore",
    platforms: [.macOS(.v14), .iOS(.v17), .watchOS(.v10), .tvOS(.v17)],
    products: [
        .library(name: "TopoCore", targets: ["TopoCore"]),
        .library(name: "TopoCoreTesting", targets: ["TopoCoreTesting"]),
    ],
    targets: [
        .target(name: "TopoCore"),
        .target(name: "TopoCoreTesting", dependencies: ["TopoCore"]),
        .testTarget(name: "TopoCoreTests", dependencies: ["TopoCore", "TopoCoreTesting"]),
    ]
)

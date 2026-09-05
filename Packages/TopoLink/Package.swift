// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TopoLink",
    platforms: [.macOS(.v14), .iOS(.v17), .watchOS(.v10), .tvOS(.v17)],
    products: [
        .library(name: "TopoLink", targets: ["TopoLink"]),
    ],
    dependencies: [
        .package(path: "../TopoCore"),
    ],
    targets: [
        .target(name: "TopoLink", dependencies: ["TopoCore"]),
        .testTarget(name: "TopoLinkTests", dependencies: ["TopoLink", "TopoCore", .product(name: "TopoCoreTesting", package: "TopoCore")]),
    ]
)

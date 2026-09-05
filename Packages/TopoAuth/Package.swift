// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TopoAuth",
    platforms: [.macOS(.v14), .iOS(.v17), .watchOS(.v10), .tvOS(.v17)],
    products: [
        .library(name: "TopoAuth", targets: ["TopoAuth"]),
    ],
    targets: [
        .target(name: "TopoAuth"),
        .testTarget(name: "TopoAuthTests", dependencies: ["TopoAuth"]),
    ]
)

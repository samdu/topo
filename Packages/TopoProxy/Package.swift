// swift-tools-version: 6.0
import PackageDescription

// The loopback relay between Claude Code in the guest and api.anthropic.com: plain HTTP in on
// 127.0.0.1, TLS out through URLSession. It carries the guest's own credential and adds none.
let package = Package(
    name: "TopoProxy",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TopoProxy", targets: ["TopoProxy"]),
    ],
    dependencies: [
        .package(path: "../TopoAuth"),
    ],
    targets: [
        .target(name: "TopoProxy", dependencies: ["TopoAuth"]),
        .testTarget(name: "TopoProxyTests", dependencies: ["TopoProxy", "TopoAuth"]),
    ]
)

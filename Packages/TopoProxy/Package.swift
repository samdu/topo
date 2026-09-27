// swift-tools-version: 6.0
import PackageDescription

// The guest's two doors on the app's loopback, sharing one HTTP/1.1 reader: `TopoProxy`, the relay
// between Claude Code in the guest and api.anthropic.com (plain HTTP in on 127.0.0.1, TLS out
// through URLSession, the guest's own credential carried and none added), and `TopoTools`, the
// phone's tool service the guest's `topo` command calls, behind a token only the guest is handed.
let package = Package(
    name: "TopoProxy",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TopoProxy", targets: ["TopoProxy"]),
        .library(name: "TopoTools", targets: ["TopoTools"]),
    ],
    dependencies: [
        .package(path: "../TopoAuth"),
    ],
    targets: [
        .target(name: "TopoProxy", dependencies: ["TopoAuth"]),
        .target(name: "TopoTools", dependencies: ["TopoProxy"]),
        .testTarget(name: "TopoProxyTests", dependencies: ["TopoProxy", "TopoAuth"]),
        .testTarget(name: "TopoToolsTests", dependencies: ["TopoTools", "TopoProxy"]),
    ]
)

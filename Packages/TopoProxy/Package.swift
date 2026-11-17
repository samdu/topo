// swift-tools-version: 6.0
import PackageDescription

// The guest's two doors on the app's loopback: `TopoProxy`, the DNS forwarder the guest's resolver
// asks and the HTTP/1.1 reader (`Wire`), and `TopoTools`, the phone's tool service the guest's `topo`
// command calls over that reader, behind a token only the guest is handed. Nothing here is between
// Claude Code and Anthropic.
let package = Package(
    name: "TopoProxy",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TopoProxy", targets: ["TopoProxy"]),
        .library(name: "TopoTools", targets: ["TopoTools"]),
    ],
    dependencies: [
        .package(path: "../TopoCore"),
    ],
    targets: [
        .target(name: "TopoProxy", dependencies: [.product(name: "TopoCore", package: "TopoCore")]),
        .target(name: "TopoTools", dependencies: ["TopoProxy", .product(name: "TopoCore", package: "TopoCore")],
                resources: [.copy("docc2md.jq")]),
        // What both test targets probe a loopback port with: whether it answers, and a squatter on it.
        .target(name: "TopoProxyTestSupport", path: "Tests/TopoProxyTestSupport"),
        .testTarget(name: "TopoProxyTests", dependencies: ["TopoProxy", "TopoProxyTestSupport"]),
        // `Pages`: two of Apple's own pages as the site answered them (2026-11-12), and one made
        // up of the block shapes no real page at hand has, for the converter's tests.
        .testTarget(name: "TopoToolsTests", dependencies: ["TopoTools", "TopoProxy", "TopoProxyTestSupport"],
                    resources: [.copy("Pages")]),
    ]
)

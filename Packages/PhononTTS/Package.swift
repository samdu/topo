// swift-tools-version:6.0
// Gradium's Swift package for Phonon (gradium-ai/xn-ptts, tag v0.6.0, MIT OR Apache-2.0), vendored:
// `Phonon.swift` as the tag has it and nothing else of its sources, so the package can neither
// play audio of its own (`PhononPlayer`, which builds an `AVAudioEngine`) nor download a model
// (`PhononModels`). `PhononCore.xcframework` is the release's compiled core, which
// scripts/fetch-phonon.sh fetches by checksum into Frameworks/; nothing it fetches is committed.
import PackageDescription

let package = Package(
    name: "PhononTTS",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PhononTTS", targets: ["PhononTTS"]),
    ],
    targets: [
        .binaryTarget(name: "PhononCore", path: "Frameworks/PhononCore.xcframework"),
        .target(
            name: "PhononTTS",
            dependencies: ["PhononCore"],
            linkerSettings: [
                .linkedFramework("CoreML"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Accelerate"),
            ]
        ),
    ]
)

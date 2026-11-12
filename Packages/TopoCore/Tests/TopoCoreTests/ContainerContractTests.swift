#if canImport(CloudKit)
import Foundation
import Testing
import TopoCore

/// The log's container and zone are a contract between bundles (CLAUDE.md, *Invariants*), and
/// `CloudKitRecordDatabase` holds the one copy the Swift that links TopoCore reads. What cannot
/// read it — Womble, which does not link TopoCore, the entitlements and `project.yml` — keeps a
/// copy of its own, and this suite holds each to the constant by reading the file it is in.
@Suite struct ContainerContractTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // TopoCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // TopoCore
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent()

    static let container = CloudKitRecordDatabase.containerIdentifier
    static let zone = CloudKitRecordDatabase.zoneName

    static func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The string literal after `prefix` on the one line of `path` that holds it.
    static func literal(after prefix: String, in path: String) throws -> String {
        let lines = try text(path).split(separator: "\n").filter { $0.contains(prefix) }
        #expect(lines.count == 1, "\(path): \(lines.count) lines with \(prefix)")
        let line = try #require(lines.first, "\(path): no line with \(prefix)")
        let rest = try #require(line.range(of: prefix).map { line[$0.upperBound...] })
        let quoted = rest.split(separator: "\"", omittingEmptySubsequences: false)
        return try #require(quoted.count >= 3 ? String(quoted[1]) : nil, "\(path): no literal after \(prefix)")
    }

    /// Every file under `top` with the extension, past what a build or a checkout keeps of its own.
    static func files(under top: URL, ext: String) throws -> [URL] {
        let walk = try #require(FileManager.default.enumerator(at: top, includingPropertiesForKeys: [.isDirectoryKey]))
        var found: [URL] = []
        for case let url as URL in walk {
            // A skip asked at a file (a worktree's `.git` is one) skips the rest of its folder.
            let folder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if folder, [".build", "build", ".git", "DerivedData", "node_modules"].contains(url.lastPathComponent) {
                walk.skipDescendants()
            } else if url.pathExtension == ext {
                found.append(url)
            }
        }
        return found
    }

    @Test(arguments: [
        "Apps/Topo.entitlements",
        "Apps/TopoiOS.entitlements",
        "Apps/TopoWatch.entitlements",
        "Apps/TopoHub/TopoHub.entitlements",
        "Womble/Sources/App/Womble.entitlements",
    ])
    func everyEntitlementNamesTheContainer(_ path: String) throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent(path))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let containers = try #require(plist["com.apple.developer.icloud-container-identifiers"] as? [String],
                                      "\(path) names no iCloud container")
        #expect(containers.contains(Self.container), "\(path): \(containers)")
    }

    /// No entitlements file names an iCloud container without being in the list above.
    @Test func noOtherEntitlementNamesAContainer() throws {
        let known: Set = ["Apps/Topo.entitlements", "Apps/TopoiOS.entitlements", "Apps/TopoWatch.entitlements",
                          "Apps/TopoHub/TopoHub.entitlements", "Womble/Sources/App/Womble.entitlements"]
        var named: Set<String> = []
        let base = Self.root.standardizedFileURL.path + "/"
        for url in try Self.files(under: Self.root, ext: "entitlements") {
            let path = url.standardizedFileURL.path
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains("com.apple.developer.icloud-container-identifiers") else { continue }
            named.insert(String(path.dropFirst(base.count)))
        }
        #expect(named == known)
    }

    /// The hub's entitlements are written from `project.yml` on every generate.
    @Test func theHubsProjectEntryNamesTheContainer() throws {
        let line = try #require(try Self.text("project.yml").split(separator: "\n")
            .first { $0.contains("com.apple.developer.icloud-container-identifiers:") })
        let list = try #require(line.split(separator: "[").last?.split(separator: "]").first)
        let items = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(items.contains(Self.container), "\(items)")
    }

    @Test func wombleReadsTheSameContainerAndZone() throws {
        let store = "Womble/Sources/Log/CloudKitStore.swift"
        #expect(try Self.literal(after: "static let containerIdentifier =", in: store) == Self.container)
        #expect(try Self.literal(after: "static let zoneName =", in: store) == Self.zone)
        let selfTest = "Womble/Sources/Diagnostics/CloudKitSelfTest.swift"
        #expect(try Self.literal(after: "logContainer: String =", in: selfTest) == Self.container)
    }

    /// The Swift that links TopoCore spells neither identifier but through the constant.
    @Test func theConstantIsTheOnlySpellingInTheSwiftThatLinksTopoCore() throws {
        var spelled: [String] = []
        for top in ["Apps", "Packages"] {
            for url in try Self.files(under: Self.root.appendingPathComponent(top), ext: "swift") {
                if url.standardizedFileURL.path.contains("/Tests/") { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                if text.contains("\"\(Self.container)\"") || text.contains("zoneName = \"\(Self.zone)\"") {
                    spelled.append(url.lastPathComponent)
                }
            }
        }
        #expect(spelled == ["CloudKitRecordDatabase.swift"])
    }
}
#endif

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
        // One literal and nothing after it but the end of the line or an argument's comma.
        let quoted = rest.split(separator: "\"", omittingEmptySubsequences: false)
        let after = quoted.count == 3 ? quoted[2].trimmingCharacters(in: .whitespaces) : "?"
        return try #require(after.isEmpty || after == "," ? String(quoted[1]) : nil,
                            "\(path): not one literal after \(prefix): \(rest)")
    }

    /// Every file under `top` with the extension, past what a build or a checkout keeps of its own.
    static func files(under top: URL, ext: String) throws -> [URL] {
        let walk = try #require(FileManager.default.enumerator(at: top, includingPropertiesForKeys: [.isDirectoryKey]))
        var found: [URL] = []
        for case let url as URL in walk {
            // Skipped only at a folder: asked at a file (a worktree's `.git` is one), the
            // enumerator skips the children of the next folder it visits instead.
            let folder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if folder, [".build", "build", ".git", ".claude", "DerivedData", "node_modules"].contains(url.lastPathComponent) {
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
            let data = try Data(contentsOf: url)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            guard plist?["com.apple.developer.icloud-container-identifiers"] != nil else { continue }
            named.insert(String(path.dropFirst(base.count)))
        }
        #expect(named == known)
    }

    /// The hub's entitlements are written from `project.yml` on every generate, and its entry is
    /// the one line there, comments aside, that names iCloud containers.
    @Test func theHubsProjectEntryNamesTheContainer() throws {
        let lines = try Self.text("project.yml").split(separator: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
                && $0.contains("com.apple.developer.icloud-container-identifiers:")
        }
        #expect(lines.count == 1, "\(lines)")
        let line = try #require(lines.first)
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

    /// Every container literal and every zone given as a literal (`zoneName = "…"`,
    /// `zoneName: "…"`) in the Swift outside the tests, by the file it is in.
    static func literals(_ pattern: String) throws -> Set<String> {
        let regex = try NSRegularExpression(pattern: pattern)
        let base = root.standardizedFileURL.path + "/"
        var found: Set<String> = []
        for top in ["Apps", "Packages"] {
            for url in try files(under: root.appendingPathComponent(top), ext: "swift") {
                let path = String(url.standardizedFileURL.path.dropFirst(base.count))
                if path.contains("/Tests/") { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    found.insert("\(path): \((text as NSString).substring(with: match.range(at: 1)))")
                }
            }
        }
        return found
    }

    /// The log's container and zone are spelled in `CloudKitRecordDatabase` alone; the one other
    /// container and zone are the board's.
    @Test func theConstantIsTheOnlySpellingInTheSwiftThatLinksTopoCore() throws {
        let database = "Packages/TopoCore/Sources/TopoCore/CloudKitRecordDatabase.swift"
        let app = "Apps/Shared/TopoCloudKit.swift"
        #expect(try Self.literals(#""(iCloud\.[^"]*)""#)
                == ["\(database): \(Self.container)", "\(app): iCloud.zone.hexagon.topo.board"])
        #expect(try Self.literals(#"zoneName\b[^"\n]*?[:=]\s*"([^"]*)""#)
                == ["\(database): \(Self.zone)", "\(app): Board"])
    }

    /// The app's own names for the log's container and zone are the constant's.
    @Test func theAppsNamesAreTheConstant() throws {
        let text = try Self.text("Apps/Shared/TopoCloudKit.swift")
        #expect(text.contains("static let containerIdentifier = CloudKitRecordDatabase.containerIdentifier\n"))
        #expect(text.contains("static let zoneName = CloudKitRecordDatabase.zoneName\n"))
    }
}
#endif

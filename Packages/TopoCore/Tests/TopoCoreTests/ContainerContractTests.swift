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

    /// The first group of every match of `pattern` in `text`, matched across lines with `^` and
    /// `$` at each line's ends, in the order they are found.
    static func matches(_ pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            $0.numberOfRanges > 1 && $0.range(at: 1).location != NSNotFound
                ? (text as NSString).substring(with: $0.range(at: 1)) : (text as NSString).substring(with: $0.range)
        }
    }

    /// The text of a Womble file, read as plain lines: one with a block comment, a conditional
    /// or a multi-line string, any of which can hide a line from the compiler or show one it does
    /// not have, fails rather than being read.
    static func plain(_ path: String) throws -> String {
        let text = try text(path)
        for form in ["/*", "#if", "\"\"\""] {
            #expect(!text.contains(form), "\(path) has \(form), which this suite does not read through")
        }
        return text
    }

    /// How many times `name` appears as a word in `text`, outside `//` lines. A second
    /// declaration adds one whatever form it is written in, so each file's count is pinned: a use
    /// added or taken away is a change to the count here, made with the file read.
    static func uses(of name: String, in text: String) throws -> Int {
        try matches(#"^(?!\s*//).*$"#, in: text).reduce(0) { sum, line in
            sum + (try matches(#"\b"# + name + #"\b"#, in: line)).count
        }
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
    /// The hub's file is XcodeGen's, written from `project.yml` (`targets.TopoHub.entitlements`)
    /// at every generate, and every validation generates before any suite runs
    /// (`scripts/mac-suite.sh`, `prepare`), so what this reads of it there is what XcodeGen made
    /// of the YAML as it now stands.
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

    /// Womble's `CloudKitStore` values are compared as compiled with this package's by Womble's own
    /// `ContainerTests`; its self-test takes the store's container as its default rather than a copy.
    @Test func wombleSelfTestReadsTheStore() throws {
        let path = "Womble/Sources/Diagnostics/CloudKitSelfTest.swift"
        let selfTest = try Self.plain(path)
        #expect(try Self.matches(#"`?logContainer`?\s*:"#, in: selfTest).count == 1)
        #expect(try Self.matches(#"^\s*static func steps\(logContainer: String = CloudKitStore\.containerIdentifier,\s*$"#,
                                 in: selfTest).count == 1)
        #expect(try Self.uses(of: "logContainer", in: selfTest) == 10, "\(path): logContainer is used other than the 10 times it was")
    }

    /// Every container literal, and every zone given as a literal (`zoneName = "…"`,
    /// `zoneName: "…"`, `zoneName: String = "…"`, the name in backticks or not, across lines or
    /// not; a literal plain, raw (`#"…"#`) or multi-line), in the Swift outside the
    /// tests, by the file it is in, once for each time it is spelled.
    static func literals(_ pattern: String) throws -> [String] {
        let base = root.standardizedFileURL.path + "/"
        var found: [String] = []
        for top in ["Apps", "Packages", "Womble/Sources"] {
            for url in try files(under: root.appendingPathComponent(top), ext: "swift") {
                let path = String(url.standardizedFileURL.path.dropFirst(base.count))
                if path.contains("/Tests/") { continue }
                found += try matches(pattern, in: String(contentsOf: url, encoding: .utf8)).map { "\(path): \($0)" }
            }
        }
        return found.sorted()
    }

    /// `TopoCloudKitTests` reads the app's names as the iOS test build has them, so the file
    /// holds no conditional that could give another platform or configuration other values.
    @Test func theAppsNamesAreTheSameInEveryBuild() throws {
        #expect(!(try Self.text("Apps/Shared/TopoCloudKit.swift")).contains("#if"))
    }

    /// The log's container and zone are spelled once in the Swift that links TopoCore, in
    /// `CloudKitRecordDatabase`, and once in Womble's, in `CloudKitStore`; the board's are spelled
    /// once in each and again as the self-test's board default, and the self-test's own zone is
    /// a `SelfTest-` name. Womble's store is held to the constant as compiled (`ContainerTests`).
    @Test func theConstantIsTheOnlySpellingInTheSwiftThatLinksTopoCore() throws {
        let database = "Packages/TopoCore/Sources/TopoCore/CloudKitRecordDatabase.swift"
        let app = "Apps/Shared/TopoCloudKit.swift"
        let store = "Womble/Sources/Log/CloudKitStore.swift"
        let cards = "Womble/Sources/Board/CardRecordStore.swift"
        let selfTest = "Womble/Sources/Diagnostics/CloudKitSelfTest.swift"
        #expect(try Self.literals(#""(?:""\s*)?(iCloud\.[^"\n]*)"#)
                == ["\(app): iCloud.zone.hexagon.topo.board", "\(database): \(Self.container)",
                    "\(cards): iCloud.zone.hexagon.topo.board", "\(selfTest): iCloud.zone.hexagon.topo.board",
                    "\(store): \(Self.container)"])
        #expect(try Self.literals(#"`?zoneName`?\s*(?::\s*[\w.?!<>]+\s*=|[:=])\s*#*"(?:""\s*)?([^"\n]*)"#)
                == ["\(app): Board", "\(database): \(Self.zone)", "\(cards): Board", "\(selfTest): SelfTest-",
                    "\(store): \(Self.zone)"])
        let text = try Self.text(database)
        #expect(try Self.matches(#"^\s*public static let containerIdentifier = "([^"]*)"\s*$"#, in: text) == [Self.container])
        #expect(try Self.matches(#"^\s*public static let zoneName = "([^"]*)"\s*$"#, in: text) == [Self.zone])
    }
}
#endif

#if canImport(CloudKit)
import Foundation
import Testing
import TopoCore

/// The log's container and zone are a contract between bundles (CLAUDE.md, *Invariants*), and
/// `CloudKitRecordDatabase` holds the constant. A bundle with a test target checks its own compiled
/// value against it: the app's `TopoCloudKitTests`, and Womble's `ContainerTests`, which reads
/// the constant's declaration line from this package's source. A file another tool reads is read
/// here by a parser, not by its text: the entitlements as property lists, and `project.yml`
/// through the hub's entitlements, which XcodeGen writes from it. What else this suite reads as
/// text is a guard against a second plain literal, and says what it sees.
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

    /// The hub's file is XcodeGen's, written from `project.yml`
    /// (`targets.TopoHub.entitlements.properties`) at every generate, and every validation
    /// generates before any suite runs (`scripts/mac-suite.sh`, `prepare`), so what this reads of
    /// it there is XcodeGen's reading of the YAML as it stands. Run by hand, it reads the file of
    /// the last generate.
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

    /// Womble's `ContainerTests` takes the constant from the one whole line declaring each name in
    /// `CloudKitRecordDatabase.swift`; this is the check that the line's literal is the value
    /// TopoCore compiles, so the two together hold Womble's compiled value to it.
    @Test func theDatabaseDeclaresEachOnOneWholeLine() throws {
        let text = try Self.text("Packages/TopoCore/Sources/TopoCore/CloudKitRecordDatabase.swift")
        #expect(try Self.matches(#"^\s*public static let containerIdentifier = "([^"\\]*)"\s*$"#, in: text) == [Self.container])
        #expect(try Self.matches(#"^\s*public static let zoneName = "([^"\\]*)"\s*$"#, in: text) == [Self.zone])
    }

    /// `TopoCloudKitTests` reads the app's values as the iOS test build has them. This is the
    /// check that the file holds no `#if` of its own; a conditional reached through another
    /// declaration, and the hub's, watch's and TV's builds, are not read.
    @Test func theAppsFileHoldsNoConditional() throws {
        #expect(!(try Self.text("Apps/Shared/TopoCloudKit.swift")).contains("#if"))
    }

    /// Every match of `pattern` in the Swift under `Apps/`, `Packages/` and `Womble/Sources`,
    /// outside `Tests/` folders, by the file it is in, once for each time it is spelled.
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

    /// A guard against a second literal copy: every `"iCloud.…"` literal, and every zone given as a
    /// literal after `zoneName` (in backticks or not; `=`, `:` or a type annotation, across lines or
    /// not), plain, raw (`#"…"#`) or multi-line, is one of those listed, counted. A value built by
    /// concatenation, interpolation or a call is not seen.
    @Test func noContainerOrZoneLiteralButTheKnownOnes() throws {
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
    }
}
#endif

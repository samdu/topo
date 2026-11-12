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

    /// Every place `name` is bound in `text`, outside `//` lines: the name on its own (in
    /// backticks or not, not after a `.`), then a type or not, then `=` or `{`.
    static func bindings(of name: String, in text: String) throws -> [String] {
        try matches(#"^(?!\s*//).*(?<![.\w`])`?"# + name + #"`?\s*(?::[^=\n{]*)?(?:=(?!=)|\{).*$"#, in: text)
    }

    /// The one literal `name` is declared as: the one place it is bound is the whole line
    /// `static let <name> = "…"`.
    static func literal(declaring name: String, in path: String) throws -> String? {
        let text = try plain(path)
        let all = try bindings(of: name, in: text)
        let whole = try matches(#"^\s*static let "# + name + #" = "([^"\\]*)"\s*$"#, in: text)
        #expect(all.count == 1 && whole.count == 1, "\(path): \(all)")
        return all.count == 1 ? whole.first : nil
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
        let key = "com.apple.developer.icloud-container-identifiers:"
        // A YAML comment runs from a `#` at the line's start or after a space to the line's end.
        let lines = try Self.text("project.yml").split(separator: "\n").map { line -> String in
            let text = String(line)
            guard let hash = try? NSRegularExpression(pattern: #"(^|\s)#"#)
                .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return text }
            return (text as NSString).substring(to: hash.range.location)
        }.filter { $0.contains(key) }
        #expect(lines.count == 1, "\(lines)")
        let line = try #require(lines.first)
        let value = try #require(line.range(of: key).map { line[$0.upperBound...] })
        let list = try #require(try Self.matches(#"^\s*\[([^\[\]]*)\]\s*$"#, in: String(value)).first,
                                "not a flow list: \(value)")
        let items = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(items.contains(Self.container), "\(items)")
    }

    @Test func wombleReadsTheSameContainerAndZone() throws {
        let store = "Womble/Sources/Log/CloudKitStore.swift"
        #expect(try Self.literal(declaring: "containerIdentifier", in: store) == Self.container)
        #expect(try Self.literal(declaring: "zoneName", in: store) == Self.zone)
        // The self-test's default is the first argument of the one `steps` there is.
        let selfTest = try Self.plain("Womble/Sources/Diagnostics/CloudKitSelfTest.swift")
        #expect(try Self.matches(#"logContainer\s*:"#, in: selfTest).count == 1)
        #expect(try Self.matches(#"^\s*static func steps\(logContainer: String = "([^"\\]*)",\s*$"#, in: selfTest)
                == [Self.container])
    }

    /// Every container literal, and every zone given as a literal (`zoneName = "…"`,
    /// `zoneName: "…"`, `zoneName: String = "…"`, across lines or not), in the Swift outside the
    /// tests, by the file it is in, once for each time it is spelled.
    static func literals(_ pattern: String) throws -> [String] {
        let base = root.standardizedFileURL.path + "/"
        var found: [String] = []
        for top in ["Apps", "Packages"] {
            for url in try files(under: root.appendingPathComponent(top), ext: "swift") {
                let path = String(url.standardizedFileURL.path.dropFirst(base.count))
                if path.contains("/Tests/") { continue }
                found += try matches(pattern, in: String(contentsOf: url, encoding: .utf8)).map { "\(path): \($0)" }
            }
        }
        return found.sorted()
    }

    /// The log's container and zone are spelled once, in `CloudKitRecordDatabase`; the one other
    /// container and zone are the board's, once each.
    @Test func theConstantIsTheOnlySpellingInTheSwiftThatLinksTopoCore() throws {
        let database = "Packages/TopoCore/Sources/TopoCore/CloudKitRecordDatabase.swift"
        let app = "Apps/Shared/TopoCloudKit.swift"
        #expect(try Self.literals(#""(iCloud\.[^"]*)""#)
                == ["\(app): iCloud.zone.hexagon.topo.board", "\(database): \(Self.container)"])
        #expect(try Self.literals(#"zoneName\s*(?::\s*[\w.?!<>]+\s*=|[:=])\s*"([^"]*)""#)
                == ["\(app): Board", "\(database): \(Self.zone)"])
        let text = try Self.text(database)
        #expect(try Self.matches(#"^\s*public static let containerIdentifier = "([^"]*)"\s*$"#, in: text) == [Self.container])
        #expect(try Self.matches(#"^\s*public static let zoneName = "([^"]*)"\s*$"#, in: text) == [Self.zone])
    }
}
#endif

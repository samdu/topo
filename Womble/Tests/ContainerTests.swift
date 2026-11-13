import XCTest

/// Womble cannot import TopoCore, so TopoCore's `CloudKitRecordDatabase.swift` is read from the
/// repository (a simulator's tests can read the Mac's files) and its two declarations taken from
/// it: the container and zone Womble compiles are compared with the ones TopoCore declares.
final class ContainerTests: XCTestCase {
    func testTheStoreReadsTopoCoresContainerAndZone() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Womble
            .deletingLastPathComponent()
            .appendingPathComponent("Packages/TopoCore/Sources/TopoCore/CloudKitRecordDatabase.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(CloudKitStore.containerIdentifier, try Self.declared("containerIdentifier", in: text))
        XCTAssertEqual(CloudKitStore.zoneName, try Self.declared("zoneName", in: text))
    }

    /// The literal of the one whole line `public static let <name> = "…"` in `text`.
    /// `ContainerContractTests` holds the file to having exactly that line for each.
    static func declared(_ name: String, in text: String) throws -> String {
        let regex = try NSRegularExpression(pattern: #"^\s*public static let "# + name + #" = "([^"\\]*)"\s*$"#,
                                            options: [.anchorsMatchLines])
        let found = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        XCTAssertEqual(found.count, 1, "\(name) is not declared once in CloudKitRecordDatabase.swift")
        let match = try XCTUnwrap(found.first)
        return (text as NSString).substring(with: match.range(at: 1))
    }
}

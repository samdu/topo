import XCTest

/// Womble cannot import TopoCore, so `CloudKitRecordDatabase.swift` is bundled with these tests as
/// a resource (`project.yml`) and its two declarations read from it: the container and zone Womble
/// compiles are compared with the ones TopoCore declares, whatever the source spelling them looks
/// like.
final class ContainerTests: XCTestCase {
    func testTheStoreReadsTopoCoresContainerAndZone() throws {
        let url = try XCTUnwrap(Bundle(for: Marker.self).url(forResource: "CloudKitRecordDatabase", withExtension: "swift"),
                                "CloudKitRecordDatabase.swift is not in the bundle")
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

    private final class Marker {}
}

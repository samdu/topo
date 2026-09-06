import XCTest

@testable import Topo

final class AcknowledgementsTests: XCTestCase {
    func testReadsTheNoteAndTheEntries() {
        let parsed = Acknowledgements.parse("""
        # Third-party

        Nothing anybody else wrote ships in a bundle.

        The format is the contract.

        ## XcodeGen
        Licence: MIT
        Where: https://github.com/yonaskolb/XcodeGen
        Use: A build tool.
        """)
        XCTAssertEqual(parsed.note, ["Nothing anybody else wrote ships in a bundle.", "The format is the contract."])
        XCTAssertEqual(parsed.entries.count, 1)
        XCTAssertEqual(parsed.entries[0].name, "XcodeGen")
        XCTAssertEqual(parsed.entries[0].fields.map(\.key), ["Licence", "Where", "Use"])
        XCTAssertEqual(parsed.entries[0].fields[1].value, "https://github.com/yonaskolb/XcodeGen")
    }

    func testAWrappedLineBelongsToTheFieldAboveIt() {
        let parsed = Acknowledgements.parse("""
        ## A thing
        Use: One sentence,
        carried on over a second line: with a colon in it.
        """)
        XCTAssertEqual(parsed.entries[0].fields.count, 1)
        XCTAssertEqual(parsed.entries[0].fields[0].value,
                       "One sentence, carried on over a second line: with a colon in it.")
    }

    /// The point of the arrangement: the screen is the file, so a build that
    /// left the file out, or a file that stopped parsing, is a failing test
    /// rather than an empty screen nobody looks at.
    func testTheShippedFileIsInTheBundleAndParses() throws {
        let acknowledgements = try XCTUnwrap(Acknowledgements.bundled(in: Bundle(for: Self.self)),
                                             "THIRD-PARTY is not in the bundle")
        XCTAssertFalse(acknowledgements.note.isEmpty)
        XCTAssertFalse(acknowledgements.entries.isEmpty)
        for entry in acknowledgements.entries {
            XCTAssertFalse(entry.name.isEmpty)
            XCTAssertTrue(entry.fields.contains { $0.key == "Licence" }, "\(entry.name) names no licence")
            XCTAssertTrue(entry.fields.allSatisfy { !$0.value.isEmpty }, "\(entry.name) has an empty field")
        }
    }
}

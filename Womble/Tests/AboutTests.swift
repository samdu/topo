import UIKit
import XCTest

final class AcknowledgementsTests: XCTestCase {
    func testReadsTheNoteAndTheEntries() {
        let parsed = Acknowledgements.parse("""
        # Third-party

        Nothing anybody else wrote ships in a bundle.

        ## XcodeGen
        Licence: MIT
        Where: https://github.com/yonaskolb/XcodeGen
        """)
        XCTAssertEqual(parsed.note, ["Nothing anybody else wrote ships in a bundle."])
        XCTAssertEqual(parsed.entries.count, 1)
        XCTAssertEqual(parsed.entries[0].name, "XcodeGen")
        XCTAssertEqual(parsed.entries[0].fields.map { $0.key }, ["Licence", "Where"])
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

    /// The screen is the file, so a build that left the file out is a failing
    /// test rather than an empty screen nobody looks at.
    func testTheShippedFileIsInTheBundleAndParses() throws {
        let acknowledgements = try XCTUnwrap(Acknowledgements.bundled(in: Bundle(for: type(of: self))),
                                             "THIRD-PARTY is not in the bundle")
        XCTAssertFalse(acknowledgements.note.isEmpty)
        XCTAssertFalse(acknowledgements.entries.isEmpty)
        for entry in acknowledgements.entries {
            XCTAssertTrue(entry.fields.contains { $0.key == "Licence" }, "\(entry.name) names no licence")
        }
    }
}

final class AboutScreenTests: XCTestCase {
    func testShowsTheNameCreditAndEveryEntryFromTheFile() {
        let about = AboutViewController(acknowledgements: Acknowledgements.parse("""
        Nothing anybody else wrote ships in a bundle.

        ## XcodeGen
        Licence: MIT
        """))
        about.loadViewIfNeeded()
        let lines = about.lines
        XCTAssertTrue(lines.contains { $0.contains("Jack Miller") && $0.contains("Ramona Fradon") })
        XCTAssertTrue(lines.contains("Nothing anybody else wrote ships in a bundle."))
        XCTAssertTrue(lines.contains("XcodeGen"))
        XCTAssertTrue(lines.contains("MIT"))
    }

    /// A build without the file says so on the screen. An acknowledgements
    /// screen showing nothing reads as "nothing was borrowed", which is a
    /// worse answer than "this build is broken".
    func testSaysSoWhenTheFileIsMissing() {
        let about = AboutViewController(acknowledgements: nil)
        about.loadViewIfNeeded()
        XCTAssertTrue(about.lines.contains { $0.contains("THIRD-PARTY is missing") })
    }
}

final class MarkViewTests: XCTestCase {
    func testDrawsTheMarkFromTheBundledDrawing() throws {
        let svg = try XCTUnwrap(MarkView.bundledSVG(in: Bundle(for: type(of: self))),
                                "topo-mark.svg is not in the bundle")
        // Eight arms, countable at icon size, and the head above them.
        XCTAssertEqual(MarkView.arms(in: svg).count, 8)
        XCTAssertEqual(MarkView.head(in: svg)?.bounds, CGRect(x: 29, y: 14, width: 42, height: 42))
        XCTAssertTrue(MarkView(svg: svg).isDrawn)
    }

    func testSaysItIsNotDrawnWhenTheDrawingIsNotThere() {
        XCTAssertFalse(MarkView(svg: nil).isDrawn)
    }
}

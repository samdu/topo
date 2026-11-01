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

    /// The licence texts are what the permissive licences ask to travel with the binary, so each
    /// is read whole: its fields are the ones written (a line of the text read as a key would
    /// split it), and the parts a licence cannot do without are in it.
    func testTheShippedLicenceTextsAreWhole() throws {
        let acknowledgements = try XCTUnwrap(Acknowledgements.bundled(in: Bundle(for: Self.self)))
        func entry(_ name: String) throws -> [String: String] {
            let entry = try XCTUnwrap(acknowledgements.entries.first { $0.name == name }, "\(name) is missing")
            return Dictionary(entry.fields.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        }
        func keys(_ name: String) -> [String] {
            acknowledgements.entries.first { $0.name == name }?.fields.map(\.key) ?? []
        }

        let apache = try entry("Licence text: Apache License 2.0")
        XCTAssertEqual(keys("Licence text: Apache License 2.0"), ["Licence", "Text"])
        XCTAssertTrue(apache["Text"]?.contains("END OF TERMS AND CONDITIONS") == true)

        XCTAssertEqual(keys("Licence text: the MIT licence"), ["Licence", "Text"])
        XCTAssertTrue(try entry("Licence text: the MIT licence")["Text"]?.contains("WITHOUT WARRANTY OF ANY KIND") == true)

        let libarchive = try entry("Licence text: libarchive")
        XCTAssertEqual(keys("Licence text: libarchive"),
                       ["Licence", "Text", "In this position", "NetBSD", "FreeBSD", "Unicode tables", "xxHash", "Regents"])
        for (key, value) in libarchive {
            XCTAssertFalse(value.contains("<author"), "libarchive's \(key) carries COPYING's placeholder")
        }
        XCTAssertTrue(libarchive["Text"]?.contains("Copyright (c) 2003-2007 Tim Kientzle") == true)
        XCTAssertTrue(libarchive["Text"]?.contains("Copyright (c) 2016 Martin Matuska") == true)
        XCTAssertTrue(libarchive["Regents"]?.contains("Copyright (c) 1985, 1986, 1992, 1993") == true)
        for key in ["Text", "In this position", "NetBSD", "FreeBSD", "Unicode tables", "xxHash", "Regents"] {
            XCTAssertTrue(libarchive[key]?.contains("Redistributions in binary form must reproduce") == true,
                          "libarchive's \(key) has no binary-form condition")
        }

        XCTAssertEqual(keys("Licence text: KokoroANE-v3 NOTICE"), ["Licence", "Text"])
        let notice = try XCTUnwrap(try entry("Licence text: KokoroANE-v3 NOTICE")["Text"])
        XCTAssertTrue(notice.contains("fast_pipeline.py and the native source/STFT stage"))
        XCTAssertTrue(notice.contains("Retain this notice and mattmireles-LICENSE"))
    }

    /// GPL-3.0 §5(a) asks for a notice of each modification with a date: every patch the build
    /// applies is named in the fork's `Modified` line.
    func testEveryPatchTheBuildAppliesIsNamed() throws {
        let acknowledgements = try XCTUnwrap(Acknowledgements.bundled(in: Bundle(for: Self.self)))
        let fork = try XCTUnwrap(acknowledgements.entries.first { $0.name.hasPrefix("iSH") })
        let modified = try XCTUnwrap(fork.fields.first { $0.key == "Modified" }?.value)
        let patches = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("patches/ish")
        let names = try FileManager.default.contentsOfDirectory(atPath: patches.path).filter { $0.hasSuffix(".patch") }
        XCTAssertFalse(names.isEmpty, "no patches read from \(patches.path)")
        for name in names {
            XCTAssertTrue(modified.contains(String(name.prefix(4)) + " "), "\(name) is not in the Modified line")
        }
    }
}

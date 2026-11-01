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
    /// entry is read whole against a copy of its source in `Tests/Fixtures/licences` (FluidAudio 0.17.7's
    /// `LICENSE` and `ThirdPartyLicenses/`, nom 7.1.3's `LICENSE`, and the notices of the libarchive
    /// files at `fc6563f`, one fixture per wording): its fields are the ones written (a line of the
    /// text read as a key would split it), and each field, with its whitespace folded as the parser
    /// folds a wrapped line, is the fixture's text and nothing less.
    func testTheShippedLicenceTextsAreWhole() throws {
        let acknowledgements = try XCTUnwrap(Acknowledgements.bundled(in: Bundle(for: Self.self)))
        func folded(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        func fixture(_ name: String) throws -> String {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "txt"), "no fixture \(name)")
            return try String(contentsOf: url, encoding: .utf8)
        }
        func fields(_ name: String) throws -> [Acknowledgements.Field] {
            try XCTUnwrap(acknowledgements.entries.first { $0.name == name }, "\(name) is missing").fields
        }
        func assertWhole(_ name: String, _ expected: [(key: String, fixture: String)], file: StaticString = #filePath, line: UInt = #line) throws {
            let found = try fields(name)
            XCTAssertEqual(found.map(\.key), ["Licence"] + expected.map(\.key), "\(name) has other fields", file: file, line: line)
            for (key, text) in expected {
                XCTAssertEqual(folded(found.first { $0.key == key }?.value ?? ""), folded(text),
                               "\(name)'s \(key) is not the fixture's text", file: file, line: line)
            }
        }

        // The terms end at "END OF TERMS AND CONDITIONS"; the appendix after it in the LICENSE file
        // tells a licensor how to apply the licence, and is no term of it.
        let apache = try fixture("licence-apache-2.0")
        let terms = "END OF TERMS AND CONDITIONS"
        let termsEnd = try XCTUnwrap(apache.range(of: terms)).upperBound
        try assertWhole("Licence text: Apache License 2.0", [("Text", String(apache[..<termsEnd]))])

        // The MIT text alone: each holder's copyright line is in the entry of the piece it covers.
        let mit = try fixture("licence-mit-nom")
        let mitText = try XCTUnwrap(mit.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).last)
        XCTAssertTrue(mit.hasPrefix("Copyright (c) 2014-2019 Geoffroy Couprie"))
        try assertWhole("Licence text: the MIT licence", [("Text", String(mitText))])

        try assertWhole("Licence text: fastcluster", [("Text", try fixture("licence-fastcluster"))])
        try assertWhole("Licence text: KokoroANE-v3 NOTICE", [("Text", try fixture("licence-kokoroane-v3-notice"))])
        try assertWhole("Licence text: libarchive", [
            ("Text", try fixture("licence-libarchive-text")),
            ("In this position", try fixture("licence-libarchive-in-this-position")),
            ("NetBSD", try fixture("licence-libarchive-netbsd")),
            ("FreeBSD", try fixture("licence-libarchive-freebsd")),
            ("Unicode tables", try fixture("licence-libarchive-unicode-tables")),
            ("xxHash", try fixture("licence-libarchive-xxhash")),
            ("Regents", try fixture("licence-libarchive-regents")),
        ])
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

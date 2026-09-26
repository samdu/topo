import XCTest

@testable import Topo

/// A reply as the voice reads it (`Speakable.text(from:)`): each row is a source the transcript
/// draws and the words the voice is handed for it.
final class SpeakableTests: XCTestCase {
    private func check(_ rows: [(source: String, spoken: String)],
                       file: StaticString = #filePath, line: UInt = #line) {
        for row in rows {
            XCTAssertEqual(Speakable.text(from: row.source), row.spoken,
                           "source: \(row.source.debugDescription)", file: file, line: line)
        }
    }

    func testInlineCodeIsReadWithItsPunctuationSaid() {
        check([
            ("Should I read `look.json`?", "Should I read look dot json?"),
            ("`settings.json`", "settings dot json"),
            ("`~/.claude/settings.json`", "tilde slash dot claude slash settings dot json"),
            ("`/home/topo`", "slash home slash topo"),
            ("Run `PrePromptSubmit` first.", "Run PrePromptSubmit first."),
        ])
    }

    func testBareFileNamesAreReadWithTheirDotsSaid() {
        check([
            ("Edit look.json, serve.py and Look.swift.", "Edit look dot json, serve dot py and Look dot swift."),
            ("I wrote it to look.json.", "I wrote it to look dot json."),
            ("CLAUDE.md", "claude dot md"),
            ("See README.md first", "See readme dot md first"),
            ("API.md", "API dot md"),
            (".gitignore", "dot gitignore"),
            ("Apps/Client/Speaker.swift", "Apps slash Client slash Speaker dot swift"),
        ])
    }

    func testPathsAreReadWithTheirSlashesSaid() {
        check([
            ("/memory", "slash memory"),
            ("/home/topo", "slash home slash topo"),
            ("Look in /home/topo.", "Look in slash home slash topo."),
            ("It is in ~/Desktop/", "It is in tilde slash Desktop"),
        ])
    }

    /// What reads as it is written: full stops, decimals, versions, abbreviations, addresses.
    func testWhatIsNotAFileNameIsLeftAlone() {
        check([
            ("It ends here. Next sentence.", "It ends here. Next sentence."),
            ("Version 3.5 is out.", "Version 3.5 is out."),
            ("Pinned at v1.2.3 today.", "Pinned at v1.2.3 today."),
            ("Bring snacks, e.g. crisps, i.e. food.", "Bring snacks, e.g. crisps, i.e. food."),
            ("Wait... what?", "Wait... what?"),
            ("Tea and/or coffee.", "Tea and/or coffee."),
            ("Mail sam@example.com today.", "Mail sam@example.com today."),
            ("See https://example.com/a.json now.", "See https://example.com/a.json now."),
            ("PrePromptSubmit", "PrePromptSubmit"),
            ("line one\nline two", "line one\nline two"),
        ])
    }

    func testMarkupIsDroppedNotSpoken() {
        check([
            ("**bold** and _em_", "bold and em"),
            ("# Heading", "Heading"),
            ("## Two\nwords", "Two\nwords"),
            ("- one\n- two", "one\ntwo"),
            ("1. first\n2. second", "first\nsecond"),
            ("Read [the docs](https://example.com/docs.html).", "Read the docs."),
            ("> quoted look.json", "quoted look dot json"),
            ("one\n\n---\n\ntwo", "one\ntwo"),
        ])
    }

    func testACodeBlockIsNamedNotRead() {
        check([
            ("```swift\nlet x = look.json\n```", "A swift code block."),
            ("```\nplain\n```", "A code block."),
            ("```objc\n[x y];\n```", "An objc code block."),
            ("Here:\n\n```sh\nls /tmp\n```\n\nDone.", "Here:\nA sh code block.\nDone."),
        ])
    }

    func testATableIsCountedNotRead() {
        check([
            ("| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |", "A table with 2 rows."),
            ("| file |\n|---|\n| look.json |", "A table with 1 row."),
            ("Sizes:\n\n| a |\n|---|\n| 1 |\n\n| b |\n|---|\n| 2 |\n| 3 |\n\nThat is all.",
             "Sizes:\nA table with 1 row.\nA table with 2 rows.\nThat is all."),
        ])
    }
}

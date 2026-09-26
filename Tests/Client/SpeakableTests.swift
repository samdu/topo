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
            ("Run a.py first.", "Run a dot py first."),
            ("`x.md`", "x dot md"),
        ])
    }

    func testPathsAreReadWithTheirSlashesSaid() {
        check([
            ("/memory", "slash memory"),
            ("/home/topo", "slash home slash topo"),
            ("Look in /home/topo.", "Look in slash home slash topo."),
            ("It is in ~/Desktop/", "It is in tilde slash Desktop"),
            ("Open Apps/Client.", "Open Apps slash Client."),
            ("`Tests/Client/`", "Tests slash Client"),
            ("In Packages/TopoCore now", "In Packages slash TopoCore now"),
            ("see src/my_module", "see src slash my_module"),
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
            ("Ask him/her.", "Ask him/her."),
            ("Yes/no?", "Yes/no?"),
            ("An A/B test.", "An A/B test."),
            ("Over TCP/IP.", "Over TCP/IP."),
            ("Add 1/2 a cup.", "Add 1/2 a cup."),
            ("On 9/26/2026.", "On 9/26/2026."),
            ("At 9 a.m. today.", "At 9 a.m. today."),
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

    /// A code block is its number in the reply, the caption the transcript draws over it, and
    /// never its language or its code.
    func testACodeBlockIsReferredToByItsNumber() {
        check([
            ("```swift\nlet x = look.json\n```", "See code block 1."),
            ("```\nplain\n```", "See code block 1."),
            ("Here:\n\n```sh\nls /tmp\n```\n\nDone.", "Here:\nSee code block 1.\nDone."),
            ("First:\n\n```swift\na\n```\n\nthen:\n\n```\nb\n```\n\n- and\n\n  ```py\n  c\n  ```",
             "First:\nSee code block 1.\nthen:\nSee code block 2.\nand\nSee code block 3."),
            ("> ```\n> quoted\n> ```\n\n```\nafter\n```", "See code block 1.\nSee code block 2."),
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

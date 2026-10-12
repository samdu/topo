import Foundation
import SwiftUI
import UIKit
import XCTest

@testable import Topo

/// `look.json` as the app reads it: field by field onto the compiled look, with a field that is
/// absent, misspelt, of the wrong kind or out of its range falling back on its own and saying so.
///
/// The first test here is the one that keeps the rest honest: it walks the look the fixture makes
/// against the compiled one leaf by leaf, so a field added to `Look` and not taught to the
/// document fails as a field the mind cannot reach — which is the whole point of the type.
@MainActor
final class LookDocumentTests: XCTestCase {

    // MARK: Every field

    /// A document naming every field overrides every field. The walk is over `Look` itself rather
    /// than over a list kept beside it, so the list cannot go stale: a new field of the look is a
    /// failure here until `look.json` can name it.
    func testAFullDocumentOverridesEveryField() throws {
        let reading = LookDocument.read(LookFixture.full)
        XCTAssertEqual(reading.notes, [], "the fixture names something the document cannot read")
        XCTAssertEqual(reading.state, .read(fields: LookFixture.fields),
                       "the fixture set a different number of fields than the look has")

        let unchanged = try LookCensus.same(Look(), reading.look)
        XCTAssertEqual(unchanged, [], "these fields of the look no document can reach")
    }

    /// The census walks the look by reflection, so it has to know every kind of value the look is
    /// made of. A kind it does not know would be quietly skipped, which would make the test above
    /// pass over a field nothing reaches; this is what says it does not.
    func testTheCensusKnowsEveryKindOfValueTheLookIsMadeOf() throws {
        XCTAssertGreaterThan(try LookCensus.leafPaths(Look()).count, 100,
                             "the walk found too few fields to be walking the whole look")
    }

    /// The button a screen share is started from stays a size a finger takes.
    func testTheBroadcastButtonStaysInReach() {
        for side in [44.0, 88] {
            XCTAssertEqual(LookDocument.read(#"{"settings": {"broadcastButton": \#(side)}}"#).look.settings.broadcastButton, side)
        }
        for side in ["43", "89", "0", "-1", "\"big\"", "null"] {
            let read = LookDocument.read(##"{"settings": {"broadcastButton": \##(side), "tint": ["#336699", "#99CCFF"]}}"##)
            XCTAssertEqual(read.look.settings.broadcastButton, Look().settings.broadcastButton, side)
            XCTAssertNotEqual(read.look.settings.tint, Look().settings.tint, "the good field was taken down with \(side)")
        }
    }


    func testAnAbsentFileIsTheCompiledLook() {
        let reading = LookDocument.read(nil)
        XCTAssertEqual(reading.look, Look())
        XCTAssertEqual(reading.state, .absent)
        XCTAssertEqual(reading.notes, [])
        XCTAssertTrue(reading.summary.contains("the compiled look"))
    }

    func testAFileThatIsNotJSONIsTheCompiledLookAndSaysSo() {
        let reading = LookDocument.read("# Look\n\nnot really json")
        XCTAssertEqual(reading.look, Look())
        XCTAssertEqual(reading.state, .unreadable("is not JSON"))
        XCTAssertTrue(reading.summary.contains("is not JSON"))
    }

    func testAFileThatIsJSONAndNotAnObjectIsTheCompiledLook() {
        let reading = LookDocument.read("[1, 2, 3]")
        XCTAssertEqual(reading.look, Look())
        XCTAssertEqual(reading.state, .unreadable("is not a JSON object"))
    }

    // MARK: One bad field

    /// The point of reading field by field rather than through `Codable`: one value the document
    /// gets wrong costs that value and nothing else. Everything the full fixture set still stands,
    /// the one bad field is the compiled default, and the row says which field and why.
    func testOneBadFieldKeepsEveryOtherOverrideAndReportsTheOne() throws {
        let broken = LookFixture.full.replacingOccurrences(of: "\"cornerRadius\": 3",
                                                           with: "\"cornerRadius\": \"wide\"")
        XCTAssertNotEqual(broken, LookFixture.full, "the fixture no longer holds the field to break")
        let reading = LookDocument.read(broken)

        XCTAssertEqual(reading.look.bubble.cornerRadius, Look().bubble.cornerRadius,
                       "a field the document got wrong was taken anyway")
        XCTAssertEqual(reading.notes, ["bubble.cornerRadius is not a length in points"])
        XCTAssertEqual(reading.state, .read(fields: LookFixture.fields - 1))

        // Everything else the document said still stands, which is the claim: one bad field is
        // one field, not a document thrown away. Compared leaf by leaf rather than with `==`,
        // because two dynamic colours built from different closures are never equal to each
        // other however they resolve, so `Look ==  Look` cannot answer this.
        var expected = LookDocument.read(LookFixture.full).look
        expected.bubble.cornerRadius = Look().bubble.cornerRadius
        XCTAssertEqual(try LookCensus.different(reading.look, expected), [])
        XCTAssertTrue(reading.summary.contains("bubble.cornerRadius"))
    }

    /// A field nobody reads is a misspelling, and a misspelling that says nothing is a document
    /// whose author has no way to find out it did nothing.
    func testAKeyNothingReadsIsReported() {
        let reading = LookDocument.read("""
        { "bubble": { "cornerRadis": 4 }, "compozer": {} }
        """)
        XCTAssertEqual(reading.look, Look())
        XCTAssertEqual(reading.notes, ["bubble.cornerRadis is not a field of the look",
                                       "compozer is not a field of the look"])
    }

    // MARK: Numbers

    /// Each field is read in a range of its own, and a value outside it is refused rather than
    /// clamped: a clamped value is a document quietly saying something other than what it says.
    func testAValueOutsideItsFieldsRangeIsRefusedAndReported() {
        let reading = LookDocument.read("""
        { "bubble": { "fillOpacity": 4, "strokeWidth": -2 } }
        """)
        XCTAssertEqual(reading.look, Look())
        XCTAssertEqual(reading.notes.count, 2)
        XCTAssertTrue(reading.notes[0].contains("bubble.fillOpacity"), reading.notes[0])
        XCTAssertTrue(reading.notes[1].contains("bubble.strokeWidth"), reading.notes[1])
    }

    /// What has to be pressed or read has a floor as well as a ceiling: a document may restyle
    /// the microphone and may not shrink it out of the person's reach.
    func testTheLengthsThatHaveToBeReachedHaveAFloor() {
        let reading = LookDocument.read("""
        { "composer": { "well": { "size": 2, "jewelSize": 1 }, "widthFraction": 0.01 },
          "badge": { "size": 3 }, "draft": { "slot": 0 } }
        """)
        XCTAssertEqual(reading.look, Look())
        XCTAssertEqual(reading.notes.count, 5, reading.notes.description)
    }

    /// JSON gives every number as an `NSNumber`, and a `Bool` is one. A true where a length goes
    /// would otherwise be a padding of one point.
    /// Topo's fields are read in ranges of their own: a scale under a quarter or over four, a
    /// frame that lasts no time or over a second, a clearance over 64 points or under none, a
    /// speed under 10 points a second (he would never arrive) or over 400, a hurry under 1 or over 20, a settle under a tenth
    /// of a second or over five, are refused, each alone; the ends of each range are taken. The
    /// fields that placed him on the flank or faded him are no longer his.
    func testTopoIsReadInItsOwnRanges() {
        let reading = LookDocument.read(#"{"mascot": {"scale": 0.1, "frameInterval": 0, "clearance": -1, "roamSpeed": 9, "hurry": 0.5, "roamSettle": 0.05}}"#)
        XCTAssertEqual(reading.look.mascot, Look.Mascot())
        XCTAssertEqual(reading.notes.count, 6, "\(reading.notes)")
        let high = LookDocument.read(#"{"mascot": {"scale": 4, "frameInterval": 1, "clearance": 64, "roamSpeed": 400, "hurry": 20, "roamSettle": 5}}"#)
        XCTAssertEqual(high.notes, [])
        XCTAssertEqual(high.look.mascot.scale, 4)
        XCTAssertEqual(high.look.mascot.frameInterval, 1)
        XCTAssertEqual(high.look.mascot.clearance, 64)
        XCTAssertEqual(high.look.mascot.roamSpeed, 400)
        XCTAssertEqual(high.look.mascot.roamSettle, 5)
        XCTAssertEqual(high.look.mascot.hurry, 20)
        let low = LookDocument.read(#"{"mascot": {"scale": 0.25, "frameInterval": 0.008333333333333333, "clearance": 0, "roamSpeed": 10, "hurry": 1, "roamSettle": 0.1}}"#)
        XCTAssertEqual(low.notes, [])
        XCTAssertEqual(low.look.mascot.scale, 0.25)
        XCTAssertEqual(low.look.mascot.clearance, 0)
        XCTAssertEqual(low.look.mascot.roamSpeed, 10)
        XCTAssertEqual(low.look.mascot.roamSettle, 0.1)
        XCTAssertEqual(low.look.mascot.hurry, 1)
        for key in ["clearance", "roamSpeed", "hurry", "roamSettle", "scale"] {
            let past = LookDocument.read(#"{"mascot": {"\#(key)": 4000}}"#)
            XCTAssertEqual(past.look.mascot, Look.Mascot(), key)
            XCTAssertEqual(past.notes.count, 1, "\(key): \(past.notes)")
        }
        for gone in ["offset", "stroll", "bobAmplitude", "bobPeriod", "hideDuration"] {
            let old = LookDocument.read(#"{"mascot": {"\#(gone)": 1}}"#)
            XCTAssertEqual(old.look.mascot, Look.Mascot(), gone)
            XCTAssertEqual(old.notes, ["mascot.\(gone) is not a field of the look"])
        }
    }

    /// The overlay of his field is drawn in colours and widths of its own: an outline's width is
    /// read from a tenth of a point to 8, its ends taken and past either refused, each alone, and
    /// a colour that is not one refused, leaving the rest as the document said.
    func testTheOverlayOfHisFieldIsReadInItsOwnRanges() {
        for width in [0.1, 8] {
            let reading = LookDocument.read(#"{"mascot": {"debug": {"lineWidth": \#(width), "hairline": \#(width)}}}"#)
            XCTAssertEqual(reading.notes, [], "\(width)")
            XCTAssertEqual(reading.look.mascot.debug.lineWidth, CGFloat(width))
            XCTAssertEqual(reading.look.mascot.debug.hairline, CGFloat(width))
        }
        for width in [0, 0.09, 8.01, -1, 4000] {
            let reading = LookDocument.read(##"{"mascot": {"debug": {"lineWidth": \##(width), "hairline": \##(width), "box": "#000000"}}}"##)
            XCTAssertEqual(reading.look.mascot.debug.lineWidth, Look.Mascot.Debug().lineWidth, "\(width)")
            XCTAssertEqual(reading.look.mascot.debug.hairline, Look.Mascot.Debug().hairline, "\(width)")
            XCTAssertNotEqual(reading.look.mascot.debug.box, Look.Mascot.Debug().box, "\(width) took the box's colour down with it")
            XCTAssertEqual(reading.notes.count, 2, "\(width): \(reading.notes)")
        }
        let wrong = LookDocument.read(#"{"mascot": {"debug": {"chosen": "green", "lineWidth": 4}}}"#)
        XCTAssertEqual(wrong.look.mascot.debug.chosen, Look.Mascot.Debug().chosen)
        XCTAssertEqual(wrong.look.mascot.debug.lineWidth, 4)
        XCTAssertEqual(wrong.notes.count, 1, "\(wrong.notes)")
    }

    /// A code block's pulse breathes from a third of a second to five a breath: both ends taken,
    /// and past either refused alone, leaving the pulse's width as the document said.
    func testACodeBlockPulsesBreathIsReadInItsOwnRange() {
        for cycle in [0.3, 5] {
            let reading = LookDocument.read(#"{"markdown": {"codePulse": {"cycle": \#(cycle)}}}"#)
            XCTAssertEqual(reading.notes, [], "\(cycle)")
            XCTAssertEqual(reading.look.markdown.codePulse.cycle, cycle)
            XCTAssertTrue(reading.fields.contains("markdown.codePulse.cycle"),
                          "\(cycle) was taken and not named among the fields taken: \(reading.fields)")
        }
        for cycle in [0.1, 0.29, 5.1, 0, -1] {
            let reading = LookDocument.read(#"{"markdown": {"codePulse": {"cycle": \#(cycle), "width": 4}}}"#)
            XCTAssertEqual(reading.look.markdown.codePulse.cycle, Look.Markdown.Pulse().cycle, "\(cycle) was taken")
            XCTAssertEqual(reading.look.markdown.codePulse.width, 4, "\(cycle) took the width down with it")
            XCTAssertEqual(reading.notes.count, 1, "\(cycle): \(reading.notes)")
        }
    }

    /// Where Topo sits is one of three names, and anything else is refused with the names listed,
    /// leaving every other field of his as the document said.
    func testThePlacementIsOneOfThreeNames() {
        for placement in Look.Mascot.Placement.allCases {
            let reading = LookDocument.read(#"{"mascot": {"placement": "\#(placement.rawValue)"}}"#)
            XCTAssertEqual(reading.notes, [], placement.rawValue)
            XCTAssertEqual(reading.look.mascot.placement, placement)
        }
        XCTAssertEqual(Look.Mascot().placement, .roam, "the compiled placement is roaming")
        for wrong in [#""floating""#, #""Glass""#, "1", "true", #"["glass"]"#] {
            let reading = LookDocument.read(#"{"mascot": {"placement": \#(wrong), "clearance": 20}}"#)
            XCTAssertEqual(reading.look.mascot.placement, .roam, wrong)
            XCTAssertEqual(reading.look.mascot.clearance, 20, "\(wrong) took clearance down with it")
            XCTAssertEqual(reading.notes, [#"mascot.placement is not one of "roam", "glass", "pinned""#], wrong)
        }
    }

    /// A pin is a place in the transcript's frame, a fraction across and down: both ends of both
    /// halves are taken; one out of `0...1`, a half missing, or something that is not a pair of
    /// numbers is refused whole, with the reason, and the compiled pin stands while every other
    /// field of his is taken — a document costs what it got wrong and no more.
    func testAPinOutOfRangeIsRefusedWholeAndNothingElseGoesWithIt() {
        for (x, y) in [(0.0, 0.0), (1.0, 1.0), (0.0, 1.0), (0.37, 0.62)] {
            let reading = LookDocument.read(#"{"mascot": {"pin": {"x": \#(x), "y": \#(y)}}}"#)
            XCTAssertEqual(reading.notes, [], "\(x), \(y)")
            XCTAssertEqual(reading.look.mascot.pin, CGPoint(x: x, y: y))
            XCTAssertEqual(reading.state, .read(fields: 1), "a pin is one field")
        }
        let compiled = Look.Mascot().pin
        XCTAssertTrue((0...1).contains(compiled.x) && (0...1).contains(compiled.y), "the compiled pin \(compiled)")
        let refused: [(String, String)] = [
            (#"{"x": 1.5, "y": 0.5}"#, "mascot.pin.x is 1.5, and a fraction across the chat between 0 and 1 is read from 0.0 to 1.0"),
            (#"{"x": 0.5, "y": -0.1}"#, "mascot.pin.y is -0.1, and a fraction down the chat, from the transcript's top to the glass's foot, between 0 and 1 is read from 0.0 to 1.0"),
            (#"{"x": 0.5}"#, "mascot.pin needs both an x and a y"),
            (#"{"x": "left", "y": 0.5}"#, "mascot.pin.x is not a fraction across the chat between 0 and 1"),
            (#"[0.5, 0.5]"#, "mascot.pin is not an object naming an x and a y"),
        ]
        for (pin, note) in refused {
            let reading = LookDocument.read(#"{"mascot": {"pin": \#(pin), "placement": "pinned", "scale": 2}}"#)
            XCTAssertEqual(reading.look.mascot.pin, compiled, pin)
            XCTAssertEqual(reading.look.mascot.placement, .pinned, "\(pin) took the placement down with it")
            XCTAssertEqual(reading.look.mascot.scale, 2, "\(pin) took the scale down with it")
            XCTAssertEqual(reading.notes, [note], pin)
        }
    }

    /// The markdown fields reach the look, and one refused — an overflow that is not one of the
    /// two, a length below nothing, a code block's radius of the wrong kind — takes nothing else
    /// down with it.
    func testTheMarkdownFieldsAreReadAndABadOneFallsBackAlone() {
        let good = LookDocument.read(#"{"markdown": {"blockSpacing": 3, "quoteIndent": 5, "codeOverflow": "wrap", "codeBlock": {"cornerRadius": 2}}}"#)
        XCTAssertEqual(good.notes, [])
        XCTAssertEqual(good.look.markdown.blockSpacing, 3)
        XCTAssertEqual(good.look.markdown.quoteIndent, 5)
        XCTAssertEqual(good.look.markdown.codeOverflow, .wrap)
        XCTAssertEqual(good.look.markdown.codeBlock.cornerRadius, 2)

        let bad = LookDocument.read(#"{"markdown": {"codeOverflow": "sideways", "listIndent": -4, "quoteIndent": 65, "codeBlock": {"cornerRadius": "round", "verticalPadding": 3}, "ruleWidth": 4, "blockSpacing": 65}}"#)
        XCTAssertEqual(bad.notes.count, 5, "\(bad.notes)")
        XCTAssertTrue(bad.notes.contains { $0.contains("markdown.codeOverflow") && $0.contains("\"scroll\"") }, "\(bad.notes)")
        XCTAssertEqual(bad.look.markdown.codeOverflow, Look().markdown.codeOverflow)
        XCTAssertEqual(bad.look.markdown.listIndent, Look().markdown.listIndent)
        XCTAssertEqual(bad.look.markdown.quoteIndent, Look().markdown.quoteIndent, "past 64 points is refused")
        XCTAssertEqual(bad.look.markdown.codeBlock.cornerRadius, Look().markdown.codeBlock.cornerRadius)
        XCTAssertEqual(bad.look.markdown.codeBlock.verticalPadding, 3)
        XCTAssertEqual(bad.look.markdown.ruleWidth, 4)
        XCTAssertEqual(bad.look.markdown.blockSpacing, Look().markdown.blockSpacing, "past 64 points is refused")
    }

    /// A table's fields reach the look, each in its own range, and one refused leaves the rest
    /// standing.
    func testTheTableFieldsAreReadAndABadOneFallsBackAlone() {
        let good = LookDocument.read(##"{"markdown": {"tableHeaderFont": {"style": "caption", "weight": "bold"}, "tableColumnSpacing": 9, "tableRowSpacing": 2, "tableRule": "#FF0000", "tableRuleWidth": 2, "tableCellMaxWidth": 180}}"##)
        XCTAssertEqual(good.notes, [])
        XCTAssertEqual(good.look.markdown.tableHeaderFont, .system(.caption).weight(.bold))
        XCTAssertEqual(good.look.markdown.tableColumnSpacing, 9)
        XCTAssertEqual(good.look.markdown.tableRowSpacing, 2)
        XCTAssertEqual(good.look.markdown.tableRuleWidth, 2)
        XCTAssertEqual(good.look.markdown.tableCellMaxWidth, 180)
        XCTAssertEqual(good.fields.filter { $0.hasPrefix("markdown.table") }.count, 6, "\(good.fields)")

        let compiled = Look().markdown
        let bad = LookDocument.read(#"{"markdown": {"tableHeaderFont": "big", "tableColumnSpacing": 65, "tableRowSpacing": -1, "tableRule": "red", "tableRuleWidth": 3, "tableCellMaxWidth": 39}}"#)
        XCTAssertEqual(bad.notes.count, 5, "\(bad.notes)")
        XCTAssertEqual(bad.look.markdown.tableHeaderFont, compiled.tableHeaderFont)
        XCTAssertEqual(bad.look.markdown.tableColumnSpacing, compiled.tableColumnSpacing)
        XCTAssertEqual(bad.look.markdown.tableRowSpacing, compiled.tableRowSpacing)
        XCTAssertEqual(bad.look.markdown.tableCellMaxWidth, compiled.tableCellMaxWidth, "a cell narrower than a word is refused")
        XCTAssertEqual(bad.look.markdown.tableRuleWidth, 3, "the one good field was taken down with the rest")
        // A link's ink is one field of its own: refused, the fields beside it are still taken.
        let link = LookDocument.read(##"{"markdown": {"linkInk": "blue", "codeInk": "#102030", "tableRowSpacing": 4}}"##)
        XCTAssertEqual(link.notes.count, 1, "\(link.notes)")
        XCTAssertTrue(link.fields.isSuperset(of: ["markdown.codeInk", "markdown.tableRowSpacing"]), "\(link.fields)")
        XCTAssertFalse(link.fields.contains("markdown.linkInk"))
        XCTAssertTrue(LookDocument.read(##"{"markdown": {"linkInk": ["#0000FF", "#8888FF"]}}"##).fields.contains("markdown.linkInk"))
        for width in [40.0, 2000] {
            XCTAssertEqual(LookDocument.read(#"{"markdown": {"tableCellMaxWidth": \#(width)}}"#).look.markdown.tableCellMaxWidth, width)
        }
        for width in ["2001", "1e999", "\"wide\"", "true"] {
            XCTAssertEqual(LookDocument.read(#"{"markdown": {"tableCellMaxWidth": \#(width)}}"#).look.markdown.tableCellMaxWidth,
                           compiled.tableCellMaxWidth, width)
        }
    }

    /// An image's height and corner are the document's, each in its range, and a refused one
    /// leaves the other standing.
    func testAnImagesHeightAndCornerAreReadInTheirRanges() {
        let compiled = Look().markdown
        let good = LookDocument.read(#"{"markdown": {"imageMaxHeight": 200, "imageCornerRadius": 4}}"#)
        XCTAssertEqual(good.notes, [])
        XCTAssertEqual(good.look.markdown.imageMaxHeight, 200)
        XCTAssertEqual(good.look.markdown.imageCornerRadius, 4)
        XCTAssertTrue(good.fields.isSuperset(of: ["markdown.imageMaxHeight", "markdown.imageCornerRadius"]), "\(good.fields)")
        for height in [24.0, 4000] {
            XCTAssertEqual(LookDocument.read(#"{"markdown": {"imageMaxHeight": \#(height)}}"#).look.markdown.imageMaxHeight, height)
        }
        for height in ["23", "4001", "0", "-1", "\"tall\"", "true", "null"] {
            let read = LookDocument.read(#"{"markdown": {"imageMaxHeight": \#(height), "imageCornerRadius": 3}}"#)
            XCTAssertEqual(read.look.markdown.imageMaxHeight, compiled.imageMaxHeight, height)
            XCTAssertEqual(read.look.markdown.imageCornerRadius, 3, "the good field was taken down with \(height)")
        }
        let bad = LookDocument.read(#"{"markdown": {"imageMaxHeight": 300, "imageCornerRadius": -1}}"#)
        XCTAssertEqual(bad.notes.count, 1, "\(bad.notes)")
        XCTAssertEqual(bad.look.markdown.imageCornerRadius, compiled.imageCornerRadius)
        XCTAssertEqual(bad.look.markdown.imageMaxHeight, 300)
    }

    /// The glass under the keyboard is read in a range of its own: a pane kept at under half its
    /// height is refused, and the ends of the range are taken.
    func testTheShortPaneIsReadInItsOwnRange() {
        let refused = LookDocument.read(#"{"composer": {"compactShare": 0.49}}"#)
        XCTAssertEqual(refused.look, Look())
        XCTAssertEqual(refused.notes.count, 1, refused.notes.description)
        XCTAssertEqual(LookDocument.read(#"{"composer": {"compactShare": 1.01}}"#).look.composer.compactShare, 2.0 / 3)
        let low = LookDocument.read(#"{"composer": {"compactShare": 0.5}}"#)
        XCTAssertEqual(low.notes, [])
        XCTAssertEqual(low.look.composer.compactShare, 0.5)
        let high = LookDocument.read(#"{"composer": {"compactShare": 1}}"#)
        XCTAssertEqual(high.notes, [])
        XCTAssertEqual(high.look.composer.compactShare, 1)
    }

    /// The least a notice is drawn at is a share from a half to 1, and one outside that is refused
    /// with the rest of the transcript standing.
    func testTheNoticesLeastScaleIsReadFromAHalfToOne() {
        XCTAssertEqual(Look().transcript.noticeLeastScale, 0.65)
        for (given, taken) in [("0.5", 0.5), ("1", 1), ("0.8", 0.8)] {
            let read = LookDocument.read(#"{"transcript": {"noticeLeastScale": \#(given), "spacing": 3}}"#)
            XCTAssertEqual(read.look.transcript.noticeLeastScale, CGFloat(taken), accuracy: 1e-9)
            XCTAssertTrue(read.notes.isEmpty, "\(read.notes)")
        }
        for refused in ["0.49", "1.01", "\"small\""] {
            let read = LookDocument.read(#"{"transcript": {"noticeLeastScale": \#(refused), "spacing": 3}}"#)
            XCTAssertEqual(read.look.transcript.noticeLeastScale, 0.65, refused)
            XCTAssertEqual(read.look.transcript.spacing, 3, "a refused scale took the spacing with it")
            XCTAssertEqual(read.notes.count, 1, "\(refused): \(read.notes)")
        }
    }

    /// A document written for the slider on the glass, the keyboard's second mark and the room
    /// between the bar's controls still reads: the keys the look no longer has are passed over,
    /// whatever they hold, with no note, and every field beside them is taken.
    func testTheKeysThatWentRefuseNothing() {
        let reading = LookDocument.read("""
        { "composer": { "spacing": 31,
                        "models": { "inset": 52, "height": 61, "stop": "not a number", "labelFont": 7 },
                        "flank": { "keyboardDown": "pencil.slash", "muted": "bell.slash" } },
          "bar": { "spacing": "wide" },
          "mascot": { "roamSpeed": 60 } }
        """)
        XCTAssertEqual(reading.notes, [])
        XCTAssertEqual(reading.state, .read(fields: 3))
        XCTAssertEqual(reading.look.composer.spacing, 31)
        XCTAssertEqual(reading.look.composer.flank.muted, "bell.slash")
        XCTAssertEqual(reading.look.mascot.roamSpeed, 60)
    }

    /// A control's mark is a symbol the system has: a name it has not is refused and the compiled
    /// mark stays, since a control drawn with nothing is one nobody can see to press.
    func testAMarkTheSystemHasNoSymbolForIsRefused() {
        for name in ["speaker.wave.2.fil", "", "not a symbol"] {
            let refused = LookDocument.read(#"{"composer": {"flank": {"muted": "\#(name)"}}}"#)
            XCTAssertEqual(refused.look, Look(), "\(name) was taken")
            XCTAssertEqual(refused.notes, ["composer.flank.muted is not the name of a symbol the system has"])
        }
        let taken = LookDocument.read(#"{"composer": {"flank": {"muted": "bell.slash"}}}"#)
        XCTAssertEqual(taken.notes, [])
        XCTAssertEqual(taken.look.composer.flank.muted, "bell.slash")
    }

    /// The row's fields are read in ranges of their own, and one refused costs itself alone: a
    /// width outside the resting one's range, a count of lines that is not a whole number from
    /// one to twenty, and a send or a mark the system has no symbol for.
    func testTheRowsFieldsAreReadInTheirOwnRanges() {
        let refused = [#"{"composer": {"typingWidthFraction": 0.05}}"#, #"{"composer": {"typingWidthFraction": 1.2}}"#,
                       #"{"composer": {"jewelInset": -1}}"#, #"{"composer": {"perchInset": 201}}"#,
                       #"{"composer": {"flank": {"slot": 4}}}"#, #"{"composer": {"flank": {"more": "pluss"}}}"#,
                       #"{"draft": {"maximumLines": 0}}"#, #"{"draft": {"maximumLines": 21}}"#,
                       #"{"draft": {"maximumLines": 2.5}}"#, #"{"draft": {"maximumLines": true}}"#,
                       #"{"draft": {"sendSymbol": "paperplan"}}"#]
        for document in refused {
            let reading = LookDocument.read(document)
            XCTAssertEqual(reading.look, Look(), "\(document) was taken")
            XCTAssertEqual(reading.notes.count, 1, "\(document): \(reading.notes)")
        }
        let taken = LookDocument.read("""
        { "composer": { "typingWidthFraction": 1, "jewelInset": 0, "perchInset": 200,
                        "flank": { "slot": 8, "more": "plus.circle" } },
          "draft": { "maximumLines": 20, "sendSymbol": "arrow.up", "slot": 0 } }
        """)
        XCTAssertEqual(taken.notes.count, 1, "the slot alone is refused: \(taken.notes)")
        XCTAssertEqual(taken.state, .read(fields: 7))
        XCTAssertEqual(taken.look.composer.typingWidthFraction, 1)
        XCTAssertEqual(taken.look.composer.jewelInset, 0)
        XCTAssertEqual(taken.look.composer.perchInset, 200)
        XCTAssertEqual(taken.look.composer.flank.slot, 8)
        XCTAssertEqual(taken.look.composer.flank.more, "plus.circle")
        XCTAssertEqual(taken.look.draft.maximumLines, 20)
        XCTAssertEqual(taken.look.draft.sendSymbol, "arrow.up")
        XCTAssertEqual(LookDocument.read(#"{"draft": {"maximumLines": 1}}"#).look.draft.maximumLines, 1)
    }

    /// The send is drawn in the message's colour, as the field's outline is, and stays a field
    /// of its own: a document that sets it moves it alone.
    func testTheSendIsTheMessagesColourUntilADocumentSaysOtherwise() throws {
        var same = Look()
        same.draft.sendInk = same.draft.written.accent
        XCTAssertEqual(try LookCensus.different(Look(), same), [])

        let reading = LookDocument.read(##"{"draft": {"sendInk": "#123456"}}"##)
        XCTAssertEqual(reading.notes, [])
        XCTAssertEqual(try LookCensus.different(Look(), reading.look), ["draft.sendInk"])
    }

    /// A value the bar or the send cannot be drawn with is refused with a note, costs that field
    /// alone, and leaves the fields beside it taken.
    func testTheBarsFieldsAndTheSendsInkAreRefusedOneAtATime() throws {
        let refused: [(String, String, String)] = [
            ("bar", #""font": "enormous", "slider": {"knob": 3}"#, "bar.slider.knob"),
            ("bar", #""ink": 7, "slider": {"knob": 3}"#, "bar.slider.knob"),
            ("bar", ##""slider": {"width": -1}, "ink": "#123456""##, "bar.ink"),
            ("bar", ##""slider": {"width": "wide", "height": 900, "inset": 0, "stop": 99, "knob": 0, "labelSpacing": 17, "restOpacity": 2, "track": true}, "ink": "#123456""##, "bar.ink"),
            ("bar", #""slider": {"labelFont": "largeTitle", "inset": 30}"#, "bar.slider.inset"),
            ("draft", #""sendInk": 7, "maximumLines": 3"#, "draft.maximumLines"),
            ("draft", #""sendInk": "puce-ish", "maximumLines": 3"#, "draft.maximumLines"),
        ]
        for (object, fields, kept) in refused {
            let reading = LookDocument.read("{\"\(object)\": {\(fields)}}")
            XCTAssertGreaterThanOrEqual(reading.notes.count, 1, "\(fields): \(reading.notes)")
            XCTAssertEqual(reading.state, .read(fields: 1), "\(fields): \(reading.notes)")
            XCTAssertEqual(try LookCensus.different(Look(), reading.look), [kept],
                           "\(fields): the refused field was taken, or took the one beside it down")
        }
    }

    func testABooleanIsNotANumber() {
        let reading = LookDocument.read("""
        { "bubble": { "strokeWidth": true } }
        """)
        XCTAssertEqual(reading.look.bubble.strokeWidth, Look().bubble.strokeWidth)
        XCTAssertEqual(reading.notes, ["bubble.strokeWidth is not a length in points"])
    }

    /// A number too big for its field never reaches a view, and neither does one too big to be a
    /// number at all — which the parser refuses outright rather than handing over as an infinity.
    /// Either way the look is the compiled one and the row says something other than "no file".
    func testANumberNoViewCouldSurviveNeverReachesOne() {
        for document in ["{ \"bubble\": { \"cornerRadius\": 1e30 } }",
                         "{ \"bubble\": { \"cornerRadius\": 1e400 } }"] {
            let reading = LookDocument.read(document)
            XCTAssertEqual(reading.look, Look(), document)
            XCTAssertNotEqual(reading.summary, LookDocument.read(nil).summary, document)
        }
    }

    /// Every integer JSON hands back is an `NSNumber` a boolean would also be, so a `1` written
    /// anywhere in a document is the field this is about: one that reads it as a boolean throws
    /// every 0 and every 1 in the file away.
    func testAOneIsANumberAndNotABoolean() {
        let reading = LookDocument.read("""
        { "bubble": { "strokeWidth": 1, "fillOpacity": 0 } }
        """)
        XCTAssertEqual(reading.notes, [])
        XCTAssertEqual(reading.look.bubble.strokeWidth, 1)
        XCTAssertEqual(reading.look.bubble.fillOpacity, 0)
    }

    /// The one column width that may be no width at all.
    func testTheColumnsWidthMayBeInfinite() {
        let reading = LookDocument.read("""
        { "transcript": { "maximumLineWidth": "infinity" } }
        """)
        XCTAssertEqual(reading.look.transcript.maximumLineWidth, .infinity)
        XCTAssertEqual(reading.notes, [])
    }

    /// The margin after Topo's turns: 70 points on the phone and none on the watch or the
    /// television, read from 0 to 200, so a reply keeps a column of words on the narrowest
    /// phone; past either end the field alone falls back.
    func testTheReplyTrailingInsetIsReadInItsRange() {
        XCTAssertEqual(Look.Transcript(.phone).replyTrailingInset, 70)
        XCTAssertEqual(Look.Transcript(.watch).replyTrailingInset, 0)
        XCTAssertEqual(Look.Transcript(.tv).replyTrailingInset, 0)
        for inset in [0, 200] as [CGFloat] {
            let reading = LookDocument.read(#"{"transcript": {"replyTrailingInset": \#(inset), "spacing": 9}}"#)
            XCTAssertEqual(reading.look.transcript.replyTrailingInset, inset)
            XCTAssertEqual(reading.notes, [])
        }
        for inset in ["-1", "201", "\"wide\""] {
            let reading = LookDocument.read(#"{"transcript": {"replyTrailingInset": \#(inset), "spacing": 9}}"#)
            XCTAssertEqual(reading.look.transcript.replyTrailingInset, Look().transcript.replyTrailingInset, inset)
            XCTAssertEqual(reading.look.transcript.spacing, 9, "\(inset) took another field down")
            XCTAssertEqual(reading.notes.count, 1, "\(inset): \(reading.notes)")
        }
    }

    /// The room before the person's turns mirrors the margin after Topo's: the same default on
    /// every screen, read in the same range, and past either end the field alone falls back.
    func testThePersonsLeadingInsetMirrorsTheReplysAndIsReadInItsRange() {
        for screen in [Look.Screen.phone, .watch, .tv] {
            XCTAssertEqual(Look.Transcript(screen).personLeadingInset, Look.Transcript(screen).replyTrailingInset, "\(screen)")
        }
        XCTAssertEqual(Look.Transcript(.phone).personLeadingInset, 70)
        for inset in [0, 200] as [CGFloat] {
            let reading = LookDocument.read(#"{"transcript": {"personLeadingInset": \#(inset), "spacing": 9}}"#)
            XCTAssertEqual(reading.look.transcript.personLeadingInset, inset)
            XCTAssertEqual(reading.notes, [])
        }
        for inset in ["-1", "201", "\"wide\""] {
            let reading = LookDocument.read(#"{"transcript": {"personLeadingInset": \#(inset), "spacing": 9}}"#)
            XCTAssertEqual(reading.look.transcript.personLeadingInset, Look().transcript.personLeadingInset, inset)
            XCTAssertEqual(reading.look.transcript.spacing, 9, "\(inset) took another field down")
            XCTAssertEqual(reading.notes.count, 1, "\(inset): \(reading.notes)")
        }
    }

    func testANullIsNotAValue() {
        let reading = LookDocument.read("""
        { "bubble": { "accent": null } }
        """)
        XCTAssertEqual(reading.look, Look())
        XCTAssertEqual(reading.notes, ["bubble.accent is null"])
    }

    // MARK: Colours

    /// A colour is a pair as `Theme` writes one, and it resolves per appearance like the palette's
    /// own: the light value in a light appearance and the dark one in a dark appearance.
    func testAColourIsAHexPairThatResolvesPerAppearance() throws {
        let reading = LookDocument.read("""
        { "bubble": { "accent": ["#102030", "#405060"] } }
        """)
        XCTAssertEqual(reading.notes, [])
        let colour = UIColor(reading.look.bubble.accent)
        XCTAssertEqual(colour.resolvedColor(with: .init(userInterfaceStyle: .light)),
                       UIColor(red: 0x10 / 255, green: 0x20 / 255, blue: 0x30 / 255, alpha: 1))
        XCTAssertEqual(colour.resolvedColor(with: .init(userInterfaceStyle: .dark)),
                       UIColor(red: 0x40 / 255, green: 0x50 / 255, blue: 0x60 / 255, alpha: 1))
    }

    /// One string is the same colour in both appearances, which is what a stone's own cast
    /// wants; eight digits carry an alpha, which is what a shadow wants.
    func testOneStringIsBothAppearancesAndEightDigitsCarryAnAlpha() throws {
        let reading = LookDocument.read("""
        { "jewel": { "cast": "#0080FF", "dropShadow": { "color": "#00000080" } } }
        """)
        XCTAssertEqual(reading.notes, [])
        let cast = UIColor(reading.look.jewel.cast)
        XCTAssertEqual(cast.resolvedColor(with: .init(userInterfaceStyle: .light)),
                       cast.resolvedColor(with: .init(userInterfaceStyle: .dark)))
        var alpha: CGFloat = 0
        UIColor(reading.look.jewel.dropShadow.color).getWhite(nil, alpha: &alpha)
        XCTAssertEqual(alpha, 0x80 / 255, accuracy: 0.01)
    }

    /// The row's two states are two enclosures under `draft`, read with the same reader the
    /// bubble is, so a document can colour a turn being written and one on its way separately
    /// and leave the landed bubble where it is.
    func testTheDraftsTwoEnclosuresAreReadFromTheDocument() throws {
        let reading = LookDocument.read("""
        { "draft": { "written": { "accent": "#112233" }, "sending": { "accent": "#445566" } } }
        """)
        XCTAssertEqual(reading.notes, [])
        XCTAssertEqual(reading.state, .read(fields: 2))
        let light = UITraitCollection(userInterfaceStyle: .light)
        XCTAssertEqual(UIColor(reading.look.draft.written.accent).resolvedColor(with: light),
                       UIColor(red: 0x11 / 255, green: 0x22 / 255, blue: 0x33 / 255, alpha: 1))
        XCTAssertEqual(UIColor(reading.look.draft.sending.accent).resolvedColor(with: light),
                       UIColor(red: 0x44 / 255, green: 0x55 / 255, blue: 0x66 / 255, alpha: 1))
        XCTAssertEqual(reading.look.bubble.accent, Look().bubble.accent,
                       "a document that colours the draft moved the landed bubble too")
    }

    /// The rest of each enclosure is the bubble's shape, so a document naming only a colour
    /// leaves the row the size the landed turn will be.
    func testTheDraftsEnclosuresShipWithTheBubblesShape() {
        let draft = Look().draft
        for enclosure in [draft.written, draft.sending] {
            XCTAssertEqual(enclosure.cornerRadius, Look().bubble.cornerRadius)
            XCTAssertEqual(enclosure.horizontalPadding, Look().bubble.horizontalPadding)
            XCTAssertEqual(enclosure.verticalPadding, Look().bubble.verticalPadding)
            XCTAssertEqual(enclosure.strokeWidth, Look().bubble.strokeWidth)
            XCTAssertEqual(enclosure.fillOpacity, Look().bubble.fillOpacity)
            XCTAssertEqual(enclosure.surface, Look().bubble.surface)
        }
    }

    func testSomethingThatIsNotAColourIsRefused() {
        for value in ["\"teal\"", "\"#12345\"", "[\"#112233\"]", "42"] {
            let reading = LookDocument.read("{ \"bubble\": { \"accent\": \(value) } }")
            XCTAssertEqual(reading.look.bubble.accent, Look().bubble.accent, value)
            XCTAssertEqual(reading.notes.count, 1, value)
        }
    }

    // MARK: Names

    func testAMaterialIsNamedAndAnUnknownOneIsRefused() {
        XCTAssertEqual(LookDocument.read("{ \"bubble\": { \"surface\": \"glass\" } }").look.bubble.surface,
                       .glass)
        let wrong = LookDocument.read("{ \"bubble\": { \"surface\": \"frosted\" } }")
        XCTAssertEqual(wrong.look.bubble.surface, Look().bubble.surface)
        XCTAssertEqual(wrong.notes.count, 1)
        XCTAssertTrue(wrong.notes[0].contains("\"material\""), wrong.notes[0])
    }

    // MARK: Compounds

    /// A shadow the document names part of keeps the rest of the compiled one, so `{"radius": 9}`
    /// is the same shadow further out rather than a black one at nothing.
    func testAShadowNamedInPartKeepsTheRestOfTheCompiledOne() {
        let reading = LookDocument.read("""
        { "jewel": { "bodyShade": { "radius": 9 } } }
        """)
        XCTAssertEqual(reading.notes, [])
        XCTAssertEqual(reading.look.jewel.bodyShade.radius, 9)
        XCTAssertEqual(reading.look.jewel.bodyShade.color, Look().jewel.bodyShade.color)
        XCTAssertEqual(reading.look.jewel.bodyShade.y, Look().jewel.bodyShade.y)
    }

    /// A font cannot be read back out of SwiftUI, so a weight with nothing to weigh is refused
    /// rather than applied to a font nobody named.
    func testAFontNamingOnlyAWeightIsRefused() {
        let reading = LookDocument.read("""
        { "transcript": { "bodyFont": { "weight": "bold" } } }
        """)
        XCTAssertEqual(reading.look.transcript.bodyFont, Look().transcript.bodyFont)
        XCTAssertEqual(reading.notes, ["transcript.bodyFont names neither a style nor a size"])
    }

    func testAFontIsAStyleOrASizeAndOneFieldEitherWay() {
        let styled = LookDocument.read("{ \"transcript\": { \"bodyFont\": \"footnote\" } }")
        XCTAssertEqual(styled.look.transcript.bodyFont, .system(.footnote))
        XCTAssertEqual(styled.state, .read(fields: 1))

        let sized = LookDocument.read("""
        { "transcript": { "bodyFont": { "size": 22, "weight": "semibold" } } }
        """)
        XCTAssertEqual(sized.look.transcript.bodyFont, Font.system(size: 22).weight(.semibold))
        XCTAssertEqual(sized.state, .read(fields: 1), "a font counts as the one field it is")
    }

    /// The bar's controls are drawn in the navigation bar, which is a fixed height and holds them
    /// beside the notice and the badge: a size past `Look.Bar.largestFont` is drawn at that, and
    /// a larger style is refused, so no document puts the model or the mute out of the bar.
    func testTheBarsFontIsNoLargerThanTheBarHolds() {
        let huge = LookDocument.read(#"{ "bar": { "font": { "size": 400, "weight": "heavy" } } }"#)
        XCTAssertEqual(huge.look.bar.font, Font.system(size: CGFloat(Look.Bar.largestFont)).weight(.heavy))
        XCTAssertEqual(huge.state, .read(fields: 1), "the size is drawn at the most, not refused")
        XCTAssertEqual(huge.notes.count, 1, "and the document is told so: \(huge.notes)")

        let most = LookDocument.read(#"{ "bar": { "font": { "size": 22 } } }"#)
        XCTAssertEqual(most.look.bar.font, Font.system(size: 22))
        XCTAssertEqual(most.notes, [])
        let small = LookDocument.read(#"{ "bar": { "font": { "size": 4 } } }"#)
        XCTAssertEqual(small.look.bar.font, Font.system(size: 4))
        XCTAssertEqual(small.notes, [])

        // The slider is read at each end of its ranges and no further, and a name under
        // a stop no larger than the slider's own height leaves it.
        let ends = LookDocument.read(#"{ "bar": { "slider": { "width": 560, "height": 44, "padding": 24, "drop": 24, "inset": 80, "stop": 28, "knob": 28, "labelSpacing": 16 } } }"#)
        XCTAssertEqual(ends.notes, [])
        var widest = Look().bar.slider
        (widest.width, widest.height, widest.inset, widest.stop, widest.knob, widest.labelSpacing) = (560, 44, 80, 28, 28, 16)
        (widest.padding, widest.drop) = (24, 24)
        XCTAssertEqual(ends.look.bar.slider, widest)
        let least = LookDocument.read(#"{ "bar": { "slider": { "width": 96, "height": 24, "padding": 4, "drop": 0, "inset": 8, "stop": 2, "knob": 2, "labelSpacing": 0 } } }"#)
        XCTAssertEqual(least.notes, [])
        var fewest = Look().bar.slider
        (fewest.width, fewest.height, fewest.inset, fewest.stop, fewest.knob, fewest.labelSpacing) = (96, 24, 8, 2, 2, 0)
        (fewest.padding, fewest.drop) = (4, 0)
        XCTAssertEqual(least.look.bar.slider, fewest)
        // Past either end, a field is refused alone and the look's own value stands.
        for field in [#""width": 561"#, #""width": 95"#, #""padding": 25"#, #""padding": 3"#, #""drop": 25"#, #""drop": -1"#, #""height": 45"#, #""height": 23"#, #""inset": 81"#, #""inset": 7"#,
                      #""stop": 29"#, #""stop": 1"#, #""knob": 29"#, #""knob": 1"#, #""labelSpacing": 17"#, #""labelSpacing": -1"#] {
            let past = LookDocument.read("{ \"bar\": { \"slider\": { \(field), \"track\": 2 } } }")
            var kept = Look().bar.slider
            kept.track = 2
            XCTAssertEqual(past.look.bar.slider, kept, "\(field): a slider past the bar's is kept, and its neighbour read")
            XCTAssertEqual(past.notes.count, 1, "\(field): \(past.notes)")
        }
        let named = LookDocument.read(#"{ "bar": { "slider": { "labelFont": { "size": 400 } } } }"#)
        XCTAssertEqual(named.look.bar.slider.labelFont, Font.system(size: CGFloat(Look.Bar.Slider.largestLabel)))
        let title = LookDocument.read(#"{ "bar": { "font": "largeTitle" } }"#)
        XCTAssertEqual(title.look.bar.font, Look().bar.font)
        XCTAssertEqual(title.notes.count, 1, "\(title.notes)")
        XCTAssertEqual(LookDocument.read(#"{ "bar": { "font": "title3" } }"#).notes, [], "a style the bar holds was refused")
    }

    /// The notice's font is drawn in the navigation bar beside the badge, which holds two lines of
    /// no more than `largestNotice` points: a larger size is drawn at that, and a larger style is
    /// refused, so no document puts a notice down over the transcript.
    func testTheNoticeFontIsNoLargerThanTheBarHolds() {
        let huge = LookDocument.read("{ \"transcript\": { \"noticeFont\": { \"size\": 400, \"weight\": \"heavy\" } } }")
        XCTAssertEqual(huge.look.transcript.noticeFont,
                       Font.system(size: CGFloat(Look.Transcript.largestNotice)).weight(.heavy))
        XCTAssertEqual(huge.state, .read(fields: 1), "the size is drawn at the most, not refused")
        XCTAssertEqual(huge.notes.count, 1, "and the document is told so: \(huge.notes)")

        let title = LookDocument.read("{ \"transcript\": { \"noticeFont\": \"largeTitle\" } }")
        XCTAssertEqual(title.look.transcript.noticeFont, Look().transcript.noticeFont)
        XCTAssertEqual(title.notes.count, 1, "\(title.notes)")
        let styledTitle = LookDocument.read("{ \"transcript\": { \"noticeFont\": { \"style\": \"title\" } } }")
        XCTAssertEqual(styledTitle.look.transcript.noticeFont, Look().transcript.noticeFont)
        XCTAssertEqual(styledTitle.notes.count, 1, "\(styledTitle.notes)")

        let titleAndSize = LookDocument.read("{ \"transcript\": { \"noticeFont\": { \"style\": \"title\", \"size\": 14 } } }")
        XCTAssertEqual(titleAndSize.look.transcript.noticeFont, Font.system(size: 14), "the size beside the style still sets")
        XCTAssertEqual(titleAndSize.notes.count, 1, "and the style is refused with a note: \(titleAndSize.notes)")

        let small = LookDocument.read("{ \"transcript\": { \"noticeFont\": \"footnote\" } }")
        XCTAssertEqual(small.look.transcript.noticeFont, .system(.footnote))
        XCTAssertEqual(small.notes, [])

        let body = LookDocument.read("{ \"transcript\": { \"bodyFont\": { \"size\": 400 } } }")
        XCTAssertEqual(body.look.transcript.bodyFont, Font.system(size: 400), "only the notice is held to the bar")
    }

    /// The cut edge of the well is a gradient, so its colours are a list — and a list holding
    /// something that is not a colour is not half a gradient.
    func testAListOfColoursIsAllOfThemOrNoneOfThem() {
        let good = LookDocument.read("""
        { "composer": { "well": { "edgeColors": ["#FF0000", "#00FF00"] } } }
        """)
        XCTAssertEqual(good.look.composer.well.edgeColors.count, 2)

        let bad = LookDocument.read("""
        { "composer": { "well": { "edgeColors": ["#FF0000", 7] } } }
        """)
        XCTAssertEqual(bad.look.composer.well.edgeColors, Look().composer.well.edgeColors)
        XCTAssertEqual(bad.notes.count, 1)
    }

    // MARK: The row

    /// A count alone is a device run that has to be repeated to learn anything, so the row names
    /// the first few reasons and counts the rest.
    func testTheRowNamesTheFirstReasonsAndCountsTheRest() {
        let reading = LookDocument.read("""
        { "bubble": { "a": 1, "b": 2, "c": 3, "d": 4, "e": 5, "f": 6, "g": 7 } }
        """)
        XCTAssertEqual(reading.notes.count, 7)
        XCTAssertTrue(reading.summary.contains("bubble.a"), reading.summary)
        XCTAssertTrue(reading.summary.contains("bubble.e"), reading.summary)
        XCTAssertFalse(reading.summary.contains("bubble.f"), reading.summary)
        XCTAssertTrue(reading.summary.contains("and 2 more"), reading.summary)
    }

    /// What a path names, as the reader knows it: a part holds fields, top-level or nested; a
    /// field is one, a compound included; a key inside a compound is inside it.
    func testThePlaceOfAPathIsTheReaders() {
        for part in ["transcript", "mascot", "composer.well", "mascot.debug"] {
            XCTAssertEqual(LookDocument.place(of: part.split(separator: ".").map(String.init)), .part, part)
        }
        for field in ["mascot.scale", "mascot.pin", "composer.glow"] {
            XCTAssertEqual(LookDocument.place(of: field.split(separator: ".").map(String.init)), .field, field)
        }
        XCTAssertEqual(LookDocument.place(of: ["composer", "glow", "radius"]), .inside("composer.glow"))
        XCTAssertEqual(LookDocument.place(of: ["mascot", "wings"]), .unknown)
        XCTAssertEqual(LookDocument.place(of: ["nothing"]), .unknown)
    }

    /// Which compound fields read an object onto what they hold, as the reader says: a shadow
    /// and a point do; a font and a pin are replaced whole; a scalar and a part are not compounds.
    func testTheReaderSaysWhichCompoundsMerge() {
        XCTAssertTrue(LookDocument.merges(["composer", "glow"]))
        for path in [["transcript", "bodyFont"], ["mascot", "pin"], ["mascot", "scale"], ["mascot"], ["nothing"]] {
            XCTAssertFalse(LookDocument.merges(path), path.joined(separator: "."))
        }
    }
}

/// The look walked by reflection, leaf by leaf, so a claim about "every field" is about the type
/// and not about a list somebody remembered to update.
///
/// The kinds of value a look is made of are named here rather than inferred, because a kind the
/// walk did not recognise would be skipped, and a skipped field is exactly the field the walk
/// exists to catch. Anything else it meets is an error, not a shrug.
enum LookCensus {
    /// How many fields of the look a document can set. A compound — a shadow, a size, a font — is
    /// one field, because that is how the reader counts what it took.
    static let fields = 95

    enum Trouble: Error, CustomStringConvertible {
        case unknownKind(String, String)

        var description: String {
            switch self {
            case .unknownKind(let path, let kind):
                "\(path) is a \(kind), which the census does not know how to compare"
            }
        }
    }

    /// Every leaf of a look, by the path the document writes it at.
    static func leafPaths(_ look: Look) throws -> [String] {
        var paths: [String] = []
        try walk(look, look, "", { path, _ in paths.append(path) })
        return paths
    }

    /// The paths at which two looks hold the same value. Empty is two looks with nothing in
    /// common, which is what a full document against the compiled look has to be.
    static func same(_ a: Look, _ b: Look) throws -> [String] {
        var same: [String] = []
        try walk(a, b, "") { path, equal in if equal { same.append(path) } }
        return same
    }

    /// The paths at which two looks part company. Empty is two looks that draw the same, which
    /// `==` cannot say for looks holding colours: a dynamic colour is never equal to another
    /// built from another closure, however the two resolve.
    static func different(_ a: Look, _ b: Look) throws -> [String] {
        var different: [String] = []
        try walk(a, b, "") { path, equal in if !equal { different.append(path) } }
        return different
    }

    private static func walk(_ a: Any, _ b: Any, _ path: String,
                             _ found: (String, Bool) -> Void) throws {
        if let leaf = compare(a, b) {
            found(path.isEmpty ? "(the look)" : path, leaf)
            return
        }
        let (left, right) = (Mirror(reflecting: a), Mirror(reflecting: b))
        if left.displayStyle == .collection || right.displayStyle == .collection {
            guard left.children.count == right.children.count else { return found(path, false) }
            for (index, pair) in zip(left.children, right.children).enumerated() {
                try walk(pair.0.value, pair.1.value, "\(path)[\(index)]", found)
            }
            return
        }
        guard !left.children.isEmpty else {
            throw Trouble.unknownKind(path, "\(type(of: a))")
        }
        for (one, other) in zip(left.children, right.children) {
            let name = one.label ?? "?"
            try walk(one.value, other.value, path.isEmpty ? name : "\(path).\(name)", found)
        }
    }

    /// Whether two values of a kind the look is made of are the same, or nil for something that
    /// is not one of those kinds and has to be walked into.
    ///
    /// A colour is compared as it resolves rather than as it was made: two dynamic colours built
    /// from different closures are never `==`, so `==` alone would call every colour changed and
    /// the walk would prove nothing about colours at all.
    private static func compare(_ a: Any, _ b: Any) -> Bool? {
        if let a = a as? Color { return (b as? Color).map { resolved(a) == resolved($0) } ?? false }
        switch a {
        case is CGFloat, is Double, is Int, is Bool, is String,
             is Font, is Font.Weight, is Font.TextStyle,
             is Angle, is UnitPoint, is CGSize,
             is Look.Surface, is BlendMode, is Look.Mascot.Placement, is Look.Markdown.CodeOverflow:
            guard let a = a as? any Equatable else { return false }
            return alike(a, b)
        default:
            return nil
        }
    }

    private static func alike<T: Equatable>(_ a: T, _ b: Any) -> Bool { a == (b as? T) }

    private static func resolved(_ colour: Color) -> [UIColor] {
        [UITraitCollection(userInterfaceStyle: .light), UITraitCollection(userInterfaceStyle: .dark)]
            .map { UIColor(colour).resolvedColor(with: $0) }
    }
}

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

    // MARK: No file, and files that are not one

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

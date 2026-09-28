import XCTest

@testable import Topo

/// The widget document as `topo widget set` reads it: each value checked where it is read, a bad
/// field costing that field and no more, a bad node costing that node and no more, and the
/// budgets cutting the tree rather than refusing it.
final class WidgetDocumentTests: XCTestCase {
    private func read(_ node: String, family: String = "systemSmall", _ source: WidgetDocument.Source = .mind) -> WidgetDocument.Reading {
        WidgetDocument.read(#"{"version": 1, "families": {"\#(family)": \#(node)}}"#, from: source)
    }

    private func tree(_ reading: WidgetDocument.Reading, _ family: WidgetFamilyName = .systemSmall) throws -> WidgetNode {
        try XCTUnwrap(reading.document.families[family], "no tree kept: \(reading.notes)")
    }

    private func children(_ node: WidgetNode) throws -> [WidgetNode] {
        guard case .stack(let stack) = node else { XCTFail("not a stack: \(node)"); return [] }
        return stack.children
    }

    // MARK: Review Focus 1

    /// One case per rule, each refused with a note that names the field and why.
    func testRefusesEach() throws {
        let cases: [(String, String, String)] = [
            ("unknown kind", #"{"kind": "vstack", "children": [{"kind": "marquee"}]}"#, "children[0] is a marquee, which is not a kind of node"),
            ("colour neither token nor hex", #"{"kind": "text", "text": "a", "colour": "teal"}"#, "colour is not a colour"),
            ("colour pair malformed", ##"{"kind": "text", "text": "a", "colour": ["#fff", "#000000"]}"##, "colour is not a colour"),
            ("glyph not a symbol", #"{"kind": "glyph", "symbol": "not.a.real.symbol.at.all"}"#, "symbol is not an SF Symbol"),
            ("style not a case", #"{"kind": "text", "text": "a", "style": "huge"}"#, "style is not one of largeTitle"),
            ("weight not a case", #"{"kind": "text", "text": "a", "weight": "chunky"}"#, "weight is not one of ultraLight"),
            ("design not a case", #"{"kind": "text", "text": "a", "design": "comic"}"#, "design is not one of default"),
            ("alignment not a case", #"{"kind": "hstack", "alignment": "leading", "children": []}"#, "alignment is not one of top"),
            ("number not a number", #"{"kind": "glyph", "symbol": "star", "size": "big"}"#, "size is not a size in points"),
            ("number a boolean", #"{"kind": "glyph", "symbol": "star", "size": true}"#, "size is not a size in points"),
            ("number out of range", #"{"kind": "vstack", "spacing": 33, "children": []}"#, "spacing is 33.0"),
            ("lines not whole", #"{"kind": "text", "text": "a", "lines": 2.5}"#, "lines is not a whole number"),
            ("gauge value outside bounds", #"{"kind": "gauge", "value": 12, "min": 0, "max": 10}"#, "value is 12.0, outside 0.0 to 10.0, and is drawn at 10.0"),
            ("gauge min not below max", #"{"kind": "gauge", "value": 1, "min": 5, "max": 5}"#, "max is not above min"),
            ("progress outside 0-1", #"{"kind": "progress", "value": 1.5}"#, "value is 1.5, outside 0.0 to 1.0"),
            ("text over its length", #"{"kind": "text", "text": "\#(String(repeating: "x", count: 201))"}"#, "text is 201 characters, and a home-screen text holds 200, so it was cut"),
            ("date not ISO 8601", #"{"kind": "text", "date": "tomorrow"}"#, "date is not an ISO 8601 date"),
            ("pose not a case", #"{"kind": "topo", "pose": "dancing"}"#, "pose is not one of idle"),
            ("image name not a name", #"{"kind": "image", "name": "../x"}"#, "name is not the name of an image"),
            ("unknown field", #"{"kind": "divider", "colour": "primary"}"#, "colour is not a field of this node"),
            ("control id malformed", #"{"kind": "button", "id": "Lights Off", "action": {"kind": "open"}}"#, "id is not a control id"),
            ("action kind unknown", #"{"kind": "button", "id": "b", "action": {"kind": "shell"}}"#, "kind is not turn, open or run"),
            ("link runs", #"{"kind": "link", "id": "l", "action": {"kind": "run", "topo": ["notify", "hi"]}}"#, "kind is run, which this takes no run of"),
            ("run off the allowlist", #"{"kind": "button", "id": "b", "action": {"kind": "run", "topo": ["calendar", "add", "x"]}}"#, "is topo calendar add, which a widget may not run"),
            ("run a lock by name", #"{"kind": "button", "id": "b", "action": {"kind": "run", "topo": ["home", "set", "4F2A", "lock-target-state", "0"]}}"#, "sets lock-target-state, which a widget may not set"),
            ("run topo widget", #"{"kind": "button", "id": "b", "action": {"kind": "run", "topo": ["widget", "clear"]}}"#, "is topo widget clear, which a widget may not run"),
            ("say too long", #"{"kind": "button", "id": "b", "action": {"kind": "turn", "say": "\#(String(repeating: "x", count: 201))"}}"#, "say is 201 characters"),
            ("label not text or glyph", #"{"kind": "button", "id": "b", "label": [{"kind": "gauge", "value": 1}], "action": {"kind": "open"}}"#, "label[0] is a gauge, and a control's label holds only text and glyphs"),
        ]
        for (rule, node, expected) in cases {
            let reading = read(node)
            XCTAssertTrue(reading.notes.contains { $0.contains(expected) }, "\(rule): expected a note with “\(expected)”, got \(reading.notes)")
        }
    }

    func testAToggleIsJudgedInBothOfItsForms() throws {
        // The reader holds the allowlist to both completed forms; which values a characteristic
        // takes is the tool's judgement, at `set` (`WidgetToolTests`).
        let reading = read(#"{"kind": "toggle", "id": "t", "on": true, "action": {"kind": "run", "topo": ["home", "set", "4F2A", "target-door-state"]}}"#)
        guard case .control(let control) = try tree(reading) else { return XCTFail("the toggle was dropped") }
        XCTAssertEqual(control.action, .open)
        XCTAssertEqual(control.on, true)
    }

    /// JSON has no spelling for an infinity; a number too big for a `Double` is the one way to
    /// write one, and it reaches no view: refused by the parse or by the reader.
    func testANumberPastADoubleReachesNoView() throws {
        let reading = read(#"{"kind": "glyph", "symbol": "star", "size": 1e400}"#)
        if case .glyph(let glyph) = reading.document.families[.systemSmall] {
            XCTAssertEqual(glyph.size, 17)
            XCTAssertFalse(reading.notes.isEmpty)
        } else {
            XCTAssertFalse(reading.readable, "\(reading)")
        }
    }

    func testTheRevisionIsTheAppsNotTheMinds() throws {
        let mind = WidgetDocument.read(#"{"revision": 9, "families": {"systemSmall": {"kind": "divider"}}}"#)
        XCTAssertEqual(mind.document.revision, 0)
        XCTAssertTrue(mind.notes.contains("revision is the app's to write, and was not read"), "\(mind.notes)")
        let kept = WidgetDocument.read(#"{"revision": 9, "families": {"systemSmall": {"kind": "divider"}}}"#, from: .store)
        XCTAssertEqual(kept.document.revision, 9)
        XCTAssertEqual(kept.notes, [])
    }

    func testADocumentThatIsNotOneIsUnreadable() {
        XCTAssertEqual(WidgetDocument.read("nope").state, .unreadable("is not JSON"))
        XCTAssertEqual(WidgetDocument.read("[1]").state, .unreadable("is not a JSON object"))
        XCTAssertFalse(WidgetDocument.read(#"{"version": 2, "families": {}}"#).readable)
        XCTAssertFalse(WidgetDocument.read(#"{"families": {"systemSmall": {"kind": "marquee"}}}"#).readable)
        let big = #"{"families": {"systemSmall": {"kind": "text", "text": "\#(String(repeating: "x", count: 17_000))"}}}"#
        XCTAssertEqual(WidgetDocument.read(big).state, .unreadable("is \(big.utf8.count) bytes, over the 16 KB a document holds"))
    }

    /// A `text` with a bad colour and a bad style keeps its words, its other fields and its
    /// place; a `vstack` with a bad spacing keeps every child.
    func testBadFieldKeepsItsNode() throws {
        let reading = read(#"""
        {"kind": "vstack", "spacing": -4, "children": [
          {"kind": "glyph", "symbol": "star.fill"},
          {"kind": "text", "text": "Kept words", "colour": "chartreuse", "style": "enormous", "weight": "bold", "lines": 2},
          {"kind": "divider"}
        ]}
        """#)
        XCTAssertEqual(reading.notes.count, 3, "\(reading.notes)")
        let kids = try children(tree(reading))
        XCTAssertEqual(kids.map(\.kind), ["glyph", "text", "divider"])
        guard case .text(let text) = kids[1] else { return XCTFail() }
        XCTAssertEqual(text.text, "Kept words")
        XCTAssertEqual(text.style, .body)
        XCTAssertNil(text.colour)
        XCTAssertEqual(text.weight, .bold)
        XCTAssertEqual(text.lines, 2)
        guard case .stack(let stack) = try tree(reading) else { return XCTFail() }
        XCTAssertNil(stack.spacing)
    }

    func testBadNodeKeepsItsSiblings() throws {
        let reading = read(#"""
        {"kind": "hstack", "children": [
          {"kind": "text", "text": "before"},
          {"kind": "marquee", "text": "gone"},
          "not a node",
          {"kind": "button", "id": "BAD ID", "action": {"kind": "open"}},
          {"kind": "text", "text": "after"}
        ]}
        """#)
        let kids = try children(tree(reading))
        XCTAssertEqual(kids, [.text(.init(text: "before")), .text(.init(text: "after"))])
        XCTAssertEqual(reading.notes.count, 3, "\(reading.notes)")
    }

    func testBudgetCutsAtTheLimit() throws {
        // Depth: seven nested stacks, the seventh cut.
        var nested = #"{"kind": "text", "text": "deep"}"#
        for _ in 0..<6 { nested = #"{"kind": "vstack", "children": [\#(nested)]}"# }
        let deep = read(nested)
        XCTAssertTrue(deep.notes.contains { $0.contains("is deeper than 6 nodes, and was cut") }, "\(deep.notes)")
        var depth = 0
        try tree(deep).walk { _ in depth += 1 }
        XCTAssertEqual(depth, 6)

        // Count: seventy texts in one stack, the stack and 63 of them kept.
        let many = (0..<70).map { #"{"kind": "text", "text": "\#($0)"}"# }.joined(separator: ",")
        let wide = read(#"{"kind": "vstack", "children": [\#(many)]}"#)
        XCTAssertEqual(try children(tree(wide)).count, 63)
        XCTAssertEqual(wide.state, .read(nodes: 64))
        XCTAssertEqual(wide.notes.filter { $0.contains("past the 64 nodes") }.count, 7)

        // Controls: eight buttons in a family, six kept.
        let buttons = (0..<8).map { #"{"kind": "button", "id": "b\#($0)", "action": {"kind": "open"}}"# }.joined(separator: ",")
        let crowded = read(#"{"kind": "vstack", "children": [\#(buttons)]}"#)
        XCTAssertEqual(try children(tree(crowded)).count, 6)
        XCTAssertEqual(crowded.notes.filter { $0.contains("past the 6 controls") }.count, 2)
    }

    func testTheInlineFamilyDrawsOneTextAndOneGlyph() throws {
        let reading = read(#"""
        {"kind": "vstack", "children": [{"kind": "glyph", "symbol": "sun.max"}, {"kind": "text", "text": "Sunny"},
          {"kind": "text", "text": "second"}, {"kind": "gauge", "value": 0.5}]}
        """#, family: "accessoryInline")
        let kids = try children(tree(reading, .accessoryInline))
        XCTAssertEqual(kids.map(\.kind), ["glyph", "text"])
        XCTAssertTrue(reading.notes.contains { $0.contains("one text and one glyph on one line") }, "\(reading.notes)")
    }

    func testAnAccessoryTextHoldsSixty() throws {
        let reading = read(#"{"kind": "text", "text": "\#(String(repeating: "y", count: 61))"}"#, family: "accessoryRectangular")
        guard case .text(let text) = try tree(reading, .accessoryRectangular) else { return XCTFail() }
        XCTAssertEqual(text.text.count, 60)
    }

    func testAFamilyMissingFallsBackToTheDefault() throws {
        let reading = WidgetDocument.read(#"{"families": {"default": {"kind": "divider"}, "systemLarge": {"kind": "spacer"}}}"#)
        XCTAssertEqual(reading.document.tree(for: .systemMedium), .divider)
        XCTAssertEqual(reading.document.tree(for: .systemLarge), .spacer(min: 0))
    }

    /// `default` is read with the home screen's 200 and drawn on a lock-screen family cut to 60,
    /// which the read says.
    func testTheDefaultDrawsSixtyOnALockScreen() throws {
        let long = String(repeating: "z", count: 200)
        let reading = WidgetDocument.read(#"{"families": {"default": {"kind": "text", "text": "\#(long)"}}}"#)
        XCTAssertTrue(reading.notes.contains { $0.hasPrefix("families.default") && $0.contains("cut to 60") }, "\(reading.notes)")
        guard case .text(let home)? = reading.document.tree(for: .systemSmall),
              case .text(let lock)? = reading.document.tree(for: .accessoryRectangular) else { return XCTFail() }
        XCTAssertEqual(home.text.count, 200)
        XCTAssertEqual(lock.text.count, 60)
    }

    func testALabelPastSixtyIsCutWithANote() throws {
        let reading = read(#"{"kind": "button", "id": "go", "label": "\#(String(repeating: "w", count: 61))", "action": {"kind": "open"}}"#)
        XCTAssertTrue(reading.notes.contains { $0.contains("label[0] is 61 characters") }, "\(reading.notes)")
        guard case .control(let control) = try tree(reading), case .text(let label)? = control.label.first else { return XCTFail() }
        XCTAssertEqual(label.text.count, 60)
    }

    /// A control may be called `tap`: the whole widget's tap is cued under an id no control has.
    func testAControlNamedTapIsNotTheWholeWidgetsTap() throws {
        let cases: [(String, String?)] = [(#"{"kind": "open"}"#, nil), (#"{"kind": "turn", "say": "the control"}"#, "widget s: the control")]
        for (action, words) in cases {
            let reading = WidgetDocument.read(#"{"tap": {"kind": "turn", "say": "the widget"}, "families": {"systemSmall": {"kind": "button", "id": "tap", "label": "Tap", "action": \#(action)}}}"#)
            XCTAssertEqual(reading.notes, [])
            XCTAssertEqual(reading.document.turn(slot: "s", control: WidgetDocument.wholeTap, turningOn: nil), "widget s: the widget")
            XCTAssertEqual(reading.document.turn(slot: "s", control: "tap", turningOn: nil), words)
        }
    }

    /// A document the mind wrote inside the byte budget is kept and drawn, though its kept copy,
    /// which writes out every text's style and design, is past the budget: 63 texts at their
    /// limit, with slashes.
    func testALargeDocumentIsKeptAndDrawn() throws {
        let words = String(repeating: "a/b ", count: 50)
        let texts = (0..<63).map { _ in #"{"kind":"text","text":"\#(words)"}"# }.joined(separator: ",")
        let input = #"{"version":1,"families":{"systemLarge":{"kind":"vstack","children":[\#(texts)]}}}"#
        XCTAssertLessThanOrEqual(input.utf8.count, WidgetDocument.byteLimit)
        let reading = WidgetDocument.read(input)
        XCTAssertEqual(reading.notes, [])
        XCTAssertGreaterThan(reading.document.text.utf8.count, WidgetDocument.byteLimit, "the kept copy fits the budget, so this holds nothing")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("widget-large-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SurfaceStore(folder: folder)
        let revision = try store.write(reading.document, slot: "demo")
        let kept = try XCTUnwrap(store.read(slot: "demo"))
        XCTAssertTrue(kept.readable, "the kept copy was not read: \(kept.state)")
        XCTAssertEqual(kept.notes, [])
        var expected = reading.document
        expected.revision = revision
        XCTAssertEqual(kept.document, expected)
    }

    /// `accessoryInline` draws one line of whatever tree it is given, the default's included.
    func testTheDefaultDrawsOneLineInline() throws {
        let reading = WidgetDocument.read(#"""
        {"families": {"default": {"kind": "vstack", "children": [{"kind": "text", "text": "one"}, {"kind": "text", "text": "two"},
          {"kind": "button", "id": "go", "label": "Go", "action": {"kind": "open"}}]}}}
        """#)
        XCTAssertTrue(reading.notes.contains { $0.contains("on accessoryInline") && $0.contains("one text and one glyph") }, "\(reading.notes)")
        let kids = try children(XCTUnwrap(reading.document.tree(for: .accessoryInline)))
        XCTAssertEqual(kids, [.text(.init(text: "one"))])
        let kept = WidgetDocument.read(reading.document.text, from: .store)
        XCTAssertEqual(kept.notes, [])
    }

    /// A control's label is nodes against the document's budget: 500 words, or 64 text nodes,
    /// are cut at it.
    func testALabelCountsAgainstTheNodeBudget() throws {
        let words = (0..<500).map { #""w\#($0)""# }.joined(separator: ",")
        let nodes = (0..<64).map { #"{"kind": "text", "text": "t\#($0)"}"# }.joined(separator: ",")
        for label in [words, nodes] {
            let reading = read(#"{"kind": "button", "id": "go", "label": [\#(label)], "action": {"kind": "open"}}"#)
            XCTAssertEqual(reading.state, .read(nodes: WidgetDocument.nodeLimit))
            guard case .control(let control) = try tree(reading) else { return XCTFail() }
            XCTAssertEqual(control.label.count, WidgetDocument.nodeLimit - 1)
            XCTAssertTrue(reading.notes.contains { $0.contains("past the 64 nodes") }, "\(reading.notes)")
        }
    }

    func testAFifthImageIsDropped() throws {
        let images = (0..<5).map { #"{"kind": "image", "name": "i\#($0)"}"# }.joined(separator: ",")
        let reading = read(#"{"kind": "vstack", "children": [\#(images)]}"#)
        XCTAssertEqual(try children(tree(reading)).count, 4)
        XCTAssertTrue(reading.notes.contains { $0.contains("past the 4 images") }, "\(reading.notes)")
    }

    /// A control and its label fit the node budget together, the label drawn from the id counted.
    func testAControlWithNoLabelAtTheBudgetIsCounted() throws {
        for texts in [61, 62] {
            let children = (0..<texts).map { #"{"kind": "text", "text": "\#($0)"}"# }
                + [#"{"kind": "button", "id": "go", "label": [{"kind": "topo"}], "action": {"kind": "open"}}"#]
            let reading = read(#"{"kind": "vstack", "children": [\#(children.joined(separator: ","))]}"#)
            var drawn = 0
            try tree(reading).walk { _ in drawn += 1 }
            XCTAssertLessThanOrEqual(drawn, WidgetDocument.nodeLimit, "\(texts) texts and a button draw \(drawn) nodes")
            XCTAssertEqual(reading.state, .read(nodes: drawn))
        }
    }

    /// What the app keeps is what was read, and a read of the kept copy is the same document with
    /// no notes.
    func testTheKeptCopyReadsBackTheSame() throws {
        let reading = WidgetDocument.read(Self.everyKind)
        XCTAssertEqual(reading.notes, [])
        var kept = reading.document
        kept.revision = 3
        let again = WidgetDocument.read(kept.text, from: .store)
        XCTAssertEqual(again.notes, [])
        XCTAssertEqual(again.document, kept)
    }

    static let everyKind = #"""
    {"version": 1, "tint": "primary", "until": "2030-01-01T00:00:00Z", "relevance": 0.5,
     "tap": {"kind": "open"},
     "families": {"systemMedium": {"kind": "hstack", "spacing": 8, "alignment": "top", "children": [
       {"kind": "topo", "pose": "thinking"},
       {"kind": "vstack", "alignment": "leading", "children": [
         {"kind": "text", "text": "Hello", "style": "headline", "weight": "bold", "design": "rounded", "colour": ["#112233", "#445566"], "lines": 2},
         {"kind": "text", "date": "2030-01-01T00:00:00Z", "dateStyle": "timer"},
         {"kind": "glyph", "symbol": "star.fill", "colour": "signal", "size": 20},
         {"kind": "image", "name": "photo", "fit": "fill", "corner": 8},
         {"kind": "gauge", "value": 3, "min": 0, "max": 10, "label": "Steps", "style": "linear", "colour": "highlight"},
         {"kind": "progress", "value": 0.25},
         {"kind": "spacer", "min": 4}, {"kind": "divider"},
         {"kind": "zstack", "alignment": "bottomTrailing", "children": []}
       ]},
       {"kind": "vstack", "children": [
         {"kind": "button", "id": "hi", "label": [{"kind": "glyph", "symbol": "hand.wave"}, "Hi"], "action": {"kind": "turn", "say": "hello"}},
         {"kind": "toggle", "id": "lamp", "label": "Lamp", "on": true, "action": {"kind": "run", "topo": ["home", "set", "4F2A", "power"]}},
         {"kind": "link", "id": "open", "label": "Open", "action": {"kind": "open"}}
       ]}
     ]}}}
    """#
}

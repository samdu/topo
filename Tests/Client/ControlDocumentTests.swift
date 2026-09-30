import SwiftUI
import UIKit
import XCTest

@testable import Topo

/// Review Focus 1 and 4 of the controls' plan: a control's document is judged field by field, a
/// refused field falls back to its default with a note and the rest stands, and a document of the
/// other kind than its slot is refused whole.
final class ControlDocumentTests: XCTestCase {
    /// A button's document with every field written, as JSON, with `change` applied to it.
    static func button(_ change: (inout [String: Any]) -> Void = { _ in }) -> String {
        var object: [String: Any] = ["version": 1, "kind": "button", "title": "Feed Daphne", "subtitle": "one treat",
                                     "symbol": "pawprint.fill", "tint": "primary", "hint": "Treat",
                                     "action": ["kind": "run", "topo": ["home", "scene", "SC-TREAT"]]]
        change(&object)
        return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
    }

    static func toggle(_ change: (inout [String: Any]) -> Void = { _ in }) -> String {
        var object: [String: Any] = ["version": 1, "kind": "toggle", "title": "Lamp", "onText": "Lit", "offText": "Dark",
                                     "symbol": "lightbulb", "onSymbol": "lightbulb.fill", "offSymbol": "lightbulb",
                                     "tint": ["#FFCC00", "#FFDD55"], "hint": "Lamp", "on": true,
                                     "action": ["kind": "run", "topo": ["home", "set", "LAMP-1", "power"]]]
        change(&object)
        return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
    }

    func testAWholeDocumentIsTakenWhole() {
        let button = ControlDocument.read(Self.button(), slot: "button-2")
        XCTAssertEqual(button.state, .read)
        XCTAssertEqual(button.notes, [])
        XCTAssertEqual(button.document.title, "Feed Daphne")
        XCTAssertEqual(button.document.subtitle, "one treat")
        XCTAssertEqual(button.document.symbol, "pawprint.fill")
        XCTAssertEqual(button.document.tint, .token(.primary))
        XCTAssertEqual(button.document.hint, "Treat")
        XCTAssertEqual(button.document.action, .run(["home", "scene", "SC-TREAT"]))
        let toggle = ControlDocument.read(Self.toggle(), slot: "toggle-1")
        XCTAssertEqual(toggle.notes, [])
        XCTAssertEqual(toggle.document.onText, "Lit")
        XCTAssertEqual(toggle.document.offSymbol, "lightbulb")
        XCTAssertEqual(toggle.document.tint, .hex(light: "#FFCC00", dark: "#FFDD55"))
        XCTAssertTrue(toggle.document.on)
    }

    /// Each rule on its own: the field falls back to its default, and the note names it.
    func testRefusesEach() {
        let cases: [(String, String, String, (ControlDocument) -> Bool)] = [
            ("symbol", Self.button { $0["symbol"] = "no.such.symbol.anywhere" }, "button-1", { $0.symbol == ControlDocument.defaultSymbol }),
            ("title", Self.button { $0["title"] = String(repeating: "x", count: 33) }, "button-1", { $0.title == ControlDocument.defaultTitle }),
            ("title", Self.button { $0["title"] = "two\nlines" }, "button-1", { $0.title == ControlDocument.defaultTitle }),
            ("subtitle", Self.button { $0["subtitle"] = String(repeating: "x", count: 33) }, "button-1", { $0.subtitle == nil }),
            ("tint", Self.button { $0["tint"] = "chartreuse" }, "button-1", { $0.tint == nil }),
            ("tint", Self.button { $0["tint"] = ["#FFFFFF"] }, "button-1", { $0.tint == nil }),
            ("hint", Self.button { $0["hint"] = String(repeating: "x", count: 33) }, "button-1", { $0.hint == nil }),
            ("onText", Self.toggle { $0["onText"] = String(repeating: "x", count: 17) }, "toggle-1", { $0.onText == nil }),
            ("offSymbol", Self.toggle { $0["offSymbol"] = "no.such.symbol.anywhere" }, "toggle-1", { $0.offSymbol == nil }),
            ("on", Self.toggle { $0["on"] = "yes" }, "toggle-1", { !$0.on }),
            ("revision", Self.button { $0["revision"] = 99 }, "button-1", { $0.revision == 0 }),
            ("default", Self.button { $0["default"] = true }, "button-1", { !$0.isDefault }),
            ("colour", Self.button { $0["colour"] = "primary" }, "button-1", { $0.title == "Feed Daphne" }),
            ("action.kind", Self.button { $0["action"] = ["kind": "launch"] }, "button-1", { $0.action == .turn(say: nil) }),
            ("action.topo", Self.button { $0["action"] = ["kind": "run", "topo": ["calendar", "add", "x"]] }, "button-1",
             { $0.action == .turn(say: nil) }),
        ]
        for (field, text, slot, holds) in cases {
            let reading = ControlDocument.read(text, slot: slot)
            XCTAssertEqual(reading.state, .read, "\(field): the document was refused whole")
            XCTAssertEqual(reading.notes.count, 1, "\(field): \(reading.notes)")
            XCTAssertTrue(reading.notes.first?.hasPrefix(field + " ") == true, "\(field): the note names \(reading.notes)")
            XCTAssertTrue(holds(reading.document), "\(field): did not fall back to its default")
        }
    }

    /// One bad field costs that field: everything else of the document stands.
    func testBadFieldKeepsTheRest() {
        let reading = ControlDocument.read(Self.button {
            $0["symbol"] = "no.such.symbol.anywhere"
            $0["tint"] = 7
            $0["action"] = ["kind": "run", "topo": ["topo", "control", "set"]]
        }, slot: "button-4")
        XCTAssertEqual(reading.notes.count, 3, "\(reading.notes)")
        XCTAssertEqual(reading.document.title, "Feed Daphne")
        XCTAssertEqual(reading.document.subtitle, "one treat")
        XCTAssertEqual(reading.document.hint, "Treat")
        XCTAssertEqual(reading.document.symbol, ControlDocument.defaultSymbol)
        XCTAssertEqual(reading.document.action, ControlDocument.standard(slot: "button-4").action,
                       "a refused action is the default's, a turn naming the slot")
    }

    /// A placed control's kind is fixed, so a document of the other kind writes nothing.
    func testKindMustMatchSlot() {
        for (text, slot) in [(Self.toggle(), "button-1"), (Self.button(), "toggle-1"),
                             (Self.toggle { $0["kind"] = nil }, "button-1"), (Self.button { $0["kind"] = nil }, "toggle-1"),
                             (Self.button { $0["kind"] = "slider" }, "button-1")] {
            let reading = ControlDocument.read(text, slot: slot)
            guard case .unreadable = reading.state else { return XCTFail("\(slot) took the other kind's document: \(text)") }
        }
        XCTAssertEqual(ControlDocument.read(Self.button { $0["kind"] = nil }, slot: "button-1").state, .read,
                       "a document that names no kind is its slot's")
    }

    /// A toggle's run is judged with on and with off appended, and refused if either is.
    func testToggleJudgedBothWays() {
        let lock = ControlDocument.read(Self.toggle { $0["action"] = ["kind": "run", "topo": ["home", "set", "LOCK-1", "lock"]] },
                                        slot: "toggle-2")
        XCTAssertEqual(lock.document.action, .turn(say: nil))
        XCTAssertTrue(lock.notes.first?.contains("with on appended") == true, "\(lock.notes)")
        let lamp = ControlDocument.read(Self.toggle(), slot: "toggle-2").document
        XCTAssertEqual(lamp.argv(turningOn: true), ["home", "set", "LAMP-1", "power", "on"])
        XCTAssertEqual(lamp.argv(turningOn: false), ["home", "set", "LAMP-1", "power", "off"])
    }

    func testTheTurnsWords() {
        XCTAssertEqual(ControlDocument.standard(slot: "button-3").turn(slot: "button-3", turningOn: nil), "control button-3: tapped, not set")
        let say = ControlDocument.read(Self.button { $0["action"] = ["kind": "turn", "say": "feed her"] }, slot: "button-3").document
        XCTAssertEqual(say.turn(slot: "button-3", turningOn: nil), "control button-3: feed her")
        let plain = ControlDocument.read(Self.toggle { $0["action"] = ["kind": "turn"] }, slot: "toggle-6").document
        XCTAssertEqual(plain.turn(slot: "toggle-6", turningOn: false), "control toggle-6: tapped off")
        XCTAssertNil(ControlDocument.read(Self.button(), slot: "button-3").document.turn(slot: "button-3", turningOn: nil))
    }

    /// What the app keeps reads back as itself, revision and default marker included.
    func testTheKeptCopyReadsBackAsItself() {
        var document = ControlDocument.read(Self.toggle(), slot: "toggle-3").document
        document.revision = 12
        let back = ControlDocument.read(document.text, slot: "toggle-3", from: .store)
        XCTAssertEqual(back.notes, [])
        XCTAssertEqual(back.document, document)
        var standard = ControlDocument.standard(slot: "button-5")
        standard.revision = 3
        XCTAssertEqual(ControlDocument.read(standard.text, slot: "button-5", from: .store).document, standard)
    }

    /// Every fixture of this suite, refused fields included: what `ControlValueTests` draws.
    static var fixtures: [(String, String)] {
        [(button(), "button-1"), (toggle(), "toggle-1"),
         (button { $0["symbol"] = "no.such.symbol"; $0["tint"] = "nope" }, "button-2"),
         (toggle { $0["onSymbol"] = "no.such.symbol"; $0["tint"] = ["#GGGGGG", "#000000"] }, "toggle-2"),
         (button { $0 = ["title": 5] }, "button-3"), (toggle { $0 = [:] }, "toggle-3"),
         (button { $0["tint"] = ["#000000", "#FFFFFF"] }, "button-4")]
    }
}

/// Review Focus 2: the value is the slot at the moment it is read, and nothing it carries can
/// trap in the system's drawing.
final class ControlValueTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("control-value-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func testValueIsTheSlot() throws {
        let store = SurfaceStore(folder: folder)
        let written = ControlDocument.read(ControlDocumentTests.toggle(), slot: "toggle-2").document
        let revision = try store.writeControl(written, slot: "toggle-2")
        let value = ControlValue.read(slot: "toggle-2", store: store)
        XCTAssertEqual(value.slot, "toggle-2")
        XCTAssertEqual(value.revision, revision)
        XCTAssertEqual(value.title, "Lamp")
        XCTAssertEqual(value.symbol, "lightbulb")
        XCTAssertEqual(value.onSymbol, "lightbulb.fill")
        XCTAssertEqual(value.tint, .hex(light: "#FFCC00", dark: "#FFDD55"))
        XCTAssertTrue(value.on)
        XCTAssertFalse(value.isDefault)
        XCTAssertFalse(value.signedOut)

        let standard = try store.writeControl(ControlDocument.standard(slot: "button-5"), slot: "button-5")
        let fallback = ControlValue.read(slot: "button-5", store: store)
        XCTAssertTrue(fallback.isDefault)
        XCTAssertEqual(fallback.revision, standard)
        XCTAssertEqual(fallback.subtitle, "button-5", "a default carries its slot's own name")
        XCTAssertEqual(fallback.symbol, ControlDocument.defaultSymbol)

        let empty = ControlValue.read(slot: "button-6", store: store)
        XCTAssertTrue(empty.signedOut, "a slot holding nothing is the signed-out phone's")
        XCTAssertEqual(empty.title, "Sign in")
        XCTAssertEqual(ControlValue.read(slot: "button-1", store: nil), empty.with(slot: "button-1"))
    }

    func testValueSurvivesAnyDocument() throws {
        let store = SurfaceStore(folder: folder)
        var values = ControlSlot.all.map { ControlValue.signedOut(slot: $0) }
        for (text, slot) in ControlDocumentTests.fixtures {
            let reading = ControlDocument.read(text, slot: slot)
            XCTAssertEqual(reading.state, .read, "\(slot): \(text)")
            try store.writeControl(reading.document, slot: slot)
            values.append(ControlValue.read(slot: slot, store: store))
        }
        for slot in ControlSlot.all {
            values.append(ControlValue(slot: slot, document: .standard(slot: slot)))
        }
        for value in values {
            for symbol in [value.symbol, value.onSymbol, value.offSymbol] {
                XCTAssertNotNil(UIImage(systemName: symbol), "\(value.slot) draws \(symbol), which the system lacks")
            }
            guard let tint = value.tint else { continue }
            for style in [UIUserInterfaceStyle.light, .dark] {
                let colour = UIColor(tint.color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
                var parts: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
                XCTAssertTrue(colour.getRed(&parts.0, green: &parts.1, blue: &parts.2, alpha: &parts.3))
                XCTAssertTrue([parts.0, parts.1, parts.2, parts.3].allSatisfy(\.isFinite), "\(value.slot)'s tint is not finite")
            }
        }
    }
}

private extension ControlValue {
    func with(slot: String) -> ControlValue { ControlValue.signedOut(slot: slot) }
}

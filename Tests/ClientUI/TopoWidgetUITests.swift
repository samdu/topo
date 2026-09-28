import UIKit
import XCTest

/// Review Focus 2, the elements and the taps: each family's fixture drawn by `WidgetNodeView` in
/// the app's debug host (`TOPO_DEBUG_WIDGET`), every text and control found by its identifier,
/// and every button, toggle and link tapped, with what it handed on — the cue's words, the run's
/// call, the URL — read back off the host's `widget-handed` line.
///
/// The fixture is walked here as JSON rather than through the app's reader, so what the test
/// expects is what the document says and not what the reader made of it.
@MainActor
final class TopoWidgetUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    static let families = ["systemSmall", "systemMedium", "systemLarge",
                           "accessoryCircular", "accessoryRectangular", "accessoryInline"]

    func testEveryTextAndControlIsFoundAndEachTapHandsOnItsAction() throws {
        for family in Self.families {
            try check(family)
        }
    }

    private func fixture(_ family: String) throws -> (String, [String: Any]) {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: family, withExtension: "json"), "no fixture \(family)")
        let text = try String(contentsOf: url, encoding: .utf8)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let families = try XCTUnwrap(root["families"] as? [String: Any])
        return (text, try XCTUnwrap(families[family] as? [String: Any]))
    }

    /// Every text and control in the tree, with the path `WidgetNodeView` names it by.
    private func walk(_ node: [String: Any], _ path: String, texts: inout [String], controls: inout [[String: Any]]) {
        switch node["kind"] as? String {
        case "text": texts.append("widget-text-\(path)")
        case "button", "toggle", "link": controls.append(node)
        default: break
        }
        for (index, child) in ((node["children"] as? [[String: Any]]) ?? []).enumerated() {
            walk(child, "\(path).\(index)", texts: &texts, controls: &controls)
        }
    }

    /// What a tap on `control` hands on, as the host writes it down.
    private func expected(_ control: [String: Any]) -> String {
        let id = control["id"] as! String
        let kind = control["kind"] as! String
        let action = control["action"] as! [String: Any]
        let on = control["on"] as? Bool ?? false
        switch action["kind"] as! String {
        case "open":
            return "url: topo://open"
        case "run":
            var argv = action["topo"] as! [String]
            if kind == "toggle" { argv.append(on ? "off" : "on") }
            return "run: " + argv.joined(separator: " ")
        default:
            let say = action["say"] as? String
            if kind == "link" {
                var parts = URLComponents()
                parts.scheme = "topo"
                parts.host = "cue"
                parts.queryItems = [URLQueryItem(name: "slot", value: "fixture"), URLQueryItem(name: "control", value: id),
                                    URLQueryItem(name: "revision", value: "0")] + (say.map { [URLQueryItem(name: "say", value: $0)] } ?? [])
                return "url: " + parts.url!.absoluteString
            }
            var words = say ?? "tapped \(id)"
            if kind == "toggle" { words += on ? " off" : " on" }
            return "cue: widget fixture: \(words)"
        }
    }

    private func check(_ family: String) throws {
        let (text, tree) = try fixture(family)
        let app = XCUIApplication()
        app.launchEnvironment["TOPO_DEBUG_WIDGET"] = text
        app.launch()
        let handed = app.staticTexts["widget-handed"]
        XCTAssertTrue(handed.waitForExistence(timeout: 30), "\(family): the host never came up")

        var texts: [String] = []
        var controls: [[String: Any]] = []
        walk(tree, "0", texts: &texts, controls: &controls)
        for identifier in texts {
            let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 5), "\(family): no \(identifier)")
        }
        for control in controls {
            let id = control["id"] as! String
            let element = app.descendants(matching: .any).matching(identifier: "widget-control-\(id)").firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 5), "\(family): no control \(id)")
            element.tap()
            let want = expected(control)
            // A `topo://` link opens the app it is in; the host hears it as the URL comes back.
            let arrived = NSPredicate { _, _ in (handed.value as? String)?.components(separatedBy: "\n").last == want }
            let wait = expectation(for: arrived, evaluatedWith: nil)
            let result = XCTWaiter().wait(for: [wait], timeout: 10)
            if result != .completed {
                let tree = XCTAttachment(string: app.debugDescription)
                tree.name = "\(family) after \(id)"
                tree.lifetime = .keepAlways
                add(tree)
            }
            XCTAssertEqual(result, .completed, "\(family): \(id) handed on \(handed.value ?? "nothing"), not \(want)")
        }
        app.terminate()
    }
}

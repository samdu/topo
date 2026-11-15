import ObjectiveC
import XCTest

/// Types into the focused element without the words reaching anything XCTest records.
///
/// `XCUIElement.typeText` writes what it types into its activity's title, a secure field
/// included, and the title reaches xcodebuild's output and the result bundle. Beneath it,
/// XCUIAutomation synthesizes the keystrokes as an event record whose text path takes a
/// `shouldRedact` flag; this calls that path directly, under a record named for what it is.
/// The classes are XCUIAutomation's own and not public, so each selector is checked against the
/// type encoding it was written for, and a mismatch throws before anything is typed.
/// `scripts/simulator-run.sh --leak-check` proves on a dummy that nothing it types is recorded.
@MainActor
enum RedactedTyping {
    struct Unavailable: Error, CustomStringConvertible { let description: String }

    /// Types `text` into `field` once it holds the keyboard's focus, and throws, having typed
    /// nothing, if it does not within `focusTimeout`: the synthesized keystrokes go to whatever has
    /// the focus, and do not wait for an element to take it as `typeText` does. The test asks the
    /// field itself (`hasKeyboardFocus`) rather than whether a keyboard is up, as
    /// `ChatReading.raiseKeyboard` does: a keyboard says some field has the focus, not which, and a
    /// password belongs in one field only. `hasKeyboardFocus` is an attribute of the element's
    /// snapshot that XCTest's headers do not declare, so it is not public API either.
    static func type(_ text: String, into field: XCUIElement, record name: String, focusTimeout: TimeInterval = 10) throws {
        let focus = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
        guard XCTWaiter().wait(for: [focus], timeout: focusTimeout) == .completed else {
            throw Unavailable(description: "the field did not take the keyboard's focus within \(Int(focusTimeout)) s; nothing was typed")
        }
        try type(text, record: name)
    }

    private static func type(_ text: String, record name: String) throws {
        let pathClass: AnyClass = try someClass("XCPointerEventPath")
        let recordClass: AnyClass = try someClass("XCSynthesizedEventRecord")

        typealias Make = @convention(c) (AnyObject, Selector) -> AnyObject?
        typealias Name = @convention(c) (AnyObject, Selector, NSString, Int) -> AnyObject?
        typealias TypeText = @convention(c) (AnyObject, Selector, NSString, Double, UInt64, Bool) -> Void
        typealias Add = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        typealias Synthesize = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> Bool

        let alloc = NSSelectorFromString("alloc")
        let pathInit: Make = try method(pathClass, "initForTextInput", "@16@0:8")
        let typeText: TypeText = try method(pathClass, "typeText:atOffset:typingSpeed:shouldRedact:", "v44@0:8@16d24Q32B40")
        let recordInit: Name = try method(recordClass, "initWithName:interfaceOrientation:", "@32@0:8@16q24")
        let add: Add = try method(recordClass, "addPointerEventPath:", "v24@0:8@16")
        let synthesize: Synthesize = try method(recordClass, "synthesizeWithError:", "B24@0:8^@16")

        guard let pathShell = (pathClass as AnyObject).perform(alloc)?.takeUnretainedValue(),
              let path = pathInit(pathShell, NSSelectorFromString("initForTextInput")),
              let recordShell = (recordClass as AnyObject).perform(alloc)?.takeUnretainedValue(),
              let record = recordInit(recordShell, NSSelectorFromString("initWithName:interfaceOrientation:"),
                                      name as NSString, UIDeviceOrientation.portrait.rawValue)
        else { throw Unavailable(description: "XCUIAutomation made no event record") }
        typeText(path, NSSelectorFromString("typeText:atOffset:typingSpeed:shouldRedact:"), text as NSString, 0, 30, true)
        add(record, NSSelectorFromString("addPointerEventPath:"), path)
        var error: NSError?
        guard synthesize(record, NSSelectorFromString("synthesizeWithError:"), &error) else {
            throw Unavailable(description: "the keystrokes were not synthesized: \(error.map { "\($0.domain) \($0.code)" } ?? "no error")")
        }
    }

    private static func someClass(_ name: String) throws -> AnyClass {
        guard let found = NSClassFromString(name) else { throw Unavailable(description: "XCUIAutomation has no \(name)") }
        return found
    }

    private static func method<T>(_ owner: AnyClass, _ name: String, _ encoding: String) throws -> T {
        let selector = NSSelectorFromString(name)
        guard let found = class_getInstanceMethod(owner, selector),
              let types = method_getTypeEncoding(found).map({ String(cString: $0) })
        else { throw Unavailable(description: "\(NSStringFromClass(owner)) has no \(name)") }
        guard types == encoding else {
            throw Unavailable(description: "\(NSStringFromClass(owner)).\(name) is \(types), not \(encoding); nothing was typed")
        }
        return unsafeBitCast(method_getImplementation(found), to: T.self)
    }
}

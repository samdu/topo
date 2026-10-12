import ReplayKit
import SwiftUI
import XCTest
@testable import Topo

@MainActor
final class ScreenShareSectionTests: XCTestCase {
    /// The system's button is the picker's own subview, and it is what a press has to land on:
    /// a press on the picker around it starts nothing.
    func testAPressOnTheSettingsRowLandsOnTheSystemsButton() throws {
        let host = UIHostingController(rootView: List { ScreenShareSection() })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let picker = try XCTUnwrap(Self.picker(in: window))
        XCTAssertEqual(picker.preferredExtension, BroadcastButton.broadcast)
        XCTAssertFalse(picker.showsMicrophoneButton)
        let centre = picker.convert(CGPoint(x: picker.bounds.midX, y: picker.bounds.midY), to: window)
        let pressed = try XCTUnwrap(window.hitTest(centre, with: nil))
        XCTAssertTrue(pressed is UIButton && pressed.superview === picker, "a press on the row lands on \(type(of: pressed)), not the system's button")
    }

    private static func picker(in view: UIView) -> RPSystemBroadcastPickerView? {
        if let picker = view as? RPSystemBroadcastPickerView { return picker }
        for child in view.subviews {
            if let picker = picker(in: child) { return picker }
        }
        return nil
    }
}

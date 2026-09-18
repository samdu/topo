import SwiftUI
import UIKit
import XCTest

@testable import Topo

/// The palette as a contract. What a token *looks* like is a drawing decision, but three things
/// about it are not: an accent has to be a different colour in each appearance or a surface in
/// one of them is wearing the other's, an ink has to clear WCAG AA against the fill it is named
/// for, and a neutral has to be the system colour it claims to alias rather than a value of ours
/// that merely resembles it. Everything here is read off the resolved components, so it fails on
/// the colour that ships and not on the literal in the source.
final class ThemeTests: XCTestCase {
    private let light = UITraitCollection(userInterfaceStyle: .light)
    private let dark = UITraitCollection(userInterfaceStyle: .dark)

    /// sRGB components of a token as it resolves in one appearance.
    private func components(_ color: Color, _ traits: UITraitCollection) -> (Double, Double, Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    private func hex(_ color: Color, _ traits: UITraitCollection) -> String {
        let (r, g, b) = components(color, traits)
        return String(format: "#%02X%02X%02X", Int(r * 255 + 0.5), Int(g * 255 + 0.5),
                      Int(b * 255 + 0.5))
    }

    /// WCAG relative luminance.
    private func luminance(_ color: Color, _ traits: UITraitCollection) -> Double {
        let (r, g, b) = components(color, traits)
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    private func contrast(_ ink: Color, on fill: Color, _ traits: UITraitCollection) -> Double {
        let a = luminance(ink, traits), b = luminance(fill, traits)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Every accent is its own colour, and a different one in each appearance: a token that
    /// resolved the same either way would be one appearance wearing the other's palette.
    func testAccentsDifferByAppearance() {
        let accents: [(String, Color)] = [("primary", Theme.primary), ("secondary", Theme.secondary),
                                          ("highlight", Theme.highlight), ("signal", Theme.signal)]
        for (name, accent) in accents {
            XCTAssertNotEqual(hex(accent, light), hex(accent, dark),
                              "\(name) resolves to the same colour in both appearances")
        }
        for appearance in [("light", light), ("dark", dark)] {
            let resolved = accents.map { hex($0.1, appearance.1) }
            XCTAssertEqual(Set(resolved).count, accents.count,
                           "two accents share a colour in \(appearance.0): \(resolved)")
        }
    }

    /// Each ink clears WCAG AA against the fill it is named for, in both appearances. The margin
    /// is thin by design — changing a role's hue or lightness re-opens this.
    func testInksClearContrastOnTheirFills() {
        let pairs: [(String, Color, Color)] = [("onPrimary", Theme.onPrimary, Theme.primary),
                                               ("onSecondary", Theme.onSecondary, Theme.secondary)]
        for (name, ink, fill) in pairs {
            for (appearance, traits) in [("light", light), ("dark", dark)] {
                let ratio = contrast(ink, on: fill, traits)
                XCTAssertGreaterThanOrEqual(
                    ratio, 4.5,
                    "\(name) on its fill reads \(String(format: "%.2f", ratio)):1 in \(appearance)")
            }
        }
    }

    /// The neutrals are Apple's, not ours: each is the system colour it names, in both
    /// appearances, so a surface follows the person's settings rather than a literal of ours.
    func testNeutralsAreTheSystemColoursTheyName() {
        let aliases: [(String, Color, UIColor)] = [
            ("background", Theme.background, .systemBackground),
            ("surface", Theme.surface, .secondarySystemBackground),
            ("border", Theme.border, .separator),
            ("text", Theme.text, .label),
            ("textMuted", Theme.textMuted, .secondaryLabel),
        ]
        for (name, token, system) in aliases {
            for (appearance, traits) in [("light", light), ("dark", dark)] {
                XCTAssertEqual(hex(token, traits), hex(Color(uiColor: system), traits),
                               "\(name) is not \(system) in \(appearance)")
            }
        }
    }

    /// The seed is fixed: the mark and the icon gradient are the same teal whatever the
    /// appearance, which is the one thing about it that is not a palette decision.
    func testSeedIsFixed() {
        XCTAssertEqual(hex(Theme.teal, light), "#1E8C9E")
        XCTAssertEqual(hex(Theme.teal, dark), "#1E8C9E")
    }
}

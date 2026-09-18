import SwiftUI
import UIKit
import XCTest

@testable import Topo

/// The palette as a contract. What a token *looks* like is a drawing decision, but what it *is* is
/// not: each accent and ink is the pair the visual-identity derivation gave it and is opaque, an
/// accent differs by appearance and from its neighbours or a surface is wearing the wrong side's
/// colour, an ink clears WCAG AA against the fill it is named for, and a neutral is the system
/// colour it claims to alias rather than a value of ours that merely resembles it. Everything here
/// is read off the resolved components, so it fails on the colour that ships and not on the
/// literal in the source.
final class ThemeTests: XCTestCase {
    private let light = UITraitCollection(userInterfaceStyle: .light)
    private let dark = UITraitCollection(userInterfaceStyle: .dark)

    /// sRGB components of a token as it resolves in one appearance.
    private func components(_ color: Color, _ traits: UITraitCollection)
        -> (r: Double, g: Double, b: Double, a: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
    }

    /// Every accent and ink, by name, with the pair the palette says it is.
    private var palette: [(name: String, color: Color, light: String, dark: String)] {
        [("primary", Theme.primary, "#007687", "#00A4BB"),
         ("secondary", Theme.secondary, "#8D5B86", "#CD96C4"),
         ("highlight", Theme.highlight, "#1679AF", "#6AC1FB"),
         ("signal", Theme.signal, "#796000", "#BDA24D"),
         ("onPrimary", Theme.onPrimary, "#FAFEFF", "#090E0F"),
         ("onSecondary", Theme.onSecondary, "#FAFEFF", "#090E0F")]
    }

    private func hex(_ color: Color, _ traits: UITraitCollection) -> String {
        let (r, g, b, _) = components(color, traits)
        return String(format: "#%02X%02X%02X", Int(r * 255 + 0.5), Int(g * 255 + 0.5),
                      Int(b * 255 + 0.5))
    }

    /// WCAG relative luminance.
    private func luminance(_ color: Color, _ traits: UITraitCollection) -> Double {
        let (r, g, b, _) = components(color, traits)
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    private func contrast(_ ink: Color, on fill: Color, _ traits: UITraitCollection) -> Double {
        let a = luminance(ink, traits), b = luminance(fill, traits)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The palette itself, pinned. The six pairs are derived from the teal seed by the
    /// visual-identity method (OKLCH, triadic at 28 degrees, chroma x1.3, `primary` at role
    /// lightness 0.52 light and 0.66 dark), and the derivation lives in the palette lab rather
    /// than in Swift, so nothing else here would notice a value moving, or a light and a dark
    /// swapping places. Changing a token means changing this table too, which is the point: it
    /// re-opens the contrast the other tests hold.
    func testPaletteIsThePairsItClaims() {
        for token in palette {
            XCTAssertEqual(hex(token.color, light), token.light, "\(token.name) in light")
            XCTAssertEqual(hex(token.color, dark), token.dark, "\(token.name) in dark")
        }
    }

    /// Every accent and ink is fully opaque in both appearances. A token that is not is one whose
    /// drawn colour is whatever is behind it, which no contrast this file computes would be about
    /// and no caller could see from the token's name.
    func testAccentsAndInksAreOpaque() {
        for token in palette {
            for (appearance, traits) in [("light", light), ("dark", dark)] {
                XCTAssertEqual(components(token.color, traits).a, 1, accuracy: 0.001,
                               "\(token.name) is not opaque in \(appearance)")
            }
        }
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

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Topo teal, the default scheme: the seed `#1E8C9E` expanded by the house method (OKLCH
/// triadic at 28°, chroma ×1.3), one value per role per mode. Colour says who is on the other
/// end, never state: a control keeps its role's colour idle or active, and state is carried
/// by fill.
enum Theme {
    /// The seed itself, where a single fixed colour is wanted (the icon gradient, the mark).
    static let teal = Color(red: 0x1E / 255, green: 0x8C / 255, blue: 0x9E / 255)

    /// Topo's own voice, and the controls that address it.
    static let primary = adaptive(light: 0x007687, dark: 0x00A4BB)
    /// The person's side: their bubble.
    static let secondary = adaptive(light: 0x8D5B86, dark: 0xCD96C4)
    /// Tiles, chips, progress, confirmations.
    static let highlight = adaptive(light: 0x1679AF, dark: 0x6AC1FB)
    /// Measured liveness: an open microphone, status dots, failures.
    static let signal = adaptive(light: 0x796000, dark: 0xBDA24D)
    /// Ink on a primary or secondary fill.
    static let onPrimary = adaptive(light: 0xFAFEFF, dark: 0x090E0F)
    static let onSecondary = adaptive(light: 0xFAFEFF, dark: 0x090E0F)
    /// The ground: tinted off-white, and true black on OLED.
    static let background = adaptive(light: 0xF4FCFD, dark: 0x000000)
    /// A raised panel; the family tint lives here, not in the ground.
    static let surface = adaptive(light: 0xEEF3F4, dark: 0x0F1415)
    static let border = adaptive(light: 0xD2D9DA, dark: 0x262B2C)
    static let text = adaptive(light: 0x191E1F, dark: 0xE5EDEE)
    static let textMuted = adaptive(light: 0x646A6C, dark: 0x939A9B)

    /// One colour that follows the appearance.
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light)
        })
        #elseif canImport(AppKit)
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
        #else
        Color(rgb: light)
        #endif
    }
}

private extension Color {
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#elseif canImport(AppKit)
private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#endif

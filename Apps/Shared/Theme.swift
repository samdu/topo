import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Topo teal, the scheme every surface wears: the seed `#1E8C9E` expanded by the house method
/// (OKLCH, triadic at a 28° spread, chroma ×1.3, `primary` at role lightness 0.52 light and
/// 0.66 dark), one value per role per appearance.
///
/// **Colour says who is on the other end; it never says state.** `primary` is Topo's own voice
/// and the controls that address it, `secondary` the person's side, `highlight` tiles, chips and
/// progress, `signal` measured liveness alone — a status dot, an open microphone, a failure mark
/// — and never a bubble's state. A control keeps its role's colour idle or active: state is
/// carried by fill and by motion, never by a change of hue.
///
/// The neutrals are Apple's semantic colours rather than values of ours, so a surface follows the
/// person's appearance, contrast and accessibility settings as the system means it to. Only the
/// four accents and their two inks are ours to name.
enum Theme {
    /// The seed itself, where one fixed colour is wanted whatever the appearance: the mark and
    /// the icon gradient.
    static let teal = Color(red: 0x1E / 255, green: 0x8C / 255, blue: 0x9E / 255)

    // MARK: Accents

    /// Topo's own voice, and the controls that address it.
    static let primary = adaptive(light: 0x007687, dark: 0x00A4BB)
    /// The person's side: the outline on their own bubble.
    static let secondary = adaptive(light: 0x8D5B86, dark: 0xCD96C4)
    /// Tiles and indicators: chips, progress, confirmations.
    static let highlight = adaptive(light: 0x1679AF, dark: 0x6AC1FB)
    /// Measured liveness: a status dot, an open microphone, a failure.
    static let signal = adaptive(light: 0x796000, dark: 0xBDA24D)

    /// Ink on a `primary` fill. 5.2:1 light, 6.5:1 dark.
    static let onPrimary = adaptive(light: 0xFAFEFF, dark: 0x090E0F)
    /// Ink on a `secondary` fill. 5.2:1 light, 8.1:1 dark.
    static let onSecondary = adaptive(light: 0xFAFEFF, dark: 0x090E0F)

    // MARK: Neutrals — Apple's, not ours

    /// The ground a screen sits on.
    static let background = systemBackground
    /// A raised panel over the ground.
    static let surface = systemSurface
    /// A hairline between two of them.
    static let border = systemBorder
    /// Body text.
    static let text = Color.primary
    /// Text that supports it: a timestamp, a caption.
    static let textMuted = Color.secondary

    /// One colour that follows the appearance. The watch has one appearance, so it takes the
    /// dark value and asks the system for nothing.
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        #if os(watchOS)
        Color(rgb: dark)
        #elseif canImport(UIKit)
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

// The semantic neutrals each platform actually has: iOS names its background tiers, the hub takes
// AppKit's, and the other two have none to name.
private extension Theme {
    #if os(iOS) || os(visionOS)
    static let systemBackground = Color(uiColor: .systemBackground)
    static let systemSurface = Color(uiColor: .secondarySystemBackground)
    static let systemBorder = Color(uiColor: .separator)
    #elseif os(macOS)
    static let systemBackground = Color(nsColor: .windowBackgroundColor)
    static let systemSurface = Color(nsColor: .controlBackgroundColor)
    static let systemBorder = Color(nsColor: .separatorColor)
    #else
    // The television and the watch name no background tier, so the ground is the black they are
    // drawn on and what sits over it is the system's own ink at a panel's weight.
    static let systemBackground = Color.black
    static let systemSurface = Color.primary.opacity(0.08)
    static let systemBorder = Color.primary.opacity(0.2)
    #endif
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

import UIKit

/// Topo teal, and the greys around it. Dark mode is an iOS 13 feature; on
/// iOS 12 every colour here is its light value, which is what those devices
/// have always shown.
enum Palette {
    /// Seed `#1E8C9E`, the default Topo scheme.
    static let teal = UIColor(red: 0x1E / 255, green: 0x8C / 255, blue: 0x9E / 255, alpha: 1)
    static let tealLight = UIColor(red: 0x5C / 255, green: 0xC3 / 255, blue: 0xD4 / 255, alpha: 1)

    static let background = dynamic(light: .white, dark: UIColor(white: 0.09, alpha: 1))
    static let text = dynamic(light: UIColor(white: 0.11, alpha: 1), dark: UIColor(white: 0.95, alpha: 1))
    static let secondaryText = dynamic(light: UIColor(white: 0.45, alpha: 1), dark: UIColor(white: 0.62, alpha: 1))
    static let separator = dynamic(light: UIColor(white: 0.90, alpha: 1), dark: UIColor(white: 0.22, alpha: 1))
    static let accent = dynamic(light: teal, dark: tealLight)

    private static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        if #available(iOS 13.0, *) {
            return UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light }
        }
        return light
    }
}

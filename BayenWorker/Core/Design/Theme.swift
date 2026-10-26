import SwiftUI
import UIKit

/// Design tokens. The house style comes from the Bayen logo: a forest-green pin with a white check on a warm
/// ivory tile, an ink-green serif wordmark. Surfaces are cream and ivory, text is green-black ink, and the
/// status colours are earthy so nothing shouts over the brand green.
enum Theme {
    // MARK: Brand

    /// The logo green. Interactive tint, primary buttons, brand marks.
    static let primary = Color(light: UIColor(hex: 0x1E5B42), dark: UIColor(hex: 0x7CC6A1))
    static let onPrimary = Color(light: UIColor(hex: 0xFBF8F1), dark: UIColor(hex: 0x0A1912))
    /// Two stops used for primary buttons and brand surfaces: the soft top-lit sweep of the logo's pin.
    static let primaryGradient = LinearGradient(
        colors: [Color(light: UIColor(hex: 0x2B7254), dark: UIColor(hex: 0x93D3B2)),
                 Color(light: UIColor(hex: 0x1A5039), dark: UIColor(hex: 0x6AB690))],
        startPoint: .top, endPoint: .bottom)
    /// The pin itself; stays a deep green in dark mode so the mark reads as the logo, not as a tint.
    static let brandPinGradient = LinearGradient(
        colors: [Color(light: UIColor(hex: 0x2E7457), dark: UIColor(hex: 0x3A8763)),
                 Color(light: UIColor(hex: 0x1C543C), dark: UIColor(hex: 0x24654A))],
        startPoint: .top, endPoint: .bottom)
    /// Green-black ink of the wordmark.
    static let ink = Color(light: UIColor(hex: 0x14271D), dark: UIColor(hex: 0xF2EEE4))

    // MARK: Surfaces

    static let background = Color(light: UIColor(hex: 0xF4EFE5), dark: UIColor(hex: 0x0B100D))
    static let card = Color(light: UIColor(hex: 0xFCFAF5), dark: UIColor(hex: 0x141B17))
    static let cardElevated = Color(light: UIColor(hex: 0xFFFDF9), dark: UIColor(hex: 0x1B241F))
    static let fill = Color(light: UIColor(hex: 0x3B3220, alpha: 0.055), dark: UIColor(white: 1, alpha: 0.07))
    /// Opaque, so floating disabled buttons never show content scrolling behind them.
    static let disabledFill = Color(light: UIColor(hex: 0xE7E0D2), dark: UIColor(hex: 0x1E2722))
    static let hairline = Color(light: UIColor(hex: 0x4A3B22, alpha: 0.11), dark: UIColor(white: 1, alpha: 0.08))
    /// Top-edge light on cards and buttons, the embossed feel of the logo tile.
    static let highlight = Color(light: UIColor(white: 1, alpha: 0.9), dark: UIColor(white: 1, alpha: 0.06))
    static let shadow = Color(light: UIColor(hex: 0x4A3B22, alpha: 0.10), dark: UIColor(white: 0, alpha: 0.5))
    /// Warm sand used for the ambient glow behind screens.
    static let sand = Color(light: UIColor(hex: 0xE8D9BC), dark: UIColor(hex: 0x2A2519))

    // MARK: Text

    static let textPrimary = ink
    static let textSecondary = Color(light: UIColor(hex: 0x5A655D), dark: UIColor(hex: 0xA6AFA8))
    static let textTertiary = Color(light: UIColor(hex: 0x8E958C), dark: UIColor(hex: 0x6E7871))

    // MARK: Semantic

    static let info = Color(light: UIColor(hex: 0x2D6A88), dark: UIColor(hex: 0x7FB8D6))
    static let success = Color(light: UIColor(hex: 0x2F8650), dark: UIColor(hex: 0x62D092))
    static let warning = Color(light: UIColor(hex: 0xA6680E), dark: UIColor(hex: 0xEDB25A))
    static let danger = Color(light: UIColor(hex: 0xB4412E), dark: UIColor(hex: 0xF07C66))
    static let neutral = Color(light: UIColor(hex: 0x767C73), dark: UIColor(hex: 0xA0A79F))

    // MARK: Shape & size

    static let cornerRadius: CGFloat = 22
    static let innerRadius: CGFloat = 16
    static let smallRadius: CGFloat = 12
    /// Minimum height of primary buttons (well above the 44 pt HIG minimum, for gloved/tired hands).
    static let bigButtonHeight: CGFloat = 60
    static let fieldHeight: CGFloat = 58
    static let screenPadding: CGFloat = 20
}

extension Font {
    /// Serif display face (New York) echoing the wordmark; for titles and big figures, never body copy.
    static func display(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .serif, weight: weight)
    }
}

extension UIFont {
    /// UIKit twin of `Font.display`, for navigation bar titles.
    static func display(_ style: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
        let base = UIFontDescriptor.preferredFontDescriptor(withTextStyle: style)
        let descriptor = (base.withDesign(.serif) ?? base)
            .addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: 0)
    }
}

/// Shared animation curves so every screen moves with the same physics.
enum Motion {
    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.82)
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.78)
    static let gentle = Animation.easeInOut(duration: 0.35)
    static let press = Animation.spring(response: 0.25, dampingFraction: 0.7)
}

extension Color {
    init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension TaskStatus {
    /// Same order of hues as the dashboard: assigned grey, in progress blue, submitted amber, approved green, rejected red.
    var color: Color {
        switch self {
        case .assigned, .unknown, .cancelled: return Theme.neutral
        case .inProgress: return Theme.info
        case .submitted: return Theme.warning
        case .approved: return Theme.success
        case .rejected: return Theme.danger
        }
    }

    var symbol: String {
        switch self {
        case .assigned: return "circle.dashed"
        case .inProgress: return "hammer.fill"
        case .submitted: return "hourglass"
        case .approved: return "checkmark.seal.fill"
        case .rejected: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    var label: String { L10n.tr("status.\(rawValue)") }
}

extension TaskCategory {
    var symbol: String {
        switch self {
        case .lighting: return "lightbulb.fill"
        case .roads: return "road.lanes"
        case .water: return "drop.fill"
        case .greenSpaces: return "tree.fill"
        case .waste: return "trash.fill"
        case .buildings: return "building.2.fill"
        case .other: return "wrench.and.screwdriver.fill"
        }
    }

    /// A restrained per-category tint for icon tiles, so the list scans faster without getting loud.
    var tint: Color {
        switch self {
        case .lighting: return Color(light: UIColor(hex: 0xB07D12), dark: UIColor(hex: 0xEDC163))
        case .roads: return Color(light: UIColor(hex: 0x5B625C), dark: UIColor(hex: 0xADB5AE))
        case .water: return Color(light: UIColor(hex: 0x2D6E8E), dark: UIColor(hex: 0x7FBFDD))
        case .greenSpaces: return Color(light: UIColor(hex: 0x3A874C), dark: UIColor(hex: 0x76CF8C))
        case .waste: return Color(light: UIColor(hex: 0x76587F), dark: UIColor(hex: 0xC2A3CC))
        case .buildings: return Color(light: UIColor(hex: 0xA5552D), dark: UIColor(hex: 0xE89A6E))
        case .other: return Theme.primary
        }
    }

    var label: String { L10n.tr("category.\(rawValue)") }
}

extension PhotoKind {
    var label: String { L10n.tr("photo.kind.\(rawValue)") }
}

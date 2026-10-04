import SwiftUI
import UIKit

/// Design tokens. Brand colours come from the Bayen logo: navy (pin + wordmark), with the Moroccan red/green only
/// inside the emblem. Surfaces are quiet neutrals so the content and status colours carry the hierarchy.
enum Theme {
    // MARK: Brand

    static let primary = Color(light: UIColor(hex: 0x1A2C52), dark: UIColor(hex: 0x9DB4EC))
    static let onPrimary = Color(light: .white, dark: UIColor(hex: 0x0A1226))
    /// Two stops used for primary buttons and brand surfaces: a soft vertical light-to-deep sweep.
    static let primaryGradient = LinearGradient(
        colors: [Color(light: UIColor(hex: 0x2A4377), dark: UIColor(hex: 0xB4C7F3)),
                 Color(light: UIColor(hex: 0x15233F), dark: UIColor(hex: 0x86A0DD))],
        startPoint: .top, endPoint: .bottom)
    static let brandRed = Color(light: UIColor(hex: 0xC1272D), dark: UIColor(hex: 0xE5484D))
    static let brandGreen = Color(light: UIColor(hex: 0x006233), dark: UIColor(hex: 0x2FB36B))

    // MARK: Surfaces

    static let background = Color(light: UIColor(hex: 0xF3F4F7), dark: UIColor(hex: 0x07090D))
    static let card = Color(light: .white, dark: UIColor(hex: 0x12151C))
    static let cardElevated = Color(light: .white, dark: UIColor(hex: 0x1A1E28))
    static let fill = Color(light: UIColor(hex: 0x0B1220, alpha: 0.045), dark: UIColor(white: 1, alpha: 0.07))
    /// Opaque, so floating disabled buttons never show content scrolling behind them.
    static let disabledFill = Color(light: UIColor(hex: 0xE6E8EE), dark: UIColor(hex: 0x1E222B))
    static let hairline = Color(light: UIColor(hex: 0x0B1220, alpha: 0.07), dark: UIColor(white: 1, alpha: 0.08))
    static let shadow = Color(light: UIColor(hex: 0x0B1A3A, alpha: 0.08), dark: UIColor(white: 0, alpha: 0.5))

    // MARK: Text

    static let textPrimary = Color(light: UIColor(hex: 0x0B1220), dark: UIColor(hex: 0xF4F6FA))
    static let textSecondary = Color(light: UIColor(hex: 0x5B6475), dark: UIColor(hex: 0x9AA3B4))
    static let textTertiary = Color(light: UIColor(hex: 0x8D95A5), dark: UIColor(hex: 0x6A7284))

    // MARK: Semantic

    static let info = Color(light: UIColor(hex: 0x2F6BFF), dark: UIColor(hex: 0x6E9BFF))
    static let success = Color(light: UIColor(hex: 0x14935A), dark: UIColor(hex: 0x3DD68C))
    static let warning = Color(light: UIColor(hex: 0xB86E00), dark: UIColor(hex: 0xFFB547))
    static let danger = Color(light: UIColor(hex: 0xD93A3A), dark: UIColor(hex: 0xFF6B6B))
    static let neutral = Color(light: UIColor(hex: 0x6B7385), dark: UIColor(hex: 0x9AA3B4))

    // MARK: Shape & size

    static let cornerRadius: CGFloat = 22
    static let innerRadius: CGFloat = 16
    static let smallRadius: CGFloat = 12
    /// Minimum height of primary buttons (well above the 44 pt HIG minimum, for gloved/tired hands).
    static let bigButtonHeight: CGFloat = 60
    static let fieldHeight: CGFloat = 58
    static let screenPadding: CGFloat = 20
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
    /// Same hues as the dashboard: assigned grey, in progress blue, submitted amber, approved green, rejected red.
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
        case .lighting: return Color(light: UIColor(hex: 0xC98A00), dark: UIColor(hex: 0xFFC94D))
        case .roads: return Color(light: UIColor(hex: 0x4B5563), dark: UIColor(hex: 0xA7B0C0))
        case .water: return Color(light: UIColor(hex: 0x0A84C6), dark: UIColor(hex: 0x5AC8FA))
        case .greenSpaces: return Color(light: UIColor(hex: 0x1F8A4C), dark: UIColor(hex: 0x4ADE80))
        case .waste: return Color(light: UIColor(hex: 0x7A5AF8), dark: UIColor(hex: 0xA78BFA))
        case .buildings: return Color(light: UIColor(hex: 0xB45309), dark: UIColor(hex: 0xF59E0B))
        case .other: return Theme.primary
        }
    }

    var label: String { L10n.tr("category.\(rawValue)") }
}

extension PhotoKind {
    var label: String { L10n.tr("photo.kind.\(rawValue)") }
}

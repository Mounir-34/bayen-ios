import SwiftUI
import UIKit

/// Brand colours come from the Bayen logo: navy (pin + wordmark), with the Moroccan red/green only inside the emblem.
/// Dark mode uses a lighter navy so text and buttons keep enough contrast.
enum Theme {
    static let primary = Color(light: UIColor(red: 26 / 255, green: 44 / 255, blue: 82 / 255, alpha: 1),     // #1A2C52
                               dark: UIColor(red: 132 / 255, green: 160 / 255, blue: 222 / 255, alpha: 1))   // #84A0DE
    static let onPrimary = Color(light: .white, dark: UIColor(red: 10 / 255, green: 18 / 255, blue: 38 / 255, alpha: 1))
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let warning = Color(light: UIColor(red: 0.70, green: 0.42, blue: 0.0, alpha: 1),
                               dark: UIColor(red: 1.0, green: 0.76, blue: 0.28, alpha: 1))
    static let danger = Color(uiColor: .systemRed)

    static let cornerRadius: CGFloat = 16
    /// Minimum height of primary buttons (well above the 44 pt HIG minimum, for gloved/tired hands).
    static let bigButtonHeight: CGFloat = 64
}

extension Color {
    init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

extension TaskStatus {
    /// Same palette as the dashboard: assigned grey, in progress blue, submitted amber, approved green, rejected red.
    var color: Color {
        switch self {
        case .assigned, .unknown, .cancelled: return Color(uiColor: .systemGray)
        case .inProgress: return Color(uiColor: .systemBlue)
        case .submitted: return Color(light: UIColor(red: 0.85, green: 0.55, blue: 0.0, alpha: 1), dark: .systemOrange)
        case .approved: return Color(uiColor: .systemGreen)
        case .rejected: return Color(uiColor: .systemRed)
        }
    }

    var symbol: String {
        switch self {
        case .assigned: return "circle"
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

    var label: String { L10n.tr("category.\(rawValue)") }
}

extension PhotoKind {
    var label: String { L10n.tr("photo.kind.\(rawValue)") }
}

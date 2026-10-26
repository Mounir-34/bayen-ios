import SwiftUI
import UIKit

/// The worker's light/dark choice from the profile; `system` follows the phone.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    static let storageKey = "bayen.appearance"

    var label: String { L10n.tr("appearance.\(rawValue)") }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Set on the windows rather than with `preferredColorScheme`: SwiftUI doesn't reliably hand control back
    /// to the system once a scheme was forced, and this also reaches alerts and sheets.
    @MainActor
    func apply() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.overrideUserInterfaceStyle = interfaceStyle }
        }
    }
}

/// Three-way System / Light / Dark switch, styled like the language picker.
struct AppearancePicker: View {
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppAppearance.allCases) { option in
                let isSelected = appearance == option
                Button {
                    guard !isSelected else { return }
                    withAnimation(Motion.snappy) { appearance = option }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: option.symbol).font(.footnote.weight(.semibold))
                        Text(option.label)
                            .font(.subheadline.weight(isSelected ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(isSelected ? Theme.onPrimary : Theme.textSecondary)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(Theme.primaryGradient)
                                .shadow(color: Theme.primary.opacity(0.25), radius: 6, x: 0, y: 3)
                                .matchedGeometryEffect(id: "pill", in: selection)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle(scale: 0.95))
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Theme.fill, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.75))
        .sensoryFeedback(.selection, trigger: appearance)
    }
}

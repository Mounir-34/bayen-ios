import SwiftUI

/// Full-width, tall, high-contrast button with icon + label.
struct BigButton: View {
    enum Style { case primary, secondary, destructive }

    let title: String
    var systemImage: String?
    var style: Style = .primary
    var isLoading = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if isLoading {
                    ProgressView().tint(foreground)
                } else if let systemImage {
                    Image(systemName: systemImage).font(.title2.weight(.semibold))
                }
                Text(title)
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: Theme.bigButtonHeight)
            .padding(.horizontal, 16)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay {
                if style == .secondary {
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).stroke(Theme.primary, lineWidth: 2)
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityLabel(title)
    }

    private var foreground: Color {
        switch style {
        case .primary: return Theme.onPrimary
        case .secondary: return Theme.primary
        case .destructive: return .white
        }
    }

    private var background: Color {
        switch style {
        case .primary: return Theme.primary
        case .secondary: return Theme.card
        case .destructive: return Theme.danger
        }
    }
}

struct StatusBadge: View {
    let status: TaskStatus
    var overrideLabel: String?

    var body: some View {
        Label(overrideLabel ?? status.label, systemImage: status.symbol)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(status.color)
            .background(status.color.opacity(0.15), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

struct CategoryIcon: View {
    let category: TaskCategory
    var size: CGFloat = 48

    var body: some View {
        Image(systemName: category.symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(Theme.primary)
            .frame(width: size, height: size)
            .background(Theme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityLabel(category.label)
    }
}

/// Coloured information banner (warnings, offline notice, rejection reason…).
struct NoticeBanner: View {
    enum Kind { case info, warning, danger, success }

    let kind: Kind
    let title: String
    var message: String?
    var systemImage: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage ?? defaultSymbol)
                .font(.title2)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if let message, !message.isEmpty {
                    Text(message).font(.body)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).stroke(color.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch kind {
        case .info: return Color(uiColor: .systemBlue)
        case .warning: return Theme.warning
        case .danger: return Theme.danger
        case .success: return Color(uiColor: .systemGreen)
        }
    }

    private var defaultSymbol: String {
        switch kind {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .danger: return "xmark.octagon.fill"
        case .success: return "checkmark.circle.fill"
        }
    }
}

/// Big labelled text field for low-tech users.
struct LabeledField<Field: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder let field: () -> Field

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage ?? "pencil")
                .font(.headline)
                .foregroundStyle(.secondary)
            field()
                .font(.title3)
                .padding(.horizontal, 14)
                .frame(minHeight: 56)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.secondary.opacity(0.3)))
        }
    }
}

/// Shows "N photos waiting to upload" (and offline state) at the top of the main screens.
struct UploadStatusBanner: View {
    @Environment(UploadManager.self) private var uploads
    @Environment(NetworkMonitor.self) private var network

    var body: some View {
        if uploads.pendingPhotoCount > 0 || !uploads.pendingSubmissionTaskIds.isEmpty || !network.isConnected {
            HStack(spacing: 10) {
                Image(systemName: network.isConnected ? "arrow.up.circle.fill" : "wifi.slash")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    if uploads.pendingPhotoCount > 0 {
                        Text(L10n.tr("upload.banner.photos", uploads.pendingPhotoCount)).font(.subheadline.weight(.semibold))
                    }
                    if !uploads.pendingSubmissionTaskIds.isEmpty {
                        Text(L10n.tr("upload.banner.submissions", uploads.pendingSubmissionTaskIds.count)).font(.subheadline)
                    }
                    Text(network.isConnected ? L10n.tr("upload.banner.sending") : L10n.tr("upload.banner.offline"))
                        .font(.footnote)
                        .opacity(0.9)
                }
                Spacer(minLength: 0)
                if uploads.blockedPhotoCount > 0 {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.danger)
                        .accessibilityLabel(L10n.tr("upload.status.failed"))
                }
            }
            .padding(12)
            .foregroundStyle(.white)
            .background(network.isConnected ? Theme.primary : Color(uiColor: .darkGray),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }
}

enum AppSettings {
    /// Opens the iOS Settings page of the app (camera/location permissions).
    @MainActor
    static func open() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

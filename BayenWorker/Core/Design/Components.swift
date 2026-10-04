import SwiftUI

// MARK: - Surfaces & modifiers

extension View {
    /// Standard content card: solid surface, continuous corners, hairline edge and a soft two-layer shadow.
    func cardStyle(padding: CGFloat? = 16, radius: CGFloat = Theme.cornerRadius) -> some View {
        modifier(CardModifier(padding: padding, radius: radius))
    }

    /// Liquid Glass on iOS 26, a thin material before that.
    @ViewBuilder
    func glass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.5))
        }
    }

    /// Fades and lifts content in the first time it appears; `index` staggers lists.
    func appearAnimation(index: Int = 0) -> some View {
        modifier(AppearModifier(delay: min(Double(index), 8) * 0.04))
    }
}

private struct CardModifier: ViewModifier {
    let padding: CGFloat?
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(padding ?? 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // Shadows live on the shape only; on the container they would also blur every child.
                shape.fill(Theme.card)
                    .shadow(color: Theme.shadow, radius: 18, x: 0, y: 8)
                    .shadow(color: Theme.shadow.opacity(0.6), radius: 1.5, x: 0, y: 1)
            }
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.75))
    }
}

private struct AppearModifier: ViewModifier {
    let delay: Double
    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 14)
            .onAppear {
                guard !visible else { return }
                withAnimation(Motion.spring.delay(delay)) { visible = true }
            }
    }
}

/// Screen background with a faint brand glow at the top — gives depth without competing with content.
struct AmbientBackground: View {
    var intensity: Double = 1

    var body: some View {
        ZStack {
            Theme.background
            GeometryReader { proxy in
                let w = proxy.size.width
                ZStack {
                    Circle()
                        .fill(Theme.primary.opacity(0.18 * intensity))
                        .frame(width: w * 1.1)
                        .blur(radius: 90)
                        .offset(x: -w * 0.35, y: -w * 0.55)
                    Circle()
                        .fill(Theme.info.opacity(0.10 * intensity))
                        .frame(width: w * 0.9)
                        .blur(radius: 100)
                        .offset(x: w * 0.45, y: -w * 0.35)
                }
                .frame(width: w, height: proxy.size.height, alignment: .top)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Buttons

/// Gentle spring press with an optional soft haptic.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    var haptic = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(Motion.press, value: configuration.isPressed)
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.55), trigger: configuration.isPressed) { _, pressed in
                haptic && pressed
            }
    }
}

/// Full-width, tall, high-contrast button with icon + label.
struct BigButton: View {
    enum Style { case primary, secondary, tinted, destructive }

    let title: String
    var systemImage: String?
    var style: Style = .primary
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            BigButtonLabel(title: title, systemImage: systemImage, style: style, isLoading: isLoading)
        }
        .buttonStyle(PressableStyle())
        .disabled(isLoading)
        .accessibilityLabel(title)
    }
}

/// The visual of `BigButton`, reusable inside `NavigationLink`s.
struct BigButtonLabel: View {
    let title: String
    var systemImage: String?
    var style: BigButton.Style = .primary
    var isLoading = false

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.innerRadius + 2, style: .continuous)
        HStack(spacing: 10) {
            if isLoading {
                ProgressView().tint(foreground).transition(.scale.combined(with: .opacity))
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .transition(.scale.combined(with: .opacity))
            }
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(Motion.snappy, value: isLoading)
        .frame(maxWidth: .infinity, minHeight: Theme.bigButtonHeight)
        .padding(.horizontal, 18)
        .foregroundStyle(foreground)
        .background { background(shape) }
        .contentShape(shape)
    }

    /// A loading button is disabled but should keep its colour, so only a truly unavailable action looks greyed out.
    private var looksEnabled: Bool { isEnabled || isLoading }

    @ViewBuilder
    private func background(_ shape: RoundedRectangle) -> some View {
        if !looksEnabled {
            shape.fill(Theme.disabledFill)
        } else {
            switch style {
            case .primary:
                shape.fill(Theme.primaryGradient)
                    .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.0)],
                                                               startPoint: .top, endPoint: .bottom), lineWidth: 1))
                    .shadow(color: Theme.primary.opacity(0.28), radius: 14, x: 0, y: 8)
            case .secondary:
                shape.fill(Theme.cardElevated)
                    .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
                    .shadow(color: Theme.shadow, radius: 8, x: 0, y: 3)
            case .tinted:
                shape.fill(Theme.primary.opacity(0.1))
            case .destructive:
                shape.fill(Theme.danger)
                    .shadow(color: Theme.danger.opacity(0.3), radius: 12, x: 0, y: 6)
            }
        }
    }

    private var foreground: Color {
        guard looksEnabled else { return Theme.textTertiary }
        switch style {
        case .primary: return Theme.onPrimary
        case .secondary, .tinted: return Theme.primary
        case .destructive: return .white
        }
    }
}

/// Round glass icon button for toolbars and overlays.
struct GlassIconButton: View {
    let systemImage: String
    var size: CGFloat = 44
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.38, weight: .semibold))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .glass(in: Circle(), interactive: true)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Status & identity

struct StatusBadge: View {
    let status: TaskStatus
    var overrideLabel: String?
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: status.symbol)
                .font(.system(size: compact ? 10 : 11, weight: .bold))
            Text(overrideLabel ?? status.label)
                .font((compact ? Font.caption : .footnote).weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 4 : 6)
        .foregroundStyle(status.color)
        .background(status.color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(status.color.opacity(0.18), lineWidth: 0.75))
        .accessibilityElement(children: .combine)
    }
}

struct CategoryIcon: View {
    let category: TaskCategory
    var size: CGFloat = 48

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        Image(systemName: category.symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(category.tint)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [category.tint.opacity(0.20), category.tint.opacity(0.08)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: shape)
            .overlay(shape.strokeBorder(category.tint.opacity(0.15), lineWidth: 0.75))
            .accessibilityLabel(category.label)
    }
}

/// A symbol inside a softly tinted circle.
struct IconCircle: View {
    let systemImage: String
    let color: Color
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.13), in: Circle())
            .accessibilityHidden(true)
    }
}

/// Circular progress used for photo requirements.
struct ProgressRing: View {
    let progress: Double
    var color: Color = Theme.primary
    var lineWidth: CGFloat = 6
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(progress, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(progress > 0 ? 1 : 0)
        }
        .frame(width: size, height: size)
        .animation(Motion.spring, value: progress)
    }
}

// MARK: - Text & sections

/// Small uppercase-style header above a group of content.
struct SectionHeader: View {
    let title: String
    var count: Int?
    var systemImage: String?

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage).font(.footnote.weight(.semibold)).foregroundStyle(Theme.textTertiary)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            if let count {
                Text(verbatim: "\(count)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Theme.fill, in: Capsule())
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
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
        let shape = RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous)
        HStack(alignment: .top, spacing: 12) {
            IconCircle(systemImage: systemImage ?? defaultSymbol, color: color, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 1)
        }
        .padding(12)
        .background(color.opacity(0.09), in: shape)
        .overlay(shape.strokeBorder(color.opacity(0.18), lineWidth: 0.75))
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch kind {
        case .info: return Theme.info
        case .warning: return Theme.warning
        case .danger: return Theme.danger
        case .success: return Theme.success
        }
    }

    private var defaultSymbol: String {
        switch kind {
        case .info: return "info"
        case .warning: return "exclamationmark"
        case .danger: return "xmark"
        case .success: return "checkmark"
        }
    }
}

/// Big labelled text field for low-tech users.
struct LabeledField<Field: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder let field: () -> Field

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)
            HStack(spacing: 12) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                }
                field()
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    // Explicit, so UIKit's process-language "natural" alignment can't override the in-app language.
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: Theme.fieldHeight)
            .background(Theme.fill, in: shape)
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.75))
        }
    }
}

/// A label/value line inside a card.
struct InfoRow: View {
    let title: String
    let value: String
    let systemImage: String
    var valueColor: Color = Theme.textPrimary
    var forceLTRValue = false

    var body: some View {
        HStack(spacing: 12) {
            IconCircle(systemImage: systemImage, color: Theme.primary, size: 32)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .environment(\.layoutDirection, forceLTRValue ? .leftToRight : layoutDirection)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    @Environment(\.layoutDirection) private var layoutDirection
}

// MARK: - Upload status

/// Shows "N photos waiting to upload" (and offline state) at the top of the main screens.
struct UploadStatusBanner: View {
    @Environment(UploadManager.self) private var uploads
    @Environment(NetworkMonitor.self) private var network

    var body: some View {
        if uploads.pendingPhotoCount > 0 || !uploads.pendingSubmissionTaskIds.isEmpty || !network.isConnected {
            let tint = network.isConnected ? Theme.info : Theme.neutral
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(tint.opacity(0.15))
                    Image(systemName: network.isConnected ? "arrow.up" : "wifi.slash")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(tint)
                        .symbolEffect(.pulse, options: .repeating, isActive: network.isConnected)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 1) {
                    if uploads.pendingPhotoCount > 0 {
                        Text(L10n.tr("upload.banner.photos", uploads.pendingPhotoCount))
                            .font(.subheadline.weight(.semibold))
                            .contentTransition(.numericText())
                    }
                    if !uploads.pendingSubmissionTaskIds.isEmpty {
                        Text(L10n.tr("upload.banner.submissions", uploads.pendingSubmissionTaskIds.count))
                            .font(.subheadline.weight(.medium))
                    }
                    Text(network.isConnected ? L10n.tr("upload.banner.sending") : L10n.tr("upload.banner.offline"))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                if uploads.blockedPhotoCount > 0 {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.danger)
                        .accessibilityLabel(L10n.tr("upload.status.failed"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .glass(in: RoundedRectangle(cornerRadius: Theme.innerRadius + 2, style: .continuous))
            .transition(.move(edge: .top).combined(with: .opacity))
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

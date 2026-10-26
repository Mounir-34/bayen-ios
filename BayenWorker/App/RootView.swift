import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(SessionStore.self) private var session

    var body: some View {
        Group {
            switch session.state {
            case .launching:
                LaunchView()
            case .loggedOut:
                AuthFlowView()
            case let .pendingApproval(phone):
                PendingApprovalView(phone: phone)
            case .suspended:
                SuspendedView()
            case .passwordChangeRequired:
                ChangePasswordView()
            case .active:
                MainTabView()
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .animation(Motion.spring, value: session.state)
        .task { await session.bootstrap() }
    }
}

private struct LaunchView: View {
    @State private var breathe = false

    var body: some View {
        ZStack {
            AmbientBackground(intensity: 1.2)
            VStack(spacing: 28) {
                BrandMark(height: 220)
                    .scaleEffect(breathe ? 1.0 : 0.96)
                    .opacity(breathe ? 1 : 0.85)
                ProgressView().tint(Theme.textSecondary)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

/// Full Bayen logo: the check pin over the serif "Bayen" wordmark and بيّن between two thin rules.
/// Drawn in SwiftUI so it stays crisp at any size and follows light/dark mode.
struct BrandMark: View {
    var height: CGFloat = 200

    var body: some View {
        VStack(spacing: height * 0.02) {
            BrandPin(height: height * 0.36)
                .padding(.bottom, height * 0.02)
            Text(verbatim: "Bayen")
                .font(.system(size: height * 0.25, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.ink)
                .kerning(-height * 0.003)
            HStack(spacing: height * 0.08) {
                Rectangle().fill(Theme.ink.opacity(0.7)).frame(width: 1, height: height * 0.16)
                Text(verbatim: "بيّن")
                    .font(.system(size: height * 0.15, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .environment(\.layoutDirection, .rightToLeft)
                Rectangle().fill(Theme.ink.opacity(0.7)).frame(width: 1, height: height * 0.16)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Bayen"))
        .accessibilityAddTraits(.isImage)
    }
}

/// Just the green check pin, for small places.
struct BrandEmblem: View {
    var size: CGFloat = 44

    var body: some View {
        BrandPin(height: size)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The logo's pin: a green teardrop with a soft top light and an embossed white check.
struct BrandPin: View {
    var height: CGFloat

    var body: some View {
        let width = height * PinShape.aspect
        ZStack {
            PinShape()
                .fill(Theme.brandPinGradient)
                .overlay(PinShape().stroke(
                    LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0)], startPoint: .top, endPoint: .center),
                    lineWidth: max(1, height * 0.012)))
                .shadow(color: Theme.shadow, radius: height * 0.06, x: 0, y: height * 0.04)
            CheckShape()
                .stroke(Color(light: UIColor(hex: 0xFBF8F1), dark: UIColor(hex: 0xF4F0E6)),
                        style: StrokeStyle(lineWidth: width * 0.13, lineCap: .round, lineJoin: .round))
                .shadow(color: .black.opacity(0.22), radius: height * 0.015, x: 0, y: height * 0.012)
                .frame(width: width * 0.48, height: width * 0.32)
                .offset(y: -height * 0.1)
        }
        .frame(width: width, height: height)
    }
}

/// Teardrop: a circle whose two tangents meet in a softly rounded point at the bottom.
private struct PinShape: Shape {
    /// Width / height of the logo's pin.
    static let aspect: CGFloat = 0.8

    func path(in rect: CGRect) -> Path {
        let r = rect.width / 2
        let center = CGPoint(x: rect.midX, y: rect.minY + r)
        let tip = CGPoint(x: rect.midX, y: rect.maxY)
        let d = tip.y - center.y
        // Angle (from straight down) of the points where the tangents from the tip touch the circle.
        let theta = acos(r / d)
        let start = Angle(radians: .pi / 2 - theta)
        let end = Angle(radians: .pi / 2 + theta)
        var p = Path()
        p.addArc(center: center, radius: r, startAngle: end, endAngle: start, clockwise: false)
        let left = CGPoint(x: center.x - r * sin(theta), y: center.y + r * cos(theta))
        let right = CGPoint(x: center.x + r * sin(theta), y: center.y + r * cos(theta))
        // Round the tip by stopping short on each tangent and curving through the point.
        let k: CGFloat = 0.1
        p.addLine(to: CGPoint(x: tip.x + (right.x - tip.x) * k, y: tip.y + (right.y - tip.y) * k))
        p.addQuadCurve(to: CGPoint(x: tip.x + (left.x - tip.x) * k, y: tip.y + (left.y - tip.y) * k), control: tip)
        p.closeSubpath()
        return p
    }
}

private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.5))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

struct MainTabView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        TabView {
            TaskListView()
                .tabItem { Label(L10n.tr("tab.tasks"), systemImage: "checklist") }
            ProfileView()
                .tabItem { Label(L10n.tr("tab.profile"), systemImage: "person.crop.circle") }
        }
    }
}

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
                BrandMark(height: 180)
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

/// Full Bayen logo (emblem + بيّن / BAYEN wordmark). Has a light-on-dark variant for dark mode.
struct BrandMark: View {
    var height: CGFloat = 200

    var body: some View {
        Image("BrandLogo")
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .shadow(color: Theme.primary.opacity(0.18), radius: 24, x: 0, y: 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "Bayen"))
            .accessibilityAddTraits(.isImage)
    }
}

/// Just the emblem (pin with the check, over the street grid), for small places.
struct BrandEmblem: View {
    var size: CGFloat = 44

    var body: some View {
        Image("BrandEmblem")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
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

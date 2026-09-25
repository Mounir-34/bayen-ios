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
        .animation(.default, value: session.state)
        .task { await session.bootstrap() }
    }
}

private struct LaunchView: View {
    var body: some View {
        VStack(spacing: 16) {
            BrandMark(height: 220)
            ProgressView().controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
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

import SwiftData
import SwiftUI

@main
struct BayenWorkerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Serif navigation titles in the wordmark's ink, matching the house style.
        // Set on appearance objects: the bare proxy attributes get dropped whenever the bar reconfigures
        // (e.g. switching the task list to the map), and the title fell back to the system font.
        let ink = UIColor(Theme.ink)
        func styled(_ appearance: UINavigationBarAppearance) -> UINavigationBarAppearance {
            appearance.largeTitleTextAttributes = [.font: UIFont.display(.largeTitle, weight: .bold), .foregroundColor: ink]
            appearance.titleTextAttributes = [.font: UIFont.display(.headline, weight: .semibold), .foregroundColor: ink]
            return appearance
        }
        let edge = UINavigationBarAppearance()
        edge.configureWithTransparentBackground()
        let standard = UINavigationBarAppearance()
        // iOS 26 bars stay transparent and fade content with the scroll edge effect; earlier ones blur.
        if #available(iOS 26.0, *) { standard.configureWithTransparentBackground() } else { standard.configureWithDefaultBackground() }
        let bar = UINavigationBar.appearance()
        bar.standardAppearance = styled(standard)
        bar.compactAppearance = styled(standard.copy())
        bar.scrollEdgeAppearance = styled(edge)
    }

    var body: some Scene {
        WindowGroup {
            if AppConfig.isRunningTests {
                // Unit tests build their own objects; don't start networking/location in the host app.
                Color.clear
            } else {
                AppRoot(env: AppEnvironment.shared)
            }
        }
    }
}

private struct AppRoot: View {
    let env: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system

    var body: some View {
        RootView()
            .environment(env)
            .environment(env.session)
            .environment(env.uploads)
            .environment(env.location)
            .environment(env.network)
            .environment(env.language)
            .environment(env.tasks)
            .modelContainer(env.modelContainer)
            .environment(\.locale, env.language.locale)
            .environment(\.layoutDirection, env.language.layoutDirection)
            .id(env.language.language) // re-render every string when the language changes
            .tint(Theme.primary)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { env.uploads.kick() }
            }
            .onAppear { appearance.apply() }
            .onChange(of: appearance) { _, new in new.apply() }
    }
}

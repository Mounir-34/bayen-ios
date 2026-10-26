import SwiftData
import SwiftUI

@main
struct BayenWorkerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Serif navigation titles in the wordmark's ink, matching the house style.
        let ink = UIColor(Theme.ink)
        let bar = UINavigationBar.appearance()
        bar.largeTitleTextAttributes = [.font: UIFont.display(.largeTitle, weight: .bold), .foregroundColor: ink]
        bar.titleTextAttributes = [.font: UIFont.display(.headline, weight: .semibold), .foregroundColor: ink]
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
    }
}

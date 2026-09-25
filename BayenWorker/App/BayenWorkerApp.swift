import SwiftData
import SwiftUI

@main
struct BayenWorkerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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

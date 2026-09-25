import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        true
    }

    /// iOS relaunches the app when background photo uploads finish; hand the completion handler to the session.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundUploadTransport.sessionIdentifier else {
            completionHandler()
            return
        }
        MainActor.assumeIsolated {
            if let transport = AppEnvironment.shared.backgroundTransport {
                transport.setBackgroundCompletionHandler(completionHandler)
            } else {
                completionHandler() // foreground-upload mode: nothing to deliver
            }
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { AppEnvironment.shared.push.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        MainActor.assumeIsolated { AppEnvironment.shared.push.didFailToRegister(error) }
    }
}

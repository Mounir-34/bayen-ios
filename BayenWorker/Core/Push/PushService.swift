import Foundation
import UIKit
import UserNotifications

/// Phase 2 — push notifications (new task assigned, submission rejected/approved).
///
/// Structure is ready; to enable it:
/// 1. Add the "Push Notifications" capability to the target (creates the `aps-environment` entitlement).
/// 2. Call `PushService.requestAuthorizationAndRegister()` after login (see `SessionStore.didLogIn`).
/// 3. Implement `POST /api/v1/me/device-token { token, platform }` on the server.
/// 4. Handle payloads `{ "type": "TASK_ASSIGNED" | "TASK_REJECTED" | "TASK_APPROVED", "taskId": "…" }` in `handle(userInfo:)`.
@MainActor
final class PushService: NSObject {
    static let isEnabled = false

    private let api: APIClient
    private var lastToken: String?
    /// Deep link requested by a tapped notification.
    var onOpenTask: ((String) -> Void)?

    init(api: APIClient) {
        self.api = api
        super.init()
    }

    func requestAuthorizationAndRegister() async {
        guard Self.isEnabled else { return }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { return }
        UNUserNotificationCenter.current().delegate = self
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// From `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    func didRegister(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard token != lastToken else { return }
        lastToken = token
        Task { try? await api.registerDeviceToken(token) }
    }

    func didFailToRegister(_ error: Error) {
        #if DEBUG
        print("APNs registration failed: \(error)")
        #endif
    }

    func handle(userInfo: [AnyHashable: Any]) {
        guard let taskId = userInfo["taskId"] as? String else { return }
        onOpenTask?(taskId)
    }
}

extension PushService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            self.handle(userInfo: userInfo)
            completionHandler()
        }
    }
}

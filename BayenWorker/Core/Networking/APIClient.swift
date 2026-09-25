import Foundation

/// Everything the worker app needs from the Bayen REST API (`/api/v1`).
/// Implemented by `HTTPAPIClient` (real server) and `MockAPIClient` (simulator, previews, tests).
protocol APIClient: AnyObject, Sendable {
    /// True when tokens are stored (the user logged in on this device).
    var hasSession: Bool { get }

    /// Called (on any thread) when the session ends or the account state changes server-side.
    var onSessionProblem: (@Sendable (SessionProblem) -> Void)? { get set }

    func register(_ request: RegisterRequest) async throws -> User
    /// Logs in and stores the token pair.
    func login(phone: String, password: String) async throws -> User
    /// Revokes the refresh token (best effort) and clears local tokens.
    func logout() async
    func me() async throws -> User

    func tasks(status: TaskStatus?) async throws -> [WorkerTask]
    func task(id: String) async throws -> TaskDetail
    func startTask(id: String, location: LocationPayload) async throws -> WorkerTask
    /// `fileURL` is the already-compressed JPEG.
    func uploadPhoto(taskId: String, fileURL: URL, metadata: PhotoMetadata) async throws -> RemotePhoto
    func deletePhoto(taskId: String, photoId: String) async throws
    func submit(taskId: String, request: SubmitRequest) async throws -> SubmitResponse

    /// Phase 2 — APNs device token registration (`POST /me/device-token`).
    func registerDeviceToken(_ token: String) async throws
}

enum SessionProblem: Equatable, Sendable {
    case loggedOut
    case accountPending
    case accountSuspended
}

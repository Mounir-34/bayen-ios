import Foundation
import Observation

/// Top-level authentication state machine driving `RootView`.
@MainActor
@Observable
final class SessionStore {
    enum State: Equatable {
        case launching
        case loggedOut
        /// Registered or tried to log in while the municipality has not approved the account yet.
        case pendingApproval(phone: String)
        case suspended
        /// Logged in with a temporary password: only the "choose a new password" screen is reachable.
        case passwordChangeRequired(User)
        case active(User)
    }

    /// What to do with a signed-in user, given `mustChangePassword`.
    enum PasswordGate: Equatable {
        case enterApp
        case changePassword
        /// A change is required but the temporary password is no longer in memory (app relaunched): log in again.
        case signOut
    }

    nonisolated static func passwordGate(for user: User, hasCurrentPassword: Bool) -> PasswordGate {
        guard user.mustChangePassword else { return .enterApp }
        return hasCurrentPassword ? .changePassword : .signOut
    }

    private(set) var state: State = .launching
    var user: User? {
        if case let .active(user) = state { return user }
        return nil
    }

    /// Kept in memory only (never persisted) so the "pending approval" screen can re-check with one tap.
    @ObservationIgnored private var pendingCredentials: (phone: String, password: String)?
    /// The temporary password typed at login, kept in memory only (never persisted) and only while a change
    /// is required, so the worker does not have to retype it as `currentPassword`.
    @ObservationIgnored private var temporaryPassword: String?
    @ObservationIgnored private var passwordChangedAt: Date?
    /// Municipality code typed at registration (the API's user object only carries the id).
    @ObservationIgnored private let defaults: UserDefaults

    private let api: APIClient
    private let language: LanguageManager
    var onLogin: (() -> Void)?

    init(api: APIClient, language: LanguageManager, defaults: UserDefaults = .standard) {
        self.api = api
        self.language = language
        self.defaults = defaults
        api.onSessionProblem = { [weak self] problem in
            Task { @MainActor in self?.handle(problem) }
        }
    }

    var municipalityCode: String? { defaults.string(forKey: "bayen.municipalityCode") }

    func bootstrap() async {
        guard api.hasSession else {
            state = .loggedOut
            return
        }
        do {
            let user = try await api.me()
            await route(user)
        } catch let error as APIError {
            switch error.code {
            case "ACCOUNT_PENDING": state = .pendingApproval(phone: "")
            case "ACCOUNT_SUSPENDED": state = .suspended
            default:
                // Offline at launch: keep the worker in, using the cached profile, so queued work continues.
                if error.isRetryable, let cached = cachedUser {
                    state = .active(cached)
                } else if error == .unauthorized {
                    state = .loggedOut
                } else if let cached = cachedUser {
                    state = .active(cached)
                } else {
                    state = .loggedOut
                }
            }
        } catch {
            state = cachedUser.map(State.active) ?? .loggedOut
        }
    }

    func login(phone: String, password: String) async throws {
        do {
            let user = try await api.login(phone: phone, password: password)
            pendingCredentials = nil
            temporaryPassword = user.mustChangePassword ? password : nil
            await route(user)
        } catch let error as APIError {
            switch error.code {
            case "ACCOUNT_PENDING":
                pendingCredentials = (phone, password)
                state = .pendingApproval(phone: phone)
            case "ACCOUNT_SUSPENDED":
                state = .suspended
            default:
                throw error
            }
        }
    }

    func register(_ request: RegisterRequest) async throws {
        _ = try await api.register(request)
        defaults.set(request.municipalityCode.uppercased(), forKey: "bayen.municipalityCode")
        pendingCredentials = (request.phone, request.password)
        state = .pendingApproval(phone: request.phone)
    }

    /// "Refresh" on the pending screen. Returns false when still pending.
    @discardableResult
    func recheckApproval() async throws -> Bool {
        guard let credentials = pendingCredentials else {
            state = .loggedOut
            return false
        }
        try await login(phone: credentials.phone, password: credentials.password)
        return user != nil
    }

    /// True when `candidate` is the temporary password the worker logged in with (the new one must differ).
    func isTemporaryPassword(_ candidate: String) -> Bool {
        temporaryPassword == candidate
    }

    /// "Choose a new password" screen: sends the temporary password kept from login as `currentPassword`.
    /// The API client stores the new token pair; on success the worker continues into the app.
    func changePassword(to newPassword: String) async throws {
        guard case .passwordChangeRequired = state, let currentPassword = temporaryPassword else {
            await logout()
            return
        }
        let user = try await api.changePassword(currentPassword: currentPassword, newPassword: newPassword)
        temporaryPassword = nil
        passwordChangedAt = Date()
        // The change succeeded, so the gate is lifted whatever the returned flag says.
        didLogIn(user.mustChangePassword ? user.with(mustChangePassword: false) : user)
    }

    func logout() async {
        await api.logout()
        defaults.removeObject(forKey: "bayen.cachedUser")
        pendingCredentials = nil
        temporaryPassword = nil
        state = .loggedOut
    }

    func backToLogin() {
        pendingCredentials = nil
        temporaryPassword = nil
        state = .loggedOut
    }

    /// Entry point after login and session restore: the main app, the password screen, or back to login.
    private func route(_ user: User) async {
        switch Self.passwordGate(for: user, hasCurrentPassword: temporaryPassword != nil) {
        case .enterApp:
            temporaryPassword = nil
            didLogIn(user)
        case .changePassword:
            state = .passwordChangeRequired(user)
        case .signOut:
            await logout()
        }
    }

    private func didLogIn(_ user: User) {
        if let data = try? JSONCoding.encoder.encode(user) { defaults.set(data, forKey: "bayen.cachedUser") }
        state = .active(user)
        onLogin?()
    }

    private var cachedUser: User? {
        guard let data = defaults.data(forKey: "bayen.cachedUser") else { return nil }
        return try? JSONCoding.decoder.decode(User.self, from: data)
    }

    private func handle(_ problem: SessionProblem) {
        switch problem {
        case .loggedOut:
            if case .active = state { state = .loggedOut }
        case .accountPending:
            state = .pendingApproval(phone: user?.phone ?? "")
        case .accountSuspended:
            state = .suspended
        case .passwordChangeRequired:
            // Already on the password screen: background requests (uploads) may still report it.
            guard case let .active(user) = state else { return }
            // A request sent just before the change may still be answered with the old refusal: not a new demand.
            if let passwordChangedAt, Date().timeIntervalSince(passwordChangedAt) < 30 { return }
            Task { await route(user.with(mustChangePassword: true)) }
        }
    }
}

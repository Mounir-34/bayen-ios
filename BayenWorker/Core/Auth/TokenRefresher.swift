import Foundation

/// Guarantees a single in-flight `POST /auth/refresh`.
///
/// When several requests fail with 401 at the same time they all call `refresh(after:)`;
/// the first one starts the refresh, the others await the same result. Refresh tokens are
/// single-use on the server (re-use revokes the whole family), so this matters.
actor TokenRefresher {
    typealias RefreshCall = @Sendable (_ refreshToken: String) async throws -> AuthTokens

    private let store: TokenStoring
    private let refreshCall: RefreshCall
    private var inFlight: Task<AuthTokens, Error>?

    /// Number of network refreshes actually performed (for tests / diagnostics).
    private(set) var refreshCount = 0

    init(store: TokenStoring, refreshCall: @escaping RefreshCall) {
        self.store = store
        self.refreshCall = refreshCall
    }

    /// - Parameter failedAccessToken: the access token that was rejected. If the stored token is already
    ///   different, another caller refreshed in the meantime and the new pair is returned without a call.
    func refresh(after failedAccessToken: String?) async throws -> AuthTokens {
        if let inFlight {
            return try await inFlight.value
        }
        guard let current = store.load() else { throw APIError.unauthorized }
        if let failedAccessToken, current.accessToken != failedAccessToken {
            return current
        }

        let call = refreshCall
        let refreshToken = current.refreshToken
        let task = Task { try await call(refreshToken) }
        inFlight = task
        refreshCount += 1
        defer { inFlight = nil }

        do {
            let tokens = try await task.value
            store.save(tokens)
            return tokens
        } catch {
            let apiError = APIError.from(error)
            // A definitive "no" from the server ends the session; network problems keep the tokens.
            if case .server(let status, _, _, _) = apiError, status == 401 || status == 403 {
                store.clear()
                throw APIError.unauthorized
            }
            throw apiError
        }
    }
}

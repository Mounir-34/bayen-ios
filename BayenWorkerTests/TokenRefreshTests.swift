import XCTest
@testable import BayenWorker

final class TokenRefreshTests: XCTestCase {
    private let listJSON = Fixtures.json(#"{"items":[],"total":0,"page":1,"pageSize":100}"#)

    private func makeTransport(refreshStatus: Int = 200, refreshDelayMs: UInt64 = 50) -> ScriptedTransport {
        let list = listJSON
        return ScriptedTransport { request in
            let path = request.url!.path
            if path.hasSuffix("/auth/refresh") {
                try await Task.sleep(nanoseconds: refreshDelayMs * 1_000_000)
                return refreshStatus == 200 ? (200, Fixtures.json(Fixtures.tokens)) : (refreshStatus, Fixtures.error("INVALID_REFRESH_TOKEN"))
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer new-access" {
                return (200, list)
            }
            return (401, Fixtures.error("TOKEN_EXPIRED"))
        }
    }

    func testExpiredTokenIsRefreshedAndRequestRetried() async throws {
        let store = InMemoryTokenStore(AuthTokens(accessToken: "old-access", refreshToken: "old-refresh"))
        let transport = makeTransport()
        let client = HTTPAPIClient(baseURL: Fixtures.baseURL, transport: transport, tokenStore: store)

        let tasks = try await client.tasks(status: nil)

        XCTAssertTrue(tasks.isEmpty)
        XCTAssertEqual(store.load(), AuthTokens(accessToken: "new-access", refreshToken: "new-refresh"))
        XCTAssertEqual(transport.count(path: "/auth/refresh"), 1)
        XCTAssertEqual(transport.count(path: "/worker/tasks"), 2) // original + retry
        let refreshBody = transport.requests.first { $0.url!.path.hasSuffix("/auth/refresh") }?.httpBody
        XCTAssertEqual(String(data: refreshBody ?? Data(), encoding: .utf8), #"{"refreshToken":"old-refresh"}"#)
    }

    func testConcurrent401sShareASingleRefresh() async throws {
        let store = InMemoryTokenStore(AuthTokens(accessToken: "old-access", refreshToken: "old-refresh"))
        let transport = makeTransport(refreshDelayMs: 200)
        let client = HTTPAPIClient(baseURL: Fixtures.baseURL, transport: transport, tokenStore: store)

        async let a = client.tasks(status: nil)
        async let b = client.tasks(status: .assigned)
        async let c = client.tasks(status: .rejected)
        _ = try await (a, b, c)

        XCTAssertEqual(transport.count(path: "/auth/refresh"), 1, "refresh tokens are single-use: only one refresh may run")
        XCTAssertEqual(store.load()?.accessToken, "new-access")
    }

    func testFailedRefreshEndsSession() async {
        let store = InMemoryTokenStore(AuthTokens(accessToken: "old-access", refreshToken: "old-refresh"))
        let client = HTTPAPIClient(baseURL: Fixtures.baseURL, transport: makeTransport(refreshStatus: 401), tokenStore: store)
        let problem = expectation(description: "session problem reported")
        client.onSessionProblem = { p in
            if p == .loggedOut { problem.fulfill() }
        }

        do {
            _ = try await client.tasks(status: nil)
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? APIError, .unauthorized)
        }
        await fulfillment(of: [problem], timeout: 1)
        XCTAssertNil(store.load())
    }

    func testRefreshIsSkippedWhenAnotherCallerAlreadyRotatedTheToken() async throws {
        let store = InMemoryTokenStore(AuthTokens(accessToken: "fresh", refreshToken: "r2"))
        let refresher = TokenRefresher(store: store) { _ in
            XCTFail("must not call the server: the token was already rotated")
            return AuthTokens(accessToken: "x", refreshToken: "y")
        }
        let tokens = try await refresher.refresh(after: "stale")
        XCTAssertEqual(tokens.accessToken, "fresh")
        let count = await refresher.refreshCount
        XCTAssertEqual(count, 0)
    }

    func testNetworkErrorDuringRefreshKeepsTokens() async {
        let store = InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r"))
        let refresher = TokenRefresher(store: store) { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await refresher.refresh(after: "a")
            XCTFail("expected error")
        } catch {
            XCTAssertTrue((error as? APIError)?.isOffline == true)
        }
        XCTAssertNotNil(store.load(), "going offline must not log the worker out")
    }
}

import XCTest
@testable import BayenWorker

/// First login with a temporary password: `mustChangePassword`, `POST /me/password` and the gate in `SessionStore`.
final class PasswordChangeTests: XCTestCase {
    private static let mustChangePhone = "+212600000006"

    private static func userJSON(mustChangePassword: Bool?) -> String {
        let flag = mustChangePassword.map { #","mustChangePassword":\#($0)"# } ?? ""
        return #"{"id":"33333333-3333-4333-8333-333333333333","municipalityId":"22222222-2222-4222-8222-222222222222","fullName":"Youssef","phone":"+212600000002","role":"WORKER","status":"ACTIVE","cin":null,"preferredLanguage":"ar","createdAt":"2026-09-01T00:00:00.000Z","approvedAt":null\#(flag)}"#
    }

    private func makeDefaults() -> UserDefaults {
        let name = "bayen-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    @MainActor
    private func makeSession(api: APIClient) -> SessionStore {
        SessionStore(api: api, language: LanguageManager(defaults: makeDefaults()), defaults: makeDefaults())
    }

    // MARK: - Decoding

    func testDecodesMustChangePassword() throws {
        let user = try JSONCoding.decoder.decode(User.self, from: Fixtures.json(Self.userJSON(mustChangePassword: true)))
        XCTAssertTrue(user.mustChangePassword)
        let done = try JSONCoding.decoder.decode(User.self, from: Fixtures.json(Self.userJSON(mustChangePassword: false)))
        XCTAssertFalse(done.mustChangePassword)
    }

    func testMustChangePasswordDefaultsToFalseWhenMissing() throws {
        let user = try JSONCoding.decoder.decode(User.self, from: Fixtures.json(Self.userJSON(mustChangePassword: nil)))
        XCTAssertFalse(user.mustChangePassword)
        XCTAssertEqual(user.fullName, "Youssef")
    }

    func testMustChangePasswordSurvivesTheProfileCacheRoundTrip() throws {
        let user = try JSONCoding.decoder.decode(User.self, from: Fixtures.json(Self.userJSON(mustChangePassword: true)))
        let copy = try JSONCoding.decoder.decode(User.self, from: JSONCoding.encoder.encode(user))
        XCTAssertEqual(copy, user)
    }

    // MARK: - POST /me/password

    func testChangePasswordSendsBothPasswordsAndStoresTheNewTokens() async throws {
        let store = InMemoryTokenStore(AuthTokens(accessToken: "old-access", refreshToken: "old-refresh"))
        let user = Self.userJSON(mustChangePassword: false)
        let transport = ScriptedTransport { _ in
            (200, Fixtures.json(#"{"accessToken":"new-access","refreshToken":"new-refresh","user":\#(user)}"#))
        }
        let client = HTTPAPIClient(baseURL: Fixtures.baseURL, transport: transport, tokenStore: store)

        let updated = try await client.changePassword(currentPassword: "Temp1234", newPassword: "MyOwnPass9")

        XCTAssertFalse(updated.mustChangePassword)
        XCTAssertEqual(store.load(), AuthTokens(accessToken: "new-access", refreshToken: "new-refresh"))
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v1/me/password")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old-access")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])
        XCTAssertEqual(body, ["currentPassword": "Temp1234", "newPassword": "MyOwnPass9"])
    }

    func testChangePasswordErrorKeepsTheOldTokens() async {
        let tokens = AuthTokens(accessToken: "old-access", refreshToken: "old-refresh")
        let store = InMemoryTokenStore(tokens)
        let transport = ScriptedTransport { _ in (422, Fixtures.error("CURRENT_PASSWORD_INCORRECT")) }
        let client = HTTPAPIClient(baseURL: Fixtures.baseURL, transport: transport, tokenStore: store)

        do {
            _ = try await client.changePassword(currentPassword: "wrong", newPassword: "MyOwnPass9")
            XCTFail("expected CURRENT_PASSWORD_INCORRECT")
        } catch {
            XCTAssertEqual((error as? APIError)?.code, "CURRENT_PASSWORD_INCORRECT")
            XCTAssertEqual((error as? APIError)?.status, 422)
        }
        XCTAssertEqual(store.load(), tokens)
    }

    func testPasswordChangeRequiredIsReportedAndKeepsQueuedWorkRetryable() async {
        let transport = ScriptedTransport { _ in (403, Fixtures.error("PASSWORD_CHANGE_REQUIRED")) }
        let client = HTTPAPIClient(baseURL: Fixtures.baseURL, transport: transport,
                                   tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")))
        let problem = expectation(description: "session problem reported")
        client.onSessionProblem = { p in
            if p == .passwordChangeRequired { problem.fulfill() }
        }

        do {
            _ = try await client.tasks(status: nil)
            XCTFail("expected PASSWORD_CHANGE_REQUIRED")
        } catch {
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.code, "PASSWORD_CHANGE_REQUIRED")
            XCTAssertEqual(apiError?.isRetryable, true, "queued photos must wait, not fail for good")
        }
        await fulfillment(of: [problem], timeout: 1)
    }

    // MARK: - Gate

    func testPasswordGateDecision() throws {
        let done = try JSONCoding.decoder.decode(User.self, from: Fixtures.json(Self.userJSON(mustChangePassword: false)))
        let required = done.with(mustChangePassword: true)
        XCTAssertEqual(SessionStore.passwordGate(for: done, hasCurrentPassword: false), .enterApp)
        XCTAssertEqual(SessionStore.passwordGate(for: done, hasCurrentPassword: true), .enterApp)
        XCTAssertEqual(SessionStore.passwordGate(for: required, hasCurrentPassword: true), .changePassword)
        XCTAssertEqual(SessionStore.passwordGate(for: required, hasCurrentPassword: false), .signOut)
    }

    @MainActor
    func testLoginWithTemporaryPasswordIsGatedUntilTheWorkerChoosesANewOne() async throws {
        let tokens = InMemoryTokenStore()
        let api = MockAPIClient(tokenStore: tokens)
        let session = makeSession(api: api)
        var logins = 0
        session.onLogin = { logins += 1 }

        try await session.login(phone: Self.mustChangePhone, password: MockAPIClient.password)

        guard case let .passwordChangeRequired(user) = session.state else {
            return XCTFail("expected the password screen, got \(session.state)")
        }
        XCTAssertTrue(user.mustChangePassword)
        XCTAssertNil(session.user, "the main app must not be reachable yet")
        XCTAssertEqual(logins, 0)
        XCTAssertTrue(session.isTemporaryPassword(MockAPIClient.password))
        do {
            _ = try await api.tasks(status: nil)
            XCTFail("worker endpoints are closed until the password is changed")
        } catch {
            XCTAssertEqual((error as? APIError)?.code, "PASSWORD_CHANGE_REQUIRED")
        }
        let oldTokens = tokens.load()

        try await session.changePassword(to: "MyOwnPass9")

        XCTAssertEqual(session.user?.phone, Self.mustChangePhone)
        XCTAssertEqual(session.user?.mustChangePassword, false)
        XCTAssertEqual(logins, 1)
        XCTAssertFalse(session.isTemporaryPassword(MockAPIClient.password), "the temporary password is dropped from memory")
        XCTAssertNotNil(tokens.load())
        XCTAssertNotEqual(tokens.load(), oldTokens, "the new token pair replaces the revoked one")
        let tasks = try await api.tasks(status: nil)
        XCTAssertFalse(tasks.isEmpty)

        // The new password is the one that works from now on.
        await session.logout()
        try await session.login(phone: Self.mustChangePhone, password: "MyOwnPass9")
        XCTAssertNotNil(session.user)
    }

    @MainActor
    func testServerErrorKeepsTheWorkerOnThePasswordScreen() async throws {
        let api = MockAPIClient()
        let session = makeSession(api: api)
        try await session.login(phone: Self.mustChangePhone, password: MockAPIClient.password)

        do {
            try await session.changePassword(to: MockAPIClient.password) // same as the temporary one
            XCTFail("expected VALIDATION_ERROR")
        } catch {
            XCTAssertEqual((error as? APIError)?.code, "VALIDATION_ERROR")
        }
        guard case .passwordChangeRequired = session.state else {
            return XCTFail("expected to stay on the password screen, got \(session.state)")
        }
    }

    @MainActor
    func testRestoredSessionWithoutThePasswordInMemorySignsOut() async throws {
        let tokens = InMemoryTokenStore()
        let api = MockAPIClient(tokenStore: tokens)
        try await makeSession(api: api).login(phone: Self.mustChangePhone, password: MockAPIClient.password)
        XCTAssertNotNil(tokens.load())

        // "Relaunch": a new SessionStore on the same stored tokens has no password in memory.
        let relaunched = makeSession(api: api)
        await relaunched.bootstrap()

        XCTAssertEqual(relaunched.state, .loggedOut)
        XCTAssertNil(tokens.load())
    }

    @MainActor
    func testLoginWithoutTheFlagGoesStraightIntoTheApp() async throws {
        let session = makeSession(api: MockAPIClient())
        try await session.login(phone: "+212600000002", password: MockAPIClient.password)
        XCTAssertNotNil(session.user)
        XCTAssertFalse(session.isTemporaryPassword(MockAPIClient.password), "no reason to keep the password in memory")
    }

    @MainActor
    func testLocalValidationOfTheNewPassword() {
        let model = ChangePasswordViewModel()
        let isTemporary: (String) -> Bool = { $0 == "Temp1234" }

        model.newPassword = "short"
        model.confirmation = "short"
        XCTAssertEqual(model.validationMessage(isTemporaryPassword: isTemporary), L10n.tr("validation.password"))

        model.newPassword = "LongEnough1"
        model.confirmation = "LongEnough2"
        XCTAssertEqual(model.validationMessage(isTemporaryPassword: isTemporary), L10n.tr("validation.passwordMismatch"))

        model.newPassword = "Temp1234"
        model.confirmation = "Temp1234"
        XCTAssertEqual(model.validationMessage(isTemporaryPassword: isTemporary), L10n.tr("validation.passwordSame"))

        model.newPassword = String(repeating: "a", count: 129)
        model.confirmation = model.newPassword
        XCTAssertEqual(model.validationMessage(isTemporaryPassword: isTemporary), L10n.tr("validation.passwordTooLong"))

        model.newPassword = "LongEnough1"
        model.confirmation = "LongEnough1"
        XCTAssertNil(model.validationMessage(isTemporaryPassword: isTemporary))
    }

    func testNewStringsExistInEveryLanguage() throws {
        let keys = ["changePassword.title", "changePassword.message", "changePassword.button", "field.confirmPassword",
                    "validation.passwordMismatch", "validation.passwordSame", "validation.passwordTooLong",
                    "error.CURRENT_PASSWORD_INCORRECT", "error.PASSWORD_CHANGE_REQUIRED"]
        for language in AppLanguage.allCases {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language.rawValue, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in keys {
                XCTAssertNotEqual(bundle.localizedString(forKey: key, value: key, table: "Localizable"), key,
                                  "\(key) is missing in \(language.rawValue)")
            }
        }
    }
}

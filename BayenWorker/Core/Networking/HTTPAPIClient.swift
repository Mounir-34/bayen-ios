import Foundation

/// `APIClient` talking to the real backend.
///
/// * Adds `Authorization: Bearer <access token>` to authenticated calls.
/// * On 401 it refreshes the token pair once (single in-flight refresh via `TokenRefresher`)
///   and retries the original request exactly once.
final class HTTPAPIClient: APIClient, @unchecked Sendable {
    let baseURL: URL
    private let transport: HTTPTransport
    private let tokenStore: TokenStoring
    private let refresher: TokenRefresher
    private let language: @Sendable () -> String

    var onSessionProblem: (@Sendable (SessionProblem) -> Void)?

    init(baseURL: URL,
         transport: HTTPTransport = URLSessionTransport(),
         tokenStore: TokenStoring,
         language: @escaping @Sendable () -> String = { "ar" }) {
        self.baseURL = baseURL
        self.transport = transport
        self.tokenStore = tokenStore
        self.language = language
        let refreshURL = baseURL.appendingPathComponent("auth/refresh")
        self.refresher = TokenRefresher(store: tokenStore) { refreshToken in
            var request = URLRequest(url: refreshURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONCoding.encoder.encode(RefreshRequest(refreshToken: refreshToken))
            let (data, response): (Data, HTTPURLResponse)
            do { (data, response) = try await transport.send(request) } catch { throw APIError.from(error) }
            guard (200..<300).contains(response.statusCode) else {
                throw APIError.fromResponse(status: response.statusCode, data: data)
            }
            do { return try JSONCoding.decoder.decode(AuthTokens.self, from: data) } catch {
                throw APIError.decoding(String(describing: error))
            }
        }
    }

    var hasSession: Bool { tokenStore.load() != nil }

    // MARK: - Auth

    func register(_ request: RegisterRequest) async throws -> User {
        let env: UserEnvelope = try await send(.post("auth/register", body: request), authorized: false)
        return env.user
    }

    func login(phone: String, password: String) async throws -> User {
        let response: LoginResponse = try await send(.post("auth/login", body: LoginRequest(phone: phone, password: password)),
                                                     authorized: false)
        tokenStore.save(AuthTokens(accessToken: response.accessToken, refreshToken: response.refreshToken))
        return response.user
    }

    func logout() async {
        if let tokens = tokenStore.load() {
            _ = try? await sendRaw(.post("auth/logout", body: RefreshRequest(refreshToken: tokens.refreshToken)), authorized: false)
        }
        tokenStore.clear()
    }

    func me() async throws -> User {
        let env: UserEnvelope = try await send(.get("me"))
        return env.user
    }

    // MARK: - Tasks

    func tasks(status: TaskStatus?) async throws -> [WorkerTask] {
        var all: [WorkerTask] = []
        var page = 1
        while true {
            var query = [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "pageSize", value: "100")]
            if let status { query.append(URLQueryItem(name: "status", value: status.rawValue)) }
            let result: Paged<WorkerTask> = try await send(.get("worker/tasks", query: query))
            all += result.items
            if result.items.isEmpty || all.count >= result.total || page >= 20 { break }
            page += 1
        }
        return all
    }

    func task(id: String) async throws -> TaskDetail {
        try await send(.get("worker/tasks/\(id)"))
    }

    func startTask(id: String, location: LocationPayload) async throws -> WorkerTask {
        let env: TaskEnvelope = try await send(.post("worker/tasks/\(id)/start", body: location))
        return env.task
    }

    func uploadPhoto(taskId: String, fileURL: URL, metadata: PhotoMetadata) async throws -> RemotePhoto {
        let multipart = MultipartFormData()
        let metadataJSON = try JSONCoding.encoder.encode(metadata)
        let image = try Data(contentsOf: fileURL)
        var endpoint = Endpoint.post("worker/tasks/\(taskId)/photos", body: Optional<String>.none)
        endpoint.rawBody = multipart.photoBody(metadataJSON: metadataJSON, imageData: image, filename: fileURL.lastPathComponent)
        endpoint.contentType = multipart.contentType
        endpoint.timeout = 120
        let env: PhotoEnvelope = try await send(endpoint)
        return env.photo
    }

    func deletePhoto(taskId: String, photoId: String) async throws {
        _ = try await sendRaw(.delete("worker/tasks/\(taskId)/photos/\(photoId)"), authorized: true)
    }

    func submit(taskId: String, request: SubmitRequest) async throws -> SubmitResponse {
        try await send(.post("worker/tasks/\(taskId)/submit", body: request))
    }

    func registerDeviceToken(_ token: String) async throws {
        _ = try await sendRaw(.post("me/device-token", body: DeviceTokenRequest(token: token, platform: "ios")), authorized: true)
    }

    // MARK: - Helpers for the background upload session

    /// Builds an authorised photo-upload request (body is provided as a file by the caller).
    func makePhotoUploadRequest(taskId: String, contentType: String) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("worker/tasks/\(taskId)/photos"))
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(language(), forHTTPHeaderField: "Accept-Language")
        guard let token = tokenStore.load()?.accessToken else { throw APIError.unauthorized }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Refreshes after a background upload got a 401 with `failedAccessToken`.
    func refreshTokens(after failedAccessToken: String?) async throws {
        do {
            _ = try await refresher.refresh(after: failedAccessToken)
        } catch let error as APIError where error == .unauthorized {
            onSessionProblem?(.loggedOut)
            throw error
        }
    }

    // MARK: - Core request pipeline

    private func send<T: Decodable>(_ endpoint: Endpoint, authorized: Bool = true) async throws -> T {
        let data = try await sendRaw(endpoint, authorized: authorized)
        do {
            return try JSONCoding.decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    @discardableResult
    private func sendRaw(_ endpoint: Endpoint, authorized: Bool) async throws -> Data {
        var accessToken: String?
        if authorized {
            guard let tokens = tokenStore.load() else {
                onSessionProblem?(.loggedOut)
                throw APIError.unauthorized
            }
            accessToken = tokens.accessToken
        }

        let (data, response) = try await perform(endpoint, accessToken: accessToken)
        if response.statusCode == 401, authorized {
            // Access token expired/invalid → refresh once, then retry once.
            let fresh: AuthTokens
            do {
                fresh = try await refresher.refresh(after: accessToken)
            } catch let error as APIError {
                if error == .unauthorized { onSessionProblem?(.loggedOut) }
                throw error
            }
            let (retryData, retryResponse) = try await perform(endpoint, accessToken: fresh.accessToken)
            return try check(retryData, retryResponse, authorized: authorized)
        }
        return try check(data, response, authorized: authorized)
    }

    private func check(_ data: Data, _ response: HTTPURLResponse, authorized: Bool) throws -> Data {
        guard (200..<300).contains(response.statusCode) else {
            let error = APIError.fromResponse(status: response.statusCode, data: data)
            if authorized {
                switch error.code {
                case "ACCOUNT_PENDING": onSessionProblem?(.accountPending)
                case "ACCOUNT_SUSPENDED": onSessionProblem?(.accountSuspended)
                default: break
                }
                if response.statusCode == 401 {
                    tokenStore.clear()
                    onSessionProblem?(.loggedOut)
                    throw APIError.unauthorized
                }
            }
            throw error
        }
        return data
    }

    private func perform(_ endpoint: Endpoint, accessToken: String?) async throws -> (Data, HTTPURLResponse) {
        var request = try endpoint.urlRequest(baseURL: baseURL)
        request.setValue(language(), forHTTPHeaderField: "Accept-Language")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        do {
            return try await transport.send(request)
        } catch {
            throw APIError.from(error)
        }
    }
}

/// Description of one HTTP call relative to the API base URL.
struct Endpoint {
    var method: String
    var path: String
    var query: [URLQueryItem] = []
    var rawBody: Data?
    var contentType: String?
    var timeout: TimeInterval = 30

    static func get(_ path: String, query: [URLQueryItem] = []) -> Endpoint {
        Endpoint(method: "GET", path: path, query: query)
    }

    static func delete(_ path: String) -> Endpoint {
        Endpoint(method: "DELETE", path: path)
    }

    static func post<B: Encodable>(_ path: String, body: B?) -> Endpoint {
        var e = Endpoint(method: "POST", path: path)
        if let body {
            e.rawBody = try? JSONCoding.encoder.encode(body)
            e.contentType = "application/json"
        }
        return e
    }

    func urlRequest(baseURL: URL) throws -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw APIError.decoding("Invalid URL for \(path)") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let rawBody {
            request.httpBody = rawBody
            request.setValue(contentType ?? "application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}

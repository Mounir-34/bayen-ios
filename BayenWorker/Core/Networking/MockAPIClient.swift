import CoreLocation
import Foundation

/// In-memory backend used by the "BayenWorker Mock" scheme, SwiftUI previews and unit tests.
///
/// Demo accounts (password `Bayen2026!`, like the server seed):
/// * `06 00 00 00 02` — active worker (Arabic)
/// * `06 00 00 00 03` — active worker (French)
/// * `06 00 00 00 04` — account pending approval
/// * `06 00 00 00 05` — account suspended
/// Newly registered accounts are auto-approved 15 seconds after registration (to demo the refresh button).
final class MockAPIClient: APIClient, @unchecked Sendable {
    static let password = "Bayen2026!"
    static let municipalityCode = "CASA-AINSEBAA"
    static let municipalityId = "6f1c1d2e-0000-4000-8000-000000000001"
    /// Aïn Sebaâ, Casablanca.
    static let center = CLLocationCoordinate2D(latitude: 33.6005, longitude: -7.5330)

    var onSessionProblem: (@Sendable (SessionProblem) -> Void)?

    /// Probability (0…1) that a photo upload fails with a network error — shows the retry queue in action.
    var photoUploadFailureRate: Double
    /// Artificial latency in seconds.
    var latency: Double

    private let lock = NSLock()
    private let tokenStore: TokenStoring
    private var users: [String: (user: User, password: String, registeredAt: Date)] = [:]
    private var currentUserId: String?
    private var taskStore: [String: WorkerTask] = [:]
    private var photos: [String: RemotePhoto] = [:] // by server id
    private var submissions: [String: Submission] = [:] // latest by task id
    private var rejectionNotes: [String: String] = [:]
    private(set) var uploadCallCount = 0

    init(tokenStore: TokenStoring = InMemoryTokenStore(), photoUploadFailureRate: Double = 0, latency: Double = 0) {
        self.tokenStore = tokenStore
        self.photoUploadFailureRate = photoUploadFailureRate
        self.latency = latency
        seed()
    }

    var hasSession: Bool { tokenStore.load() != nil }

    // MARK: - Auth

    func register(_ request: RegisterRequest) async throws -> User {
        try await delay()
        guard request.municipalityCode.uppercased() == Self.municipalityCode else {
            throw APIError.server(status: 404, code: "MUNICIPALITY_NOT_FOUND", message: "Unknown municipality code")
        }
        guard let phone = PhoneNumber.normalize(request.phone) else {
            throw APIError.server(status: 400, code: "VALIDATION_ERROR", message: "Invalid phone")
        }
        guard request.password.count >= 8 else {
            throw APIError.server(status: 400, code: "VALIDATION_ERROR", message: "Password too short")
        }
        return try withLock {
            if users.values.contains(where: { $0.user.phone == phone }) {
                throw APIError.server(status: 409, code: "PHONE_ALREADY_REGISTERED", message: "Already registered")
            }
            let user = User(id: UUID().uuidString.lowercased(), municipalityId: Self.municipalityId, fullName: request.fullName,
                            phone: phone, role: "WORKER", status: .pending, cin: request.cin?.uppercased(),
                            preferredLanguage: request.preferredLanguage, createdAt: Date(), approvedAt: nil)
            users[user.id] = (user, request.password, Date())
            return user
        }
    }

    func login(phone: String, password: String) async throws -> User {
        try await delay()
        let user: User = try withLock {
            guard let e164 = PhoneNumber.normalize(phone),
                  let entry = users.values.first(where: { $0.user.phone == e164 }),
                  entry.password == password else {
                throw APIError.server(status: 401, code: "INVALID_CREDENTIALS", message: "Invalid phone or password")
            }
            var u = entry.user
            if u.status == .pending, Date().timeIntervalSince(entry.registeredAt) > 15, !u.phone.hasSuffix("04") {
                u = u.with(status: .active)
                users[u.id] = (u, entry.password, entry.registeredAt)
            }
            switch u.status {
            case .pending: throw APIError.server(status: 403, code: "ACCOUNT_PENDING", message: "Pending")
            case .suspended: throw APIError.server(status: 403, code: "ACCOUNT_SUSPENDED", message: "Suspended")
            default: break
            }
            currentUserId = u.id
            return u
        }
        tokenStore.save(AuthTokens(accessToken: "mock-access-\(UUID().uuidString)", refreshToken: "mock-refresh-\(UUID().uuidString)"))
        return user
    }

    func logout() async {
        withLock { currentUserId = nil }
        tokenStore.clear()
    }

    func me() async throws -> User {
        try await delay()
        return try withLock {
            guard tokenStore.load() != nil else { throw APIError.unauthorized }
            // After an app restart the mock "server" forgets who is logged in: default to the demo worker.
            let id = currentUserId ?? users.values.first(where: { $0.user.phone == "+212600000002" })!.user.id
            currentUserId = id
            return users[id]!.user
        }
    }

    // MARK: - Tasks

    func tasks(status: TaskStatus?) async throws -> [WorkerTask] {
        try await delay()
        return try withLock {
            try requireSession()
            return taskStore.values
                .filter { status == nil ? $0.status != .cancelled : $0.status == status }
                .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        }
    }

    func task(id: String) async throws -> TaskDetail {
        try await delay()
        return try withLock {
            try requireSession()
            guard let task = taskStore[id] else { throw Self.notFound }
            let taskPhotos = photos.values.filter { $0.taskId == id }.sorted { $0.capturedAt < $1.capturedAt }
            let latest = submissions[id]
            return TaskDetail(task: task, photos: taskPhotos, latestSubmission: latest,
                              rejectionNote: latest?.reviewStatus == .rejected ? latest?.reviewNote : nil)
        }
    }

    func startTask(id: String, location: LocationPayload) async throws -> WorkerTask {
        try await delay()
        return try withLock {
            try requireSession()
            guard var task = taskStore[id] else { throw Self.notFound }
            guard task.status == .assigned || task.status == .rejected else {
                throw APIError.server(status: 409, code: "INVALID_TRANSITION",
                                      message: "Cannot move task from \(task.status.rawValue) to IN_PROGRESS",
                                      transitionFrom: task.status.rawValue)
            }
            task.status = .inProgress
            task.startedAt = task.startedAt ?? Date()
            taskStore[id] = task
            return task
        }
    }

    func uploadPhoto(taskId: String, fileURL: URL, metadata: PhotoMetadata) async throws -> RemotePhoto {
        try await delay(extra: 0.6)
        let shouldFail = Double.random(in: 0..<1) < photoUploadFailureRate
        return try withLock {
            uploadCallCount += 1
            try requireSession()
            if shouldFail { throw APIError.network(code: URLError.networkConnectionLost.rawValue) }
            // Idempotency on clientPhotoId, exactly like the server.
            if let existing = photos.values.first(where: { $0.clientPhotoId == metadata.clientPhotoId }) {
                return existing
            }
            guard let task = taskStore[taskId] else { throw Self.notFound }
            guard task.status == .inProgress else {
                throw APIError.server(status: 409, code: "TASK_NOT_IN_PROGRESS", message: "Task not in progress")
            }
            let distance = Geo.distanceMeters(from: task.coordinate,
                                              to: CLLocationCoordinate2D(latitude: metadata.latitude, longitude: metadata.longitude))
            var flags: [String] = []
            if distance > Double(task.radiusMeters) { flags.append("DISTANCE_EXCEEDED") }
            if metadata.horizontalAccuracy > 50 { flags.append("LOW_GPS_ACCURACY") }
            if metadata.isSimulatedLocation { flags.append("SIMULATED_LOCATION") }
            let photo = RemotePhoto(id: UUID().uuidString.lowercased(), taskId: taskId, clientPhotoId: metadata.clientPhotoId,
                                    kind: metadata.kind, capturedAt: metadata.capturedAt, latitude: metadata.latitude,
                                    longitude: metadata.longitude, horizontalAccuracy: metadata.horizontalAccuracy,
                                    distanceFromTaskMeters: distance, flags: flags, submissionId: nil,
                                    url: fileURL.absoluteString, thumbnailUrl: nil)
            photos[photo.id] = photo
            return photo
        }
    }

    func deletePhoto(taskId: String, photoId: String) async throws {
        try await delay()
        try withLock {
            try requireSession()
            guard let photo = photos[photoId], photo.taskId == taskId else { throw Self.notFound }
            guard photo.submissionId == nil else {
                throw APIError.server(status: 409, code: "PHOTO_ALREADY_SUBMITTED", message: "Already submitted")
            }
            photos[photoId] = nil
        }
    }

    func submit(taskId: String, request: SubmitRequest) async throws -> SubmitResponse {
        try await delay()
        return try withLock {
            try requireSession()
            guard var task = taskStore[taskId] else { throw Self.notFound }
            guard task.status == .inProgress else {
                throw APIError.server(status: 409, code: "INVALID_TRANSITION",
                                      message: "Cannot move task from \(task.status.rawValue) to SUBMITTED",
                                      transitionFrom: task.status.rawValue)
            }
            let ids = Array(Set(request.photoIds))
            guard !ids.isEmpty, ids.allSatisfy({ photos[$0]?.taskId == taskId && photos[$0]?.submissionId == nil }) else {
                throw APIError.server(status: 422, code: "INVALID_PHOTO_IDS", message: "Invalid photo ids")
            }
            let submissionId = UUID().uuidString.lowercased()
            var flags = Set(ids.flatMap { photos[$0]!.flags })
            if ids.count < task.minPhotos { flags.insert("MISSING_PHOTOS") }
            if task.requireBeforePhoto, !ids.contains(where: { photos[$0]!.kind == .before }) { flags.insert("MISSING_BEFORE_PHOTO") }
            for id in ids {
                let p = photos[id]!
                photos[id] = RemotePhoto(id: p.id, taskId: p.taskId, clientPhotoId: p.clientPhotoId, kind: p.kind,
                                         capturedAt: p.capturedAt, latitude: p.latitude, longitude: p.longitude,
                                         horizontalAccuracy: p.horizontalAccuracy, distanceFromTaskMeters: p.distanceFromTaskMeters,
                                         flags: p.flags, submissionId: submissionId, url: p.url, thumbnailUrl: p.thumbnailUrl)
            }
            let submission = Submission(id: submissionId, taskId: taskId, note: request.note, submittedAt: Date(),
                                        reviewStatus: .pending, reviewNote: nil, flags: flags.sorted(), photoIds: ids)
            submissions[taskId] = submission
            task.status = .submitted
            task.submittedAt = Date()
            taskStore[taskId] = task
            return SubmitResponse(submission: submission, flags: submission.flags)
        }
    }

    func registerDeviceToken(_ token: String) async throws {
        try await delay()
    }

    // MARK: - Test helpers

    func taskSnapshot(_ id: String) -> WorkerTask? { withLock { taskStore[id] } }
    func remotePhotoCount() -> Int { withLock { photos.count } }

    // MARK: - Internals

    private static let notFound = APIError.server(status: 404, code: "NOT_FOUND", message: "Not found")

    private func requireSession() throws {
        guard tokenStore.load() != nil else { throw APIError.unauthorized }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private func delay(extra: Double = 0) async throws {
        let seconds = latency > 0 ? latency + extra : 0
        if seconds > 0 { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    }

    private func seed() {
        let now = Date()
        func user(_ id: String, _ name: String, _ phone: String, _ status: UserStatus, _ lang: AppLanguage, cin: String? = nil) {
            let u = User(id: id, municipalityId: Self.municipalityId, fullName: name, phone: phone, role: "WORKER", status: status,
                         cin: cin, preferredLanguage: lang, createdAt: now.addingTimeInterval(-40 * 86_400),
                         approvedAt: status == .active ? now.addingTimeInterval(-20 * 86_400) : nil)
            users[id] = (u, Self.password, now.addingTimeInterval(-40 * 86_400))
        }
        user("6f1c1d2e-0000-4000-8000-000000000102", "يوسف العمراني", "+212600000002", .active, .ar, cin: "BE123456")
        user("6f1c1d2e-0000-4000-8000-000000000103", "Khadija Ait Lahcen", "+212600000003", .active, .fr)
        user("6f1c1d2e-0000-4000-8000-000000000104", "عمر التازي", "+212600000004", .pending, .ar)
        user("6f1c1d2e-0000-4000-8000-000000000105", "Rachid Bennani", "+212600000005", .suspended, .fr)

        let c = Self.center
        func task(_ n: Int, _ title: String, _ description: String, _ category: TaskCategory, dLat: Double, dLng: Double,
                  status: TaskStatus, dueInDays: Double?, radius: Int = 50, minPhotos: Int = 2, requireBefore: Bool = true,
                  address: String?, priority: TaskPriority = .normal) {
            let id = String(format: "6f1c1d2e-0000-4000-8000-%012ld", 200 + n)
            let started: Date? = [.inProgress, .submitted, .approved, .rejected].contains(status) ? now.addingTimeInterval(-3 * 3600) : nil
            taskStore[id] = WorkerTask(
                id: id, municipalityId: Self.municipalityId, title: title, description: description, category: category,
                latitude: c.latitude + dLat, longitude: c.longitude + dLng, radiusMeters: radius, address: address,
                priority: priority, dueDate: dueInDays.map { now.addingTimeInterval($0 * 86_400) }, status: status,
                requireBeforePhoto: requireBefore, minPhotos: minPhotos, paymentAmountMAD: 350,
                createdAt: now.addingTimeInterval(-5 * 86_400), startedAt: started,
                submittedAt: [.submitted, .approved].contains(status) ? now.addingTimeInterval(-2 * 3600) : nil,
                closedAt: status == .approved ? now.addingTimeInterval(-3600) : nil, flags: [])
        }
        task(1, "إصلاح عمود الإنارة رقم 14", "المصباح لا يشتغل منذ أسبوع. تغيير المصباح والتأكد من الأسلاك.", .lighting,
             dLat: 0.0001, dLng: 0.0001, status: .assigned, dueInDays: 2, address: "شارع الشفشاوني، عين السبع", priority: .high)
        task(2, "Reboucher un nid-de-poule", "Nid-de-poule d'environ 60 cm devant l'école primaire. Nettoyer puis reboucher à l'enrobé à froid.", .roads,
             dLat: 0.0035, dLng: -0.0021, status: .assigned, dueInDays: 1, radius: 80, address: "Rue 12, Hay Mohammadi")
        task(3, "سقي وتقليم أشجار الحديقة", "تقليم الأغصان اليابسة وسقي الأشجار في الحديقة الصغيرة.", .greenSpaces,
             dLat: -0.0018, dLng: 0.0027, status: .inProgress, dueInDays: 3, radius: 100, minPhotos: 3, address: "حديقة الياسمين")
        task(4, "Réparer le conteneur à déchets", "Le couvercle du conteneur est cassé. Remplacer la charnière.", .waste,
             dLat: 0.0022, dLng: 0.0040, status: .rejected, dueInDays: -1, address: "Bd. Moulay Ismaïl")
        rejectionNotes[String(format: "6f1c1d2e-0000-4000-8000-%012ld", 204)] =
            "صورة \"بعد\" لا تُظهر الغطاء الجديد. المرجو التقاط صورة واضحة للحاوية كاملة."
        task(5, "Fuite d'eau – borne fontaine", "Changer le joint de la borne fontaine.", .water,
             dLat: -0.0040, dLng: -0.0015, status: .submitted, dueInDays: 4, address: "Place Al Amal")
        task(6, "صباغة باب المركز الثقافي", "صباغة الباب الخارجي باللون الأخضر.", .buildings,
             dLat: 0.0050, dLng: 0.0010, status: .approved, dueInDays: -3, requireBefore: false, address: "المركز الثقافي عين السبع")

        for (taskId, note) in rejectionNotes {
            submissions[taskId] = Submission(id: UUID().uuidString.lowercased(), taskId: taskId, note: nil,
                                             submittedAt: now.addingTimeInterval(-86_400), reviewStatus: .rejected,
                                             reviewNote: note, flags: [], photoIds: [])
        }
    }
}

extension User {
    func with(status: UserStatus) -> User {
        User(id: id, municipalityId: municipalityId, fullName: fullName, phone: phone, role: role, status: status, cin: cin,
             preferredLanguage: preferredLanguage, createdAt: createdAt, approvedAt: status == .active ? Date() : approvedAt)
    }
}

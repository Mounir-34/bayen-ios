import CoreLocation
import Foundation

struct User: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let municipalityId: String
    let fullName: String
    let phone: String
    let role: String
    let status: UserStatus
    let cin: String?
    let preferredLanguage: AppLanguage
    let createdAt: Date
    let approvedAt: Date?
}

struct WorkerTask: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: String
    let municipalityId: String
    let title: String
    let description: String
    let category: TaskCategory
    let latitude: Double
    let longitude: Double
    let radiusMeters: Int
    let address: String?
    let priority: TaskPriority
    let dueDate: Date?
    var status: TaskStatus
    let requireBeforePhoto: Bool
    let minPhotos: Int
    let paymentAmountMAD: Double?
    let createdAt: Date
    var startedAt: Date?
    var submittedAt: Date?
    var closedAt: Date?
    /// Flags of the latest submission.
    let flags: [String]

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    var isOverdue: Bool {
        guard let dueDate, [.assigned, .inProgress, .rejected].contains(status) else { return false }
        return dueDate < Date()
    }
}

struct RemotePhoto: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: String
    let taskId: String
    let clientPhotoId: String
    let kind: PhotoKind
    let capturedAt: Date
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let distanceFromTaskMeters: Double
    let flags: [String]
    let submissionId: String?
    let url: String
    let thumbnailUrl: String?
}

struct Submission: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let taskId: String
    let note: String?
    let submittedAt: Date
    let reviewStatus: ReviewStatus
    let reviewNote: String?
    let flags: [String]
    let photoIds: [String]
}

struct TaskDetail: Codable, Equatable, Sendable {
    let task: WorkerTask
    let photos: [RemotePhoto]
    let latestSubmission: Submission?
    let rejectionNote: String?
}

struct Paged<Item: Codable & Sendable>: Codable, Sendable {
    let items: [Item]
    let total: Int
    let page: Int
    let pageSize: Int
}

struct AuthTokens: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
}

// MARK: - Response envelopes

struct LoginResponse: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let user: User
}

struct UserEnvelope: Codable, Sendable { let user: User }
struct TaskEnvelope: Codable, Sendable { let task: WorkerTask }
struct PhotoEnvelope: Codable, Sendable { let photo: RemotePhoto }

struct SubmitResponse: Codable, Sendable {
    let submission: Submission
    let flags: [String]
}

// MARK: - Requests

struct RegisterRequest: Codable, Sendable {
    let fullName: String
    let phone: String
    let password: String
    let municipalityCode: String
    let cin: String?
    let preferredLanguage: AppLanguage
}

struct LoginRequest: Codable, Sendable {
    let phone: String
    let password: String
}

struct RefreshRequest: Codable, Sendable {
    let refreshToken: String
}

struct LocationPayload: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let accuracy: Double

    init(latitude: Double, longitude: Double, accuracy: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
    }

    init(_ location: CLLocation) {
        self.init(latitude: location.coordinate.latitude,
                  longitude: location.coordinate.longitude,
                  accuracy: max(0, location.horizontalAccuracy))
    }
}

struct SubmitRequest: Codable, Equatable, Sendable {
    let photoIds: [String]
    let note: String?
    let latitude: Double
    let longitude: Double
    let accuracy: Double
}

/// Metadata JSON sent with each photo (multipart field `metadata`).
struct PhotoMetadata: Codable, Equatable, Sendable {
    let kind: PhotoKind
    let capturedAt: Date
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let altitude: Double?
    let isSimulatedLocation: Bool
    let deviceModel: String
    let osVersion: String
    let appVersion: String
    let clientPhotoId: String
}

struct DeviceTokenRequest: Codable, Sendable {
    let token: String
    let platform: String
}

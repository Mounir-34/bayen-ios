import Foundation
import SwiftData

/// Upload state shown to the worker for each photo.
enum PhotoUploadStatus: String, Codable, Sendable {
    case waiting
    case uploading
    case uploaded
    case failed
}

/// A photo captured on this device. Saved (file + this row) *before* any network activity,
/// so nothing is lost if the app is killed or there is no signal.
@Model
final class PendingPhoto {
    @Attribute(.unique) var clientPhotoId: String
    var taskId: String
    var kindRaw: String
    var capturedAt: Date
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double
    var altitude: Double?
    var isSimulatedLocation: Bool
    var deviceModel: String
    var osVersion: String
    var appVersion: String
    /// File name inside `PhotoFileStore.directory`.
    var fileName: String
    var width: Int
    var height: Int

    var statusRaw: String
    var remotePhotoId: String?
    var attemptCount: Int
    var nextAttemptAt: Date?
    var lastErrorCode: String?
    /// A non-retryable error (e.g. TASK_NOT_IN_PROGRESS): waits for a manual "retry".
    var isPermanentFailure: Bool
    /// The worker deleted it; the queue removes it (and the server copy, if uploaded).
    var markedForDeletion: Bool

    init(clientPhotoId: String, taskId: String, kind: PhotoKind, metadata: PhotoMetadata, fileName: String, width: Int, height: Int) {
        self.clientPhotoId = clientPhotoId
        self.taskId = taskId
        self.kindRaw = kind.rawValue
        self.capturedAt = metadata.capturedAt
        self.latitude = metadata.latitude
        self.longitude = metadata.longitude
        self.horizontalAccuracy = metadata.horizontalAccuracy
        self.altitude = metadata.altitude
        self.isSimulatedLocation = metadata.isSimulatedLocation
        self.deviceModel = metadata.deviceModel
        self.osVersion = metadata.osVersion
        self.appVersion = metadata.appVersion
        self.fileName = fileName
        self.width = width
        self.height = height
        self.statusRaw = PhotoUploadStatus.waiting.rawValue
        self.remotePhotoId = nil
        self.attemptCount = 0
        self.nextAttemptAt = nil
        self.lastErrorCode = nil
        self.isPermanentFailure = false
        self.markedForDeletion = false
    }

    var kind: PhotoKind { PhotoKind(rawValue: kindRaw) ?? .after }

    var status: PhotoUploadStatus {
        get { PhotoUploadStatus(rawValue: statusRaw) ?? .waiting }
        set { statusRaw = newValue.rawValue }
    }

    var metadata: PhotoMetadata {
        PhotoMetadata(kind: kind, capturedAt: capturedAt, latitude: latitude, longitude: longitude,
                      horizontalAccuracy: horizontalAccuracy, altitude: altitude, isSimulatedLocation: isSimulatedLocation,
                      deviceModel: deviceModel, osVersion: osVersion, appVersion: appVersion, clientPhotoId: clientPhotoId)
    }
}

/// "I'm done" pressed; sent once every photo in `clientPhotoIds` is uploaded.
@Model
final class PendingSubmission {
    @Attribute(.unique) var taskId: String
    var clientPhotoIds: [String]
    /// Photos that were already on the server (e.g. uploaded before a reinstall).
    var extraRemotePhotoIds: [String]
    var note: String?
    var latitude: Double
    var longitude: Double
    var accuracy: Double
    var createdAt: Date
    var attemptCount: Int
    var nextAttemptAt: Date?
    var lastErrorCode: String?
    var isPermanentFailure: Bool

    init(taskId: String, clientPhotoIds: [String], extraRemotePhotoIds: [String], note: String?, location: LocationPayload, createdAt: Date) {
        self.taskId = taskId
        self.clientPhotoIds = clientPhotoIds
        self.extraRemotePhotoIds = extraRemotePhotoIds
        self.note = note
        self.latitude = location.latitude
        self.longitude = location.longitude
        self.accuracy = location.accuracy
        self.createdAt = createdAt
        self.attemptCount = 0
        self.nextAttemptAt = nil
        self.lastErrorCode = nil
        self.isPermanentFailure = false
    }
}

/// "Start task" pressed without connectivity; sent before the task's photos.
@Model
final class PendingTaskStart {
    @Attribute(.unique) var taskId: String
    var latitude: Double
    var longitude: Double
    var accuracy: Double
    var createdAt: Date
    var attemptCount: Int
    var nextAttemptAt: Date?

    init(taskId: String, location: LocationPayload, createdAt: Date) {
        self.taskId = taskId
        self.latitude = location.latitude
        self.longitude = location.longitude
        self.accuracy = location.accuracy
        self.createdAt = createdAt
        self.attemptCount = 0
        self.nextAttemptAt = nil
    }
}

enum QueueStore {
    static let schema = Schema([PendingPhoto.self, PendingSubmission.self, PendingTaskStart.self])

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            configuration = ModelConfiguration(schema: schema, url: PhotoFileStore.supportDirectory.appendingPathComponent("Queue.store"))
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

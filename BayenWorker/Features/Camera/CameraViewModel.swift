import CoreLocation
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class CameraViewModel {
    let task: WorkerTask
    var kind: PhotoKind
    private(set) var isCapturing = false
    private(set) var cameraAuthorized: Bool?
    private(set) var flashToggle = false
    var errorMessage: String?
    /// Short confirmation after a capture ("Photo saved").
    private(set) var lastSavedKind: PhotoKind?

    @ObservationIgnored let camera = CameraService()
    @ObservationIgnored private let openedAt = Date()

    init(task: WorkerTask, kind: PhotoKind) {
        self.task = task
        self.kind = kind
    }

    func appear(location: LocationService) async {
        location.start()
        location.simulateArrival(at: task.coordinate)
        let granted = await camera.requestAccess()
        cameraAuthorized = granted
        if granted { camera.start() }
    }

    func disappear(location: LocationService) {
        camera.stop()
        location.stop()
    }

    // MARK: - GPS state shown in the overlay

    enum GPSState: Equatable {
        case denied
        case searching(secondsLeft: Int)
        case good(accuracy: Double)
        case weak(accuracy: Double)
    }

    func gpsState(location: LocationService, now: Date = Date()) -> GPSState {
        if location.isDenied { return .denied }
        let waited = now.timeIntervalSince(openedAt)
        guard let loc = location.location, abs(loc.timestamp.timeIntervalSince(now)) < 60 else {
            return .searching(secondsLeft: max(0, Int(LocationService.fixTimeout - waited)))
        }
        if loc.horizontalAccuracy <= LocationService.goodAccuracy { return .good(accuracy: loc.horizontalAccuracy) }
        if waited < LocationService.fixTimeout {
            return .searching(secondsLeft: max(0, Int(LocationService.fixTimeout - waited)))
        }
        return .weak(accuracy: loc.horizontalAccuracy)
    }

    /// Capture is allowed with a good fix, or with any fix once the 20 s timeout passed (with a warning).
    func canCapture(location: LocationService, now: Date = Date()) -> Bool {
        guard cameraAuthorized == true, !isCapturing, location.location != nil else { return false }
        switch gpsState(location: location, now: now) {
        case .good, .weak: return true
        case .denied, .searching: return false
        }
    }

    func distanceToTask(location: LocationService) -> Double? {
        guard let loc = location.location else { return nil }
        return Geo.distanceMeters(from: loc.coordinate, to: task.coordinate)
    }

    func isOutsideRadius(location: LocationService) -> Bool {
        guard let d = distanceToTask(location: location) else { return false }
        return d > Double(task.radiusMeters)
    }

    // MARK: - Capture

    func capture(location: LocationService, uploads: UploadManager) async {
        guard canCapture(location: location), let fix = location.location else { return }
        isCapturing = true
        errorMessage = nil
        defer { isCapturing = false }

        let capturedAt = Date()
        let clientPhotoId = UUID().uuidString.lowercased()
        let metadata = PhotoMetadata(
            kind: kind,
            capturedAt: capturedAt,
            latitude: fix.coordinate.latitude,
            longitude: fix.coordinate.longitude,
            horizontalAccuracy: max(0, fix.horizontalAccuracy),
            altitude: fix.verticalAccuracy >= 0 ? fix.altitude : nil,
            isSimulatedLocation: fix.isSimulatedBySoftware && !DemoMode.isActive,
            deviceModel: DeviceInfo.deviceModel,
            osVersion: DeviceInfo.osVersion,
            appVersion: DeviceInfo.appVersion,
            clientPhotoId: clientPhotoId)

        do {
            let raw: Data
            if let demo = DemoMode.photo(for: kind) { raw = demo } else { raw = try await camera.capture() }
            flashToggle.toggle()
            let processed = try await Task.detached(priority: .userInitiated) {
                try PhotoProcessor.process(raw, location: fix, capturedAt: capturedAt)
            }.value
            try uploads.enqueuePhoto(taskId: task.id, jpeg: processed, metadata: metadata)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            lastSavedKind = kind
            UIAccessibility.post(notification: .announcement, argument: L10n.tr("camera.saved"))
            // After the BEFORE photo, the next ones are AFTER photos.
            if kind == .before { kind = .after }
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            errorMessage = L10n.tr("camera.error.capture")
        }
    }
}

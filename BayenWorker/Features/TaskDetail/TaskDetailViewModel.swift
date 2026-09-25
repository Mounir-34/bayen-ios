import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class TaskDetailViewModel {
    let taskId: String
    private(set) var detail: TaskDetail?
    private(set) var isLoading = false
    private(set) var isStarting = false
    var errorMessage: String?
    var infoMessage: String?
    /// Kind to open the camera with; non-nil presents the camera.
    var cameraKind: PhotoKind?

    init(taskId: String) { self.taskId = taskId }

    func load(store: TaskStore, api: APIClient) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let detail = try await api.task(id: taskId)
            self.detail = detail
            store.update(detail.task)
            store.setRejectionNote(detail.rejectionNote, for: taskId)
        } catch {
            // Offline: the cached task from the list is enough to work.
            if store.task(id: taskId) == nil { errorMessage = APIError.from(error).localizedMessage }
        }
    }

    /// Server photos that can still be part of the next submission.
    var unsubmittedRemotePhotos: [RemotePhoto] {
        (detail?.photos ?? []).filter { $0.submissionId == nil }
    }

    enum PrimaryAction: Equatable {
        case start(isRestart: Bool)
        case takePhotos
        case markDone
        case waitingReview(queued: Bool)
        case approved
        case unavailable
    }

    func primaryAction(task: WorkerTask, status: TaskStatus, localPhotos: [PendingPhoto], hasPendingSubmission: Bool) -> PrimaryAction {
        if hasPendingSubmission { return .waitingReview(queued: true) }
        switch status {
        case .assigned: return .start(isRestart: false)
        case .rejected: return .start(isRestart: true)
        case .inProgress:
            let requirement = PhotoRequirement(task: task, localPhotos: localPhotos, remotePhotos: unsubmittedRemotePhotos)
            return requirement.isMet ? .markDone : .takePhotos
        case .submitted: return .waitingReview(queued: false)
        case .approved: return .approved
        case .cancelled, .unknown: return .unavailable
        }
    }

    /// Starts the task with the current location. Offline → queued, and the worker can go on taking photos.
    func start(task: WorkerTask, store: TaskStore, api: APIClient, uploads: UploadManager, location: LocationService,
               network: NetworkMonitor) async {
        guard location.isAuthorized else {
            errorMessage = L10n.tr("location.denied.message")
            return
        }
        isStarting = true
        errorMessage = nil
        defer { isStarting = false }

        guard let fix = await location.waitForFix(timeout: 12) else {
            errorMessage = L10n.tr("location.noFix")
            return
        }
        let payload = LocationPayload(fix)
        let localPhotos = uploads.photos(for: task.id)

        if !network.isConnected {
            queueStart(task: task, payload: payload, store: store, uploads: uploads)
        } else {
            do {
                let updated = try await api.startTask(id: task.id, location: payload)
                store.update(updated)
            } catch {
                let e = APIError.from(error)
                if e.isRetryable {
                    queueStart(task: task, payload: payload, store: store, uploads: uploads)
                } else if e.code == "INVALID_TRANSITION", e.transitionFrom == TaskStatus.inProgress.rawValue {
                    var t = task
                    t.status = .inProgress
                    store.update(t)
                } else {
                    errorMessage = e.localizedMessage
                    return
                }
            }
        }

        // Straight to the camera; BEFORE photo first when required.
        let hasBefore = localPhotos.contains { $0.kind == .before } || unsubmittedRemotePhotos.contains { $0.kind == .before }
        cameraKind = task.requireBeforePhoto && !hasBefore ? .before : .after
    }

    private func queueStart(task: WorkerTask, payload: LocationPayload, store: TaskStore, uploads: UploadManager) {
        uploads.queueStart(taskId: task.id, location: payload)
        var t = task
        t.status = .inProgress
        t.startedAt = Date()
        store.update(t)
        infoMessage = L10n.tr("task.start.queued")
    }
}

/// Minimum-photo rules of a task (`minPhotos`, `requireBeforePhoto`).
struct PhotoRequirement {
    let total: Int
    let minimum: Int
    let beforeRequired: Bool
    let hasBefore: Bool
    let hasAfter: Bool

    init(task: WorkerTask, localPhotos: [PendingPhoto], remotePhotos: [RemotePhoto]) {
        let kinds = localPhotos.map(\.kind) + remotePhotos.map(\.kind)
        total = kinds.count
        minimum = max(1, task.minPhotos)
        beforeRequired = task.requireBeforePhoto
        hasBefore = kinds.contains(.before)
        hasAfter = kinds.contains(.after)
    }

    var hasEnough: Bool { total >= minimum }
    var isMet: Bool { hasEnough && hasAfter && (!beforeRequired || hasBefore) }
}

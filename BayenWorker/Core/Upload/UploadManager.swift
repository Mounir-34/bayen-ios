import Foundation
import Observation
import SwiftData

/// Offline-first queue for everything the worker produces in the field:
/// task starts, photos (upload / delete) and submissions.
///
/// Rules
/// * Everything is persisted in SwiftData (+ the JPEG on disk) **before** any network call.
/// * Each item is retried with exponential backoff (`RetryPolicy`); network changes (`NWPathMonitor`)
///   and app foregrounding trigger an immediate pass.
/// * Uploads are idempotent: the same `clientPhotoId` is sent on every retry and the server returns the
///   original photo for duplicates.
/// * A task's photos are uploaded only after its queued start; a submission is sent only when all of its
///   photos are uploaded.
@MainActor
@Observable
final class UploadManager {
    // MARK: Observable summary for the UI

    /// Photos not yet on the server (waiting, uploading or failed).
    private(set) var pendingPhotoCount = 0
    /// Photos that need the worker's attention (non-retryable error).
    private(set) var blockedPhotoCount = 0
    private(set) var uploadingIds: Set<String> = []
    private(set) var pendingSubmissionTaskIds: Set<String> = []
    private(set) var pendingStartTaskIds: Set<String> = []
    /// Flags returned by the server for submissions sent from the queue (task id → flags).
    private(set) var lastSubmissionFlags: [String: [String]] = [:]

    /// Called after a queued submission reached the server.
    @ObservationIgnored var onTaskSubmitted: ((String) -> Void)?

    // MARK: Dependencies

    @ObservationIgnored let context: ModelContext
    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let transport: PhotoUploadTransport
    @ObservationIgnored private let network: NetworkStatusProviding
    @ObservationIgnored let files: PhotoFileStore
    @ObservationIgnored private let retryPolicy: RetryPolicy
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored var random: () -> Double = { Double.random(in: 0...1) }
    @ObservationIgnored var maxConcurrentUploads = 2
    /// Disabled in tests, which drive `processQueue()` manually.
    @ObservationIgnored var schedulesRetries = true

    @ObservationIgnored private var isProcessing = false
    @ObservationIgnored private var needsAnotherPass = false
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var inFlight: [String: Task<Void, Never>] = [:]

    init(container: ModelContainer,
         api: APIClient,
         transport: PhotoUploadTransport,
         network: NetworkStatusProviding,
         files: PhotoFileStore = .default,
         retryPolicy: RetryPolicy = RetryPolicy()) {
        self.context = container.mainContext
        self.api = api
        self.transport = transport
        self.network = network
        self.files = files
        self.retryPolicy = retryPolicy
        recoverInterruptedUploads()
        refreshSummary()
    }

    // MARK: - Enqueue

    /// Saves the photo file and its metadata, then schedules the upload.
    @discardableResult
    func enqueuePhoto(taskId: String, jpeg: PhotoProcessor.Result, metadata: PhotoMetadata) throws -> PendingPhoto {
        let fileName = try files.save(jpeg.data, clientPhotoId: metadata.clientPhotoId)
        let photo = PendingPhoto(clientPhotoId: metadata.clientPhotoId, taskId: taskId, kind: metadata.kind, metadata: metadata,
                                 fileName: fileName, width: jpeg.width, height: jpeg.height)
        context.insert(photo)
        do {
            try context.save()
        } catch {
            files.delete(fileName)
            throw error
        }
        refreshSummary()
        kick()
        return photo
    }

    func queueStart(taskId: String, location: LocationPayload) {
        if fetchStart(taskId) == nil {
            context.insert(PendingTaskStart(taskId: taskId, location: location, createdAt: now()))
            try? context.save()
        }
        refreshSummary()
        kick()
    }

    /// Queues the submission of all current photos of the task.
    func queueSubmission(taskId: String, note: String?, location: LocationPayload, extraRemotePhotoIds: [String] = []) throws {
        let ids = photos(for: taskId).map(\.clientPhotoId)
        if let existing = fetchSubmission(taskId) { context.delete(existing) }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        context.insert(PendingSubmission(taskId: taskId, clientPhotoIds: ids, extraRemotePhotoIds: extraRemotePhotoIds,
                                         note: (trimmed?.isEmpty ?? true) ? nil : trimmed, location: location, createdAt: now()))
        try context.save()
        refreshSummary()
        kick()
    }

    func delete(_ photo: PendingPhoto) {
        if photo.remotePhotoId == nil, !uploadingIds.contains(photo.clientPhotoId) {
            removeLocal(photo)
        } else {
            photo.markedForDeletion = true
            try? context.save()
        }
        refreshSummary()
        kick()
    }

    /// Manual retry of a blocked photo or submission.
    func retry(taskId: String) {
        for photo in photos(for: taskId) where photo.status == .failed {
            photo.isPermanentFailure = false
            photo.nextAttemptAt = nil
            photo.status = .waiting
        }
        if let submission = fetchSubmission(taskId) {
            submission.isPermanentFailure = false
            submission.nextAttemptAt = nil
        }
        try? context.save()
        refreshSummary()
        kick()
    }

    /// Manual retry of everything that is blocked or backing off (Profile → "Retry now").
    func retryAll() {
        for photo in (try? context.fetch(FetchDescriptor<PendingPhoto>())) ?? [] where photo.status != .uploaded {
            photo.isPermanentFailure = false
            photo.nextAttemptAt = nil
            if photo.status == .failed { photo.status = .waiting }
        }
        for submission in (try? context.fetch(FetchDescriptor<PendingSubmission>())) ?? [] {
            submission.isPermanentFailure = false
            submission.nextAttemptAt = nil
        }
        try? context.save()
        refreshSummary()
        kick()
    }

    /// Whether this task has a photo that needs a manual retry.
    func hasBlockedPhotos(taskId: String) -> Bool {
        photos(for: taskId).contains { $0.isPermanentFailure }
    }

    func discardSubmission(taskId: String) {
        if let submission = fetchSubmission(taskId) {
            context.delete(submission)
            try? context.save()
        }
        refreshSummary()
    }

    // MARK: - Queries

    /// Client ids of every photo of the task stored on the device, including ones waiting to be deleted on the server.
    func storedClientPhotoIds(for taskId: String) -> Set<String> {
        let descriptor = FetchDescriptor<PendingPhoto>(predicate: #Predicate { $0.taskId == taskId })
        return Set(((try? context.fetch(descriptor)) ?? []).map(\.clientPhotoId))
    }

    func photos(for taskId: String) -> [PendingPhoto] {
        let descriptor = FetchDescriptor<PendingPhoto>(
            predicate: #Predicate { $0.taskId == taskId && !$0.markedForDeletion },
            sortBy: [SortDescriptor(\.capturedAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func pendingSubmission(for taskId: String) -> PendingSubmission? { fetchSubmission(taskId) }
    func hasPendingStart(_ taskId: String) -> Bool { pendingStartTaskIds.contains(taskId) }

    // MARK: - Processing

    /// Starts a queue pass in the background.
    func kick() {
        Task { await processQueue() }
    }

    /// Runs passes until nothing new arrived meanwhile. Safe to call concurrently (calls are coalesced).
    func processQueue() async {
        if isProcessing {
            UploadLog.info("processQueue: already running, coalesced")
            needsAnotherPass = true
            return
        }
        isProcessing = true
        repeat {
            needsAnotherPass = false
            await runPass()
        } while needsAnotherPass
        isProcessing = false
        refreshSummary()
        scheduleWakeUp()
    }

    private func runPass() async {
        guard network.isConnected, api.hasSession else {
            UploadLog.info("pass skipped: connected=\(network.isConnected) hasSession=\(api.hasSession)")
            return
        }
        UploadLog.info("pass: transport=\(type(of: transport)) pendingStarts=\(pendingStartTaskIds.sorted()) uploading=\(uploadingIds.count)")
        await processStarts()
        await processDeletions()
        processUploads()
        await processSubmissions()
    }

    private func processStarts() async {
        let starts = ((try? context.fetch(FetchDescriptor<PendingTaskStart>(sortBy: [SortDescriptor(\.createdAt)]))) ?? [])
            .filter { isDue($0.nextAttemptAt) }
        for start in starts {
            let location = LocationPayload(latitude: start.latitude, longitude: start.longitude, accuracy: start.accuracy)
            do {
                _ = try await api.startTask(id: start.taskId, location: location)
                context.delete(start)
                UploadLog.info("queued start sent for task \(start.taskId)")
            } catch {
                let e = APIError.from(error)
                UploadLog.info("queued start for task \(start.taskId) failed: \(e)")
                if e.code == "INVALID_TRANSITION", e.transitionFrom == TaskStatus.inProgress.rawValue {
                    context.delete(start) // already started (e.g. response was lost)
                } else if e == .unauthorized {
                    break
                } else if e.isRetryable {
                    start.attemptCount += 1
                    start.nextAttemptAt = now().addingTimeInterval(retryPolicy.delay(afterFailures: start.attemptCount, random: random))
                } else {
                    context.delete(start) // the server state wins; photo uploads will surface the problem
                }
            }
            try? context.save()
        }
        refreshSummary()
    }

    private func processDeletions() async {
        let descriptor = FetchDescriptor<PendingPhoto>(predicate: #Predicate { $0.markedForDeletion })
        for photo in (try? context.fetch(descriptor)) ?? [] where !uploadingIds.contains(photo.clientPhotoId) && isDue(photo.nextAttemptAt) {
            guard let remoteId = photo.remotePhotoId else {
                removeLocal(photo)
                continue
            }
            do {
                try await api.deletePhoto(taskId: photo.taskId, photoId: remoteId)
                removeLocal(photo)
            } catch {
                let e = APIError.from(error)
                if e.code == "NOT_FOUND" || e.code == "PHOTO_ALREADY_SUBMITTED" {
                    removeLocal(photo)
                } else if e.isRetryable {
                    photo.attemptCount += 1
                    photo.nextAttemptAt = now().addingTimeInterval(retryPolicy.delay(afterFailures: photo.attemptCount, random: random))
                    try? context.save()
                }
            }
        }
    }

    /// Starts uploads (up to `maxConcurrentUploads` at a time) without waiting for them: with a background
    /// URLSession a transfer can legitimately wait hours for coverage, and that must not block the rest of
    /// the queue. Each finished upload triggers a new pass (next photo, then the submission).
    private func processUploads() {
        // Filtered in Swift, not with a #Predicate: the compound predicate on statusRaw/Bool columns
        // returned no rows on device, so queued photos were never picked up.
        let descriptor = FetchDescriptor<PendingPhoto>(sortBy: [SortDescriptor(\.capturedAt)])
        let blockedTasks = pendingStartTaskIds
        let stored: [PendingPhoto]
        do { stored = try context.fetch(descriptor) } catch {
            UploadLog.info("photo fetch failed: \(error)")
            stored = []
        }
        for p in stored where p.status == .uploaded && p.remotePhotoId == nil {
            p.status = .waiting // inconsistent row: "uploaded" without a server id → upload again (idempotent)
        }
        let all = stored.filter { $0.status != .uploaded && !$0.markedForDeletion && !$0.isPermanentFailure }
        if all.isEmpty && !stored.isEmpty {
            let states = stored.map { "\($0.clientPhotoId.prefix(8)) status=\($0.statusRaw) remote=\($0.remotePhotoId ?? "nil") deleted=\($0.markedForDeletion) blocked=\($0.isPermanentFailure) err=\($0.lastErrorCode ?? "-")" }
            UploadLog.info("no uploadable photos; stored rows:\n  " + states.joined(separator: "\n  "))
        }
        let eligible = all
            .filter { isDue($0.nextAttemptAt) && !uploadingIds.contains($0.clientPhotoId) && !blockedTasks.contains($0.taskId) }
            .map(\.clientPhotoId)
        if !all.isEmpty {
            let details: [String] = all.map { (p: PendingPhoto) -> String in
                let next = p.nextAttemptAt?.description ?? "-"
                let err = p.lastErrorCode ?? "-"
                let blocked = blockedTasks.contains(p.taskId)
                return "\(p.clientPhotoId.prefix(8)) task=\(p.taskId) status=\(p.statusRaw) next=\(next) err=\(err) startBlocked=\(blocked)"
            }
            UploadLog.info("photos not uploaded: \(all.count), eligible now: \(eligible.count)\n  " + details.joined(separator: "\n  "))
        }

        for id in eligible where uploadingIds.count < maxConcurrentUploads {
            uploadingIds.insert(id)
            inFlight[id] = Task { [weak self] in
                guard let self else { return }
                await self.upload(clientPhotoId: id)
                self.inFlight[id] = nil
                await self.processQueue()
            }
        }
    }

    /// Test/diagnostic helper: returns when no upload is running and no pass is in progress.
    func waitUntilIdle() async {
        while true {
            let tasks = Array(inFlight.values)
            if tasks.isEmpty && !isProcessing { return }
            for task in tasks { await task.value }
            if tasks.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
    }

    private func upload(clientPhotoId: String) async {
        defer { uploadingIds.remove(clientPhotoId) }
        guard let photo = fetchPhoto(clientPhotoId), photo.status != .uploaded, !photo.markedForDeletion else { return }
        guard files.exists(photo.fileName) else {
            UploadLog.info("\(clientPhotoId.prefix(8)): file missing at \(files.url(for: photo.fileName).path)")
            photo.status = .failed
            photo.isPermanentFailure = true
            photo.lastErrorCode = "FILE_MISSING"
            try? context.save()
            return
        }

        photo.status = .uploading
        photo.attemptCount += 1
        try? context.save()

        let job = UploadJob(taskId: photo.taskId, clientPhotoId: clientPhotoId, fileURL: files.url(for: photo.fileName),
                            metadata: photo.metadata)
        UploadLog.info("\(clientPhotoId.prefix(8)): uploading to task \(photo.taskId) (attempt \(photo.attemptCount))")
        do {
            let remote = try await transport.upload(job)
            UploadLog.info("\(clientPhotoId.prefix(8)): uploaded → \(remote.id)")
            photo.remotePhotoId = remote.id
            photo.status = .uploaded
            photo.lastErrorCode = nil
            photo.nextAttemptAt = nil
        } catch {
            let e = APIError.from(error)
            UploadLog.info("\(clientPhotoId.prefix(8)): upload failed: \(e) (retryable=\(e.isRetryable))")
            photo.lastErrorCode = e.code ?? (e.isOffline ? "OFFLINE" : "NETWORK")
            if e == .unauthorized {
                // Not the photo's fault: wait for the next login without burning attempts.
                photo.status = .waiting
                photo.attemptCount = max(0, photo.attemptCount - 1)
            } else if e.isRetryable {
                photo.status = .failed
                photo.nextAttemptAt = now().addingTimeInterval(retryPolicy.delay(afterFailures: photo.attemptCount, random: random))
            } else {
                photo.status = .failed
                photo.isPermanentFailure = true
            }
        }
        try? context.save()
        refreshSummary()
    }

    private func processSubmissions() async {
        let submissions = ((try? context.fetch(FetchDescriptor<PendingSubmission>(sortBy: [SortDescriptor(\.createdAt)]))) ?? [])
            .filter { !$0.isPermanentFailure && isDue($0.nextAttemptAt) }

        for submission in submissions {
            let photos = submission.clientPhotoIds.compactMap(fetchPhoto).filter { !$0.markedForDeletion }
            // Wait until every photo of this submission is on the server.
            guard photos.allSatisfy({ $0.status == .uploaded && $0.remotePhotoId != nil }) else {
                let states = photos.map { "\($0.clientPhotoId.prefix(8))=\($0.statusRaw)" }.joined(separator: ", ")
                UploadLog.info("submission for task \(submission.taskId) waits for photos: \(states)")
                continue
            }
            let photoIds = Array(Set(photos.compactMap(\.remotePhotoId) + submission.extraRemotePhotoIds)).sorted()
            guard !photoIds.isEmpty else {
                submission.isPermanentFailure = true
                submission.lastErrorCode = "NO_PHOTOS"
                try? context.save()
                continue
            }
            let request = SubmitRequest(photoIds: photoIds, note: submission.note, latitude: submission.latitude,
                                        longitude: submission.longitude, accuracy: submission.accuracy)
            let taskId = submission.taskId
            do {
                let response = try await api.submit(taskId: taskId, request: request)
                complete(submission, photos: photos, flags: response.flags)
            } catch {
                let e = APIError.from(error)
                if e.code == "INVALID_TRANSITION", e.transitionFrom == TaskStatus.submitted.rawValue {
                    complete(submission, photos: photos, flags: []) // an earlier attempt succeeded, only the response was lost
                } else if e == .unauthorized {
                    break
                } else if e.isRetryable {
                    submission.attemptCount += 1
                    submission.lastErrorCode = e.code ?? "NETWORK"
                    submission.nextAttemptAt = now().addingTimeInterval(
                        retryPolicy.delay(afterFailures: submission.attemptCount, random: random))
                    try? context.save()
                } else {
                    submission.isPermanentFailure = true
                    submission.lastErrorCode = e.code ?? "ERROR"
                    try? context.save()
                }
            }
        }
    }

    private func complete(_ submission: PendingSubmission, photos: [PendingPhoto], flags: [String]) {
        let taskId = submission.taskId
        // The server now holds the proof; free the device storage.
        for photo in photos { removeLocal(photo, save: false) }
        context.delete(submission)
        try? context.save()
        lastSubmissionFlags[taskId] = flags
        refreshSummary()
        onTaskSubmitted?(taskId)
    }

    // MARK: - Helpers

    private func isDue(_ date: Date?) -> Bool {
        guard let date else { return true }
        return date <= now()
    }

    private func removeLocal(_ photo: PendingPhoto, save: Bool = true) {
        files.delete(photo.fileName)
        context.delete(photo)
        if save { try? context.save() }
    }

    private func fetchPhoto(_ clientPhotoId: String) -> PendingPhoto? {
        var d = FetchDescriptor<PendingPhoto>(predicate: #Predicate { $0.clientPhotoId == clientPhotoId })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    private func fetchSubmission(_ taskId: String) -> PendingSubmission? {
        var d = FetchDescriptor<PendingSubmission>(predicate: #Predicate { $0.taskId == taskId })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    private func fetchStart(_ taskId: String) -> PendingTaskStart? {
        var d = FetchDescriptor<PendingTaskStart>(predicate: #Predicate { $0.taskId == taskId })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    /// After a crash/kill, rows left in "uploading" go back to "waiting" (the background transport
    /// re-attaches to transfers that are still running).
    private func recoverInterruptedUploads() {
        for photo in (try? context.fetch(FetchDescriptor<PendingPhoto>())) ?? [] where photo.status == .uploading {
            photo.status = .waiting
        }
        try? context.save()
    }

    func refreshSummary() {
        let all = (try? context.fetch(FetchDescriptor<PendingPhoto>())) ?? []
        let visible = all.filter { !$0.markedForDeletion }
        pendingPhotoCount = visible.filter { $0.status != .uploaded }.count
        blockedPhotoCount = visible.filter { $0.isPermanentFailure }.count
        pendingSubmissionTaskIds = Set(((try? context.fetch(FetchDescriptor<PendingSubmission>())) ?? []).map(\.taskId))
        pendingStartTaskIds = Set(((try? context.fetch(FetchDescriptor<PendingTaskStart>())) ?? []).map(\.taskId))
    }

    private func scheduleWakeUp() {
        wakeTask?.cancel()
        wakeTask = nil
        guard schedulesRetries else { return }
        let photoDates = ((try? context.fetch(FetchDescriptor<PendingPhoto>())) ?? [])
            .filter { !$0.isPermanentFailure && $0.status != .uploaded }.compactMap(\.nextAttemptAt)
        let submissionDates = ((try? context.fetch(FetchDescriptor<PendingSubmission>())) ?? [])
            .filter { !$0.isPermanentFailure }.compactMap(\.nextAttemptAt)
        let startDates = ((try? context.fetch(FetchDescriptor<PendingTaskStart>())) ?? []).compactMap(\.nextAttemptAt)
        guard let next = (photoDates + submissionDates + startDates).min() else { return }
        let delay = max(0.5, next.timeIntervalSince(now()))
        wakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.processQueue()
        }
    }
}

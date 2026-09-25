import SwiftData
import XCTest
@testable import BayenWorker

@MainActor
final class UploadQueueTests: XCTestCase {
    private let taskId = "6f1c1d2e-0000-4000-8000-000000000201" // mock task #1 (ASSIGNED)
    private var clock = Date(timeIntervalSince1970: 1_790_000_000)
    private var api: MockAPIClient!
    private var network: StaticNetworkStatus!
    private var container: ModelContainer!

    override func setUp() async throws {
        clock = Date(timeIntervalSince1970: 1_790_000_000)
        api = MockAPIClient()
        _ = try await api.login(phone: "0600000002", password: MockAPIClient.password)
        _ = try await api.startTask(id: taskId, location: LocationPayload(latitude: 33.6006, longitude: -7.5329, accuracy: 8))
        network = StaticNetworkStatus(isConnected: true)
        container = try QueueStore.makeContainer(inMemory: true)
    }

    private func makeManager(transport: PhotoUploadTransport) -> UploadManager {
        let manager = UploadManager(container: container, api: api, transport: transport, network: network,
                                    files: PhotoFileStore(directory: temporaryDirectory()))
        manager.schedulesRetries = false
        manager.random = { 0.5 } // no jitter
        manager.now = { [unowned self] in self.clock }
        return manager
    }

    private func enqueue(_ manager: UploadManager, kind: PhotoKind = .after) throws -> PendingPhoto {
        let jpeg = try PhotoProcessor.process(SyntheticPhoto.make(size: CGSize(width: 400, height: 300)), location: nil, capturedAt: clock)
        let metadata = PhotoMetadata(kind: kind, capturedAt: clock, latitude: 33.6006, longitude: -7.5329, horizontalAccuracy: 8,
                                     altitude: nil, isSimulatedLocation: false, deviceModel: "Test", osVersion: "iOS 17",
                                     appVersion: "1.0", clientPhotoId: UUID().uuidString.lowercased())
        return try manager.enqueuePhoto(taskId: taskId, jpeg: jpeg, metadata: metadata)
    }

    private func run(_ manager: UploadManager) async {
        await manager.processQueue()
        await manager.waitUntilIdle()
    }

    func testPhotoIsPersistedBeforeAnyUpload() async throws {
        network.isConnected = false
        let manager = makeManager(transport: DirectUploadTransport(api: api))
        let photo = try enqueue(manager)

        XCTAssertTrue(manager.files.exists(photo.fileName))
        let stored = try container.mainContext.fetch(FetchDescriptor<PendingPhoto>())
        XCTAssertEqual(stored.map(\.clientPhotoId), [photo.clientPhotoId])
        XCTAssertEqual(manager.pendingPhotoCount, 1)
    }

    func testRetriesWithExponentialBackoffThenSucceeds() async throws {
        let transport = FlakyTransport(base: DirectUploadTransport(api: api), failures: 2)
        let manager = makeManager(transport: transport)
        let photo = try enqueue(manager)
        await run(manager)

        // 1st failure → retry in 2 s
        XCTAssertEqual(photo.status, .failed)
        XCTAssertEqual(photo.attemptCount, 1)
        XCTAssertEqual(photo.nextAttemptAt, clock.addingTimeInterval(2))

        // Not due yet → nothing happens
        await run(manager)
        XCTAssertEqual(transport.jobs.count, 1)

        // 2nd failure → retry in 4 s
        clock.addTimeInterval(2)
        await run(manager)
        XCTAssertEqual(photo.attemptCount, 2)
        XCTAssertEqual(photo.nextAttemptAt, clock.addingTimeInterval(4))

        clock.addTimeInterval(4)
        await run(manager)
        XCTAssertEqual(photo.status, .uploaded)
        XCTAssertNotNil(photo.remotePhotoId)
        XCTAssertEqual(manager.pendingPhotoCount, 0)

        // Idempotency: every attempt used the same clientPhotoId.
        XCTAssertEqual(Set(transport.jobs.map(\.clientPhotoId)), [photo.clientPhotoId])
        XCTAssertEqual(transport.jobs.count, 3)
    }

    func testServerDeduplicatesRetriedUploads() async throws {
        let meta = PhotoMetadata(kind: .after, capturedAt: clock, latitude: 33.6, longitude: -7.53, horizontalAccuracy: 5,
                                 altitude: nil, isSimulatedLocation: false, deviceModel: "T", osVersion: "iOS", appVersion: "1",
                                 clientPhotoId: "same-id")
        let url = temporaryDirectory().appendingPathComponent("x.jpg")
        try SyntheticPhoto.make(size: CGSize(width: 10, height: 10)).write(to: url)
        let first = try await api.uploadPhoto(taskId: taskId, fileURL: url, metadata: meta)
        let second = try await api.uploadPhoto(taskId: taskId, fileURL: url, metadata: meta) // e.g. response was lost
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(api.remotePhotoCount(), 1)
    }

    func testPermanentErrorIsNotRetriedUntilManualRetry() async throws {
        let transport = FlakyTransport(base: DirectUploadTransport(api: api), failures: 1,
                                       error: .server(status: 409, code: "TASK_NOT_IN_PROGRESS", message: ""))
        let manager = makeManager(transport: transport)
        let photo = try enqueue(manager)
        await run(manager)
        XCTAssertTrue(photo.isPermanentFailure)
        XCTAssertEqual(manager.blockedPhotoCount, 1)

        clock.addTimeInterval(3600)
        await run(manager)
        XCTAssertEqual(transport.jobs.count, 1, "non-retryable errors wait for the worker")

        manager.retry(taskId: taskId)
        await run(manager)
        XCTAssertEqual(photo.status, .uploaded)
    }

    func testNothingIsSentWhileOffline() async throws {
        network.isConnected = false
        let transport = FlakyTransport(base: DirectUploadTransport(api: api), failures: 0)
        let manager = makeManager(transport: transport)
        let photo = try enqueue(manager)
        await run(manager)
        XCTAssertEqual(transport.jobs.count, 0)
        XCTAssertEqual(photo.status, .waiting)

        network.isConnected = true // NWPathMonitor would call kick() here
        await run(manager)
        XCTAssertEqual(photo.status, .uploaded)
    }

    func testSubmissionIsSentOnlyAfterAllPhotosAreUploaded() async throws {
        let transport = FlakyTransport(base: DirectUploadTransport(api: api), failures: 1)
        let manager = makeManager(transport: transport)
        manager.maxConcurrentUploads = 1
        var submitted: [String] = []
        manager.onTaskSubmitted = { submitted.append($0) }

        network.isConnected = false
        let before = try enqueue(manager, kind: .before)
        let after = try enqueue(manager, kind: .after)
        try manager.queueSubmission(taskId: taskId, note: "  Lampe changée ", location: LocationPayload(latitude: 33.6, longitude: -7.53, accuracy: 9))
        XCTAssertEqual(manager.pendingSubmissionTaskIds, [taskId])

        network.isConnected = true
        await run(manager)
        // First upload failed → submission must still be waiting.
        XCTAssertTrue(submitted.isEmpty)
        XCTAssertEqual(api.taskSnapshot(taskId)?.status, .inProgress)
        XCTAssertNotNil(manager.pendingSubmission(for: taskId))

        clock.addTimeInterval(10)
        await run(manager)
        XCTAssertEqual(submitted, [taskId])
        XCTAssertEqual(api.taskSnapshot(taskId)?.status, .submitted)
        XCTAssertTrue(manager.pendingSubmissionTaskIds.isEmpty)
        // Local copies are freed once the server has the proof.
        XCTAssertFalse(manager.files.exists(before.fileName))
        XCTAssertFalse(manager.files.exists(after.fileName))
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<PendingPhoto>()), 0)
    }

    func testQueuedStartIsSentBeforePhotos() async throws {
        let assignedTask = "6f1c1d2e-0000-4000-8000-000000000202"
        let manager = makeManager(transport: DirectUploadTransport(api: api))
        network.isConnected = false
        manager.queueStart(taskId: assignedTask, location: LocationPayload(latitude: 33.6, longitude: -7.53, accuracy: 10))
        let jpeg = try PhotoProcessor.process(SyntheticPhoto.make(size: CGSize(width: 100, height: 100)), location: nil, capturedAt: clock)
        let photo = try manager.enqueuePhoto(taskId: assignedTask, jpeg: jpeg, metadata: PhotoMetadata(
            kind: .before, capturedAt: clock, latitude: 33.6, longitude: -7.53, horizontalAccuracy: 10, altitude: nil,
            isSimulatedLocation: false, deviceModel: "T", osVersion: "iOS", appVersion: "1", clientPhotoId: "p-start"))

        network.isConnected = true
        await run(manager)
        XCTAssertEqual(api.taskSnapshot(assignedTask)?.status, .inProgress)
        XCTAssertEqual(photo.status, .uploaded, "without the start first the server would answer TASK_NOT_IN_PROGRESS")
        XCTAssertFalse(manager.hasPendingStart(assignedTask))
    }

    func testDeletingAnUploadedPhotoRemovesItOnTheServer() async throws {
        let manager = makeManager(transport: DirectUploadTransport(api: api))
        let photo = try enqueue(manager)
        await run(manager)
        XCTAssertEqual(api.remotePhotoCount(), 1)

        manager.delete(photo)
        await run(manager)
        XCTAssertEqual(api.remotePhotoCount(), 0)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<PendingPhoto>()), 0)
    }

    func testRetryPolicyIsExponentialAndCapped() async {
        let policy = RetryPolicy(baseDelay: 2, multiplier: 2, maxDelay: 300, jitter: 0.2)
        XCTAssertEqual(policy.delay(afterFailures: 1, random: { 0.5 }), 2)
        XCTAssertEqual(policy.delay(afterFailures: 2, random: { 0.5 }), 4)
        XCTAssertEqual(policy.delay(afterFailures: 5, random: { 0.5 }), 32)
        XCTAssertEqual(policy.delay(afterFailures: 20, random: { 0.5 }), 300)
        XCTAssertEqual(policy.delay(afterFailures: 1, random: { 0 }), 1.6, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(afterFailures: 1, random: { 1 }), 2.4, accuracy: 0.0001)
    }
}

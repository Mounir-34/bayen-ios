import Foundation
import Observation

/// The worker's tasks, shared by the list, the map and the detail screens.
/// The last successful list is cached on disk so the app is usable without signal.
@MainActor
@Observable
final class TaskStore {
    private(set) var tasks: [WorkerTask] = []
    /// Admin's rejection reason per rejected task (only returned by the detail endpoint).
    private(set) var rejectionNotes: [String: String] = [:]
    private(set) var isLoading = false
    private(set) var lastError: APIError?
    private(set) var lastUpdated: Date?

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let uploads: UploadManager
    @ObservationIgnored private let cacheURL = PhotoFileStore.supportDirectory.appendingPathComponent("tasks-cache.json")

    private struct Cache: Codable {
        let tasks: [WorkerTask]
        let rejectionNotes: [String: String]
        let updatedAt: Date
    }

    init(api: APIClient, uploads: UploadManager) {
        self.api = api
        self.uploads = uploads
        loadCache()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await api.tasks(status: nil).filter { $0.status != .cancelled }
            tasks = fetched
            lastError = nil
            lastUpdated = Date()
            await loadRejectionNotes(for: fetched.filter { $0.status == .rejected })
            saveCache()
        } catch {
            lastError = APIError.from(error)
        }
    }

    func task(id: String) -> WorkerTask? { tasks.first { $0.id == id } }

    func update(_ task: WorkerTask) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
        saveCache()
    }

    func setRejectionNote(_ note: String?, for taskId: String) {
        rejectionNotes[taskId] = note
    }

    func markSubmitted(_ taskId: String) {
        guard var task = task(id: taskId) else { return }
        task.status = .submitted
        task.submittedAt = Date()
        update(task)
    }

    /// Status including work queued on this device (a queued start shows "in progress", a queued
    /// submission shows "waiting for review").
    func effectiveStatus(of task: WorkerTask) -> TaskStatus {
        if uploads.pendingSubmissionTaskIds.contains(task.id) { return .submitted }
        if uploads.pendingStartTaskIds.contains(task.id), task.status == .assigned || task.status == .rejected { return .inProgress }
        return task.status
    }

    func clear() {
        tasks = []
        rejectionNotes = [:]
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private func loadRejectionNotes(for rejected: [WorkerTask]) async {
        await withTaskGroup(of: (String, String?).self) { group in
            for task in rejected {
                let api = self.api
                group.addTask { (task.id, try? await api.task(id: task.id).rejectionNote) }
            }
            for await (id, note) in group {
                if let note { rejectionNotes[id] = note }
            }
        }
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONCoding.decoder.decode(Cache.self, from: data) else { return }
        tasks = cache.tasks
        rejectionNotes = cache.rejectionNotes
        lastUpdated = cache.updatedAt
    }

    private func saveCache() {
        let cache = Cache(tasks: tasks, rejectionNotes: rejectionNotes, updatedAt: lastUpdated ?? Date())
        if let data = try? JSONCoding.encoder.encode(cache) {
            try? data.write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}

/// Navigation for the Tasks tab.
enum TaskRoute: Hashable {
    case detail(taskId: String)
    case submit(taskId: String)
}

@MainActor
@Observable
final class TaskRouter {
    var path: [TaskRoute] = []
    func popToRoot() { path.removeAll() }
}

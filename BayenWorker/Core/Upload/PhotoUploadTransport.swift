import Foundation

/// One photo to upload.
struct UploadJob: Sendable, Equatable {
    let taskId: String
    let clientPhotoId: String
    let fileURL: URL
    let metadata: PhotoMetadata
}

/// How photo bytes reach the server. The queue logic (`UploadManager`) does not care which one is used.
protocol PhotoUploadTransport: AnyObject, Sendable {
    func upload(_ job: UploadJob) async throws -> RemotePhoto
}

/// Plain foreground upload through the `APIClient` (mock mode, tests).
final class DirectUploadTransport: PhotoUploadTransport, @unchecked Sendable {
    private let api: APIClient
    init(api: APIClient) { self.api = api }

    func upload(_ job: UploadJob) async throws -> RemotePhoto {
        try await api.uploadPhoto(taskId: job.taskId, fileURL: job.fileURL, metadata: job.metadata)
    }
}

/// Uploads through a **background** `URLSession`: transfers continue while the app is suspended or
/// even terminated by the system, and iOS relaunches the app to deliver the result.
///
/// Each task's `taskDescription` is the `clientPhotoId`. When the app is relaunched, calling `upload(_:)`
/// for a photo that already has a running background task *joins* that task instead of starting a new one,
/// and results that arrived while nobody was waiting are buffered — so no photo is sent twice
/// (and if it were, the server is idempotent on `clientPhotoId`).
final class BackgroundUploadTransport: NSObject, PhotoUploadTransport, URLSessionDataDelegate, @unchecked Sendable {
    static let sessionIdentifier = "ma.bayen.worker.photo-uploads"

    private let api: HTTPAPIClient
    private let bodyDirectory: URL
    private let lock = NSLock()
    private var session: URLSession!
    private var waiters: [String: [CheckedContinuation<RemotePhoto, Error>]] = [:]
    private var responseData: [Int: Data] = [:]
    private var bufferedResults: [String: Result<RemotePhoto, APIError>] = [:]
    private var usedTokens: [Int: String] = [:]
    private var backgroundCompletionHandler: (() -> Void)?

    init(api: HTTPAPIClient) {
        self.api = api
        self.bodyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("upload-bodies", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: bodyDirectory, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.timeoutIntervalForResource = 7 * 24 * 3600
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Stored from `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        locked { backgroundCompletionHandler = handler }
    }

    func upload(_ job: UploadJob) async throws -> RemotePhoto {
        let id = job.clientPhotoId
        // 1. A result may have arrived while the app was not waiting (relaunch).
        if let buffered = locked({ bufferedResults.removeValue(forKey: id) }) {
            return try buffered.get()
        }

        // 2. Join a transfer that is still running from a previous launch.
        let tasks = await session.allTasks
        let running = tasks.contains { task in
            guard task.taskDescription == id else { return false }
            return task.state == .running || task.state == .suspended
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RemotePhoto, Error>) in
            // The joined transfer may have finished between the check above and now.
            let (buffered, isFirstWaiter): (Result<RemotePhoto, APIError>?, Bool) = locked {
                if let buffered = bufferedResults.removeValue(forKey: id) { return (buffered, false) }
                waiters[id, default: []].append(continuation)
                return (nil, waiters[id]?.count == 1)
            }
            if let buffered {
                continuation.resume(with: buffered.mapError { $0 as Error })
                return
            }
            guard !running, isFirstWaiter else { return }
            do {
                try startTask(for: job)
            } catch {
                finish(clientPhotoId: id, with: .failure(APIError.from(error)))
            }
        }
    }

    /// Synchronous critical section (NSLock must not be held across `await`).
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func startTask(for job: UploadJob) throws {
        let multipart = MultipartFormData()
        let bodyURL = bodyDirectory.appendingPathComponent("\(job.clientPhotoId).body")
        try multipart.writePhotoBody(metadataJSON: try JSONCoding.encoder.encode(job.metadata), imageFile: job.fileURL, to: bodyURL)
        let request = try api.makePhotoUploadRequest(taskId: job.taskId, contentType: multipart.contentType)
        let task = session.uploadTask(with: request, fromFile: bodyURL)
        task.taskDescription = job.clientPhotoId
        let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
        locked { usedTokens[task.taskIdentifier] = token }
        task.resume()
    }

    private func finish(clientPhotoId: String, with result: Result<RemotePhoto, APIError>) {
        let continuations: [CheckedContinuation<RemotePhoto, Error>] = locked {
            let list = waiters.removeValue(forKey: clientPhotoId) ?? []
            if list.isEmpty { bufferedResults[clientPhotoId] = result }
            return list
        }
        try? FileManager.default.removeItem(at: bodyDirectory.appendingPathComponent("\(clientPhotoId).body"))
        for c in continuations { c.resume(with: result.mapError { $0 as Error }) }
    }

    // MARK: URLSession delegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        locked { responseData[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let clientPhotoId = task.taskDescription else { return }
        let (data, usedToken): (Data, String?) = locked {
            (responseData.removeValue(forKey: task.taskIdentifier) ?? Data(), usedTokens.removeValue(forKey: task.taskIdentifier))
        }

        if let error {
            finish(clientPhotoId: clientPhotoId, with: .failure(APIError.from(error)))
            return
        }
        guard let http = task.response as? HTTPURLResponse else {
            finish(clientPhotoId: clientPhotoId, with: .failure(.network(code: URLError.badServerResponse.rawValue)))
            return
        }
        if (200..<300).contains(http.statusCode) {
            do {
                let envelope = try JSONCoding.decoder.decode(PhotoEnvelope.self, from: data)
                finish(clientPhotoId: clientPhotoId, with: .success(envelope.photo))
            } catch {
                finish(clientPhotoId: clientPhotoId, with: .failure(.decoding(String(describing: error))))
            }
        } else if http.statusCode == 401 {
            // Token expired while the photo waited: refresh, then let the queue retry (idempotent).
            let api = self.api
            Task {
                let refreshed = (try? await api.refreshTokens(after: usedToken)) != nil
                self.finish(clientPhotoId: clientPhotoId,
                            with: .failure(refreshed ? .network(code: URLError.userAuthenticationRequired.rawValue) : .unauthorized))
            }
        } else {
            finish(clientPhotoId: clientPhotoId, with: .failure(APIError.fromResponse(status: http.statusCode, data: data)))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler: (() -> Void)? = locked {
            let h = backgroundCompletionHandler
            backgroundCompletionHandler = nil
            return h
        }
        DispatchQueue.main.async { handler?() }
    }
}

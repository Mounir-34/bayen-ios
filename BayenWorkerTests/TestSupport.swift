import Foundation
import SwiftData
import XCTest
@testable import BayenWorker

/// Programmable `HTTPTransport`: each request is answered by `handler`.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Int, Data)

    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let handler: Handler

    init(handler: @escaping Handler) { self.handler = handler }

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    func count(path: String) -> Int { requests.filter { $0.url?.path.hasSuffix(path) == true }.count }

    private func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        _requests.append(request)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        record(request)
        let (status, data) = try await handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return (data, response)
    }
}

enum Fixtures {
    static let baseURL = URL(string: "https://api.test/api/v1")!

    static func json(_ string: String) -> Data { Data(string.utf8) }

    static func error(_ code: String, message: String = "x") -> Data {
        json(#"{"error":{"code":"\#(code)","message":"\#(message)"}}"#)
    }

    static func task(id: String = "11111111-1111-4111-8111-111111111111", status: String = "ASSIGNED",
                     category: String = "LIGHTING", dueDate: String = "\"2026-09-30T08:00:00.000Z\"") -> String {
        """
        {"id":"\(id)","municipalityId":"22222222-2222-4222-8222-222222222222","title":"Fix lantern","description":"",
         "category":"\(category)","latitude":33.6,"longitude":-7.53,"radiusMeters":50,"address":null,"priority":"NORMAL",
         "dueDate":\(dueDate),"assigneeId":"33333333-3333-4333-8333-333333333333",
         "createdById":"44444444-4444-4444-8444-444444444444","status":"\(status)","requireBeforePhoto":true,"minPhotos":2,
         "paymentAmountMAD":350.5,"startLatitude":null,"startLongitude":null,"startAccuracy":null,
         "createdAt":"2026-09-20T10:00:00Z","startedAt":null,"submittedAt":null,"closedAt":null,"flags":[]}
        """
    }

    static let tokens = #"{"accessToken":"new-access","refreshToken":"new-refresh"}"#
}

/// Upload transport that fails a configurable number of times before delegating.
final class FlakyTransport: PhotoUploadTransport, @unchecked Sendable {
    private let base: PhotoUploadTransport
    private let lock = NSLock()
    var failuresRemaining: Int
    var error: APIError
    private(set) var jobs: [UploadJob] = []

    init(base: PhotoUploadTransport, failures: Int, error: APIError = .network(code: URLError.notConnectedToInternet.rawValue)) {
        self.base = base
        self.failuresRemaining = failures
        self.error = error
    }

    private func record(_ job: UploadJob) -> Bool {
        lock.lock(); defer { lock.unlock() }
        jobs.append(job)
        let shouldFail = failuresRemaining > 0
        if shouldFail { failuresRemaining -= 1 }
        return shouldFail
    }

    func upload(_ job: UploadJob) async throws -> RemotePhoto {
        if record(job) { throw error }
        return try await base.upload(job)
    }
}

extension XCTestCase {
    func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bayen-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

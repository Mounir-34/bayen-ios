import XCTest
@testable import BayenWorker

final class APIClientDecodingTests: XCTestCase {
    func testDecodesTaskWithFractionalAndPlainDates() throws {
        let task = try JSONCoding.decoder.decode(WorkerTask.self, from: Fixtures.json(Fixtures.task()))
        XCTAssertEqual(task.status, .assigned)
        XCTAssertEqual(task.category, .lighting)
        XCTAssertEqual(task.radiusMeters, 50)
        XCTAssertEqual(task.paymentAmountMAD, 350.5)
        XCTAssertEqual(task.dueDate, ISO8601.parse("2026-09-30T08:00:00Z"))
        XCTAssertEqual(task.createdAt.timeIntervalSince1970, 1_789_898_400, accuracy: 0.001)
        XCTAssertNil(task.startedAt)
    }

    func testUnknownEnumValuesDoNotBreakDecoding() throws {
        let task = try JSONCoding.decoder.decode(WorkerTask.self,
                                                  from: Fixtures.json(Fixtures.task(status: "ARCHIVED", category: "DRONES")))
        XCTAssertEqual(task.status, .unknown)
        XCTAssertEqual(task.category, .other)
    }

    func testDecodesPagedTaskList() throws {
        let json = #"{"items":[\#(Fixtures.task()),\#(Fixtures.task(id: "55555555-5555-4555-8555-555555555555", status: "REJECTED", dueDate: "null"))],"total":2,"page":1,"pageSize":100}"#
        let page = try JSONCoding.decoder.decode(Paged<WorkerTask>.self, from: Fixtures.json(json))
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.items[1].status, .rejected)
        XCTAssertNil(page.items[1].dueDate)
    }

    func testDecodesTaskDetailWithPhotosAndRejection() throws {
        let json = """
        {"task":\(Fixtures.task(status: "REJECTED")),
         "photos":[{"id":"66666666-6666-4666-8666-666666666666","taskId":"11111111-1111-4111-8111-111111111111",
           "uploaderId":"33333333-3333-4333-8333-333333333333","clientPhotoId":"abc","kind":"BEFORE","sha256":"00",
           "mimeType":"image/jpeg","sizeBytes":1000,"width":2500,"height":1875,"capturedAt":"2026-09-24T09:00:00.123Z",
           "receivedAt":"2026-09-24T09:00:05.000Z","latitude":33.6,"longitude":-7.53,"horizontalAccuracy":8,"altitude":null,
           "isSimulatedLocation":false,"deviceModel":"iPhone15,2","osVersion":"iOS 17.5","appVersion":"1.0.0 (1)",
           "distanceFromTaskMeters":4.2,"flags":["LOW_GPS_ACCURACY"],"submissionId":null,
           "url":"https://s3/x.jpg","thumbnailUrl":null}],
         "latestSubmission":{"id":"77777777-7777-4777-8777-777777777777","taskId":"11111111-1111-4111-8111-111111111111",
           "workerId":"33333333-3333-4333-8333-333333333333","note":null,"submitLatitude":33.6,"submitLongitude":-7.53,
           "submitAccuracy":10,"submittedAt":"2026-09-23T09:00:00.000Z","reviewStatus":"REJECTED",
           "reviewedById":null,"reviewedAt":null,"reviewNote":"Photo floue","flags":[],"photoIds":[]},
         "rejectionNote":"Photo floue"}
        """
        let detail = try JSONCoding.decoder.decode(TaskDetail.self, from: Fixtures.json(json))
        XCTAssertEqual(detail.photos.first?.kind, .before)
        XCTAssertEqual(detail.photos.first?.flags, ["LOW_GPS_ACCURACY"])
        XCTAssertEqual(detail.latestSubmission?.reviewStatus, .rejected)
        XCTAssertEqual(detail.rejectionNote, "Photo floue")
    }

    func testErrorEnvelopeIsMappedWithTransitionDetails() {
        let data = Fixtures.json(#"{"error":{"code":"INVALID_TRANSITION","message":"no","details":{"from":"SUBMITTED","to":"SUBMITTED"}}}"#)
        let error = APIError.fromResponse(status: 409, data: data)
        XCTAssertEqual(error, .server(status: 409, code: "INVALID_TRANSITION", message: "no", transitionFrom: "SUBMITTED"))
        XCTAssertFalse(error.isRetryable)
    }

    func testValidationErrorDetailsArrayIsTolerated() {
        let data = Fixtures.json(#"{"error":{"code":"VALIDATION_ERROR","message":"bad","details":[{"path":"phone","message":"x"}]}}"#)
        XCTAssertEqual(APIError.fromResponse(status: 400, data: data).code, "VALIDATION_ERROR")
    }

    func testNonJSONErrorAndRetryability() {
        XCTAssertEqual(APIError.fromResponse(status: 502, data: Data("<html>".utf8)), .http(status: 502))
        XCTAssertTrue(APIError.http(status: 502).isRetryable)
        XCTAssertTrue(APIError.server(status: 429, code: "RATE_LIMITED", message: "").isRetryable)
        XCTAssertFalse(APIError.server(status: 422, code: "INVALID_PHOTO_IDS", message: "").isRetryable)
        XCTAssertTrue(APIError.from(URLError(.notConnectedToInternet)).isOffline)
    }

    func testPhotoMetadataEncodesISODatesWithMilliseconds() throws {
        let meta = PhotoMetadata(kind: .after, capturedAt: Date(timeIntervalSince1970: 1_790_000_000.5), latitude: 33.6,
                                 longitude: -7.5, horizontalAccuracy: 7.5, altitude: nil, isSimulatedLocation: false,
                                 deviceModel: "iPhone15,2", osVersion: "iOS 17.5", appVersion: "1.0.0 (1)", clientPhotoId: "cid")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(meta)) as? [String: Any])
        XCTAssertEqual(object["capturedAt"] as? String, "2026-09-21T14:13:20.500Z")
        XCTAssertEqual(object["kind"] as? String, "AFTER")
        XCTAssertEqual(object["clientPhotoId"] as? String, "cid")
    }

    func testTaskListFollowsPagination() async throws {
        let transport = ScriptedTransport { request in
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "page" }?.value
            let item = page == "1" ? Fixtures.task() : Fixtures.task(id: "55555555-5555-4555-8555-555555555555")
            return (200, Fixtures.json(#"{"items":[\#(item)],"total":2,"page":\#(page ?? "1"),"pageSize":1}"#))
        }
        let client = HTTPAPIClient(baseURL: Fixtures.baseURL, transport: transport,
                                   tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")))
        let tasks = try await client.tasks(status: nil)
        XCTAssertEqual(tasks.map(\.id), ["11111111-1111-4111-8111-111111111111", "55555555-5555-4555-8555-555555555555"])
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer a")
    }

    func testLoginStoresTokensAndMapsPendingAccount() async throws {
        let store = InMemoryTokenStore()
        let transport = ScriptedTransport { request in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            if body.contains("+212600000004") { return (403, Fixtures.error("ACCOUNT_PENDING")) }
            let user = #"{"id":"33333333-3333-4333-8333-333333333333","municipalityId":"22222222-2222-4222-8222-222222222222","fullName":"Youssef","phone":"+212600000002","role":"WORKER","status":"ACTIVE","cin":null,"preferredLanguage":"ar","createdAt":"2026-09-01T00:00:00.000Z","approvedAt":null,"approvedById":null,"anonymizedAt":null}"#
            return (200, Fixtures.json(#"{"accessToken":"acc","refreshToken":"ref","user":\#(user)}"#))
        }
        let client = HTTPAPIClient(baseURL: Fixtures.baseURL, transport: transport, tokenStore: store)
        let user = try await client.login(phone: "+212600000002", password: "Bayen2026!")
        XCTAssertEqual(user.fullName, "Youssef")
        XCTAssertEqual(store.load(), AuthTokens(accessToken: "acc", refreshToken: "ref"))

        do {
            _ = try await client.login(phone: "+212600000004", password: "Bayen2026!")
            XCTFail("expected ACCOUNT_PENDING")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "ACCOUNT_PENDING")
        }
    }

    func testMultipartBodyContainsMetadataAndFile() {
        let multipart = MultipartFormData(boundary: "B")
        let body = multipart.photoBody(metadataJSON: Data(#"{"kind":"AFTER"}"#.utf8), imageData: Data([0xFF, 0xD8]), filename: "x.jpg")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"metadata\"\r\n"))
        XCTAssertTrue(text.contains("{\"kind\":\"AFTER\"}"))
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"x.jpg\"\r\nContent-Type: image/jpeg"))
        XCTAssertTrue(text.hasSuffix("--B--\r\n"))
        XCTAssertEqual(multipart.contentType, "multipart/form-data; boundary=B")
    }
}

import XCTest
@testable import BayenWorker

final class PhotoDedupTests: XCTestCase {
    private func remote(_ clientPhotoId: String, kind: PhotoKind = .after) -> RemotePhoto {
        RemotePhoto(id: "remote-\(clientPhotoId)", taskId: "task", clientPhotoId: clientPhotoId, kind: kind,
                    capturedAt: Date(), latitude: 0, longitude: 0, horizontalAccuracy: 5, distanceFromTaskMeters: 0,
                    flags: [], submissionId: nil, url: "https://example.test/\(clientPhotoId).jpg", thumbnailUrl: nil)
    }

    func testServerCopiesOfLocalPhotosAreHidden() {
        let photos = [remote("a"), remote("b"), remote("c")]
        XCTAssertEqual(photos.notStored(locally: ["a", "c"]).map(\.clientPhotoId), ["b"])
    }

    func testNothingStoredLocallyKeepsEverything() {
        let photos = [remote("a"), remote("b")]
        XCTAssertEqual(photos.notStored(locally: []).map(\.clientPhotoId), ["a", "b"])
    }

    /// Two photos taken and uploaded here must count as two, not four, toward the minimum.
    func testRequirementCountsEachPhotoOnce() {
        let task = WorkerTask(id: "task", municipalityId: "m", title: "t", description: "", category: .other,
                              latitude: 0, longitude: 0, radiusMeters: 50, address: nil, priority: .normal, dueDate: nil,
                              status: .inProgress, requireBeforePhoto: false, minPhotos: 2, paymentAmountMAD: nil,
                              createdAt: Date(), startedAt: nil, submittedAt: nil, closedAt: nil, flags: [])
        let serverCopies = [remote("a"), remote("b")]
        let requirement = PhotoRequirement(task: task, localPhotos: [],
                                           remotePhotos: serverCopies.notStored(locally: ["a"]))
        XCTAssertEqual(requirement.total, 1)
        XCTAssertFalse(requirement.hasEnough)
    }
}

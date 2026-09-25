import CoreLocation
import XCTest
@testable import BayenWorker

final class DistanceTests: XCTestCase {
    private let casablanca = CLLocationCoordinate2D(latitude: 33.5731, longitude: -7.5898)
    private let rabat = CLLocationCoordinate2D(latitude: 34.0209, longitude: -6.8416)

    func testZeroDistance() {
        XCTAssertEqual(Geo.distanceMeters(from: casablanca, to: casablanca), 0, accuracy: 1e-9)
    }

    func testCasablancaToRabatMatchesServerFormula() {
        // Reference computed with server/src/lib/geo.ts haversineMeters(...)
        let d = Geo.distanceMeters(from: casablanca, to: rabat)
        XCTAssertEqual(d, 85_201, accuracy: 1)
    }

    func testIsSymmetric() {
        XCTAssertEqual(Geo.distanceMeters(from: casablanca, to: rabat), Geo.distanceMeters(from: rabat, to: casablanca), accuracy: 1e-6)
    }

    func testShortDistanceAgreesWithCoreLocation() {
        let a = CLLocationCoordinate2D(latitude: 33.6005, longitude: -7.5330)
        let b = CLLocationCoordinate2D(latitude: 33.6009, longitude: -7.5326) // ≈ 58 m
        let ours = Geo.distanceMeters(from: a, to: b)
        let apple = CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        XCTAssertEqual(ours, apple, accuracy: apple * 0.005)
        XCTAssertEqual(ours, 57.9, accuracy: 0.1)
    }

    func testRadiusCheck() {
        let center = CLLocationCoordinate2D(latitude: 33.6005, longitude: -7.5330)
        let near = CLLocationCoordinate2D(latitude: 33.60065, longitude: -7.5330) // ≈ 16.7 m north
        XCTAssertTrue(Geo.isInside(near, center: center, radiusMeters: 50))
        XCTAssertFalse(Geo.isInside(near, center: center, radiusMeters: 10))
    }

    func testDistanceFormatting() {
        let short = Geo.formatDistance(35.4, locale: Locale(identifier: "fr_FR"))
        XCTAssertTrue(short.hasPrefix("35") && short.hasSuffix("m"), short)
        XCTAssertTrue(Geo.formatDistance(1234, locale: Locale(identifier: "fr_FR")).hasPrefix("1,2"))
    }
}

final class PhoneNumberTests: XCTestCase {
    func testNormalisesMoroccanFormats() {
        XCTAssertEqual(PhoneNumber.normalize("06 12 34 56 78"), "+212612345678")
        XCTAssertEqual(PhoneNumber.normalize("+212 6-12-34-56-78"), "+212612345678")
        XCTAssertEqual(PhoneNumber.normalize("00212712345678"), "+212712345678")
        XCTAssertNil(PhoneNumber.normalize("0912345678"))
        XCTAssertNil(PhoneNumber.normalize("06123"))
    }

    func testDisplayMask() {
        XCTAssertEqual(PhoneNumber.formatNational("612345678"), "6 12 34 56 78")
        XCTAssertEqual(PhoneNumber.display("+212612345678"), "+212 6 12 34 56 78")
    }
}

final class PhotoProcessorTests: XCTestCase {
    func testResizesAndEmbedsGPS() throws {
        let original = SyntheticPhoto.make(size: CGSize(width: 4000, height: 3000))
        let location = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 33.6005, longitude: -7.5330), altitude: 40,
                                  horizontalAccuracy: 8, verticalAccuracy: 5, timestamp: Date())
        let result = try PhotoProcessor.process(original, location: location, capturedAt: Date())
        XCTAssertEqual(max(result.width, result.height), 2500)
        let gps = try XCTUnwrap(PhotoProcessor.readGPS(from: result.data))
        XCTAssertEqual(gps.latitude, 33.6005, accuracy: 1e-6)
        XCTAssertEqual(gps.longitude, -7.5330, accuracy: 1e-6)
    }
}

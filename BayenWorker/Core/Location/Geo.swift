import CoreLocation
import Foundation

enum Geo {
    /// Mean Earth radius (IUGG) — same constant as `server/src/lib/geo.ts`, so the app shows
    /// exactly the distance the server will compute.
    static let earthRadiusMeters = 6_371_008.8

    /// Great-circle distance in metres (Haversine).
    static func distanceMeters(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let toRad = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * toRad
        let dLon = (b.longitude - a.longitude) * toRad
        let h = pow(sin(dLat / 2), 2) + cos(a.latitude * toRad) * cos(b.latitude * toRad) * pow(sin(dLon / 2), 2)
        return 2 * earthRadiusMeters * asin(min(1, sqrt(h)))
    }

    /// Whether `point` is inside the task's allowed circle.
    static func isInside(_ point: CLLocationCoordinate2D, center: CLLocationCoordinate2D, radiusMeters: Double) -> Bool {
        distanceMeters(from: point, to: center) <= radiusMeters
    }

    /// Localised short distance: "35 m", "1.2 km" (locale-aware digits and separators).
    static func formatDistance(_ meters: Double, locale: Locale = L10n.locale) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .medium
        if meters < 1000 {
            formatter.numberFormatter.maximumFractionDigits = 0
            return formatter.string(from: Measurement(value: max(0, meters.rounded()), unit: UnitLength.meters))
        }
        formatter.numberFormatter.maximumFractionDigits = 1
        return formatter.string(from: Measurement(value: meters / 1000, unit: UnitLength.kilometers))
    }
}

import CoreLocation
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Resizes a captured JPEG to ≤ 2500 px (long edge), re-encodes it at quality 0.8 and embeds
/// the capture time and GPS position in EXIF/GPS metadata (keeping the camera's own EXIF).
enum PhotoProcessor {
    static let maxPixelSize = 2500
    static let jpegQuality: Double = 0.8

    enum ProcessingError: Error { case unreadableImage, encodingFailed }

    struct Result {
        let data: Data
        let width: Int
        let height: Int
    }

    static func process(_ original: Data, location: CLLocation?, capturedAt: Date,
                        maxPixelSize: Int = PhotoProcessor.maxPixelSize, quality: Double = PhotoProcessor.jpegQuality) throws -> Result {
        guard let source = CGImageSourceCreateWithData(original as CFData, nil) else { throw ProcessingError.unreadableImage }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // bakes the orientation into the pixels
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ProcessingError.unreadableImage
        }

        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyPixelWidth] = image.width
        properties[kCGImagePropertyPixelHeight] = image.height

        var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation] = 1
        tiff[kCGImagePropertyTIFFDateTime] = exifDateString(capturedAt)
        tiff[kCGImagePropertyTIFFSoftware] = "Bayen \(DeviceInfo.appVersion)"
        if tiff[kCGImagePropertyTIFFMake] == nil { tiff[kCGImagePropertyTIFFMake] = "Apple" }
        if tiff[kCGImagePropertyTIFFModel] == nil { tiff[kCGImagePropertyTIFFModel] = DeviceInfo.deviceModel }
        properties[kCGImagePropertyTIFFDictionary] = tiff

        var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        exif[kCGImagePropertyExifDateTimeOriginal] = exifDateString(capturedAt)
        exif[kCGImagePropertyExifDateTimeDigitized] = exifDateString(capturedAt)
        exif[kCGImagePropertyExifOffsetTimeOriginal] = exifOffsetString(capturedAt)
        exif[kCGImagePropertyExifPixelXDimension] = image.width
        exif[kCGImagePropertyExifPixelYDimension] = image.height
        properties[kCGImagePropertyExifDictionary] = exif

        if let location {
            properties[kCGImagePropertyGPSDictionary] = gpsDictionary(location, capturedAt: capturedAt)
        }
        properties[kCGImageDestinationLossyCompressionQuality] = quality

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ProcessingError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ProcessingError.encodingFailed }
        return Result(data: output as Data, width: image.width, height: image.height)
    }

    static func gpsDictionary(_ location: CLLocation, capturedAt: Date) -> [CFString: Any] {
        let c = location.coordinate
        var gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: abs(c.latitude),
            kCGImagePropertyGPSLatitudeRef: c.latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude: abs(c.longitude),
            kCGImagePropertyGPSLongitudeRef: c.longitude >= 0 ? "E" : "W",
            kCGImagePropertyGPSHPositioningError: location.horizontalAccuracy,
            kCGImagePropertyGPSDateStamp: utcString(capturedAt, format: "yyyy:MM:dd"),
            kCGImagePropertyGPSTimeStamp: utcString(capturedAt, format: "HH:mm:ss.SS"),
        ]
        if location.verticalAccuracy >= 0 {
            gps[kCGImagePropertyGPSAltitude] = abs(location.altitude)
            gps[kCGImagePropertyGPSAltitudeRef] = location.altitude >= 0 ? 0 : 1
        }
        return gps
    }

    /// Reads GPS latitude/longitude back from a JPEG (used by tests and diagnostics).
    static func readGPS(from data: Data) -> CLLocationCoordinate2D? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
              let lng = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        let latSign: Double = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -1 : 1
        let lngSign: Double = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -1 : 1
        return CLLocationCoordinate2D(latitude: lat * latSign, longitude: lng * lngSign)
    }

    private static func exifDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.string(from: date)
    }

    private static func exifOffsetString(_ date: Date) -> String {
        let seconds = TimeZone.current.secondsFromGMT(for: date)
        let sign = seconds >= 0 ? "+" : "-"
        return String(format: "%@%02ld:%02ld", sign, abs(seconds) / 3600, (abs(seconds) % 3600) / 60)
    }

    private static func utcString(_ date: Date, format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f.string(from: date)
    }
}

/// Memory-friendly thumbnails for the UI.
enum ImageThumbnail {
    static func load(_ url: URL, maxPixelSize: Int = 400) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

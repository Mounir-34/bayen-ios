import Foundation
import UIKit

/// Simulator-only support for recording demo videos. Compiled out of every device and release build.
///
/// Launch with `BAYEN_DEMO_PHOTOS=/path/to/folder` (containing `before.jpg` and `after.jpg`) and the simulator
/// "camera" uses those real pictures instead of the synthetic test photo. The location set with
/// `xcrun simctl location` is then also not reported as simulated, so the demo submission isn't flagged.
enum DemoMode {
    #if DEBUG && targetEnvironment(simulator)
    private static let photosDirectory = ProcessInfo.processInfo.environment["BAYEN_DEMO_PHOTOS"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    static var isActive: Bool { photosDirectory != nil }

    static func photo(for kind: PhotoKind) -> Data? {
        guard let photosDirectory else { return nil }
        return try? Data(contentsOf: photosDirectory.appendingPathComponent(kind == .before ? "before.jpg" : "after.jpg"))
    }
    #else
    static let isActive = false

    static func photo(for kind: PhotoKind) -> Data? { nil }
    #endif

    /// What the viewfinder shows for `kind` while demoing.
    static func previewImage(for kind: PhotoKind) -> UIImage? {
        photo(for: kind).flatMap(UIImage.init(data:))
    }
}

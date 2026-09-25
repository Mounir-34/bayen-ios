import Foundation
import os

/// Diagnostics for the photo upload queue. Shows up in the Xcode console (filter on "[Upload]")
/// and in Console.app (subsystem "ma.bayen.worker", category "upload").
enum UploadLog {
    private static let logger = Logger(subsystem: "ma.bayen.worker", category: "upload")

    static func info(_ message: String) {
        logger.notice("[Upload] \(message, privacy: .public)") // also shown in the Xcode console
    }
}

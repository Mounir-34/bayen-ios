import Foundation

/// JPEG files of captured photos, in Application Support (not visible in Files, not purged like Caches,
/// excluded from iCloud backup).
struct PhotoFileStore: Sendable {
    let directory: URL

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bayen", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static let `default` = PhotoFileStore(directory: supportDirectory.appendingPathComponent("Photos", isDirectory: true))

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    func url(for fileName: String) -> URL { directory.appendingPathComponent(fileName) }

    /// Writes atomically with file protection that still allows background uploads after first unlock.
    func save(_ data: Data, clientPhotoId: String) throws -> String {
        let fileName = "\(clientPhotoId).jpg"
        try data.write(to: url(for: fileName), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return fileName
    }

    func delete(_ fileName: String) {
        try? FileManager.default.removeItem(at: url(for: fileName))
    }

    func exists(_ fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: fileName).path)
    }
}

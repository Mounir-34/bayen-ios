import Foundation

/// Builds a `multipart/form-data` body on disk (background URLSession uploads must come from a file).
struct MultipartFormData {
    let boundary: String

    init(boundary: String = "Boundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    /// Parts: `metadata` (JSON string field) then `file` (image/jpeg).
    func photoBody(metadataJSON: Data, imageData: Data, filename: String) -> Data {
        var body = Data()
        let crlf = "\r\n"
        func append(_ string: String) { body.append(Data(string.utf8)) }

        append("--\(boundary)\(crlf)")
        // Plain text field (no per-part Content-Type): with `application/json` the server's multipart
        // parser turns the value into an object and validation fails.
        append("Content-Disposition: form-data; name=\"metadata\"\(crlf)\(crlf)")
        body.append(metadataJSON)
        append(crlf)

        append("--\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\(crlf)")
        append("Content-Type: image/jpeg\(crlf)\(crlf)")
        body.append(imageData)
        append(crlf)

        append("--\(boundary)--\(crlf)")
        return body
    }

    func writePhotoBody(metadataJSON: Data, imageFile: URL, to destination: URL) throws {
        let image = try Data(contentsOf: imageFile)
        let body = photoBody(metadataJSON: metadataJSON, imageData: image, filename: imageFile.lastPathComponent)
        try body.write(to: destination, options: .atomic)
    }
}

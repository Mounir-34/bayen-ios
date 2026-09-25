@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// Live-only photo capture (AVFoundation). There is deliberately **no** photo-library access anywhere
/// in the app, so old or downloaded pictures cannot be submitted as proof.
///
/// On the simulator (no camera) `capture()` renders a synthetic test photo so the full flow can be tried.
final class CameraService: NSObject, @unchecked Sendable {
    enum CameraError: Error { case notAuthorized, unavailable, captureFailed }

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "ma.bayen.camera.session")
    private let lock = NSLock()
    private var pending: [Int64: CheckedContinuation<Data, Error>] = [:]
    private var isConfigured = false

    /// False on the simulator or devices without a back camera.
    let hasCamera: Bool = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil

    static var authorizationStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }

    func requestAccess() async -> Bool {
        guard hasCamera else { return true }
        switch Self.authorizationStatus {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func start() {
        guard hasCamera else { return }
        sessionQueue.async { [self] in
            if !isConfigured { configure() }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        guard hasCamera else { return }
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Captures one JPEG (with the camera's own EXIF). Must be called while the session runs.
    func capture() async throws -> Data {
        guard hasCamera else { return SyntheticPhoto.make() }
        guard Self.authorizationStatus == .authorized else { throw CameraError.notAuthorized }
        return try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                guard session.isRunning else {
                    continuation.resume(throwing: CameraError.unavailable)
                    return
                }
                let settings: AVCapturePhotoSettings
                if output.availablePhotoCodecTypes.contains(.jpeg) {
                    settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                } else {
                    settings = AVCapturePhotoSettings()
                }
                if output.supportedFlashModes.contains(.auto) { settings.flashMode = .auto }
                settings.photoQualityPrioritization = .balanced
                if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90 // the app is portrait-only
                }
                lock.lock(); pending[settings.uniqueID] = continuation; lock.unlock()
                output.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration(); isConfigured = true }
        session.sessionPreset = .photo
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input), session.canAddOutput(output) else { return }
        session.addInput(input)
        session.addOutput(output)
        output.maxPhotoQualityPrioritization = .balanced
        if device.isFocusModeSupported(.continuousAutoFocus), (try? device.lockForConfiguration()) != nil {
            device.focusMode = .continuousAutoFocus
            device.unlockForConfiguration()
        }
    }
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        lock.lock()
        let continuation = pending.removeValue(forKey: photo.resolvedSettings.uniqueID)
        lock.unlock()
        if let error {
            continuation?.resume(throwing: error)
        } else if let data = photo.fileDataRepresentation() {
            continuation?.resume(returning: data)
        } else {
            continuation?.resume(throwing: CameraError.captureFailed)
        }
    }
}

/// Live camera preview.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/// Test picture used when no camera exists (simulator).
enum SyntheticPhoto {
    static func make(size: CGSize = CGSize(width: 3024, height: 4032)) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let colors = [UIColor(red: 0.09, green: 0.39, blue: 0.28, alpha: 1).cgColor,
                          UIColor(red: 0.95, green: 0.75, blue: 0.3, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let text = "BAYEN · SIMULATOR\n\(ISO8601.string(from: Date()))" as NSString
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            text.draw(in: CGRect(x: 0, y: size.height / 2 - 200, width: size.width, height: 400),
                      withAttributes: [.font: UIFont.boldSystemFont(ofSize: 150), .foregroundColor: UIColor.white,
                                       .paragraphStyle: paragraph])
        }
        return image.jpegData(compressionQuality: 0.95) ?? Data()
    }
}

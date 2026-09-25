import Foundation

/// Build-time configuration (see Config/*.xcconfig → Info.plist).
struct AppConfig {
    enum Mode: String { case live, mock }

    let baseURL: URL
    let mode: Mode
    /// Whether photos go through the background `URLSession` (see `BackgroundUploadTransport`).
    ///
    /// Background transfers are executed by the system daemon (`nsurlsessiond`), not by the app. That daemon
    /// cannot reach a plain-HTTP dev server on the LAN (and is unreliable in the Simulator): the transfer is
    /// never failed, it just "waits for connectivity" for up to 7 days, so photos stay "waiting" forever.
    /// Default: background only for HTTPS on a real device. Override with `BAYEN_UPLOAD_MODE=background|foreground`.
    let usesBackgroundUploads: Bool

    static let current: AppConfig = {
        let info = Bundle.main.infoDictionary ?? [:]
        let env = ProcessInfo.processInfo.environment
        // Env vars (scheme → Run → Arguments) override the build configuration.
        let modeRaw = env["BAYEN_API_MODE"] ?? (info["BayenAPIMode"] as? String) ?? "live"
        let urlRaw = env["BAYEN_API_BASE_URL"] ?? (info["BayenAPIBaseURL"] as? String) ?? "http://localhost:3000/api/v1"
        let url = URL(string: urlRaw) ?? URL(string: "http://localhost:3000/api/v1")!

        let background: Bool
        switch env["BAYEN_UPLOAD_MODE"]?.lowercased() {
        case "background": background = true
        case "foreground": background = false
        default:
            #if targetEnvironment(simulator)
            background = false
            #else
            background = url.scheme?.lowercased() == "https"
            #endif
        }
        return AppConfig(baseURL: url, mode: Mode(rawValue: modeRaw) ?? .live, usesBackgroundUploads: background)
    }()

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

enum DeviceInfo {
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Hardware identifier, e.g. "iPhone15,2" (simulator: "Simulator arm64 / iPhone15,2").
    static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        if let simModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "Simulator \(machine) / \(simModel)"
        }
        return machine
    }
}

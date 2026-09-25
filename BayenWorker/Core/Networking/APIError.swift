import Foundation

/// Server error body: `{ "error": { "code", "message", "details"? } }`.
struct APIErrorBody: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
        let code: String
        let message: String
        /// Only the shape used by INVALID_TRANSITION (`{ from, to }`) is decoded; anything else is ignored.
        let transition: TransitionDetails?

        enum CodingKeys: String, CodingKey { case code, message, details }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = try c.decode(String.self, forKey: .code)
            message = (try? c.decode(String.self, forKey: .message)) ?? code
            transition = try? c.decodeIfPresent(TransitionDetails.self, forKey: .details)
        }
    }

    struct TransitionDetails: Decodable, Sendable, Equatable {
        let from: String?
        let to: String?
    }

    let error: Payload
}

enum APIError: Error, Equatable, Sendable {
    /// The server answered with an error envelope.
    case server(status: Int, code: String, message: String, transitionFrom: String? = nil)
    /// No session / refresh failed: the user must log in again.
    case unauthorized
    /// Transport problem (offline, timeout, DNS…). Always retryable.
    case network(code: Int)
    /// Unexpected payload.
    case decoding(String)
    /// Non-JSON error (e.g. proxy HTML page).
    case http(status: Int)

    var code: String? {
        if case let .server(_, code, _, _) = self { return code }
        return nil
    }

    /// For INVALID_TRANSITION: the status the task was in on the server.
    var transitionFrom: String? {
        if case let .server(_, _, _, from) = self { return from }
        return nil
    }

    var status: Int? {
        switch self {
        case let .server(status, _, _, _), let .http(status): return status
        case .unauthorized: return 401
        default: return nil
        }
    }

    /// Whether repeating the same request later could succeed.
    var isRetryable: Bool {
        switch self {
        case .network: return true
        case .decoding, .unauthorized: return false
        case let .server(status, code, _, _):
            if code == "RATE_LIMITED" { return true }
            return status >= 500 || status == 408 || status == 429
        case let .http(status):
            return status >= 500 || status == 408 || status == 429
        }
    }

    var isOffline: Bool {
        if case let .network(code) = self {
            return [URLError.notConnectedToInternet.rawValue,
                    URLError.networkConnectionLost.rawValue,
                    URLError.timedOut.rawValue,
                    URLError.cannotConnectToHost.rawValue,
                    URLError.cannotFindHost.rawValue,
                    URLError.dataNotAllowed.rawValue,
                    URLError.internationalRoamingOff.rawValue].contains(code)
        }
        return false
    }

    static func from(_ error: Error) -> APIError {
        if let api = error as? APIError { return api }
        if let url = error as? URLError { return .network(code: url.errorCode) }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return .network(code: ns.code) }
        if error is DecodingError { return .decoding(String(describing: error)) }
        return .network(code: URLError.unknown.rawValue)
    }

    /// Builds an error from a non-2xx response.
    static func fromResponse(status: Int, data: Data) -> APIError {
        if let body = try? JSONCoding.decoder.decode(APIErrorBody.self, from: data) {
            return .server(status: status, code: body.error.code, message: body.error.message,
                           transitionFrom: body.error.transition?.from)
        }
        return .http(status: status)
    }
}

extension APIError {
    /// Localised, user-facing message (ar/fr) for this error.
    var localizedMessage: String {
        switch self {
        case let .server(_, code, _, _):
            let key = "error.\(code)"
            let value = L10n.tr(key)
            return value == key ? L10n.tr("error.generic") : value
        case .unauthorized:
            return L10n.tr("error.UNAUTHORIZED")
        case .network:
            return isOffline ? L10n.tr("error.offline") : L10n.tr("error.network")
        case .decoding, .http:
            return L10n.tr("error.generic")
        }
    }
}

import Foundation

/// Decodes unknown raw values into `.unknown` instead of failing the whole payload,
/// so an older app keeps working when the server adds a new enum case.
private func decodeRaw(_ decoder: Decoder) throws -> String {
    try decoder.singleValueContainer().decode(String.self)
}

enum TaskStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case assigned = "ASSIGNED"
    case inProgress = "IN_PROGRESS"
    case submitted = "SUBMITTED"
    case approved = "APPROVED"
    case rejected = "REJECTED"
    case cancelled = "CANCELLED"
    case unknown = "UNKNOWN"

    init(from decoder: Decoder) throws {
        self = TaskStatus(rawValue: try decodeRaw(decoder)) ?? .unknown
    }
}

enum TaskCategory: String, Codable, CaseIterable, Sendable, Hashable {
    case lighting = "LIGHTING"
    case roads = "ROADS"
    case water = "WATER"
    case greenSpaces = "GREEN_SPACES"
    case waste = "WASTE"
    case buildings = "BUILDINGS"
    case other = "OTHER"

    init(from decoder: Decoder) throws {
        self = TaskCategory(rawValue: try decodeRaw(decoder)) ?? .other
    }
}

enum TaskPriority: String, Codable, Sendable, Hashable {
    case low = "LOW"
    case normal = "NORMAL"
    case high = "HIGH"

    init(from decoder: Decoder) throws {
        self = TaskPriority(rawValue: try decodeRaw(decoder)) ?? .normal
    }
}

enum PhotoKind: String, Codable, CaseIterable, Sendable, Hashable {
    case before = "BEFORE"
    case after = "AFTER"
}

enum UserStatus: String, Codable, Sendable, Hashable {
    case pending = "PENDING"
    case active = "ACTIVE"
    case suspended = "SUSPENDED"
    case unknown = "UNKNOWN"

    init(from decoder: Decoder) throws {
        self = UserStatus(rawValue: try decodeRaw(decoder)) ?? .unknown
    }
}

enum ReviewStatus: String, Codable, Sendable, Hashable {
    case pending = "PENDING"
    case approved = "APPROVED"
    case rejected = "REJECTED"
    case unknown = "UNKNOWN"

    init(from decoder: Decoder) throws {
        self = ReviewStatus(rawValue: try decodeRaw(decoder)) ?? .unknown
    }
}

enum AppLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case ar
    case fr
    case en

    var id: String { rawValue }
    var isRTL: Bool { self == .ar }
    /// Name of the language written in that language (shown in the picker).
    var nativeName: String {
        switch self {
        case .ar: return "العربية"
        case .fr: return "Français"
        case .en: return "English"
        }
    }
}

import Foundation

enum LayoutType: String, Codable, CaseIterable, Identifiable {
    case defaultLayout = "default"
    case niri

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .defaultLayout: "Default"
        case .niri: "Niri (Scrolling)"
        }
    }
}

enum MonitorAssignment: Equatable, Hashable {
    case any
    case main
    case secondary
    case numbered(Int)
    case pattern(String)

    var displayName: String {
        switch self {
        case .any: "Any"
        case .main: "Main"
        case .secondary: "Secondary"
        case let .numbered(n): "Monitor \(n)"
        case let .pattern(p): "Pattern: \(p)"
        }
    }

    func toMonitorDescription() -> MonitorDescription? {
        switch self {
        case .any: return nil
        case .main: return .main
        case .secondary: return .secondary
        case let .numbered(n): return .sequenceNumber(n)
        case let .pattern(p):
            if case let .success(desc) = parseMonitorDescription(p) {
                return desc
            }
            return nil
        }
    }

    static func fromString(_ raw: String) -> MonitorAssignment {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "main": return .main
        case "secondary": return .secondary
        default:
            if let num = Int(trimmed), num >= 1 {
                return .numbered(num)
            }
            return .pattern(trimmed)
        }
    }
}

extension MonitorAssignment: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, value
    }

    private enum AssignmentType: String, Codable {
        case any, main, secondary, numbered, pattern
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(AssignmentType.self, forKey: .type)
        switch type {
        case .any: self = .any
        case .main: self = .main
        case .secondary: self = .secondary
        case .numbered:
            let value = try container.decode(Int.self, forKey: .value)
            self = .numbered(value)
        case .pattern:
            let value = try container.decode(String.self, forKey: .value)
            self = .pattern(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .any:
            try container.encode(AssignmentType.any, forKey: .type)
        case .main:
            try container.encode(AssignmentType.main, forKey: .type)
        case .secondary:
            try container.encode(AssignmentType.secondary, forKey: .type)
        case let .numbered(n):
            try container.encode(AssignmentType.numbered, forKey: .type)
            try container.encode(n, forKey: .value)
        case let .pattern(p):
            try container.encode(AssignmentType.pattern, forKey: .type)
            try container.encode(p, forKey: .value)
        }
    }
}

struct WorkspaceConfiguration: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var displayName: String?
    var monitorAssignment: MonitorAssignment
    var layoutType: LayoutType
    var isPersistent: Bool

    var effectiveDisplayName: String {
        displayName?.isEmpty == false ? displayName! : name
    }

    init(
        id: UUID = UUID(),
        name: String,
        displayName: String? = nil,
        monitorAssignment: MonitorAssignment = .any,
        layoutType: LayoutType = .defaultLayout,
        isPersistent: Bool = false
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.monitorAssignment = monitorAssignment
        self.layoutType = layoutType
        self.isPersistent = isPersistent
    }
}

// SPDX-License-Identifier: GPL-2.0-only
import Foundation

public enum WorkspaceIDPolicy {
    public static func normalizeRawID(_ candidate: String) -> String? {
        ZigIPCSupport.normalizedWorkspaceID(candidate)
    }

    public static func rawID(from workspaceNumber: Int) -> String? {
        ZigIPCSupport.workspaceID(fromNumber: workspaceNumber)
    }

    public static func workspaceNumber(from rawID: String) -> Int? {
        ZigIPCSupport.workspaceNumber(fromRawID: rawID)
    }

    public static func lowestUnusedRawID<S: Sequence>(in rawIDs: S) -> String where S.Element == String {
        let usedNumbers = Set(rawIDs.compactMap(workspaceNumber(from:)))
        var candidate = 1
        while usedNumbers.contains(candidate) {
            candidate += 1
        }
        return String(candidate)
    }

    public static func sortsBefore(_ lhs: String, _ rhs: String) -> Bool {
        switch (workspaceNumber(from: lhs), workspaceNumber(from: rhs)) {
        case let (lhs?, rhs?):
            return lhs < rhs
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }
}

public enum WorkspaceTarget: Equatable, Sendable {
    case rawID(String)
    case displayName(String)

    public init(resolvingLegacyValue value: String) {
        if let rawID = WorkspaceIDPolicy.normalizeRawID(value) {
            self = .rawID(rawID)
        } else {
            self = .displayName(value)
        }
    }

    public init?(workspaceNumber: Int) {
        guard let rawID = WorkspaceIDPolicy.rawID(from: workspaceNumber) else { return nil }
        self = .rawID(rawID)
    }

    public var legacyValue: String {
        switch self {
        case let .rawID(rawID):
            rawID
        case let .displayName(displayName):
            displayName
        }
    }
}

extension WorkspaceTarget: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case rawID = "raw-id"
        case displayName = "display-name"
    }

    public init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer(),
           let legacyValue = try? singleValue.decode(String.self)
        {
            self.init(resolvingLegacyValue: legacyValue)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let value = try container.decode(String.self, forKey: .value)

        switch kind {
        case .rawID:
            self = .rawID(WorkspaceIDPolicy.normalizeRawID(value) ?? value)
        case .displayName:
            self = .displayName(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .rawID(rawID):
            try container.encode(Kind.rawID, forKey: .kind)
            try container.encode(rawID, forKey: .value)
        case let .displayName(displayName):
            try container.encode(Kind.displayName, forKey: .kind)
            try container.encode(displayName, forKey: .value)
        }
    }
}

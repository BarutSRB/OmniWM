import Foundation

struct WorkspaceName: Equatable, Hashable {
    let raw: String

    private init(_ raw: String) {
        self.raw = raw
    }

    static func parse(_ raw: String) -> Result<WorkspaceName, ParseError> {
        if raw == "focused" || raw == "non-focused" ||
            raw == "visible" || raw == "invisible" || raw == "non-visible" ||
            raw == "active" || raw == "non-active" || raw == "inactive" ||
            raw == "back-and-forth" || raw == "back_and_forth" || raw == "previous" ||
            raw == "prev" || raw == "next" ||
            raw == "monitor" || raw == "workspace" ||
            raw == "monitors" || raw == "workspaces" ||
            raw == "all" || raw == "none" ||
            raw == "mouse" || raw == "target"
        {
            return .failure(ParseError("'\(raw)' is a reserved workspace name"))
        }
        if raw.isEmpty {
            return .failure(ParseError("Empty workspace name is forbidden"))
        }
        if raw.contains(",") {
            return .failure(ParseError("Workspace names are not allowed to contain comma"))
        }
        if raw.starts(with: "_") {
            return .failure(ParseError("Workspace names starting with underscore are reserved for future use"))
        }
        if raw.starts(with: "-") {
            return .failure(ParseError("Workspace names starting with dash are disallowed"))
        }
        if raw.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return .failure(ParseError("Whitespace characters are forbidden in workspace names"))
        }
        return .success(WorkspaceName(raw))
    }
}

typealias StringLogicalSegments = [StringLogicalSegment]

enum StringLogicalSegment: Comparable, Equatable {
    case string(String)
    case number(Int)

    static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)):
            a < b
        case let (.number(a), .number(b)):
            a < b
        case (.number, _):
            true
        case (.string, _):
            false
        }
    }
}

extension [StringLogicalSegment] {
    static func < (lhs: Self, rhs: Self) -> Bool {
        for (a, b) in zip(lhs, rhs) {
            if a < b {
                return true
            }
            if a > b {
                return false
            }
        }
        if lhs.count != rhs.count {
            return lhs.count < rhs.count
        }
        return false
    }
}

extension String {
    func toLogicalSegments() -> StringLogicalSegments {
        var currentSegment = ""
        var isPrevNumber = false
        var result: [String] = []

        for char in self {
            let isCurNumber = Int(char.description) != nil
            if isCurNumber != isPrevNumber, !currentSegment.isEmpty {
                result.append(currentSegment)
                currentSegment = ""
            }
            currentSegment.append(char)
            isPrevNumber = isCurNumber
        }

        if !currentSegment.isEmpty {
            result.append(currentSegment)
        }

        return result.map { Int($0).map(StringLogicalSegment.number) ?? .string($0) }
    }
}

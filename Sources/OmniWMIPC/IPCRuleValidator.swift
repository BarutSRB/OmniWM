import Foundation

public struct IPCRuleValidationReport: Equatable, Sendable {
    public let bundleIdError: String?
    public let invalidRegexMessage: String?

    public init(bundleIdError: String?, invalidRegexMessage: String?) {
        self.bundleIdError = bundleIdError
        self.invalidRegexMessage = invalidRegexMessage
    }

    public var isValid: Bool {
        bundleIdError == nil && invalidRegexMessage == nil
    }
}

public enum IPCRuleValidator {
    private static let appIdentifierPattern = try! NSRegularExpression(
        pattern: "^[a-zA-Z0-9]+([.-][a-zA-Z0-9]+)*$"
    )

    public static func bundleIdError(for bundleId: String) -> String? {
        let trimmed = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Bundle ID is required"
        }

        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard appIdentifierPattern.firstMatch(in: trimmed, range: range) != nil else {
            return "Invalid bundle ID format"
        }
        return nil
    }

    public static func invalidRegexMessage(for pattern: String?) -> String? {
        guard let pattern = pattern?.trimmingCharacters(in: .whitespacesAndNewlines), !pattern.isEmpty else {
            return nil
        }

        do {
            _ = try NSRegularExpression(pattern: pattern)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public static func validate(_ rule: IPCRuleDefinition) -> IPCRuleValidationReport {
        IPCRuleValidationReport(
            bundleIdError: bundleIdError(for: rule.bundleId),
            invalidRegexMessage: invalidRegexMessage(for: rule.titleRegex)
        )
    }
}

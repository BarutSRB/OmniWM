// SPDX-License-Identifier: GPL-2.0-only
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
    public static let maximumTitleRegexLength = 256

    public static func bundleIdError(for bundleId: String) -> String? {
        switch ZigIPCSupport.bundleIDValidationCode(for: bundleId) {
        case ZigIPCSupport.bundleIDValidationNone:
            return nil
        case ZigIPCSupport.bundleIDValidationRequired:
            return "Bundle ID is required"
        case ZigIPCSupport.bundleIDValidationInvalid:
            return "Invalid bundle ID format"
        default:
            return "Invalid bundle ID format"
        }
    }

    public static func invalidRegexMessage(for pattern: String?) -> String? {
        guard let pattern = pattern?.trimmingCharacters(in: .whitespacesAndNewlines), !pattern.isEmpty else {
            return nil
        }
        guard pattern.count <= maximumTitleRegexLength else {
            return "Title regex is too long"
        }
        if containsNestedQuantifier(in: pattern) {
            return "Title regex contains nested repetition"
        }

        do {
            _ = try NSRegularExpression(pattern: pattern)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func containsNestedQuantifier(in pattern: String) -> Bool {
        pattern.range(
            of: #"\([^)]*[*+][^)]*\)\s*[*+{]"#,
            options: .regularExpression
        ) != nil
    }

    public static func validate(_ rule: IPCRuleDefinition) -> IPCRuleValidationReport {
        IPCRuleValidationReport(
            bundleIdError: bundleIdError(for: rule.bundleId),
            invalidRegexMessage: invalidRegexMessage(for: rule.titleRegex)
        )
    }
}

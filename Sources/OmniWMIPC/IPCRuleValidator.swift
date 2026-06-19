// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

public struct IPCRuleValidationReport: Equatable, Sendable {
    public let bundleIdError: String?
    public let invalidRegexMessage: String?
    public let identifierError: String?

    public init(bundleIdError: String?, invalidRegexMessage: String?, identifierError: String? = nil) {
        self.bundleIdError = bundleIdError
        self.invalidRegexMessage = invalidRegexMessage
        self.identifierError = identifierError
    }

    public var isValid: Bool {
        bundleIdError == nil && invalidRegexMessage == nil && identifierError == nil
    }
}

public enum IPCRuleValidator {
    private static let appIdentifierPattern = try! NSRegularExpression(
        pattern: "^[a-zA-Z0-9]+([.-][a-zA-Z0-9]+)*$"
    )

    public static func bundleIdError(for bundleId: String) -> String? {
        let trimmed = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard appIdentifierPattern.firstMatch(in: trimmed, range: range) != nil else {
            return "Invalid bundle ID format"
        }
        return nil
    }

    public static func identifierError(for rule: IPCRuleDefinition) -> String? {
        let hasAnchor = nonEmpty(rule.bundleId)
            || nonEmpty(rule.appNameSubstring)
            || nonEmpty(rule.titleSubstring)
            || nonEmpty(rule.titleRegex)
        return hasAnchor ? nil : "Set a bundle ID, app name, or title matcher"
    }

    private static func nonEmpty(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            invalidRegexMessage: invalidRegexMessage(for: rule.titleRegex),
            identifierError: identifierError(for: rule)
        )
    }
}

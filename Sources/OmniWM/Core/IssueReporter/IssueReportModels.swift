// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct RewrittenIssue: Equatable, Sendable {
    var title: String
    var body: String
}

enum IssueAIAvailability: Equatable, Sendable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupported

    var message: String? {
        switch self {
        case .available:
            nil
        case .deviceNotEligible:
            "On-device AI requires a Mac with Apple Silicon (M1 or later). You can still write and submit manually."
        case .appleIntelligenceNotEnabled:
            "Turn on Apple Intelligence in System Settings to use AI rewriting. You can still write and submit manually."
        case .modelNotReady:
            "The on-device model is still downloading — try again shortly. You can still write and submit manually."
        case .unsupported:
            "AI rewriting needs a newer version of macOS. You can still write and submit manually."
        }
    }
}

enum IssueReportError: LocalizedError, Equatable {
    case unavailable
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "On-device AI is unavailable on this Mac."
        case let .generationFailed(detail):
            detail
        }
    }
}

@MainActor
protocol IssueRewriting {
    var availability: IssueAIAvailability { get }
    func rewrite(_ freeform: String, hotkeyContext: String) async throws -> RewrittenIssue
}

@MainActor
enum IssueRewritingFactory {
    static func make() -> (any IssueRewriting)? {
        if #available(macOS 27.0, *) {
            return FoundationModelsIssueEngine()
        }
        return nil
    }
}

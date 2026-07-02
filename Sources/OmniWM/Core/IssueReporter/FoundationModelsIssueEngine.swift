// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import FoundationModels

@MainActor
final class FoundationModelsIssueEngine: IssueRewriting {
    var availability: IssueAIAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            .available
        case let .unavailable(reason):
            Self.map(reason)
        @unknown default:
            .modelNotReady
        }
    }

    func rewrite(_ freeform: String, hotkeyContext: String) async throws -> RewrittenIssue {
        let instructions: String
        if hotkeyContext.isEmpty {
            instructions = IssueTemplate.rewriteInstructions
        } else {
            instructions = """
            \(IssueTemplate.rewriteInstructions)

            \(IssueTemplate.hotkeyContextPreamble)
            \(hotkeyContext)
            """
        }
        let session = LanguageModelSession {
            instructions
        }
        do {
            let generated = try await session.respond(
                to: freeform,
                generating: GeneratedIssue.self,
                options: GenerationOptions(samplingMode: .greedy)
            ).content
            let body = IssueTemplate.assemble(
                summary: generated.summary,
                stepsToReproduce: generated.stepsToReproduce,
                expectedBehavior: generated.expectedBehavior,
                actualBehavior: generated.actualBehavior,
                additionalContext: generated.additionalContext
            )
            return RewrittenIssue(title: generated.title, body: body)
        } catch {
            throw IssueReportError.generationFailed(error.localizedDescription)
        }
    }

    private static func map(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> IssueAIAvailability {
        switch reason {
        case .deviceNotEligible:
            .deviceNotEligible
        case .appleIntelligenceNotEnabled:
            .appleIntelligenceNotEnabled
        case .modelNotReady:
            .modelNotReady
        @unknown default:
            .modelNotReady
        }
    }
}

@Generable
private struct GeneratedIssue {
    @Guide(description: "A short, specific issue title")
    var title: String
    @Guide(description: "One-sentence summary of the problem, or 'Not provided'")
    var summary: String
    @Guide(description: "Minimal, numbered, deterministic steps to reproduce, or 'Not provided'")
    var stepsToReproduce: String
    @Guide(description: "What the user expected to happen, or 'Not provided'")
    var expectedBehavior: String
    @Guide(description: "What actually happened and how it deviates from expected, or 'Not provided'")
    var actualBehavior: String
    @Guide(description: "Other context the user gave: layout, monitors, app/window, hotkey+command, or 'Not provided'")
    var additionalContext: String
}

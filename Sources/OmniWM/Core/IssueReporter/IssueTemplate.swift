// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

enum IssueTemplate {
    static let notProvided = "Not provided"

    static let requiredHeaders = [
        "## Summary",
        "## Steps to Reproduce",
        "## Expected Behavior",
        "## Actual Behavior",
        "## Additional Context"
    ]

    static func assemble(
        summary: String,
        stepsToReproduce: String,
        expectedBehavior: String,
        actualBehavior: String,
        additionalContext: String
    ) -> String {
        let contents = [summary, stepsToReproduce, expectedBehavior, actualBehavior, additionalContext]
        return zip(requiredHeaders, contents)
            .map { header, content in
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(header)\n\(trimmed.isEmpty ? notProvided : trimmed)"
            }
            .joined(separator: "\n\n")
    }

    static func compose(_ content: IssueComposition) -> String {
        var sections: [String] = []

        func addSection(_ header: String, _ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            sections.append("\(header)\n\(trimmed)")
        }

        if content.category != .unspecified {
            sections.append("**Category:** \(content.category.displayName)")
        }
        addSection("## What happened", content.actual)
        addSection("## Expected behavior", content.expected)
        addSection("## Steps to reproduce", content.repro)
        addSection("## Affected app(s)", content.affectedApps)
        sections.append("**Active layout:** \(content.layout.displayName)")

        switch content.regression {
        case .unknown:
            break
        case .no:
            sections.append("**Regression:** No, it never worked.")
        case .yes:
            let version = content.regressionVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            sections.append("**Regression:** Yes" + (version.isEmpty ? "." : " — last worked in \(version)."))
        }

        return sections.joined(separator: "\n\n")
    }

    static let rewriteInstructions = loadPrompt("issue-rewrite-prompt")

    static let hotkeyContextPreamble = loadPrompt("issue-hotkey-context-preamble")

    private static func loadPrompt(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Prompts"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            fatalOffMain("Missing bundled prompt resource: Prompts/\(name).md")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

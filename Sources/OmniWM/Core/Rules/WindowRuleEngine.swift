// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation
import OmniWMIPC

enum WindowDecisionDisposition: Equatable, Sendable {
    case managed
    case floating
    case unmanaged
    case undecided
}

enum WindowDecisionSource: Equatable, Sendable {
    case manualOverride
    case userRule(UUID)
    case builtInRule(String)
    case heuristic
}

enum WindowDecisionLayoutKind: String, Equatable, Sendable {
    case explicitLayout
    case fallbackLayout
}

enum WindowDecisionDeferredReason: String, Equatable, Sendable {
    case attributeFetchFailed
    case requiredTitleMissing
}

enum WindowDecisionAdmissionOutcome: String, Equatable, Sendable {
    case trackedTiling
    case trackedFloating
    case ignored
    case deferred
}

enum ManualWindowOverride: String, Codable, Equatable {
    case forceTile
    case forceFloat
}

struct ManagedWindowRuleEffects: Equatable, Sendable {
    var minWidth: Double?
    var minHeight: Double?
    var matchedRuleId: UUID?

    static let none = ManagedWindowRuleEffects()
}

struct WindowDecision: Equatable, Sendable {
    let disposition: WindowDecisionDisposition
    let source: WindowDecisionSource
    let layoutDecisionKind: WindowDecisionLayoutKind
    let workspaceName: String?
    let ruleEffects: ManagedWindowRuleEffects
    let heuristicReasons: [AXWindowHeuristicReason]
    let deferredReason: WindowDecisionDeferredReason?

    var managesWindow: Bool {
        disposition == .managed
    }

    var trackedMode: TrackedWindowMode? {
        switch disposition {
        case .managed:
            .tiling
        case .floating:
            .floating
        case .unmanaged, .undecided:
            nil
        }
    }

    var admissionOutcome: WindowDecisionAdmissionOutcome {
        switch disposition {
        case .managed:
            .trackedTiling
        case .floating:
            .trackedFloating
        case .unmanaged:
            .ignored
        case .undecided:
            .deferred
        }
    }

    var tracksWindow: Bool {
        trackedMode != nil
    }

    var isResolved: Bool {
        disposition != .undecided
    }
}

struct WindowRuleFacts: Equatable, Sendable {
    let appName: String?
    let ax: AXWindowFacts
    let sizeConstraints: WindowSizeConstraints?
    let windowServer: WindowServerInfo?
}

enum WindowRuleReevaluationTarget: Hashable, Sendable {
    case window(WindowToken)
    case pid(pid_t)
}

struct WindowRuleReevaluationOutcome: Equatable, Sendable {
    let resolvedAnyTarget: Bool
    let evaluatedAnyWindow: Bool
    let relayoutNeeded: Bool

    static let none = WindowRuleReevaluationOutcome(
        resolvedAnyTarget: false,
        evaluatedAnyWindow: false,
        relayoutNeeded: false
    )
}

struct WindowDecisionDebugSnapshot: Equatable, Sendable {
    let token: WindowToken?
    let appName: String?
    let bundleId: String?
    let title: String?
    let axRole: String?
    let axSubrole: String?
    let appFullscreen: Bool
    let manualOverride: ManualWindowOverride?
    let disposition: WindowDecisionDisposition
    let source: WindowDecisionSource
    let layoutDecisionKind: WindowDecisionLayoutKind
    let deferredReason: WindowDecisionDeferredReason?
    let admissionOutcome: WindowDecisionAdmissionOutcome
    let workspaceName: String?
    let minWidth: Double?
    let minHeight: Double?
    let matchedRuleId: UUID?
    let heuristicReasons: [AXWindowHeuristicReason]
    let attributeFetchSucceeded: Bool

    var sourceDescription: String {
        switch source {
        case .manualOverride:
            "manualOverride"
        case let .userRule(ruleId):
            "userRule(\(ruleId.uuidString))"
        case let .builtInRule(name):
            "builtInRule(\(name))"
        case .heuristic:
            "heuristic"
        }
    }

    private func stringValue<T>(_ value: T?) -> String {
        value.map { String(describing: $0) } ?? "nil"
    }

    func formattedDump() -> String {
        let lines: [String] = [
            "token=\(token.map { "\($0.pid):\($0.windowId)" } ?? "nil")",
            "appName=\(appName ?? "nil")",
            "bundleId=\(bundleId ?? "nil")",
            "title=\(title ?? "nil")",
            "axRole=\(axRole ?? "nil")",
            "axSubrole=\(axSubrole ?? "nil")",
            "appFullscreen=\(appFullscreen)",
            "manualOverride=\(manualOverride?.rawValue ?? "nil")",
            "disposition=\(String(describing: disposition))",
            "source=\(sourceDescription)",
            "layoutDecisionKind=\(layoutDecisionKind.rawValue)",
            "deferredReason=\(deferredReason?.rawValue ?? "nil")",
            "admissionOutcome=\(admissionOutcome.rawValue)",
            "workspaceName=\(workspaceName ?? "nil")",
            "minWidth=\(stringValue(minWidth))",
            "minHeight=\(stringValue(minHeight))",
            "matchedRuleId=\(matchedRuleId?.uuidString ?? "nil")",
            "heuristicReasons=\(heuristicReasons.map(\.rawValue).joined(separator: ","))",
            "attributeFetchSucceeded=\(attributeFetchSucceeded)"
        ]
        return lines.joined(separator: "\n")
    }

}

@MainActor
final class WindowRuleEngine {
    static let cleanShotBundleId = "pl.maketheweb.cleanshotx"
    private static let cleanShotRecordingOverlayRuleName = "cleanShotRecordingOverlay"

    private enum RuleSource {
        case user
        case builtIn(String)
    }

    private struct CompiledRule {
        let rule: AppRule
        let source: RuleSource
        let titleRegex: NSRegularExpression?
        let order: Int

        var requiresTitle: Bool {
            rule.titleSubstring?.isEmpty == false || titleRegex != nil
        }

        var requiresDynamicReevaluation: Bool {
            rule.hasAdvancedMatchers
        }

        func matches(_ facts: WindowRuleFacts) -> Bool {
            if rule.bundleId.caseInsensitiveCompare(facts.ax.bundleId ?? "") != .orderedSame {
                return false
            }

            if let appNameSubstring = nonEmpty(rule.appNameSubstring) {
                guard let appName = facts.appName,
                      appName.localizedCaseInsensitiveContains(appNameSubstring)
                else {
                    return false
                }
            }

            if let titleSubstring = nonEmpty(rule.titleSubstring) {
                guard let title = facts.ax.title,
                      title.localizedCaseInsensitiveContains(titleSubstring)
                else {
                    return false
                }
            }

            if let titleRegex {
                guard let title = facts.ax.title else { return false }
                let range = NSRange(title.startIndex..., in: title)
                guard titleRegex.firstMatch(in: title, range: range) != nil else {
                    return false
                }
            }

            if let axRole = nonEmpty(rule.axRole), facts.ax.role != axRole {
                return false
            }

            if let axSubrole = nonEmpty(rule.axSubrole), facts.ax.subrole != axSubrole {
                return false
            }

            return true
        }

        private func nonEmpty(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return value
        }
    }

    private var compiledUserRules: [CompiledRule] = []
    private let builtInRules: [CompiledRule]
    private var titleFetchBundleIds: Set<String> = []
    private(set) var invalidRegexMessagesByRuleId: [UUID: String] = [:]

    private(set) var requiresTitle = false
    private(set) var hasDynamicReevaluationRules = false

    init() {
        builtInRules = Self.makeBuiltInRules()
        titleFetchBundleIds = Self.titleBundleIds(from: builtInRules)
        requiresTitle = !titleFetchBundleIds.isEmpty
        hasDynamicReevaluationRules = builtInRules.contains { $0.requiresDynamicReevaluation }
    }

    var needsWindowReevaluation: Bool {
        hasDynamicReevaluationRules
    }

    func requiresTitle(for bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return titleFetchBundleIds.contains(bundleId.lowercased())
    }

    func rebuild(rules: [AppRule]) {
        var invalidRegexMessagesByRuleId: [UUID: String] = [:]
        compiledUserRules = rules.enumerated().compactMap { index, rule in
            guard rule.hasAnyRule else { return nil }
            return compile(
                rule: rule,
                source: .user,
                order: index,
                invalidRegexMessagesByRuleId: &invalidRegexMessagesByRuleId
            )
        }
        self.invalidRegexMessagesByRuleId = invalidRegexMessagesByRuleId

        titleFetchBundleIds = Self.titleBundleIds(from: builtInRules)
        titleFetchBundleIds.formUnion(Self.titleBundleIds(from: compiledUserRules))
        requiresTitle = !titleFetchBundleIds.isEmpty
        hasDynamicReevaluationRules = compiledUserRules.contains { $0.requiresDynamicReevaluation }
            || builtInRules.contains { $0.requiresDynamicReevaluation }
    }

    func decision(
        for facts: WindowRuleFacts,
        token: WindowToken?,
        appFullscreen: Bool
    ) -> WindowDecision {
        _ = token

        let userRule = bestMatch(in: compiledUserRules, facts: facts)
        let builtInRule = bestMatch(in: builtInRules, facts: facts)

        let workspaceName = userRule?.rule.assignToWorkspace
        let effects = ManagedWindowRuleEffects(
            minWidth: userRule?.rule.minWidth,
            minHeight: userRule?.rule.minHeight,
            matchedRuleId: userRule?.rule.id
        )

        let kernelOutput = solveWindowDecisionKernel(
            matchedUserAction: userRule?.rule.effectiveLayoutAction,
            matchedBuiltInAction: builtInRule?.rule.effectiveLayoutAction,
            matchedBuiltInSourceKind: builtInRule.flatMap { builtInSourceKind(for: $0) },
            specialCaseKind: specialCaseKind(for: facts),
            facts: facts.ax,
            titleRequired: requiresTitle(for: facts.ax.bundleId),
            appFullscreen: appFullscreen
        )

        return WindowDecision(
            disposition: kernelOutput.disposition,
            source: decisionSource(
                from: kernelOutput,
                userRule: userRule
            ),
            layoutDecisionKind: kernelOutput.layoutDecisionKind,
            workspaceName: workspaceName,
            ruleEffects: effects,
            heuristicReasons: kernelOutput.heuristicReasons,
            deferredReason: kernelOutput.deferredReason
        )
    }

    private func specialCaseKind(for facts: WindowRuleFacts) -> WindowDecisionSpecialCaseKind {
        guard facts.ax.bundleId == Self.cleanShotBundleId,
              facts.ax.subrole == (kAXStandardWindowSubrole as String),
              facts.windowServer?.level == 103
        else {
            return .none
        }

        return .cleanShotRecordingOverlay
    }

    private func decisionSource(
        from output: WindowDecisionKernelOutput,
        userRule: CompiledRule?
    ) -> WindowDecisionSource {
        switch output.sourceKind {
        case .userRule:
            guard let userRule else {
                preconditionFailure("Window decision kernel returned a user-rule source without a matched user rule")
            }
            return .userRule(userRule.rule.id)
        case .builtInRule:
            guard let builtInSourceKind = output.builtInSourceKind else {
                preconditionFailure("Window decision kernel returned a built-in source without a built-in source kind")
            }
            return .builtInRule(builtInRuleName(for: builtInSourceKind))
        case .heuristic:
            return .heuristic
        }
    }

    private func builtInSourceKind(for compiled: CompiledRule) -> WindowDecisionBuiltInSourceKind? {
        switch compiled.source {
        case .user:
            return nil
        case let .builtIn(name):
            switch name {
            case "defaultFloatingApp":
                return .defaultFloatingApp
            case "browserPictureInPicture":
                return .browserPictureInPicture
            default:
                preconditionFailure("Unknown built-in window rule source '\(name)'")
            }
        }
    }

    private func builtInRuleName(for sourceKind: WindowDecisionBuiltInSourceKind) -> String {
        switch sourceKind {
        case .defaultFloatingApp:
            "defaultFloatingApp"
        case .browserPictureInPicture:
            "browserPictureInPicture"
        case .cleanShotRecordingOverlay:
            Self.cleanShotRecordingOverlayRuleName
        }
    }

    private func bestMatch(in rules: [CompiledRule], facts: WindowRuleFacts) -> CompiledRule? {
        var best: CompiledRule?

        for candidate in rules where candidate.matches(facts) {
            guard let currentBest = best else {
                best = candidate
                continue
            }

            if candidate.rule.specificity > currentBest.rule.specificity
                || (candidate.rule.specificity == currentBest.rule.specificity && candidate.order < currentBest.order)
            {
                best = candidate
            }
        }

        return best
    }

    private static func titleBundleIds(from rules: [CompiledRule]) -> Set<String> {
        Set(
            rules.compactMap { compiled in
                guard compiled.requiresTitle else { return nil }
                return compiled.rule.bundleId.lowercased()
            }
        )
    }

    private func compile(
        rule: AppRule,
        source: RuleSource,
        order: Int,
        invalidRegexMessagesByRuleId: inout [UUID: String]
    ) -> CompiledRule? {
        let titleRegex: NSRegularExpression?
        if let pattern = rule.titleRegex, !pattern.isEmpty {
            if let invalidMessage = IPCRuleValidator.invalidRegexMessage(for: pattern) {
                invalidRegexMessagesByRuleId[rule.id] = invalidMessage
                return nil
            }
            do {
                titleRegex = try NSRegularExpression(pattern: pattern)
            } catch {
                invalidRegexMessagesByRuleId[rule.id] = error.localizedDescription
                return nil
            }
        } else {
            titleRegex = nil
        }

        return CompiledRule(
            rule: rule,
            source: source,
            titleRegex: titleRegex,
            order: order
        )
    }

    private static func compileBuiltInRegex(_ pattern: String, source: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("Invalid built-in \(source) regex '\(pattern)': \(error)")
        }
    }

    private static func makeBuiltInRules() -> [CompiledRule] {
        var rules: [CompiledRule] = []

        for (index, bundleId) in DefaultFloatingApps.bundleIds.sorted().enumerated() {
            let rule = AppRule(
                bundleId: bundleId,
                layout: .float
            )
            rules.append(
                CompiledRule(
                    rule: rule,
                    source: .builtIn("defaultFloatingApp"),
                    titleRegex: nil,
                    order: index
                )
            )
        }

        let pipRules: [AppRule] = [
            AppRule(
                bundleId: "org.mozilla.firefox",
                titleRegex: "^Picture-in-Picture$",
                layout: .float
            ),
            AppRule(
                bundleId: "app.zen-browser.zen",
                titleRegex: "^Picture-in-Picture$",
                layout: .float
            )
        ]

        let pipOffset = rules.count
        for (index, rule) in pipRules.enumerated() {
            rules.append(
                CompiledRule(
                    rule: rule,
                    source: .builtIn("browserPictureInPicture"),
                    titleRegex: compileBuiltInRegex(
                        rule.titleRegex ?? "",
                        source: "browserPictureInPicture"
                    ),
                    order: pipOffset + index
                )
            )
        }

        return rules
    }
}

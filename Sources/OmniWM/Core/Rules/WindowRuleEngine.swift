// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
final class WindowRuleEngine {
    static let ownedWindowRuleName = "ownedWindow"
    nonisolated static let externalSurfaceRuleName = "externalSurface"
    nonisolated static let unprovenIndependentRootRuleName = "unprovenIndependentRoot"
    nonisolated static let hiddenTitleBarWindowRuleName = "hiddenTitleBarWindow"

    private enum Selection {
        case matched(MatchedWindowRules)
        case rejected(WindowDecision)
    }

    private var compiledUserRules: [CompiledWindowRule] = []
    private let builtInRules: [CompiledWindowRule]
    private var titleRules: [CompiledWindowRule] = []
    private(set) var invalidRegexMessagesByRuleId: [UUID: String] = [:]

    private(set) var hasDynamicReevaluationRules = false
    private let eligibilityPolicy: WindowEligibilityPolicy

    init(
        inputMethodBundleIds: Set<String>? = nil,
        hiddenTitleBarFullscreenButtonOptionalBundleIds: Set<String>? = nil,
        hiddenTitleBarNonStandardSubroleBundleIds: Set<String>? = nil
    ) {
        eligibilityPolicy = WindowEligibilityPolicy(
            hiddenTitleBarFullscreenButtonOptionalBundleIds: hiddenTitleBarFullscreenButtonOptionalBundleIds
                ?? HiddenTitleBarRegistry.fullscreenButtonOptionalBundleIds,
            hiddenTitleBarNonStandardSubroleBundleIds: hiddenTitleBarNonStandardSubroleBundleIds
                ?? HiddenTitleBarRegistry.nonStandardSubroleBundleIds,
            inputMethodBundleIds: inputMethodBundleIds ?? InputMethodBundleRegistry.discover()
        )
        builtInRules = CompiledWindowRule.makeBuiltInRules()
        titleRules = builtInRules.filter(\.requiresTitle)
        hasDynamicReevaluationRules = builtInRules.contains { $0.requiresDynamicReevaluation }
    }

    var needsWindowReevaluation: Bool {
        hasDynamicReevaluationRules
    }

    func requiresTitle(for bundleId: String?, appName: String? = nil) -> Bool {
        titleRules.contains { $0.matchesApp(bundleId: bundleId, appName: appName) }
    }

    func rebuild(rules: [AppRule]) {
        var invalidRegexMessagesByRuleId: [UUID: String] = [:]
        compiledUserRules = rules.enumerated().compactMap { index, rule in
            guard rule.hasIdentifyingMatcher, rule.hasEffect else { return nil }
            return CompiledWindowRule.compile(
                rule: rule,
                source: .user,
                order: index,
                invalidRegexMessagesByRuleId: &invalidRegexMessagesByRuleId
            )
        }
        self.invalidRegexMessagesByRuleId = invalidRegexMessagesByRuleId

        titleRules = (builtInRules + compiledUserRules).filter(\.requiresTitle)
        hasDynamicReevaluationRules = compiledUserRules.contains { $0.requiresDynamicReevaluation }
            || builtInRules.contains { $0.requiresDynamicReevaluation }
    }

    static func applyingManualOverride(
        _ decision: WindowDecision,
        manualOverride: ManualWindowOverride?
    ) -> WindowDecision {
        guard let manualOverride, decision.tracksWindow else {
            return decision
        }
        return WindowDecision(
            disposition: manualOverride == .forceTile ? .managed : .floating,
            source: .manualOverride,
            layoutDecisionKind: .explicitLayout,
            workspaceName: decision.workspaceName,
            ruleEffects: decision.ruleEffects,
            admissionHints: decision.admissionHints,
            heuristicReasons: [],
            deferredReason: nil
        )
    }

    func decision(
        for facts: WindowRuleFacts,
        token: WindowToken?,
        appFullscreen: Bool
    ) -> WindowDecision {
        if eligibilityPolicy.isExternalSurface(facts) {
            return externalSurfaceDecision()
        }
        let eligibility = eligibilityPolicy.eligibility(for: facts, token: token, appFullscreen: appFullscreen)
        let matches: MatchedWindowRules
        switch selectRules(for: facts, eligibility: eligibility) {
        case let .rejected(decision):
            return decision
        case let .matched(selected):
            matches = selected
        }
        if let decision = matches.explicitDecision(for: facts) {
            return decision
        }
        if facts.ax.title == nil,
           requiresTitle(for: facts.ax.bundleId, appName: facts.appName)
        {
            return matches.fallbackDecision(disposition: .undecided, deferredReason: .requiredTitleMissing)
        }
        if appFullscreen {
            return matches.fallbackDecision(disposition: .managed)
        }
        if eligibilityPolicy.acceptsHiddenTitleBar(facts) {
            return matches.fallbackDecision(
                disposition: .managed,
                source: .builtInRule(Self.hiddenTitleBarWindowRuleName)
            )
        }
        return matches.heuristicDecision(for: facts)
    }

    private func selectRules(for facts: WindowRuleFacts, eligibility: WindowStructuralEligibility) -> Selection {
        let userRule: CompiledWindowRule?
        let builtInRule: CompiledWindowRule?
        switch eligibility {
        case .eligible:
            userRule = bestMatch(in: compiledUserRules, facts: facts)
            builtInRule = bestMatch(in: builtInRules, facts: facts)
        case .requiresExplicitInclusion:
            userRule = bestExplicitInclusionMatch(in: compiledUserRules, facts: facts)
            builtInRule = bestExplicitInclusionMatch(in: builtInRules, facts: facts)
            if userRule == nil, builtInRule == nil {
                return .rejected(externalSurfaceDecision())
            }
        case .requiresExplicitUserInclusion:
            userRule = bestExplicitInclusionMatch(in: compiledUserRules, facts: facts)
            builtInRule = nil
            if userRule == nil {
                return .rejected(externalSurfaceDecision())
            }
        case .requiresIndependentRootInclusion:
            userRule = bestExplicitInclusionMatch(in: compiledUserRules, facts: facts)
            builtInRule = bestExplicitInclusionMatch(in: builtInRules, facts: facts)
            if userRule == nil, builtInRule == nil {
                return .rejected(unprovenIndependentRootDecision())
            }
        case .external:
            return .rejected(externalSurfaceDecision())
        case let .deferred(reason):
            return .rejected(deferredStructuralDecision(reason: reason))
        }
        return .matched(MatchedWindowRules(userRule: userRule, builtInRule: builtInRule))
    }

    private func externalSurfaceDecision() -> WindowDecision {
        WindowDecision(
            disposition: .unmanaged,
            source: .builtInRule(Self.externalSurfaceRuleName),
            layoutDecisionKind: .explicitLayout,
            workspaceName: nil,
            ruleEffects: .none,
            admissionHints: .none,
            heuristicReasons: [],
            deferredReason: nil
        )
    }

    private func unprovenIndependentRootDecision() -> WindowDecision {
        WindowDecision(
            disposition: .unmanaged,
            source: .builtInRule(Self.unprovenIndependentRootRuleName),
            layoutDecisionKind: .explicitLayout,
            workspaceName: nil,
            ruleEffects: .none,
            admissionHints: .none,
            heuristicReasons: [],
            deferredReason: nil
        )
    }

    private func deferredStructuralDecision(
        reason: WindowDecisionDeferredReason
    ) -> WindowDecision {
        WindowDecision(
            disposition: .undecided,
            source: .heuristic,
            layoutDecisionKind: .fallbackLayout,
            workspaceName: nil,
            ruleEffects: .none,
            admissionHints: .none,
            heuristicReasons: reason == .attributeFetchFailed ? [.attributeFetchFailed] : [],
            deferredReason: reason
        )
    }

    private func bestMatch(
        in rules: [CompiledWindowRule],
        facts: WindowRuleFacts,
        requireExplicitInclusion: Bool = false
    ) -> CompiledWindowRule? {
        var best: CompiledWindowRule?

        for candidate in rules {
            if requireExplicitInclusion,
               !candidate.explicitlyIncludesNonstandardSurface
            {
                continue
            }
            guard candidate.matches(facts) else { continue }
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

    private func bestExplicitInclusionMatch(
        in rules: [CompiledWindowRule],
        facts: WindowRuleFacts
    ) -> CompiledWindowRule? {
        bestMatch(
            in: rules,
            facts: facts,
            requireExplicitInclusion: true
        )
    }
}

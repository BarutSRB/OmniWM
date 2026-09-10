// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
struct MatchedWindowRules {
    let userRule: CompiledWindowRule?
    let builtInRule: CompiledWindowRule?

    func explicitDecision(for facts: WindowRuleFacts) -> WindowDecision? {
        if let userRule, let decision = explicitDecision(userRule) {
            return decision
        }
        if let builtInRule,
           builtInRule.canApplyExplicitly(to: facts),
           let decision = explicitDecision(builtInRule)
        {
            return decision
        }
        return nil
    }

    func fallbackDecision(
        disposition: WindowDecisionDisposition,
        source: WindowDecisionSource? = nil,
        deferredReason: WindowDecisionDeferredReason? = nil
    ) -> WindowDecision {
        makeDecision(
            disposition: disposition,
            source: source ?? fallbackSource(),
            layoutDecisionKind: .fallbackLayout,
            deferredReason: deferredReason
        )
    }

    func heuristicDecision(for facts: WindowRuleFacts) -> WindowDecision {
        let heuristic = AXWindowService.heuristicDisposition(for: facts.ax)
        return makeDecision(
            disposition: heuristic.disposition,
            source: userRule.map { .userRule($0.rule.id) } ?? .heuristic,
            layoutDecisionKind: .fallbackLayout,
            heuristicReasons: heuristic.reasons,
            deferredReason: heuristic.disposition == .undecided ? .attributeFetchFailed : nil
        )
    }

    private func explicitDecision(_ compiled: CompiledWindowRule) -> WindowDecision? {
        let source: WindowDecisionSource = switch compiled.source {
        case .user:
            .userRule(compiled.rule.id)
        case let .builtIn(name):
            .builtInRule(name)
        }
        let disposition: WindowDecisionDisposition
        switch compiled.rule.effectiveLayoutAction {
        case .float:
            disposition = .floating
        case .tile:
            disposition = .managed
        case .auto:
            return nil
        }
        return makeDecision(disposition: disposition, source: source, layoutDecisionKind: .explicitLayout)
    }

    private func fallbackSource() -> WindowDecisionSource {
        if let userRule {
            return .userRule(userRule.rule.id)
        }
        if let builtInRule, case let .builtIn(name) = builtInRule.source {
            return .builtInRule(name)
        }
        return .heuristic
    }

    private func makeDecision(
        disposition: WindowDecisionDisposition,
        source: WindowDecisionSource,
        layoutDecisionKind: WindowDecisionLayoutKind,
        heuristicReasons: [AXWindowHeuristicReason] = [],
        deferredReason: WindowDecisionDeferredReason? = nil
    ) -> WindowDecision {
        WindowDecision(
            disposition: disposition,
            source: source,
            layoutDecisionKind: layoutDecisionKind,
            workspaceName: userRule?.rule.assignToWorkspace,
            ruleEffects: ManagedWindowRuleEffects(
                minWidth: userRule?.rule.minWidth,
                minHeight: userRule?.rule.minHeight,
                matchedRuleId: userRule?.rule.id
            ),
            admissionHints: ManagedWindowAdmissionHints(
                initialNiriContainerPrimarySpan: userRule?.rule.validInitialContainerPrimarySpan
            ),
            heuristicReasons: heuristicReasons,
            deferredReason: deferredReason
        )
    }
}

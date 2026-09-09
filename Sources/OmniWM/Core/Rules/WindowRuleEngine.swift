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
    private static let nativeFullscreenSubrole = "AXFullScreenWindow"
    private static let systemSurfaceLevelFloor = CGWindowLevelForKey(.statusWindow)

    private enum StructuralEligibility {
        case eligible
        case requiresExplicitInclusion
        case requiresExplicitUserInclusion
        case requiresIndependentRootInclusion
        case external
        case deferred(WindowDecisionDeferredReason)
    }

    private var compiledUserRules: [CompiledWindowRule] = []
    private let builtInRules: [CompiledWindowRule]
    private var titleRules: [CompiledWindowRule] = []
    private(set) var invalidRegexMessagesByRuleId: [UUID: String] = [:]

    private(set) var hasDynamicReevaluationRules = false
    private let inputMethodBundleIds: Set<String>
    private let hiddenTitleBarFullscreenButtonOptionalBundleIds: Set<String>
    private let hiddenTitleBarNonStandardSubroleBundleIds: Set<String>

    init(
        inputMethodBundleIds: Set<String>? = nil,
        hiddenTitleBarFullscreenButtonOptionalBundleIds: Set<String>? = nil,
        hiddenTitleBarNonStandardSubroleBundleIds: Set<String>? = nil
    ) {
        self.hiddenTitleBarFullscreenButtonOptionalBundleIds = hiddenTitleBarFullscreenButtonOptionalBundleIds
            ?? HiddenTitleBarRegistry.fullscreenButtonOptionalBundleIds
        self.hiddenTitleBarNonStandardSubroleBundleIds = hiddenTitleBarNonStandardSubroleBundleIds
            ?? HiddenTitleBarRegistry.nonStandardSubroleBundleIds
        self.inputMethodBundleIds = inputMethodBundleIds ?? InputMethodBundleRegistry.discover()
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
        if facts.ax.role == (kAXHelpTagRole as String) {
            return externalSurfaceDecision()
        }

        if let bundleId = facts.ax.bundleId?.lowercased(),
           inputMethodBundleIds.contains(bundleId)
        {
            return externalSurfaceDecision()
        }

        let structuralEligibility = structuralEligibility(
            for: facts,
            token: token,
            appFullscreen: appFullscreen
        )

        let userRule: CompiledWindowRule?
        let builtInRule: CompiledWindowRule?
        switch structuralEligibility {
        case .eligible:
            userRule = bestMatch(in: compiledUserRules, facts: facts)
            builtInRule = bestMatch(in: builtInRules, facts: facts)
        case .requiresExplicitInclusion:
            userRule = bestExplicitInclusionMatch(in: compiledUserRules, facts: facts)
            builtInRule = bestExplicitInclusionMatch(in: builtInRules, facts: facts)
            if userRule == nil, builtInRule == nil {
                return externalSurfaceDecision()
            }
        case .requiresExplicitUserInclusion:
            userRule = bestExplicitInclusionMatch(in: compiledUserRules, facts: facts)
            builtInRule = nil
            if userRule == nil {
                return externalSurfaceDecision()
            }
        case .requiresIndependentRootInclusion:
            userRule = bestExplicitInclusionMatch(in: compiledUserRules, facts: facts)
            builtInRule = bestExplicitInclusionMatch(in: builtInRules, facts: facts)
            if userRule == nil, builtInRule == nil {
                return unprovenIndependentRootDecision()
            }
        case .external:
            return externalSurfaceDecision()
        case let .deferred(reason):
            return deferredStructuralDecision(reason: reason)
        }

        let workspaceName = userRule?.rule.assignToWorkspace
        let effects = ManagedWindowRuleEffects(
            minWidth: userRule?.rule.minWidth,
            minHeight: userRule?.rule.minHeight,
            matchedRuleId: userRule?.rule.id
        )
        let admissionHints = ManagedWindowAdmissionHints(
            initialNiriContainerPrimarySpan: userRule?.rule.validInitialContainerPrimarySpan
        )

        if let userRule,
           let userDecision = explicitDecision(
               userRule,
               workspaceName: workspaceName,
               effects: effects,
               admissionHints: admissionHints
           )
        {
            return userDecision
        }

        // Built-in layout can still inherit workspace assignment and sizing effects
        // from a matching user auto rule.
        if let builtInRule,
           builtInRule.canApplyExplicitly(to: facts),
           let builtInDecision = explicitDecision(
               builtInRule,
               workspaceName: workspaceName,
               effects: effects,
               admissionHints: admissionHints
           )
        {
            return builtInDecision
        }

        if facts.ax.title == nil,
           requiresTitle(for: facts.ax.bundleId, appName: facts.appName)
        {
            return WindowDecision(
                disposition: .undecided,
                source: userRule.map { .userRule($0.rule.id) }
                    ?? builtInRule.map { builtInRuleSource(for: $0) }
                    ?? .heuristic,
                layoutDecisionKind: .fallbackLayout,
                workspaceName: workspaceName,
                ruleEffects: effects,
                admissionHints: admissionHints,
                heuristicReasons: [],
                deferredReason: .requiredTitleMissing
            )
        }

        if appFullscreen {
            return WindowDecision(
                disposition: .managed,
                source: userRule.map { .userRule($0.rule.id) }
                    ?? builtInRule.map { builtInRuleSource(for: $0) }
                    ?? .heuristic,
                layoutDecisionKind: .fallbackLayout,
                workspaceName: workspaceName,
                ruleEffects: effects,
                admissionHints: admissionHints,
                heuristicReasons: [],
                deferredReason: nil
            )
        }

        if HiddenTitleBarRegistry.decision(
            for: facts.ax,
            windowServer: facts.windowServer,
            fullscreenButtonOptionalBundleIds: hiddenTitleBarFullscreenButtonOptionalBundleIds,
            nonStandardSubroleBundleIds: hiddenTitleBarNonStandardSubroleBundleIds
        ) {
            return WindowDecision(
                disposition: .managed,
                source: .builtInRule(Self.hiddenTitleBarWindowRuleName),
                layoutDecisionKind: .fallbackLayout,
                workspaceName: workspaceName,
                ruleEffects: effects,
                admissionHints: admissionHints,
                heuristicReasons: [],
                deferredReason: nil
            )
        }

        let heuristic = AXWindowService.heuristicDisposition(for: facts.ax)

        return WindowDecision(
            disposition: heuristic.disposition,
            source: userRule.map { .userRule($0.rule.id) } ?? .heuristic,
            layoutDecisionKind: .fallbackLayout,
            workspaceName: workspaceName,
            ruleEffects: effects,
            admissionHints: admissionHints,
            heuristicReasons: heuristic.reasons,
            deferredReason: heuristic.disposition == .undecided ? .attributeFetchFailed : nil
        )
    }

    private func structuralEligibility(
        for facts: WindowRuleFacts,
        token: WindowToken?,
        appFullscreen: Bool
    ) -> StructuralEligibility {
        guard facts.ax.attributeFetchSucceeded else {
            return .deferred(.attributeFetchFailed)
        }

        guard let role = facts.ax.role,
              let subrole = facts.ax.subrole
        else {
            return .deferred(.attributeFetchFailed)
        }

        let windowServerEvidence: WindowServerInfo?
        if let token {
            guard let windowServer = facts.windowServer,
                  let windowId = UInt32(exactly: token.windowId),
                  windowServer.id == windowId,
                  pid_t(windowServer.pid) == token.pid
            else {
                return .deferred(.windowServerEvidenceMissing)
            }
            windowServerEvidence = windowServer
        } else {
            windowServerEvidence = facts.windowServer
        }

        if let windowServer = windowServerEvidence,
           windowServer.parentId != 0,
           windowServer.parentId != windowServer.id
        {
            return .external
        }

        if let windowServer = windowServerEvidence,
           windowServer.level >= Self.systemSurfaceLevelFloor
        {
            return .requiresExplicitUserInclusion
        }

        if facts.ax.appPolicy == .prohibited
            || (facts.ax.appPolicy == .accessory && !facts.ax.hasCloseButton)
        {
            return .requiresExplicitInclusion
        }

        guard role == (kAXWindowRole as String) else {
            return .requiresExplicitInclusion
        }

        if appFullscreen || Self.automaticRootSubroles.contains(subrole) {
            return .eligible
        }

        if Self.independentRootSubroles.contains(subrole) {
            if HiddenTitleBarRegistry.decision(
                for: facts.ax,
                windowServer: facts.windowServer,
                fullscreenButtonOptionalBundleIds: hiddenTitleBarFullscreenButtonOptionalBundleIds,
                nonStandardSubroleBundleIds: hiddenTitleBarNonStandardSubroleBundleIds
            ) {
                return .eligible
            }

            let hasWindowChrome = facts.ax.hasCloseButton
                || facts.ax.hasFullscreenButton
                || facts.ax.hasZoomButton
                || facts.ax.hasMinimizeButton
            if hasWindowChrome || facts.ax.isMain == true || facts.ax.isModal == true {
                return .eligible
            }
            if facts.ax.isMain == nil || facts.ax.isModal == nil {
                return .deferred(.independentRootEvidenceMissing)
            }
            return .requiresIndependentRootInclusion
        }

        return .requiresExplicitInclusion
    }

    private static let automaticRootSubroles: Set<String> = [
        kAXStandardWindowSubrole as String,
        nativeFullscreenSubrole
    ]

    private static let independentRootSubroles: Set<String> = [
        kAXDialogSubrole as String,
        kAXFloatingWindowSubrole as String
    ]

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

    private func explicitDecision(
        _ compiled: CompiledWindowRule,
        workspaceName: String?,
        effects: ManagedWindowRuleEffects,
        admissionHints: ManagedWindowAdmissionHints
    ) -> WindowDecision? {
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

        return WindowDecision(
            disposition: disposition,
            source: source,
            layoutDecisionKind: .explicitLayout,
            workspaceName: workspaceName,
            ruleEffects: effects,
            admissionHints: admissionHints,
            heuristicReasons: [],
            deferredReason: nil
        )
    }

    private func builtInRuleSource(for compiled: CompiledWindowRule) -> WindowDecisionSource {
        switch compiled.source {
        case let .builtIn(name):
            .builtInRule(name)
        case .user:
            .heuristic
        }
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

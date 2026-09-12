// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    private static let finderQuickLookSubrole = "Quick Look"
    private static let finderBundleId = "com.apple.finder"
    func shouldInheritTrackedParentWorkspace(for evaluation: WindowDecisionEvaluation) -> Bool {
        let facts = evaluation.facts
        guard let windowServer = facts.windowServer,
              windowServer.parentId != 0
        else {
            return false
        }

        let axFacts = facts.ax
        if axFacts.attributeFetchSucceeded {
            return AXWindowService.isSystemModalSurface(role: axFacts.role, subrole: axFacts.subrole)
        }

        if windowServer.hasDocumentTag {
            return false
        }

        return windowServer.hasModalTag || windowServer.hasTransientSurfaceEvidence
    }

    func allowsFloatingSpawnPlacement(
        for evaluation: WindowDecisionEvaluation,
        mode: TrackedWindowMode
    ) -> Bool {
        let ax = evaluation.facts.ax
        return mode == .floating
            && ax.attributeFetchSucceeded
            && ax.bundleId == Self.finderBundleId
            && ax.role == kAXWindowRole as String
            && ax.subrole == Self.finderQuickLookSubrole
    }

    func trackedModeForLifecycle(
        decision: WindowDecision,
        existingEntry: WindowState?
    ) -> TrackedWindowMode? {
        if let trackedMode = decision.trackedMode {
            return trackedMode
        }
        if decision.disposition == .undecided {
            return existingEntry?.mode
        }
        return nil
    }

    func shouldDeferAdmission(
        evaluation: WindowDecisionEvaluation,
        axRef: AXWindowRef,
        mode: TrackedWindowMode,
        windowInfo: WindowServerInfo?
    ) -> Bool {
        if let admissionGeometry = evaluation.admissionGeometry {
            if mode == .tiling,
               !admissionGeometry.isSizeSettable
            {
                return true
            }
            guard let frame = evaluation.facts.windowServer?.frame
                ?? windowInfo?.frame
                ?? admissionGeometry.frame
            else {
                return true
            }
            return !Self.isMeaningfulAdmissionFrame(frame)
        }
        if mode == .tiling,
           !AXWindowService.isSizeSettable(axRef)
        {
            return true
        }
        if let frame = evaluation.facts.windowServer?.frame ?? windowInfo?.frame,
           Self.isMeaningfulAdmissionFrame(frame)
        {
            return false
        }
        guard let axFrame = AXWindowService.framePreferFast(axRef)
            ?? (try? AXWindowService.frame(axRef))
        else {
            return true
        }
        return !Self.isMeaningfulAdmissionFrame(axFrame)
    }

    static func isMeaningfulAdmissionFrame(_ frame: CGRect) -> Bool {
        !frame.isNull
            && !frame.isInfinite
            && frame.width > 1
            && frame.height > 1
    }

    func trackedModePreservingAutomaticFallbackState(
        decision: WindowDecision,
        existingEntry: WindowState?,
        context: WindowRuleReevaluationContext
    ) -> TrackedWindowMode? {
        if context == .automatic,
           let existingEntry,
           decision.isUnprovenIndependentRootDecision
        {
            floatDemotionTracker.clearSample(for: existingEntry.token)
            return existingEntry.mode
        }

        guard let trackedMode = trackedModeForLifecycle(
            decision: decision,
            existingEntry: existingEntry
        ) else {
            return nil
        }

        guard context == .automatic,
              let existingEntry,
              decision.layoutDecisionKind == .fallbackLayout
        else {
            return trackedMode
        }

        if existingEntry.mode == .floating,
           trackedMode == .tiling,
           existingEntry.managedReplacementMetadata?.transientWindowServerEvidence == true
        {
            return .floating
        }

        if existingEntry.mode == .tiling,
           trackedMode == .floating
        {
            return floatDemotionTracker.mode(for: existingEntry.token, decision: decision)
        }

        floatDemotionTracker.clearSample(for: existingEntry.token)
        return trackedMode
    }
}

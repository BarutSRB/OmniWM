// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

enum WindowStructuralEligibility {
    case eligible
    case requiresExplicitInclusion
    case requiresExplicitUserInclusion
    case requiresIndependentRootInclusion
    case external
    case deferred(WindowDecisionDeferredReason)
}

@MainActor
struct WindowEligibilityPolicy {
    private static let nativeFullscreenSubrole = "AXFullScreenWindow"
    private static let systemSurfaceLevelFloor = CGWindowLevelForKey(.statusWindow)

    let hiddenTitleBarFullscreenButtonOptionalBundleIds: Set<String>
    let hiddenTitleBarNonStandardSubroleBundleIds: Set<String>
    let inputMethodBundleIds: Set<String>

    func isExternalSurface(_ facts: WindowRuleFacts) -> Bool {
        if facts.ax.role == (kAXHelpTagRole as String) {
            return true
        }
        if let bundleId = facts.ax.bundleId?.lowercased(), inputMethodBundleIds.contains(bundleId) {
            return true
        }
        return false
    }

    func acceptsHiddenTitleBar(_ facts: WindowRuleFacts) -> Bool {
        HiddenTitleBarRegistry.decision(
            for: facts.ax,
            windowServer: facts.windowServer,
            fullscreenButtonOptionalBundleIds: hiddenTitleBarFullscreenButtonOptionalBundleIds,
            nonStandardSubroleBundleIds: hiddenTitleBarNonStandardSubroleBundleIds
        )
    }

    func eligibility(
        for facts: WindowRuleFacts,
        token: WindowToken?,
        appFullscreen: Bool
    ) -> WindowStructuralEligibility {
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
            return independentRootEligibility(for: facts)
        }

        return .requiresExplicitInclusion
    }

    private func independentRootEligibility(for facts: WindowRuleFacts) -> WindowStructuralEligibility {
        if acceptsHiddenTitleBar(facts) {
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

    private static let automaticRootSubroles: Set<String> = [
        kAXStandardWindowSubrole as String,
        nativeFullscreenSubrole
    ]

    private static let independentRootSubroles: Set<String> = [
        kAXDialogSubrole as String,
        kAXFloatingWindowSubrole as String
    ]
}

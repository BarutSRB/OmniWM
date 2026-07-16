// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

@MainActor
extension LayoutRefreshController {
    static func shouldReadmitTrackedWindow(
        entry: WindowState,
        workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode,
        ruleEffects: ManagedWindowRuleEffects,
        shouldPreservePreFullscreenState: Bool,
        appFullscreen: Bool
    ) -> Bool {
        shouldPreservePreFullscreenState
            || appFullscreen
            || entry.workspaceId != workspaceId
            || entry.mode != mode
            || entry.ruleEffects != ruleEffects
    }

    func observedWindowFrame(_ entry: WindowState) -> CGRect? {
        fastFrame(for: entry.token, axRef: entry.axRef)
    }

    static func hiddenEdgeReveal(isZoomApp: Bool) -> CGFloat {
        isZoomApp ? 0 : hiddenWindowEdgeRevealEpsilon
    }

    func isZoomApp(_ pid: pid_t) -> Bool {
        controller?.appInfoCache.bundleId(for: pid) == "us.zoom.xos"
    }

    func markNativeFullscreenRestoredForFrameApply(_ token: WindowToken) {
        nativeFullscreenRestoredFrameApplyTokens.insert(token)
    }

    func consumeNativeFullscreenRestoredFrameApply(for token: WindowToken) -> Bool {
        nativeFullscreenRestoredFrameApplyTokens.remove(token) != nil
    }
}

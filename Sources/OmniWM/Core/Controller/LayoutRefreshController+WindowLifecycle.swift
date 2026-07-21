// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

@MainActor
extension LayoutRefreshController {
    func makeNiriRemovalSeeds(
        from payloads: [WindowRemovalPayload]
    ) -> [WorkspaceDescriptor.ID: NiriWindowRemovalSeed] {
        var seeds: [WorkspaceDescriptor.ID: NiriWindowRemovalSeed] = [:]
        for payload in payloads {
            switch payload.layoutType {
            case .dwindle:
                continue
            case .niri,
                 .defaultLayout:
                let existing = seeds[payload.workspaceId]
                var removedNodeIds = existing?.removedNodeIds ?? []
                if let removedNodeId = payload.removedNodeId {
                    removedNodeIds.append(removedNodeId)
                }
                let mergedOldFrames = (existing?.oldFrames ?? [:])
                    .merging(payload.niriOldFrames) { current, _ in current }
                seeds[payload.workspaceId] = NiriWindowRemovalSeed(
                    removedNodeIds: removedNodeIds,
                    oldFrames: mergedOldFrames,
                    removedColumn: existing?.removedColumn == true || payload.removedNiriColumn
                )
            }
        }
        return seeds
    }

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

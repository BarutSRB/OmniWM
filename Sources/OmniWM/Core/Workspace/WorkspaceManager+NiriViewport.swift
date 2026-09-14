// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    func niriViewportState(for workspaceId: WorkspaceDescriptor.ID) -> ViewportState {
        recordedViewportStates[workspaceId] ?? ViewportState()
    }

    func normalizeNiriRefreshRate(
        _ state: inout ViewportState,
        for workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let refreshRate = niriEngine?.monitorForWorkspace(workspaceId)?.refreshRate else { return }
        state.displayRefreshRate = refreshRate
    }

    func updateNiriViewportState(
        _ state: ViewportState,
        for workspaceId: WorkspaceDescriptor.ID
    ) {
        var state = state
        normalizeNiriRefreshRate(&state, for: workspaceId)
        recordReconcileEvent(
            .viewportChanged(
                workspaceId: workspaceId,
                state: state,
                source: .workspaceManager
            )
        )
    }

    func niriViewportChangeRequiresInvalidation(
        previous: ViewportState?,
        next: ViewportState,
        pendingOffsetAnimation: Bool
    ) -> Bool {
        guard let previous else {
            return next.selectedNodeId != nil || !pendingOffsetAnimation
        }
        if previous.selectedNodeId != next.selectedNodeId {
            return true
        }
        if previous.activeColumnIndex != next.activeColumnIndex {
            return true
        }
        if previous.viewOffset != next.viewOffset {
            return true
        }
        if previous.viewOffsetToRestore != next.viewOffsetToRestore {
            return true
        }
        if previous.activatePrevColumnOnRemoval != next.activatePrevColumnOnRemoval {
            return true
        }
        return false
    }

    func withNiriViewportState(
        for workspaceId: WorkspaceDescriptor.ID,
        _ mutate: (inout ViewportState) -> Void
    ) {
        var state = niriViewportState(for: workspaceId)
        withEngineMutationScope(in: workspaceId, label: "viewport_mutation") {
            mutate(&state)
        }
        updateNiriViewportState(state, for: workspaceId)
    }
}

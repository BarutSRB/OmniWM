// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    func activeLayoutKind(for workspaceId: WorkspaceDescriptor.ID) -> ActiveLayoutKind {
        guard let descriptor = workspaceCatalog.descriptor(for: workspaceId) else { return .niri }
        return settings.workspaces.layoutType(for: descriptor.name) == .dwindle ? .dwindle : .niri
    }

    func reconcileSnapshot() -> ReconcileSnapshot {
        var entries = windowQueries.allEntries()
        entries.sort {
            $0.workspaceId == $1.workspaceId
                ? ($0.pid == $1.pid ? $0.windowId < $1.windowId : $0.pid < $1.pid)
                : $0.workspaceId < $1.workspaceId
        }

        var workspaceIds: Set<WorkspaceDescriptor.ID> = []
        workspaceIds.reserveCapacity(min(entries.count, workspaceCatalog.count))
        let windowSnapshots = entries.map { entry in
            workspaceIds.insert(entry.workspaceId)
            return ReconcileWindowSnapshot(
                token: entry.token,
                workspaceId: entry.workspaceId,
                mode: entry.mode,
                lifecyclePhase: entry.lifecyclePhase,
                observedState: entry.observedState,
                desiredState: entry.desiredState,
                restoreIntent: entry.restoreIntent,
                lifetimeAuthority: entry.lifetimeAuthority
            )
        }

        var layouts: [WorkspaceDescriptor.ID: LayoutTopology] = [:]
        for workspaceId in workspaceIds {
            let topology = layoutTopology(for: workspaceId)
            if topology.hasColumns || !topology.dwindleFullscreenTokens.isEmpty {
                layouts[workspaceId] = topology
            }
        }

        return ReconcileSnapshot(
            topologyProfile: currentTopologyProfile(),
            focusSession: focusSessionSnapshot,
            windows: windowSnapshots,
            viewports: recordedViewportStates,
            layouts: layouts
        )
    }

    func reconcileSnapshotDump() -> String {
        ReconcileDebugDump.snapshot(reconcileSnapshot())
    }
}

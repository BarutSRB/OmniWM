// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    func persistedRestoreMetadata(for entry: WindowState) -> ManagedReplacementMetadata? {
        let bundleId = entry.managedReplacementMetadata?.bundleId
            ?? persistedRestoreBundleIdProvider?(entry.pid)
        guard bundleId != nil || entry.managedReplacementMetadata != nil else {
            return nil
        }

        let fallback = ManagedReplacementMetadata(
            bundleId: bundleId,
            workspaceId: entry.workspaceId,
            mode: entry.mode,
            role: nil,
            subrole: nil,
            title: nil,
            windowLevel: nil,
            parentWindowId: nil,
            frame: entry.observedState.frame ?? entry.desiredState.floatingFrame ?? entry.floatingState?.lastFrame,
            transientWindowServerEvidence: entry.managedReplacementMetadata?.transientWindowServerEvidence ?? false,
            degradedWindowServerChildEvidence: entry.managedReplacementMetadata?
                .degradedWindowServerChildEvidence ?? false
        )

        guard let metadata = entry.managedReplacementMetadata else {
            return fallback
        }

        var merged = fallback.mergingNonNilValues(from: metadata)
        merged.workspaceId = entry.workspaceId
        merged.mode = entry.mode
        return merged
    }

    func persistedWindowRestoreCatalogBuildSnapshot() -> RestoreCatalogBuildSnapshot {
        let context = monitorResolutionContext()
        let topologyProfile = context.topologyProfile
        var snapshotEntries: [PersistedWindowRestoreCatalogBuildEntry] = []

        for entry in windowQueries.allEntries() {
            guard let metadata = persistedRestoreMetadata(for: entry),
                  let restoreIntent = entry.restoreIntent,
                  let workspaceName = descriptor(for: entry.workspaceId)?.name
            else {
                continue
            }

            let preferredMonitor: DisplayFingerprint?
            if configuredMonitorDescription(for: workspaceName, context: context) != nil {
                preferredMonitor = homeMonitor(for: entry.workspaceId, context: context).map(DisplayFingerprint.init)
            } else {
                preferredMonitor = monitor(for: entry.workspaceId, context: context).map(DisplayFingerprint.init)
                    ?? restoreIntent.preferredMonitor
            }

            snapshotEntries.append(
                PersistedWindowRestoreCatalogBuildEntry(
                    token: entry.token,
                    metadata: metadata,
                    workspaceName: workspaceName,
                    topologyProfile: topologyProfile,
                    preferredMonitor: preferredMonitor,
                    floatingFrame: restoreIntent.floatingFrame,
                    normalizedFloatingOrigin: restoreIntent.normalizedFloatingOrigin,
                    restoreToFloating: restoreIntent.restoreToFloating,
                    rescueEligible: restoreIntent.rescueEligible,
                    niriPlacement: restoreIntent.niriPlacement,
                    detachedNiriContainerSizingState: restoreIntent.detachedNiriContainerSizingState,
                    dwindlePlacement: restoreIntent.dwindlePlacement
                )
            )
        }

        return RestoreCatalogBuildSnapshot(entries: snapshotEntries)
    }
}

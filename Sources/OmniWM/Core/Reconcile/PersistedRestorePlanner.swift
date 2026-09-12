// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

enum PersistedRestorePlanner {
    struct Input {
        let token: WindowToken
        let metadata: ManagedReplacementMetadata
        let catalog: PersistedWindowRestoreCatalog
        let consumedEntries: Set<PersistedWindowRestoreConsumptionKey>
        let monitors: [Monitor]
        let workspaceIdForName: (String) -> WorkspaceDescriptor.ID?
    }

    struct Plan: Equatable {
        let persistedEntry: PersistedWindowRestoreEntry
        let workspaceId: WorkspaceDescriptor.ID
        let preferredMonitorId: Monitor.ID?
        let targetMode: TrackedWindowMode
        let floatingFrame: CGRect?
        let niriPlacement: PersistedNiriPlacement?
        let detachedNiriContainerSizingState: NiriContainerSizingState?
        let dwindlePlacement: PersistedDwindlePlacement?
        let consumedKey: PersistedWindowRestoreKey
        let consumedEntry: PersistedWindowRestoreConsumptionKey
    }

    static func plan(_ input: Input) -> Plan? {
        let matches = persistedHydrationMatches(
            token: input.token,
            metadata: input.metadata,
            catalog: input.catalog,
            consumedEntries: input.consumedEntries
        )

        guard matches.count == 1,
              let persistedEntry = matches.first,
              let workspaceId = input.workspaceIdForName(persistedEntry.restoreIntent.workspaceName)
        else {
            return nil
        }

        let preferredMonitor = resolvePersistedPreferredMonitor(
            persistedEntry.restoreIntent.preferredMonitor,
            fallbackWorkspaceId: workspaceId,
            monitors: input.monitors
        )

        let targetMode: TrackedWindowMode = persistedEntry.restoreIntent.restoreToFloating ? .floating : input.metadata
            .mode
        let floatingFrame = persistedEntry.restoreIntent.rescueEligible
            ? resolvedPersistedFloatingFrame(
                for: persistedEntry.restoreIntent,
                preferredMonitor: preferredMonitor
            )
            : nil

        return Plan(
            persistedEntry: persistedEntry,
            workspaceId: workspaceId,
            preferredMonitorId: preferredMonitor?.id,
            targetMode: targetMode,
            floatingFrame: floatingFrame,
            niriPlacement: persistedEntry.restoreIntent.niriPlacement,
            detachedNiriContainerSizingState: persistedEntry.restoreIntent.detachedNiriContainerSizingState,
            dwindlePlacement: persistedEntry.restoreIntent.dwindlePlacement,
            consumedKey: persistedEntry.key,
            consumedEntry: PersistedWindowRestoreConsumptionKey(entry: persistedEntry)
        )
    }

    private static func persistedHydrationMatches(
        token: WindowToken,
        metadata: ManagedReplacementMetadata,
        catalog: PersistedWindowRestoreCatalog,
        consumedEntries: Set<PersistedWindowRestoreConsumptionKey>
    ) -> [PersistedWindowRestoreEntry] {
        let allHardMatches = catalog.entries.filter { entry in
            entry.identity?.matches(token: token, metadata: metadata) == true
        }
        let availableEntries = catalog.entries.filter { entry in
            !consumedEntries.contains(PersistedWindowRestoreConsumptionKey(entry: entry))
        }
        let availableHardMatches = allHardMatches.filter { entry in
            !consumedEntries.contains(PersistedWindowRestoreConsumptionKey(entry: entry))
        }

        if !availableHardMatches.isEmpty {
            return availableHardMatches
        }
        if !allHardMatches.isEmpty {
            return []
        }

        return availableEntries.filter { entry in
            entry.key.matches(metadata)
        }
    }

    private static func resolvePersistedPreferredMonitor(
        _ preferredMonitor: DisplayFingerprint?,
        fallbackWorkspaceId _: WorkspaceDescriptor.ID,
        monitors: [Monitor]
    ) -> Monitor? {
        guard let preferredMonitor else {
            return monitors.first
        }

        if let displayUUID = preferredMonitor.displayUUID {
            var match: Monitor?
            for monitor in monitors where monitor.displayUUID == displayUUID {
                guard match == nil else {
                    match = nil
                    break
                }
                match = monitor
            }
            if let match {
                return match
            }
        } else if let exactRuntimeMonitor = monitors.first(where: {
            $0.displayUUID == nil &&
                $0.displayId == preferredMonitor.displayId &&
                Monitor.namesMatch($0.name, preferredMonitor.name)
        }) {
            return exactRuntimeMonitor
        }

        let bestFallback = monitors.min { lhs, rhs in
            let lhsScore = persistedMonitorMatchScore(
                fingerprint: preferredMonitor,
                monitor: lhs
            )
            let rhsScore = persistedMonitorMatchScore(
                fingerprint: preferredMonitor,
                monitor: rhs
            )
            if lhsScore.namePenalty != rhsScore.namePenalty {
                return lhsScore.namePenalty < rhsScore.namePenalty
            }
            if lhsScore.geometryDelta != rhsScore.geometryDelta {
                return lhsScore.geometryDelta < rhsScore.geometryDelta
            }
            return MonitorRestoreOrder(monitor: lhs) < MonitorRestoreOrder(monitor: rhs)
        }

        return bestFallback ?? monitors.first
    }

    private static func persistedMonitorMatchScore(
        fingerprint: DisplayFingerprint,
        monitor: Monitor
    ) -> (namePenalty: Int, geometryDelta: CGFloat) {
        let namePenalty = fingerprint.name.localizedCaseInsensitiveCompare(monitor.name) == .orderedSame ? 0 : 1
        let anchorDistance = fingerprint.anchorPoint.distanceSquared(to: monitor.workspaceAnchorPoint)
        let widthDelta = abs(fingerprint.frameSize.width - monitor.frame.width)
        let heightDelta = abs(fingerprint.frameSize.height - monitor.frame.height)
        return (namePenalty, anchorDistance + widthDelta + heightDelta)
    }

    private static func resolvedPersistedFloatingFrame(
        for intent: PersistedRestoreIntent,
        preferredMonitor: Monitor?
    ) -> CGRect? {
        guard let floatingFrame = intent.floatingFrame else { return nil }
        guard let preferredMonitor else { return floatingFrame }

        let currentFingerprint = DisplayFingerprint(monitor: preferredMonitor)
        let shouldUseNormalizedOrigin = intent.normalizedFloatingOrigin != nil
            && intent.preferredMonitor != currentFingerprint

        if shouldUseNormalizedOrigin,
           let normalizedFloatingOrigin = intent.normalizedFloatingOrigin
        {
            let origin = FloatingFrameGeometry.origin(
                from: normalizedFloatingOrigin,
                windowSize: floatingFrame.size,
                in: preferredMonitor.visibleFrame
            )
            return FloatingFrameGeometry.clamped(
                CGRect(origin: origin, size: floatingFrame.size),
                in: preferredMonitor.visibleFrame
            )
        }

        return FloatingFrameGeometry.clamped(floatingFrame, in: preferredMonitor.visibleFrame)
    }
}

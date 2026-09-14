// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    func setNiriRestorePlacements(_ placements: [WindowToken: PersistedNiriPlacement]) {
        let changedPlacements = placements.filter { token, placement in
            guard let entry = windowQueries.entry(for: token), entry.mode == .tiling else { return false }
            let restoreIntent = StateReducer.restoreIntent(for: entry, monitors: monitors)
            return restoreIntent.niriPlacement != placement
                || restoreIntent.detachedNiriContainerSizingState != nil
        }
        guard !changedPlacements.isEmpty else { return }
        recordReconcileEvent(
            .niriPlacementsResolved(
                placements: changedPlacements,
                source: .workspaceManager
            )
        )
    }

    func setDwindleRestorePlacements(_ placements: [WindowToken: PersistedDwindlePlacement]) {
        var changedPlacements: [WindowToken: PersistedDwindlePlacement] = [:]
        for (token, captured) in placements {
            guard let entry = windowQueries.entry(for: token), entry.mode == .tiling else { continue }
            let stored = StateReducer.restoreIntent(for: entry, monitors: monitors).dwindlePlacement
            let placement = captured.preservingPrunedSteps(of: stored)
            if placement != stored {
                changedPlacements[token] = placement
            }
        }
        guard !changedPlacements.isEmpty else { return }
        recordReconcileEvent(
            .dwindlePlacementsResolved(
                placements: changedPlacements,
                source: .workspaceManager
            )
        )
    }

    func managedReplacementMetadata(for token: WindowToken) -> ManagedReplacementMetadata? {
        windowQueries.managedReplacementMetadata(for: token)
    }

    @discardableResult
    func setManagedReplacementMetadata(
        _ metadata: ManagedReplacementMetadata?,
        for token: WindowToken
    ) -> Bool {
        guard let entry = windowQueries.entry(for: token) else {
            return false
        }
        guard windowQueries.managedReplacementMetadata(for: token) != metadata else {
            return false
        }
        recordReconcileEvent(
            .managedReplacementMetadataChanged(
                token: token,
                workspaceId: entry.workspaceId,
                monitorId: monitorId(for: entry.workspaceId),
                metadata: metadata,
                source: .workspaceManager
            )
        )
        return true
    }

    @discardableResult
    func updateManagedReplacementTitle(
        _ title: String,
        for token: WindowToken
    ) -> Bool {
        guard var metadata = windowQueries.managedReplacementMetadata(for: token) else {
            return false
        }
        guard metadata.title != title else {
            return false
        }
        metadata.title = title
        return setManagedReplacementMetadata(metadata, for: token)
    }

    @discardableResult
    func setWindowMode(_ mode: TrackedWindowMode, for token: WindowToken) -> Bool {
        guard let entry = entry(for: token) else { return false }
        let oldMode = entry.mode
        guard oldMode != mode else { return false }

        let workspaceId = entry.workspaceId
        let previousFocus = focusSessionSnapshot
        recordReconcileEvent(
            .windowModeChanged(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId(for: workspaceId),
                mode: mode,
                source: .workspaceManager
            )
        )
        if auxiliaryFocusStateChanged(from: previousFocus) {
            notifySessionStateChanged()
        }
        return true
    }

    func floatingState(for token: WindowToken) -> FloatingState? {
        windowQueries.floatingState(for: token)
    }

    func setFloatingState(_ state: FloatingState?, for token: WindowToken) {
        guard let entry = windowQueries.entry(for: token) else { return }
        guard windowQueries.floatingState(for: token) != state else { return }
        recordReconcileEvent(
            .floatingStateChanged(
                token: token,
                workspaceId: entry.workspaceId,
                state: state,
                source: .workspaceManager
            )
        )
    }

    func manualLayoutOverride(for token: WindowToken) -> ManualWindowOverride? {
        windowQueries.manualLayoutOverride(for: token)
    }

    func setManualLayoutOverride(_ override: ManualWindowOverride?, for token: WindowToken) {
        guard let entry = windowQueries.entry(for: token) else { return }
        guard windowQueries.manualLayoutOverride(for: token) != override else { return }
        recordReconcileEvent(
            .manualLayoutOverrideChanged(
                token: token,
                workspaceId: entry.workspaceId,
                layoutOverride: override,
                source: .workspaceManager
            )
        )
    }

    @discardableResult
    func updateAdmissionHints(
        _ admissionHints: ManagedWindowAdmissionHints,
        for token: WindowToken
    ) -> Bool {
        guard let entry = windowQueries.entry(for: token), entry.admissionHints != admissionHints else { return false }
        recordReconcileEvent(
            .windowAdmissionHintsChanged(
                token: token,
                workspaceId: entry.workspaceId,
                admissionHints: admissionHints,
                source: .workspaceManager
            )
        )
        return windowQueries.admissionHints(for: token) == admissionHints
    }

    func updateFloatingGeometry(
        frame: CGRect,
        for token: WindowToken,
        referenceMonitor: Monitor? = nil,
        restoreToFloating: Bool = true
    ) {
        guard let entry = entry(for: token) else { return }

        let resolvedReferenceMonitor = referenceMonitor
            ?? frame.center.monitorApproximation(in: monitors)
            ?? monitor(for: entry.workspaceId)
        let referenceVisibleFrame = resolvedReferenceMonitor?.visibleFrame ?? frame
        let normalizedOrigin = normalizedFloatingOrigin(
            for: frame,
            in: referenceVisibleFrame
        )

        let state = FloatingState(
            lastFrame: frame,
            normalizedOrigin: normalizedOrigin,
            referenceMonitorId: resolvedReferenceMonitor?.id,
            restoreToFloating: restoreToFloating
        )
        guard windowQueries.floatingState(for: token) != state else { return }

        recordReconcileEvent(
            .floatingGeometryUpdated(
                token: token,
                workspaceId: entry.workspaceId,
                referenceMonitorId: resolvedReferenceMonitor?.id,
                frame: frame,
                normalizedOrigin: normalizedOrigin,
                restoreToFloating: restoreToFloating,
                source: .workspaceManager
            )
        )
    }

    func resolvedFloatingFrame(
        for token: WindowToken,
        preferredMonitor: Monitor? = nil
    ) -> CGRect? {
        guard let entry = entry(for: token),
              let floatingState = floatingState(for: token)
        else {
            return nil
        }

        let targetMonitor = preferredMonitor
            ?? monitor(for: entry.workspaceId)
            ?? floatingState.referenceMonitorId.flatMap { monitor(byId: $0) }
        let visibleFrame = targetMonitor?.visibleFrame ?? floatingState.lastFrame

        if let targetMonitor,
           floatingState.referenceMonitorId == targetMonitor.id || floatingState.normalizedOrigin == nil
        {
            return FloatingFrameGeometry.clamped(floatingState.lastFrame, in: visibleFrame)
        }

        let origin = FloatingFrameGeometry.origin(
            from: floatingState.normalizedOrigin ?? .zero,
            windowSize: floatingState.lastFrame.size,
            in: visibleFrame
        )
        return FloatingFrameGeometry.clamped(
            CGRect(origin: origin, size: floatingState.lastFrame.size),
            in: visibleFrame
        )
    }

    func normalizedFloatingOrigin(
        for frame: CGRect,
        in visibleFrame: CGRect
    ) -> CGPoint {
        let availableWidth = max(1, visibleFrame.width - frame.width)
        let availableHeight = max(1, visibleFrame.height - frame.height)
        let normalizedX = (frame.origin.x - visibleFrame.minX) / availableWidth
        let normalizedY = (frame.origin.y - visibleFrame.minY) / availableHeight
        return CGPoint(
            x: min(max(0, normalizedX), 1),
            y: min(max(0, normalizedY), 1)
        )
    }
}

// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Carbon
import Foundation
import QuartzCore
import ScreenCaptureKit

@MainActor
final class OverviewDragSession {
    private weak var overview: OverviewController?
    private let projection: OverviewViewportProjection
    private let overviewSnapshot: OverviewSnapshot
    private let windowSession: OverviewWindowSession
    private let structuralActions: OverviewStructuralActions
    private let mutationSession: OverviewMutationSession
    private var dragGhostController: DragGhostController?
    private var dragSession: OverviewStructuralActions.DragSession?

    private var state: OverviewState {
        overview?.state ?? .closed
    }

    private var windowFacts: OverviewWindowFacts {
        structuralActions.windowFacts
    }

    var isActive: Bool {
        dragSession != nil
    }

    init(
        projection: OverviewViewportProjection,
        snapshot: OverviewSnapshot,
        windowSession: OverviewWindowSession,
        structuralActions: OverviewStructuralActions,
        mutationSession: OverviewMutationSession
    ) {
        self.projection = projection
        overviewSnapshot = snapshot
        self.windowSession = windowSession
        self.structuralActions = structuralActions
        self.mutationSession = mutationSession
    }

    func connect(overview: OverviewController) {
        self.overview = overview
    }

    func reset() {
        dragGhostController?.endDrag()
        dragGhostController = nil
        dragSession = nil
    }

    private func updateWindowDisplays() {
        windowSession.updateWindowDisplays(state: state)
    }

    func beginDrag(on monitorId: Monitor.ID, handle: WindowHandle, startPoint: CGPoint) {
        guard case .open = state,
              !mutationSession.isTransferring
        else {
            return
        }
        guard let entry = windowFacts.visibleManagedEntry(for: handle) else { return }

        projection.activeInteractionMonitorId = monitorId
        dragSession = OverviewStructuralActions.DragSession(
            handle: handle,
            windowId: entry.windowId,
            workspaceId: entry.workspaceId,
            monitorId: monitorId,
            startPoint: startPoint
        )

        if let frame = overviewSnapshot.windows[handle]?.frame {
            if dragGhostController == nil {
                dragGhostController = DragGhostController()
            }
            dragGhostController?.beginDrag(
                windowId: entry.windowId,
                originalFrame: frame,
                cursorLocation: projection.globalPoint(from: startPoint, on: monitorId)
            )
        }
    }

    func updateDrag(on monitorId: Monitor.ID, at point: CGPoint) {
        guard case .open = state else {
            cancelDrag()
            return
        }
        guard dragSession != nil else { return }
        projection.activeInteractionMonitorId = monitorId
        dragGhostController?.updatePosition(cursorLocation: projection.globalPoint(from: point, on: monitorId))

        let target = resolveDragTarget(at: point, on: monitorId)
        let currentTarget = projection.layoutsByMonitor[monitorId]?.dragTarget
        if target != currentTarget {
            projection.setDragTarget(target, for: monitorId)
            updateWindowDisplays()
        }
    }

    func endDrag(on monitorId: Monitor.ID, at point: CGPoint) {
        guard case .open = state else {
            cancelDrag()
            return
        }
        guard let session = dragSession else { return }
        projection.activeInteractionMonitorId = monitorId
        dragGhostController?.updatePosition(cursorLocation: projection.globalPoint(from: point, on: monitorId))

        let target = projection.layoutsByMonitor[monitorId]?.dragTarget
        projection.clearDragTargets()
        dragGhostController?.endDrag()
        dragSession = nil

        guard let target else {
            updateWindowDisplays()
            return
        }

        let outcome = structuralActions.performDragAction(
            session: session,
            target: target
        )
        switch outcome {
        case let .changed(mutation):
            mutationSession.completeStructuralMutation(mutation)
        case let .awaitingAdmission(mutation, deferredTarget):
            mutationSession.completeDeferredDragMutation(mutation, target: deferredTarget)
        case .unchanged:
            updateWindowDisplays()
        }
    }

    func cancelDrag() {
        projection.clearDragTargets()
        dragGhostController?.endDrag()
        dragSession = nil
        updateWindowDisplays()
    }

    private func resolveDragTarget(at point: CGPoint, on monitorId: Monitor.ID) -> OverviewDragTarget? {
        guard let layout = projection.layoutsByMonitor[monitorId] else { return nil }
        return layout.resolveDragTarget(at: point, draggedHandle: dragSession?.handle)
    }
}

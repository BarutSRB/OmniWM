// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

private let niriTouchpadGestureRecognitionThreshold: CGFloat = 16.0

extension MouseEventHandler {
    struct GestureFrameMetrics {
        var cumulativeX: CGFloat
        var cumulativeY: CGFloat
        var rawDeltaX: CGFloat
        var rawDeltaY: CGFloat
    }

    func handleGestureEvent(_ snapshot: GestureEventSnapshot) {
        let location = snapshot.location
        let phase = NSEvent.Phase(rawValue: snapshot.phaseRawValue)
        let activeTouchCount = Self.activeTouchCount(in: snapshot.touches)

        if phase == .ended || phase == .cancelled {
            defer {
                clearGestureLatches()
                resetGestureState()
            }
            guard gestureFramePreconditionsSatisfied(at: location) else { return }
            if state.gesturePhase == .committed {
                finishCommittedGestureOnRelease(timestamp: snapshot.timestamp, allowFlick: phase == .ended)
            }
            return
        }

        guard gestureFramePreconditionsSatisfied(at: location) else { return }

        if phase == .began, state.gesturePhase != .idle {
            abortActiveGestureIfNeeded()
        }

        guard !snapshot.touches.isEmpty else {
            abortActiveGestureIfNeeded()
            return
        }

        let requiredFingers = state.lockedGestureContext?.fingerCount ?? activeTouchCount
        guard let averageTouchPosition = Self.averageGestureTouchPosition(
            requiredFingers: requiredFingers,
            touches: snapshot.touches
        ) else {
            if state.gesturePhase == .committed, activeTouchCount < requiredFingers {
                finalizeCommittedGestureAfterTouchRelease(timestamp: snapshot.timestamp)
                return
            }
            abortActiveGestureIfNeeded()
            return
        }

        if state.gesturePhase == .idle {
            armGestureIfPossible(
                at: location,
                activeTouchCount: activeTouchCount,
                average: averageTouchPosition,
                timestamp: snapshot.timestamp
            )
            return
        }
        processActiveGestureFrame(average: averageTouchPosition, timestamp: snapshot.timestamp)
    }

    private func gestureFramePreconditionsSatisfied(at location: CGPoint) -> Bool {
        guard let controller else { return false }
        guard controller.isEnabled,
              controller.settings.gestures.scrollEnabled || controller.settings.gestures.workspaceSwipeEnabled
        else {
            abortActiveGestureIfNeeded()
            return false
        }
        if controller.isOverviewOpen() {
            cancelActiveMouseInteraction()
            abortActiveGestureIfNeeded()
            return false
        }
        if shouldBlockOwnWindowInput(at: location) {
            abortActiveGestureIfNeeded()
            return false
        }
        guard !state.isResizing, !state.isMoving else {
            abortActiveGestureIfNeeded()
            return false
        }
        return true
    }

    private func armGestureIfPossible(
        at location: CGPoint,
        activeTouchCount: Int,
        average: CGPoint,
        timestamp: TimeInterval
    ) {
        guard let context = resolveGestureArmContext(at: location, fingerCount: activeTouchCount) else { return }
        state.lockedGestureContext = context
        if context.workspaceAxis != nil {
            state.workspaceSwipeTracker.reset()
            state.workspaceSwipeTracker.push(delta: 0, timestamp: timestamp)
        }
        state.gestureStartX = average.x
        state.gestureStartY = average.y
        state.gestureLastAverageX = average.x
        state.gestureLastAverageY = average.y
        state.gesturePhase = .armed
    }

    private func resolveGestureArmContext(
        at location: CGPoint,
        fingerCount: Int
    ) -> MouseInputState.LockedGestureContext? {
        guard let controller, let config = trackpadGestureConfig else { return nil }
        guard let monitor = location.monitorApproximation(in: controller.workspaceManager.monitors),
              let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        else { return nil }
        let supportsColumnScroll = switch controller.settings.workspaces.layoutType(for: workspace.name) {
        case .niri,
             .defaultLayout:
            controller.niriEngine != nil
        case .dwindle:
            false
        }
        guard TrackpadGestureIntent.hasCandidateMode(
            config,
            fingerCount: fingerCount,
            columnContextAvailable: supportsColumnScroll
        ) else { return nil }
        let columnScrollCandidate = config.columnScrollEnabled
            && fingerCount == config.columnScrollFingerCount
            && supportsColumnScroll
        let isWorkspaceCandidate = config.workspaceSwipeEnabled && fingerCount == config.workspaceSwipeFingerCount
        let columnScrollAxis: WorkspaceSwipeAxis
        if let engine = controller.niriEngine, supportsColumnScroll {
            columnScrollAxis = resolvedNiriOrientation(
                engine: engine,
                workspaceId: workspace.id,
                monitor: monitor
            ) == .horizontal ? .horizontal : .vertical
        } else {
            columnScrollAxis = .horizontal
        }
        let workspaceAxis: WorkspaceSwipeAxis? = if isWorkspaceCandidate {
            if columnScrollCandidate {
                columnScrollAxis == .horizontal ? .vertical : .horizontal
            } else {
                config.workspaceSwipeAxis
            }
        } else {
            nil
        }
        return .init(
            workspaceId: workspace.id,
            monitorId: monitor.id,
            fingerCount: fingerCount,
            columnScrollCandidate: columnScrollCandidate,
            columnScrollAxis: columnScrollAxis,
            workspaceAxis: workspaceAxis
        )
    }

    private func processActiveGestureFrame(average: CGPoint, timestamp: TimeInterval) {
        guard let controller else { return }
        guard let lockedContext = state.lockedGestureContext else {
            assertionFailure("Active gesture missing locked context")
            abortActiveGestureIfNeeded()
            return
        }
        guard let monitor = controller.workspaceManager.monitor(byId: lockedContext.monitorId) else {
            abortActiveGestureIfNeeded()
            return
        }

        let metrics = GestureFrameMetrics(
            cumulativeX: (average.x - state.gestureStartX) * GestureEventSnapshot.normalizedPositionToGestureUnits,
            cumulativeY: (average.y - state.gestureStartY) * GestureEventSnapshot.normalizedPositionToGestureUnits,
            rawDeltaX: (average.x - state.gestureLastAverageX) * GestureEventSnapshot.normalizedPositionToGestureUnits,
            rawDeltaY: (average.y - state.gestureLastAverageY) * GestureEventSnapshot.normalizedPositionToGestureUnits
        )

        if let axis = lockedContext.workspaceAxis,
           state.gesturePhase == .armed || state.activeGestureMode == .workspaceSwitch(axis: axis)
        {
            state.workspaceSwipeTracker.push(
                delta: Double(axis == .horizontal ? metrics.rawDeltaX : metrics.rawDeltaY),
                timestamp: timestamp
            )
        }

        if state.gesturePhase == .armed {
            let distanceSquared = metrics.cumulativeX * metrics.cumulativeX
                + metrics.cumulativeY * metrics.cumulativeY
            let thresholdSquared = niriTouchpadGestureRecognitionThreshold * niriTouchpadGestureRecognitionThreshold
            guard distanceSquared >= thresholdSquared else {
                state.gestureLastAverageX = average.x
                state.gestureLastAverageY = average.y
                return
            }
            guard commitGestureMode(metrics: metrics, lockedContext: lockedContext) else { return }
        }

        state.gestureLastAverageX = average.x
        state.gestureLastAverageY = average.y
        dispatchCommittedGestureFrame(
            metrics: metrics,
            lockedContext: lockedContext,
            monitor: monitor,
            timestamp: timestamp
        )
    }

    static func averageGestureTouchPosition(
        requiredFingers: Int,
        touches: [GestureTouchSample]
    ) -> CGPoint? {
        guard requiredFingers > 0 else { return nil }

        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        var touchCount = 0
        var activeCount = 0

        for touch in touches {
            if touch.phase == .ended || touch.phase == .cancelled {
                continue
            }

            touchCount += 1
            if touchCount > requiredFingers {
                return nil
            }

            guard let normalizedPosition = touch.normalizedPosition else {
                return nil
            }

            sumX += normalizedPosition.x
            sumY += normalizedPosition.y
            activeCount += 1
        }

        guard touchCount == requiredFingers, activeCount > 0 else { return nil }

        return CGPoint(
            x: sumX / CGFloat(activeCount),
            y: sumY / CGFloat(activeCount)
        )
    }
}

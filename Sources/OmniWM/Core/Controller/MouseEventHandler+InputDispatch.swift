// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    var isInputSuppressed: Bool {
        guard let controller else { return true }
        return controller.isLockScreenActive || controller.isFrontmostAppLockScreen()
    }

    var trackpadGestureConfig: TrackpadGestureIntent.Config? {
        guard let settings = controller?.settings else { return nil }
        return TrackpadGestureIntent.Config(
            columnScrollEnabled: settings.gestures.scrollEnabled && controller?.isOverviewOpen() != true,
            columnScrollFingerCount: settings.gestures.fingerCount.rawValue,
            workspaceSwipeEnabled: settings.gestures.workspaceSwipeEnabled && controller?.isOverviewOpen() != true,
            workspaceSwipeFingerCount: settings.gestures.workspaceSwipeFingerCount.rawValue,
            workspaceSwipeAxis: settings.gestures.effectiveWorkspaceSwipeAxis,
            overviewEnabled: settings.gestures.overviewGestureEnabled && controller?.isOverviewOpen() != true,
            overviewFingerCount: settings.gestures.overviewGestureFingerCount.rawValue
        )
    }

    func dispatchMouseMoved(
        at location: CGPoint,
        modifiersRawValue: UInt64 = 0,
        windowIdUnderPointer: Int? = nil
    ) {
        state.latestFocusFollowsMouseSample = .init(
            location: location,
            modifiersRawValue: modifiersRawValue,
            windowIdUnderPointer: windowIdUnderPointer
        )
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            resetHoveredEdgesIfNeeded()
            return
        }
        controller?.mouseWarpHandler.handleMouseWarpMoved(at: location)
        recordMouseWarpSample()
        handleMouseMovedFromTap(
            at: location,
            modifiersRawValue: modifiersRawValue,
            windowIdUnderPointer: windowIdUnderPointer
        )
    }

    @discardableResult
    func dispatchMouseDown(
        at location: CGPoint,
        modifiers: CGEventFlags,
        button: MouseButton = .left,
        windowIdUnderPointer: Int? = nil
    ) -> Bool {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return false
        }
        guard controller != nil else { return false }
        let blocked = shouldBlockOwnWindowInput(at: location)
        if MouseTrace.shared.isActive {
            let geometric = controller?.ownedWindowRegistry.containsGeometric(point: location) ?? false
            MouseTrace.record(
                "tap: down \(button == .right ? "R" : "L") loc=\(TraceFormat.point(location)) "
                    + "ownGeom=\(geometric) ownInteractive=\(blocked) "
                    + "decision=\(blocked ? "yieldToOwned" : "handledByWM")"
            )
        }
        if blocked {
            return false
        }
        if button == .left {
            clearNativeTitleBarDrag()
        }
        return handleMouseDownFromTap(
            at: location,
            modifiers: modifiers,
            button: button,
            windowIdUnderPointer: windowIdUnderPointer
        )
    }

    func dispatchMouseDragged(at location: CGPoint, button: MouseButton = .left) {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return
        }
        controller?.mouseWarpHandler.handleMouseWarpMoved(at: location)
        recordMouseWarpSample()
        beginNativeTitleBarDragIfNeeded(button: button)
        if !isCapturedInteraction(button), shouldBlockOwnWindowInput(at: location) {
            cancelActiveMouseInteraction()
            return
        }
        handleMouseDraggedFromTap(at: location, button: button)
    }

    func dispatchMouseUp(at location: CGPoint, button: MouseButton = .left) {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return
        }
        markNativeTitleBarDragFallbackReleased(button: button)
        finishNativeTitleBarDragIfNeeded(button: button)
        if !isCapturedInteraction(button), shouldBlockOwnWindowInput(at: location) {
            cancelActiveMouseInteraction()
            return
        }
        handleMouseUpFromTap(at: location, button: button)
    }

    func dispatchScrollWheel(_ payload: MouseScrollIntake) {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return
        }
        handleScrollWheelFromTap(payload)
    }

    func receiveTapMouseMoved(
        at location: CGPoint,
        modifiersRawValue: UInt64,
        windowIdUnderPointer: Int? = nil
    ) {
        EventIntake.post(
            .mouseMoved(
                location: location,
                modifiersRawValue: modifiersRawValue,
                windowIdUnderPointer: windowIdUnderPointer
            )
        )
    }

    @discardableResult
    func receiveTapMouseDown(
        at location: CGPoint,
        modifiers: CGEventFlags,
        button: MouseButton = .left
    ) -> Bool {
        if shouldBlockOwnWindowInput(at: location) {
            dropPendingTapEvents()
        } else {
            flushQueuedTapEventsBeforeImmediateDispatch()
            if button == .left, !isInputSuppressed {
                retireNativeTitleBarDragAtInputBoundary()
            }
        }
        return dispatchMouseDown(
            at: location,
            modifiers: modifiers,
            button: button
        )
    }

    func receiveTapMouseDragged(at location: CGPoint, button: MouseButton = .left) {
        if !isInputSuppressed {
            beginNativeTitleBarDragIfNeeded(button: button)
        }
        EventIntake.post(.mouseDragged(button: button, location: location))
    }

    func receiveAnnotatedNativeMouseDragged(windowIdUnderPointer: Int?) {
        guard state.awaitsNativeTitleBarDragTarget,
              state.nativeTitleBarDrag == nil,
              let windowIdUnderPointer,
              let entry = controller?.workspaceManager.entry(forWindowId: windowIdUnderPointer),
              entry.mode == .tiling
        else {
            if windowIdUnderPointer != nil {
                state.awaitsNativeTitleBarDragTarget = false
                state.nativeTitleBarDragFallbackToken = nil
                state.nativeTitleBarDragFallbackReleased = false
            }
            return
        }
        state.awaitsNativeTitleBarDragTarget = false
        state.nativeTitleBarDragFallbackToken = nil
        state.nativeTitleBarDragFallbackReleased = false
        state.nativeTitleBarDrag = .init(token: entry.token)
        beginNativeTitleBarDragIfNeeded(button: .left)
    }

    func receiveTapMouseUp(at location: CGPoint, button: MouseButton = .left) {
        markNativeTitleBarDragFallbackReleased(button: button)
        defer {
            if state.capturedInteractionButton == button {
                state.capturedInteractionButton = nil
            }
        }
        if !isCapturedInteraction(button), shouldBlockOwnWindowInput(at: location) {
            dropPendingTapEvents()
        } else {
            flushQueuedTapEventsBeforeImmediateDispatch()
        }
        dispatchMouseUp(at: location, button: button)
    }

    func receiveTapScrollWheel(_ payload: MouseScrollIntake) -> Bool {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return false
        }
        let suppress = shouldSuppressScroll(
            at: payload.location,
            momentumPhase: payload.momentumPhase,
            phase: payload.phase,
            modifiers: payload.modifiers
        )
        if suppress, MouseTrace.shared.isActive {
            MouseTrace.record("tap: scroll suppressed loc=\(TraceFormat.point(payload.location))")
        }
        if payload.momentumPhase == 0, payload.phase == 0 {
            EventIntake.post(.mouseScroll(payload))
        } else {
            recordDroppedTrackpadScroll()
        }
        return suppress
    }

    private func shouldSuppressScroll(
        at location: CGPoint,
        momentumPhase: UInt32,
        phase: UInt32,
        modifiers: CGEventFlags
    ) -> Bool {
        let isTrackpad = momentumPhase != 0 || phase != 0
        if isTrackpad { return suppressTrackpadScroll(momentumPhase: momentumPhase, phase: phase) }

        guard let controller, controller.isEnabled,
              controller.settings.gestures.trackpadGesturesEnabled
        else {
            return false
        }
        if controller.isOverviewOpen() { return false }
        if shouldBlockOwnWindowInput(at: location) { return false }
        guard !state.isResizing, !state.isMoving else { return false }
        guard controller.settings.gestures.scrollEnabled else { return false }
        let requiredModifiers = controller.settings.gestures.scrollModifierKey.cgEventFlag
        guard Self.mouseWheelModifiersMatch(modifiers, required: requiredModifiers) else { return false }
        return resolveScrollContext(at: location) != nil
    }

    private func suppressTrackpadScroll(momentumPhase: UInt32, phase: UInt32) -> Bool {
        if isTrackpadSwipeSessionActive { return true }
        if state.consumeTrackpadScrollUntilAllTouchesLift { return true }
        if state.suppressTrackpadMomentumScroll {
            if momentumPhase != 0 { return true }
            if phase == CGScrollPhase.ended.rawValue || phase == CGScrollPhase.cancelled.rawValue {
                return true
            }
            state.suppressTrackpadMomentumScroll = false
        }
        return false
    }

    func receiveTapGestureEvent(_ snapshot: GestureEventSnapshot) {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return
        }
        guard shouldProcessGestureFrame(snapshot) else { return }
        if shouldBlockOwnWindowInput(at: snapshot.location) {
            dropPendingTapEvents()
        } else {
            flushQueuedTapEventsBeforeImmediateDispatch()
        }
        handleGestureEvent(snapshot)
    }

    private func shouldProcessGestureFrame(_ snapshot: GestureEventSnapshot) -> Bool {
        guard state.gesturePhase == .idle else { return true }
        let activeTouchCount = Self.activeTouchCount(in: snapshot.touches)
        guard activeTouchCount > 0 else {
            state.suppressGestureStartUntilAllTouchesLift = false
            state.consumeTrackpadScrollUntilAllTouchesLift = false
            return true
        }
        if state.suppressGestureStartUntilAllTouchesLift { return false }
        guard let config = trackpadGestureConfig else { return false }
        return TrackpadGestureIntent.allowsGestureStart(config, fingerCount: activeTouchCount)
    }

    nonisolated static func activeTouchCount(in touches: [GestureTouchSample]) -> Int {
        touches.count(where: { $0.phase != .ended && $0.phase != .cancelled })
    }

    func dropPendingTapEvents() {
        controller?.eventIntake.removePendingMouseEvents()
    }

    private func flushQueuedTapEventsBeforeImmediateDispatch() {
        controller?.eventIntake.drainNow()
    }

    func dispatchQueuedMouseDragged(at location: CGPoint, button: MouseButton) {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return
        }
        controller?.mouseWarpHandler.handleMouseWarpMoved(at: location)
        recordMouseWarpSample()
        beginNativeTitleBarDragIfNeeded(button: button)
        if shouldBlockOwnWindowInput(at: location) {
            cancelActiveMouseInteraction()
            return
        }
        handleMouseDraggedFromTap(at: location, button: button, requirePressedButtonCheck: false)
    }
}

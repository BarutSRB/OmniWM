// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    private func handleDwindleMoveDrag(at location: CGPoint) {
        guard let controller, let engine = controller.dwindleEngine, let move = engine.interactiveMove else {
            cancelActiveMouseInteraction()
            return
        }
        let now = controller.animationClock.now()
        state.dragGhostController?.updatePosition(cursorLocation: location)
        if let target = engine.interactiveMoveUpdate(currentLocation: location, at: now),
           let frame = engine.presentedFrame(for: target, in: move.workspaceId, at: now)
        {
            state.dragGhostController?.showSwapTarget(frame: frame)
        } else {
            state.dragGhostController?.hideSwapTarget()
        }
    }

    func finishDwindleMove() {
        guard let controller, let engine = controller.dwindleEngine, let move = engine.interactiveMove else { return }
        guard move.targetToken != nil else {
            engine.interactiveMoveCancel()
            return
        }
        let wsId = move.workspaceId
        let swapped = controller.workspaceManager.withEngineMutationScope(
            in: wsId,
            label: "dwindle_mouse_swap",
            source: .mouse
        ) {
            engine.interactiveMoveEnd() != nil
        }
        guard swapped else { return }
        controller.workspaceManager.recordLayoutOperation(.windowsSwapped, in: wsId, source: .mouse)
        if controller.hasStartedServices {
            controller.layoutRefreshController.requestImmediateRelayout(reason: .interactiveGesture)
        }
    }

    func finishNiriMove(at location: CGPoint) {
        guard let controller else { return }
        guard let engine = controller.niriEngine, let move = engine.interactiveMove else {
            controller.niriEngine?.interactiveMoveCancel()
            return
        }
        let wsId = move.workspaceId
        guard let monitor = controller.workspaceManager.monitor(for: wsId) else {
            engine.interactiveMoveCancel()
            return
        }
        let geometry = controller.niriInteractionGeometry(for: monitor)
        let movedToken = move.windowToken
        var didEnd = false
        controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
            didEnd = engine.interactiveMoveEnd(
                at: location,
                motion: controller.motionPolicy.snapshot(),
                state: &vstate,
                workingFrame: geometry.workingFrame,
                gaps: geometry.innerGap
            )
        }
        guard didEnd else { return }
        controller.workspaceManager.recordLayoutOperation(
            .interactiveMoveEnded(token: movedToken),
            in: wsId,
            source: .mouse
        )
        controller.layoutRefreshController.requestImmediateRelayout(reason: .interactiveGesture)
    }

    func handleMouseDraggedFromTap(
        at location: CGPoint,
        button: MouseButton,
        requirePressedButtonCheck: Bool = true
    ) {
        guard let controller else { return }
        guard canHandleManagedMouseInteraction(controller: controller) else { return }
        if requirePressedButtonCheck {
            guard pressedMouseButtonsProvider() & button.pressedMask != 0 else {
                cancelActiveMouseInteraction()
                return
            }
        }

        if state.isMoving {
            guard shouldAcceptInteractionButton(button) else { return }
            if state.moveLayout == .dwindle {
                handleDwindleMoveDrag(at: location)
                return
            }
            updateNiriMove(at: location)
            return
        }

        guard state.isResizing else { return }
        guard shouldAcceptInteractionButton(button) else { return }

        updateManagedResize(at: location)
    }

    func canHandleManagedMouseInteraction(controller: WMController) -> Bool {
        guard controller.isEnabled else {
            cancelActiveMouseInteraction()
            return false
        }
        if controller.isOverviewOpen() {
            cancelActiveMouseInteraction()
            return false
        }

        return true
    }

    private func updateNiriMove(at location: CGPoint) {
        guard let controller else { return }
        guard let engine = controller.niriEngine,
              let move = engine.interactiveMove
        else {
            cancelActiveMouseInteraction()
            return
        }
        let wsId = move.workspaceId

        let hoverTarget = engine.interactiveMoveUpdate(currentLocation: location)
        state.dragGhostController?.updatePosition(cursorLocation: location)

        if let hoverTarget {
            switch hoverTarget {
            case let .window(nodeId, handle, insertPosition):
                if insertPosition == .swap {
                    if let entry = controller.workspaceManager.entry(for: handle),
                       let frame = AXWindowService.framePreferFast(entry.axRef)
                    {
                        state.dragGhostController?.showSwapTarget(frame: frame)
                    }
                } else if let dropFrame = engine.insertionDropzoneFrame(
                    targetWindowId: nodeId,
                    position: insertPosition,
                    in: wsId,
                    gaps: move.gaps,
                    orientation: move.orientation
                ) {
                    state.dragGhostController?.showSwapTarget(frame: dropFrame)
                }
            default:
                state.dragGhostController?.hideSwapTarget()
            }
        } else {
            state.dragGhostController?.hideSwapTarget()
        }
    }

    private func updateManagedResize(at location: CGPoint) {
        guard let controller else { return }
        if state.resizeLayout == .dwindle {
            guard let engine = controller.dwindleEngine,
                  let wsId = engine.interactiveResize?.workspaceId
            else {
                cancelActiveMouseInteraction()
                return
            }
            if engine.interactiveResizeUpdate(currentLocation: location) {
                controller.layoutRefreshController.renderDwindleInteractiveResize(for: wsId)
            }
            return
        }

        guard let engine = controller.niriEngine,
              let resize = engine.interactiveResize,
              let monitor = controller.workspaceManager.monitor(for: resize.workspaceId)
        else {
            cancelActiveMouseInteraction()
            return
        }

        let geometry = controller.niriInteractionGeometry(for: monitor)
        let gaps = LayoutGaps(
            horizontal: geometry.innerGap,
            vertical: geometry.innerGap
        )
        let wsId = resize.workspaceId

        if engine.interactiveResizeUpdate(
            currentLocation: location,
            monitorFrame: geometry.workingFrame,
            gaps: gaps,
            viewportState: { mutate in
                controller.workspaceManager.withNiriViewportState(for: wsId, mutate)
            }
        ) {
            controller.layoutRefreshController.renderInteractiveResize(for: wsId)
        }
    }
}

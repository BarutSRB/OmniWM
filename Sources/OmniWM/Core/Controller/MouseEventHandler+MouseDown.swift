// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    func handleMouseDownFromTap(
        at location: CGPoint,
        modifiers: CGEventFlags,
        button: MouseButton,
        windowIdUnderPointer: Int?
    ) -> Bool {
        guard let controller else { return false }
        guard canHandleManagedMouseInteraction(controller: controller) else { return false }

        if shouldBlockOwnWindowInput(at: location) {
            return false
        }
        guard !state.isMoving, !state.isResizing else { return false }

        guard let wsId = workspaceIdForPointer(at: location) ?? controller.activeWorkspace()?.id else {
            return false
        }

        if button == .left, modifiers.isDisjoint(with: Self.relevantModifierFlags) {
            recordPointerFocusIntent(at: location, workspaceId: wsId, windowIdUnderPointer: windowIdUnderPointer)
        }

        let layoutType = controller.workspaceManager.descriptor(for: wsId)
            .map { controller.settings.workspaces.layoutType(for: $0.name) }
        if layoutType == .dwindle {
            return handleDwindleMouseDown(at: location, modifiers: modifiers, button: button, wsId: wsId)
        }

        guard let engine = controller.niriEngine else { return false }

        if button == .left,
           let moveMode = Self.mouseMoveMode(
               modifiers: modifiers,
               required: controller.settings.gestures.mouseMoveModifierKey.cgEventFlags
           )
        {
            beginNiriMove(at: location, mode: moveMode, engine: engine, workspaceId: wsId, button: button)
            return false
        }

        guard button == .right,
              Self.modifierFlagsMatch(
                  modifiers,
                  required: controller.settings.gestures.mouseResizeModifierKey.cgEventFlag
              )
        else { return false }

        return beginNiriResize(at: location, engine: engine, workspaceId: wsId, button: button)
    }

    private func recordPointerFocusIntent(
        at location: CGPoint, workspaceId wsId: WorkspaceDescriptor.ID, windowIdUnderPointer: Int?
    ) {
        guard let controller else { return }
        state.awaitsNativeTitleBarDragTarget = windowIdUnderPointer == nil
        state.nativeTitleBarDragFallbackReleased = false
        let exactToken = nativeTitleBarDragCandidate(windowIdUnderPointer: windowIdUnderPointer)
        let focusIntentToken = exactToken ?? (windowIdUnderPointer == nil
            ? geometricFocusIntentCandidate(at: location, workspaceId: wsId)
            : nil)
        if let token = focusIntentToken {
            controller.axEventHandler.noteMouseFocusIntent(token: token)
        } else {
            controller.axEventHandler.noteUnmanagedPointerClick()
        }
        state.nativeTitleBarDragFallbackToken = exactToken == nil ? focusIntentToken : nil
        if let exactToken {
            state.awaitsNativeTitleBarDragTarget = false
            let token = exactToken
            state.nativeTitleBarDrag = .init(token: token)
        }
    }

    private func beginNiriMove(
        at location: CGPoint, mode moveMode: MouseMoveMode, engine: NiriLayoutEngine,
        workspaceId wsId: WorkspaceDescriptor.ID, button: MouseButton
    ) {
        guard let controller,
              let tiledWindow = engine.hitTestTiled(point: location, in: wsId),
              let monitor = controller.workspaceManager.monitor(for: wsId)
        else { return }
        let geometry = controller.niriInteractionGeometry(for: monitor)
        let orientation = resolvedNiriOrientation(
            engine: engine,
            workspaceId: wsId,
            monitor: monitor
        )

        let isInsertMode = moveMode == .insert
        var moveStarted = false
        controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
            if engine.interactiveMoveBegin(
                windowId: tiledWindow.id,
                windowToken: tiledWindow.token,
                startLocation: location,
                isInsertMode: isInsertMode,
                context: .init(
                    workspaceId: wsId,
                    motion: controller.motionPolicy.snapshot(),
                    workingFrame: geometry.workingFrame,
                    gaps: geometry.innerGap,
                    orientation: orientation
                ),
                state: &vstate
            ) {
                moveStarted = true
            }
        }
        if moveStarted {
            state.isMoving = true
            state.moveLayout = .niri
            state.activeInteractionButton = button
            state.capturedInteractionButton = button
            NSCursor.closedHand.set()

            showNiriDragGhost(for: tiledWindow.token, at: location)
            return
        }
    }

    private func showNiriDragGhost(for token: WindowToken, at location: CGPoint) {
        guard let controller else { return }
        if let entry = controller.workspaceManager.entry(for: token),
           let frame = AXWindowService.framePreferFast(entry.axRef)
        {
            if state.dragGhostController == nil {
                state.dragGhostController = DragGhostController()
            }
            state.dragGhostController?.beginDrag(
                windowId: entry.windowId,
                originalFrame: frame,
                cursorLocation: location
            )
        }
    }

    private func beginNiriResize(
        at location: CGPoint, engine: NiriLayoutEngine, workspaceId wsId: WorkspaceDescriptor.ID, button: MouseButton
    ) -> Bool {
        guard let controller else { return false }
        guard let monitor = controller.workspaceManager.monitor(for: wsId) else { return false }
        let tiledWindow = engine.hitTestTiled(point: location, in: wsId)
            ?? focusedBorderResizeToken(
                at: location,
                in: wsId,
                scale: controller.backingScaleFactor(for: monitor),
                appliedBorder: controller.surfaceReconciler.appliedScene.border
            ).flatMap { engine.findNode(for: $0, in: wsId) }
        guard let tiledWindow,
              let frame = tiledWindow.renderedFrame ?? tiledWindow.frame
        else { return false }

        let edges = resizeEdges(for: location, in: frame)
        let currentViewOffset = controller.workspaceManager.niriViewportState(for: wsId).viewOffset
        let orientation = resolvedNiriOrientation(
            engine: engine,
            workspaceId: wsId,
            monitor: monitor
        )
        if engine.interactiveResizeBegin(
            windowId: tiledWindow.id,
            edges: edges,
            startLocation: location,
            in: wsId,
            orientation: orientation,
            viewOffset: currentViewOffset
        ) {
            state.isResizing = true
            state.activeInteractionButton = button
            state.capturedInteractionButton = button
            state.currentHoveredEdges = edges
            controller.niriLayoutHandler.cancelActiveAnimations(for: wsId)
            edges.cursor.set()
            return true
        }
        return false
    }

    private func handleDwindleMouseDown(
        at location: CGPoint,
        modifiers: CGEventFlags,
        button: MouseButton,
        wsId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller, let engine = controller.dwindleEngine else { return false }
        if button == .left {
            return beginDwindleMove(at: location, modifiers: modifiers, engine: engine, wsId: wsId)
        }
        guard button == .right,
              Self.modifierFlagsMatch(
                  modifiers,
                  required: controller.settings.gestures.mouseResizeModifierKey.cgEventFlag
              )
        else { return false }

        guard let monitor = controller.workspaceManager.monitor(for: wsId) else { return false }
        let now = controller.animationClock.now()
        let token = engine.hitTestFocusableWindow(point: location, in: wsId, at: now)
            ?? focusedBorderResizeToken(
                at: location,
                in: wsId,
                scale: controller.backingScaleFactor(for: monitor),
                appliedBorder: controller.surfaceReconciler.appliedScene.border
            )
        guard let token,
              let node = engine.findNode(for: token, in: wsId),
              let frame = node.presentedFrame(at: now)
        else { return false }

        let edges = resizeEdges(for: location, in: frame)
        controller.dwindleLayoutHandler.refreshEngineConstraints(workspaceId: wsId, monitor: monitor)
        let innerGap = controller.resolvedDwindleSettings(for: monitor).innerGap
        guard engine.interactiveResizeBegin(
            token: token,
            edges: edges,
            startLocation: location,
            in: wsId,
            innerGap: innerGap
        ) else {
            return false
        }

        controller.layoutRefreshController.stopDwindleAnimation(for: monitor.displayId)
        engine.cancelAnimations(in: wsId)
        state.isResizing = true
        state.activeInteractionButton = button
        state.capturedInteractionButton = button
        state.currentHoveredEdges = edges
        state.resizeLayout = .dwindle
        edges.cursor.set()
        return true
    }

    private func beginDwindleMove(
        at location: CGPoint,
        modifiers: CGEventFlags,
        engine: DwindleLayoutEngine,
        wsId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller else { return false }
        let now = controller.animationClock.now()
        guard Self.mouseMoveMode(
            modifiers: modifiers,
            required: controller.settings.gestures.mouseMoveModifierKey.cgEventFlags
        ) == .swap,
            let token = engine.hitTestFocusableWindow(point: location, in: wsId, at: now),
            let frame = engine.presentedFrame(for: token, in: wsId, at: now),
            engine.interactiveMoveBegin(token: token, startLocation: location, in: wsId)
        else { return false }

        state.isMoving = true
        state.moveLayout = .dwindle
        state.activeInteractionButton = .left
        state.capturedInteractionButton = .left
        NSCursor.closedHand.set()
        if state.dragGhostController == nil {
            state.dragGhostController = DragGhostController()
        }
        state.dragGhostController?.beginDrag(windowId: token.windowId, originalFrame: frame, cursorLocation: location)
        return false
    }

    func focusedBorderResizeToken(
        at location: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        scale: CGFloat,
        appliedBorder: DesiredBorderSurface?
    ) -> WindowToken? {
        guard let controller,
              let appliedBorder,
              appliedBorder.token == controller.workspaceManager.borderFocusToken,
              let entry = controller.workspaceManager.entry(for: appliedBorder.token),
              entry.workspaceId == workspaceId,
              entry.mode == .tiling
        else {
            return nil
        }
        let geometry = appliedBorder.config.resolvedGeometry(for: appliedBorder.frame, scale: scale)
        guard geometry.width > 0,
              geometry.surfaceFrame.contains(location),
              !geometry.targetFrame.contains(location)
        else {
            return nil
        }
        return appliedBorder.token
    }

    private func resizeEdges(for location: CGPoint, in frame: CGRect) -> ResizeEdge {
        var edges: ResizeEdge = location.x < frame.midX ? [.left] : [.right]
        edges.insert(location.y < frame.midY ? .bottom : .top)
        return edges
    }

    func shouldAcceptInteractionButton(_ button: MouseButton) -> Bool {
        state.activeInteractionButton == nil || state.activeInteractionButton == button
    }

    func isCapturedInteraction(_ button: MouseButton) -> Bool {
        state.capturedInteractionButton == button
    }
}

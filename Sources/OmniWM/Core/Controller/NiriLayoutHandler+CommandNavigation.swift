// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension NiriLayoutHandler {
    func focusDownOrLeftInNiri() {
        executeCombinedNavigation { engine, currentNode, context, state in
            engine.focusDownOrLeft(
                currentSelection: currentNode,
                context: context,
                state: &state
            )
        }
    }

    func focusUpOrRightInNiri() {
        executeCombinedNavigation { engine, currentNode, context, state in
            engine.focusUpOrRight(
                currentSelection: currentNode,
                context: context,
                state: &state
            )
        }
    }

    func focusWindowInColumnInNiri(index: Int) {
        executeCombinedNavigation { engine, currentNode, context, state in
            engine.focusWindowInColumn(
                index,
                currentSelection: currentNode,
                context: context,
                state: &state
            )
        }
    }

    func focusWindowTopInNiri() {
        executeCombinedNavigation { engine, currentNode, context, state in
            engine.focusWindowTop(
                currentSelection: currentNode,
                context: context,
                state: &state
            )
        }
    }

    func focusWindowBottomInNiri() {
        executeCombinedNavigation { engine, currentNode, context, state in
            engine.focusWindowBottom(
                currentSelection: currentNode,
                context: context,
                state: &state
            )
        }
    }

    func focusWindowDownOrTopInNiri() {
        executeCombinedNavigation { engine, currentNode, context, state in
            engine.focusWindowDownOrTop(
                currentSelection: currentNode,
                context: context,
                state: &state
            )
        }
    }

    func focusWindowUpOrBottomInNiri() {
        executeCombinedNavigation { engine, currentNode, context, state in
            engine.focusWindowUpOrBottom(
                currentSelection: currentNode,
                context: context,
                state: &state
            )
        }
    }

    func focusWindowOrWorkspaceInNiri(direction: Direction) {
        guard direction == .down || direction == .up else { return }
        executeCombinedNavigation(onNoTarget: { [weak self] in
            self?.controller?.workspaceNavigationHandler.switchWorkspaceRelative(
                isNext: direction == .down,
                wrapAround: false
            )
        }, { engine, currentNode, context, state in
            engine.focusTarget(
                direction: direction,
                currentSelection: currentNode,
                context: context,
                state: &state
            )
        })
    }

    func focusColumnFirstInNiri() {
        executeCombinedNavigation { engine, currentNode, context, state in
            engine.focusColumnFirst(
                currentSelection: currentNode,
                context: context,
                state: &state
            )
        }
    }

    func focusColumnLastInNiri() {
        executeCombinedNavigation { engine, currentNode, context, state in
            engine.focusColumnLast(
                currentSelection: currentNode,
                context: context,
                state: &state
            )
        }
    }

    func focusColumnInNiri(index: Int) {
        executeCombinedNavigation { engine, currentNode, context, state in
            engine.focusColumn(
                index,
                currentSelection: currentNode,
                context: context,
                state: &state
            )
        }
    }

    private func executeCombinedNavigation(
        onNoTarget: (() -> Void)? = nil,
        _ navigationAction: (
            NiriLayoutEngine,
            NiriNode,
            NiriInteractionContext,
            inout ViewportState
        )
            -> NiriNode?
    ) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }
        guard let monitor = controller.workspaceManager.monitor(for: wsId) else { return }

        var state = controller.workspaceManager.niriViewportState(for: wsId)
        guard let currentNode = navigationSelection(engine: engine, workspaceId: wsId, state: &state) else {
            onNoTarget?()
            return
        }

        let gap = controller.innerGap(for: monitor)
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let motion = controller.motionPolicy.snapshot()
        let orientation = controller.settings.monitors.effectiveOrientation(for: monitor)
        let context = NiriInteractionContext(
            workspaceId: wsId,
            motion: motion,
            workingFrame: workingFrame,
            gaps: gap,
            orientation: orientation
        )
        guard let newNode = controller.workspaceManager.withEngineMutationScope(label: "focus_navigation", {
            navigationAction(engine, currentNode, context, &state)
        }) else {
            onNoTarget?()
            return
        }
        controller.niriLayoutHandler.activateNode(
            newNode, in: wsId, state: &state,
            options: .init(
                activateWindow: false,
                ensureVisible: false,
                layoutRefresh: false,
                axFocus: false
            )
        )
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: wsId,
                viewportState: state,
                rememberedFocusToken: nil,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
        controller.niriLayoutHandler.focusSelectedWindowAndRequestRelayout(in: wsId)
    }

    private func navigationSelection(
        engine: NiriLayoutEngine,
        workspaceId wsId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) -> NiriNode? {
        guard let controller else { return nil }
        if let currentId = state.selectedNodeId,
           let node = engine.findNode(by: currentId, in: wsId)
        {
            return node
        } else if let lastFocused = controller.workspaceManager.lastFocusedToken(in: wsId),
                  let node = engine.findNode(for: lastFocused, in: wsId)
        {
            state.selectedNodeId = node.id
            return node
        } else if let selectedId = engine.validateSelection(state.selectedNodeId, in: wsId),
                  let node = engine.findNode(by: selectedId, in: wsId)
        {
            state.selectedNodeId = selectedId
            return node
        } else {
            return nil
        }
    }
}

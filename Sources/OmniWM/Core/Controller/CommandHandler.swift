import AppKit
import Foundation

@MainActor
final class CommandHandler {
    private weak var controller: WMController?

    private var pendingNavigationTask: Task<Void, Never>?
    private var isProcessingNavigation = false
    private var navigationQueue: [Direction] = []

    init(controller: WMController) {
        self.controller = controller
    }

    func cleanup() {
        pendingNavigationTask?.cancel()
        pendingNavigationTask = nil
        isProcessingNavigation = false
        navigationQueue.removeAll()
    }

    func handle(_ command: HotkeyCommand) {
        guard let controller else { return }
        guard controller.isEnabled else { return }

        switch command {
        case let .focus(direction):
            focusNeighborInNiri(direction: direction)
        case .focusPrevious:
            focusPreviousInNiri()
        case let .move(direction):
            moveWindowInNiri(direction: direction)
        case let .swap(direction):
            swapWindowInNiri(direction: direction)
        case let .moveToWorkspace(index):
            controller.internalWorkspaceNavigationHandler?.moveFocusedWindow(toWorkspaceIndex: index)
        case .moveWindowToWorkspaceUp:
            controller.internalWorkspaceNavigationHandler?.moveWindowToAdjacentWorkspace(direction: .up)
        case .moveWindowToWorkspaceDown:
            controller.internalWorkspaceNavigationHandler?.moveWindowToAdjacentWorkspace(direction: .down)
        case let .moveColumnToWorkspace(index):
            controller.internalWorkspaceNavigationHandler?.moveColumnToWorkspaceByIndex(index: index)
        case .moveColumnToWorkspaceUp:
            controller.internalWorkspaceNavigationHandler?.moveColumnToAdjacentWorkspace(direction: .up)
        case .moveColumnToWorkspaceDown:
            controller.internalWorkspaceNavigationHandler?.moveColumnToAdjacentWorkspace(direction: .down)
        case let .switchWorkspace(index):
            controller.internalWorkspaceNavigationHandler?.switchWorkspace(index: index)
        case let .moveToMonitor(direction):
            controller.internalWorkspaceNavigationHandler?.moveFocusedWindowToMonitor(direction: direction)
        case let .focusMonitor(direction):
            controller.internalWorkspaceNavigationHandler?.focusMonitorInDirection(direction)
        case .focusMonitorPrevious:
            controller.internalWorkspaceNavigationHandler?.focusMonitorCyclic(previous: true)
        case .focusMonitorNext:
            controller.internalWorkspaceNavigationHandler?.focusMonitorCyclic(previous: false)
        case .focusMonitorLast:
            controller.internalWorkspaceNavigationHandler?.focusLastMonitor()
        case let .moveColumnToMonitor(direction):
            controller.internalWorkspaceNavigationHandler?.moveColumnToMonitorInDirection(direction)
        case .toggleFullscreen:
            toggleNiriFullscreen()
        case .toggleNativeFullscreen:
            toggleNativeFullscreenForFocused()
        case let .moveColumn(direction):
            moveColumnInNiri(direction: direction)
        case let .consumeWindow(direction):
            consumeWindowInNiri(direction: direction)
        case let .expelWindow(direction):
            expelWindowInNiri(direction: direction)
        case .toggleColumnTabbed:
            toggleColumnTabbedInNiri()
        case .focusDownOrLeft:
            focusDownOrLeftInNiri()
        case .focusUpOrRight:
            focusUpOrRightInNiri()
        case .focusColumnFirst:
            focusColumnFirstInNiri()
        case .focusColumnLast:
            focusColumnLastInNiri()
        case let .focusColumn(index):
            focusColumnInNiri(index: index)
        case .focusWindowTop:
            focusWindowTopInNiri()
        case .focusWindowBottom:
            focusWindowBottomInNiri()
        case .cycleColumnWidthForward:
            cycleColumnWidthInNiri(forwards: true)
        case .cycleColumnWidthBackward:
            cycleColumnWidthInNiri(forwards: false)
        case .toggleColumnFullWidth:
            toggleColumnFullWidthInNiri()
        case let .moveWorkspaceToMonitor(direction):
            controller.internalWorkspaceNavigationHandler?.moveCurrentWorkspaceToMonitor(direction: direction)
        case .balanceSizes:
            balanceSizesInNiri()
        case let .summonWorkspace(index):
            controller.internalWorkspaceNavigationHandler?.summonWorkspace(index: index)
        case .openWindowFinder:
            controller.openWindowFinder()
        case .raiseAllFloatingWindows:
            controller.raiseAllFloatingWindows()
        case .openMenuAnywhere:
            controller.openMenuAnywhere()
        case .openMenuPalette:
            controller.openMenuPalette()
        }
    }

    private func focusNeighborInNiri(direction: Direction) {
        pendingNavigationTask?.cancel()

        if isProcessingNavigation {
            navigationQueue = [direction]
            pendingNavigationTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000)
                if let self, let queued = navigationQueue.first {
                    navigationQueue.removeAll()
                    executeFocusNeighborInNiri(direction: queued)
                }
            }
            return
        }

        executeFocusNeighborInNiri(direction: direction)
    }

    private func executeFocusNeighborInNiri(direction: Direction) {
        guard let controller else { return }
        isProcessingNavigation = true
        defer { isProcessingNavigation = false }

        var animatingWorkspaceId: WorkspaceDescriptor.ID?

        controller.internalLayoutRefreshController?.runLightSession {
            guard let engine = controller.internalNiriEngine else { return }
            guard let wsId = controller.activeWorkspace()?.id else { return }
            var state = controller.internalWorkspaceManager.niriViewportState(for: wsId)

            guard let currentId = state.selectedNodeId,
                  let currentNode = engine.findNode(by: currentId)
            else {
                if let lastFocused = controller.internalLastFocusedByWorkspace[wsId],
                   let lastNode = engine.findNode(for: lastFocused)
                {
                    state.selectedNodeId = lastNode.id
                    controller.internalWorkspaceManager.updateNiriViewportState(state, for: wsId)
                    controller.internalFocusedHandle = lastFocused
                    engine.updateFocusTimestamp(for: lastNode.id)
                    controller.focusWindow(lastFocused)
                } else if let firstHandle = controller.internalWorkspaceManager.entries(in: wsId).first?.handle,
                          let firstNode = engine.findNode(for: firstHandle)
                {
                    state.selectedNodeId = firstNode.id
                    controller.internalWorkspaceManager.updateNiriViewportState(state, for: wsId)
                    controller.internalFocusedHandle = firstHandle
                    engine.updateFocusTimestamp(for: firstNode.id)
                    controller.focusWindow(firstHandle)
                }
                return
            }

            guard let monitor = controller.internalWorkspaceManager.monitor(for: wsId) else { return }
            let gap = CGFloat(controller.internalWorkspaceManager.gaps)
            let workingFrame = controller.insetWorkingFrame(from: monitor.visibleFrame)

            if let newNode = engine.focusTarget(
                direction: direction,
                currentSelection: currentNode,
                in: wsId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gap
            ) {
                state.selectedNodeId = newNode.id
                controller.internalWorkspaceManager.updateNiriViewportState(state, for: wsId)

                if let windowNode = newNode as? NiriWindow {
                    controller.internalFocusedHandle = windowNode.handle
                    engine.updateFocusTimestamp(for: windowNode.id)
                }

                controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()

                if let windowNode = newNode as? NiriWindow {
                    controller.focusWindow(windowNode.handle)
                }

                let updatedState = controller.internalWorkspaceManager.niriViewportState(for: wsId)
                if updatedState.viewOffsetPixels.isAnimating {
                    animatingWorkspaceId = wsId
                }
            }
        }

        if let wsId = animatingWorkspaceId {
            controller.internalLayoutRefreshController?.startScrollAnimation(for: wsId)
        }
    }

    private func focusPreviousInNiri() {
        guard let controller else { return }

        var animatingWorkspaceId: WorkspaceDescriptor.ID?

        controller.internalLayoutRefreshController?.runLightSession {
            guard let engine = controller.internalNiriEngine else { return }
            guard let wsId = controller.activeWorkspace()?.id else { return }
            var state = controller.internalWorkspaceManager.niriViewportState(for: wsId)

            if let currentId = state.selectedNodeId {
                engine.updateFocusTimestamp(for: currentId)
            }

            guard let monitor = controller.internalWorkspaceManager.monitor(for: wsId) else { return }
            let gap = CGFloat(controller.internalWorkspaceManager.gaps)
            let workingFrame = controller.insetWorkingFrame(from: monitor.visibleFrame)

            guard let previousWindow = engine.focusPrevious(
                currentNodeId: state.selectedNodeId,
                in: wsId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gap,
                limitToWorkspace: true
            ) else {
                return
            }

            state.selectedNodeId = previousWindow.id
            controller.internalWorkspaceManager.updateNiriViewportState(state, for: wsId)

            controller.internalFocusedHandle = previousWindow.handle

            controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()
            controller.focusWindow(previousWindow.handle)

            let updatedState = controller.internalWorkspaceManager.niriViewportState(for: wsId)
            if updatedState.viewOffsetPixels.isAnimating {
                animatingWorkspaceId = wsId
            }
        }

        if let wsId = animatingWorkspaceId {
            controller.internalLayoutRefreshController?.startScrollAnimation(for: wsId)
        }
    }

    private func focusDownOrLeftInNiri() {
        executeCombinedNavigation { engine, currentNode, wsId, state, workingFrame, gaps in
            engine.focusDownOrLeft(currentSelection: currentNode, in: wsId, state: &state, workingFrame: workingFrame, gaps: gaps)
        }
    }

    private func focusUpOrRightInNiri() {
        executeCombinedNavigation { engine, currentNode, wsId, state, workingFrame, gaps in
            engine.focusUpOrRight(currentSelection: currentNode, in: wsId, state: &state, workingFrame: workingFrame, gaps: gaps)
        }
    }

    private func focusColumnFirstInNiri() {
        executeCombinedNavigation { engine, currentNode, wsId, state, workingFrame, gaps in
            engine.focusColumnFirst(currentSelection: currentNode, in: wsId, state: &state, workingFrame: workingFrame, gaps: gaps)
        }
    }

    private func focusColumnLastInNiri() {
        executeCombinedNavigation { engine, currentNode, wsId, state, workingFrame, gaps in
            engine.focusColumnLast(currentSelection: currentNode, in: wsId, state: &state, workingFrame: workingFrame, gaps: gaps)
        }
    }

    private func focusColumnInNiri(index: Int) {
        executeCombinedNavigation { engine, currentNode, wsId, state, workingFrame, gaps in
            engine.focusColumn(index, currentSelection: currentNode, in: wsId, state: &state, workingFrame: workingFrame, gaps: gaps)
        }
    }

    private func focusWindowTopInNiri() {
        executeCombinedNavigation { engine, currentNode, wsId, state, workingFrame, gaps in
            engine.focusWindowTop(currentSelection: currentNode, in: wsId, state: &state, workingFrame: workingFrame, gaps: gaps)
        }
    }

    private func focusWindowBottomInNiri() {
        executeCombinedNavigation { engine, currentNode, wsId, state, workingFrame, gaps in
            engine.focusWindowBottom(currentSelection: currentNode, in: wsId, state: &state, workingFrame: workingFrame, gaps: gaps)
        }
    }

    private func cycleColumnWidthInNiri(forwards: Bool) {
        guard let controller else { return }

        controller.internalLayoutRefreshController?.runLightSession {
            guard let engine = controller.internalNiriEngine else { return }
            guard let wsId = controller.activeWorkspace()?.id else { return }
            let state = controller.internalWorkspaceManager.niriViewportState(for: wsId)

            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId) as? NiriWindow,
                  let column = engine.findColumn(containing: windowNode, in: wsId)
            else {
                return
            }

            engine.toggleColumnWidth(column, forwards: forwards)
            controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()
        }
    }

    private func toggleColumnFullWidthInNiri() {
        guard let controller else { return }

        controller.internalLayoutRefreshController?.runLightSession {
            guard let engine = controller.internalNiriEngine else { return }
            guard let wsId = controller.activeWorkspace()?.id else { return }
            let state = controller.internalWorkspaceManager.niriViewportState(for: wsId)

            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId) as? NiriWindow,
                  let column = engine.findColumn(containing: windowNode, in: wsId)
            else {
                return
            }

            engine.toggleFullWidth(column)
            controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()
        }
    }

    private func executeCombinedNavigation(
        _ navigationAction: (NiriLayoutEngine, NiriNode, WorkspaceDescriptor.ID, inout ViewportState, CGRect, CGFloat) -> NiriNode?
    ) {
        guard let controller else { return }
        guard let engine = controller.internalNiriEngine else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }
        guard let monitor = controller.internalWorkspaceManager.monitor(for: wsId) else { return }
        var state = controller.internalWorkspaceManager.niriViewportState(for: wsId)

        guard let currentId = state.selectedNodeId,
              let currentNode = engine.findNode(by: currentId)
        else {
            return
        }

        let gap = CGFloat(controller.internalWorkspaceManager.gaps)
        let workingFrame = controller.insetWorkingFrame(from: monitor.visibleFrame)
        guard let newNode = navigationAction(engine, currentNode, wsId, &state, workingFrame, gap) else {
            return
        }

        state.selectedNodeId = newNode.id
        controller.internalWorkspaceManager.updateNiriViewportState(state, for: wsId)

        if let windowNode = newNode as? NiriWindow {
            controller.internalFocusedHandle = windowNode.handle
            engine.updateFocusTimestamp(for: windowNode.id)
        }

        controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()

        if let windowNode = newNode as? NiriWindow {
            controller.focusWindow(windowNode.handle)
        }

        let updatedState = controller.internalWorkspaceManager.niriViewportState(for: wsId)
        if updatedState.viewOffsetPixels.isAnimating {
            controller.internalLayoutRefreshController?.startScrollAnimation(for: wsId)
        }
    }

    private func moveWindowInNiri(direction: Direction) {
        guard let controller else { return }

        var animatingWorkspaceId: WorkspaceDescriptor.ID?

        controller.internalLayoutRefreshController?.runLightSession {
            guard let engine = controller.internalNiriEngine else { return }
            guard let wsId = controller.activeWorkspace()?.id else { return }
            var state = controller.internalWorkspaceManager.niriViewportState(for: wsId)

            guard let currentId = state.selectedNodeId,
                  let currentNode = engine.findNode(by: currentId),
                  let windowNode = currentNode as? NiriWindow
            else {
                return
            }

            guard let monitor = controller.internalWorkspaceManager.monitor(for: wsId) else { return }
            let workingFrame = controller.insetWorkingFrame(from: monitor.visibleFrame)
            let gaps = CGFloat(controller.internalWorkspaceManager.gaps)

            let oldFrames = engine.captureWindowFrames(in: wsId)

            if engine.moveWindow(windowNode, direction: direction, in: wsId, state: &state, workingFrame: workingFrame, gaps: gaps) {
                controller.internalWorkspaceManager.updateNiriViewportState(state, for: wsId)
                controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()

                let newFrames = engine.captureWindowFrames(in: wsId)
                _ = engine.triggerMoveAnimations(in: wsId, oldFrames: oldFrames, newFrames: newFrames)

                let updatedState = controller.internalWorkspaceManager.niriViewportState(for: wsId)
                if updatedState.viewOffsetPixels.isAnimating || engine.hasAnyWindowAnimationsRunning(in: wsId) {
                    animatingWorkspaceId = wsId
                }
            }
        }

        if let wsId = animatingWorkspaceId {
            controller.internalLayoutRefreshController?.startScrollAnimation(for: wsId)
        }
    }

    private func swapWindowInNiri(direction: Direction) {
        guard let controller else { return }

        var animatingWorkspaceId: WorkspaceDescriptor.ID?

        controller.internalLayoutRefreshController?.runLightSession {
            guard let engine = controller.internalNiriEngine else { return }
            guard let wsId = controller.activeWorkspace()?.id else { return }

            var state = controller.internalWorkspaceManager.niriViewportState(for: wsId)
            guard let currentId = state.selectedNodeId,
                  let currentNode = engine.findNode(by: currentId),
                  let windowNode = currentNode as? NiriWindow
            else {
                return
            }

            guard let monitor = controller.internalWorkspaceManager.monitor(for: wsId) else { return }
            let workingFrame = controller.insetWorkingFrame(from: monitor.visibleFrame)
            let gaps = CGFloat(controller.internalWorkspaceManager.gaps)

            let oldFrames = engine.captureWindowFrames(in: wsId)

            if engine.swapWindow(windowNode, direction: direction, in: wsId, state: &state, workingFrame: workingFrame, gaps: gaps) {
                controller.internalWorkspaceManager.updateNiriViewportState(state, for: wsId)
                controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()

                let newFrames = engine.captureWindowFrames(in: wsId)
                _ = engine.triggerMoveAnimations(in: wsId, oldFrames: oldFrames, newFrames: newFrames)

                let updatedState = controller.internalWorkspaceManager.niriViewportState(for: wsId)
                if updatedState.viewOffsetPixels.isAnimating || engine.hasAnyWindowAnimationsRunning(in: wsId) {
                    animatingWorkspaceId = wsId
                }
            }
        }

        if let wsId = animatingWorkspaceId {
            controller.internalLayoutRefreshController?.startScrollAnimation(for: wsId)
        }
    }

    private func toggleNiriFullscreen() {
        guard let controller else { return }

        controller.internalLayoutRefreshController?.runLightSession {
            guard let engine = controller.internalNiriEngine else { return }
            guard let wsId = controller.activeWorkspace()?.id else { return }
            let state = controller.internalWorkspaceManager.niriViewportState(for: wsId)

            guard let currentId = state.selectedNodeId,
                  let currentNode = engine.findNode(by: currentId),
                  let windowNode = currentNode as? NiriWindow
            else {
                return
            }

            if windowNode.sizingMode == .fullscreen {
                windowNode.sizingMode = .normal

                if let savedHeight = windowNode.savedHeight {
                    windowNode.height = savedHeight
                    windowNode.savedHeight = nil
                }
            } else {
                windowNode.savedHeight = windowNode.height
                windowNode.sizingMode = .fullscreen
            }
            controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()
        }
    }

    private func toggleNativeFullscreenForFocused() {
        guard let controller else { return }
        guard let handle = controller.internalFocusedHandle else { return }
        guard let entry = controller.internalWorkspaceManager.entry(for: handle) else { return }

        let currentState = AXWindowService.isFullscreen(entry.axRef)
        let newState = !currentState

        _ = AXWindowService.setNativeFullscreen(entry.axRef, fullscreen: newState)

        if newState {
            controller.internalBorderManager.hideBorder()
        }
    }

    private func moveColumnInNiri(direction: Direction) {
        guard let controller else { return }

        var animatingWorkspaceId: WorkspaceDescriptor.ID?

        controller.internalLayoutRefreshController?.runLightSession {
            guard let engine = controller.internalNiriEngine else { return }
            guard let wsId = controller.activeWorkspace()?.id else { return }
            var state = controller.internalWorkspaceManager.niriViewportState(for: wsId)

            guard let currentId = state.selectedNodeId,
                  let currentNode = engine.findNode(by: currentId),
                  let windowNode = currentNode as? NiriWindow,
                  let column = engine.findColumn(containing: windowNode, in: wsId)
            else {
                return
            }

            guard let monitor = controller.internalWorkspaceManager.monitor(for: wsId) else { return }
            let workingFrame = controller.insetWorkingFrame(from: monitor.visibleFrame)
            let gaps = CGFloat(controller.internalWorkspaceManager.gaps)

            let oldFrames = engine.captureWindowFrames(in: wsId)

            if engine.moveColumn(column, direction: direction, in: wsId, state: &state, workingFrame: workingFrame, gaps: gaps) {
                controller.internalWorkspaceManager.updateNiriViewportState(state, for: wsId)
                controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()

                let newFrames = engine.captureWindowFrames(in: wsId)
                _ = engine.triggerMoveAnimations(in: wsId, oldFrames: oldFrames, newFrames: newFrames)

                let updatedState = controller.internalWorkspaceManager.niriViewportState(for: wsId)
                if updatedState.viewOffsetPixels.isAnimating || engine.hasAnyWindowAnimationsRunning(in: wsId) {
                    animatingWorkspaceId = wsId
                }
            }
        }

        if let wsId = animatingWorkspaceId {
            controller.internalLayoutRefreshController?.startScrollAnimation(for: wsId)
        }
    }

    private func consumeWindowInNiri(direction: Direction) {
        guard let controller else { return }

        var animatingWorkspaceId: WorkspaceDescriptor.ID?

        controller.internalLayoutRefreshController?.runLightSession {
            guard let engine = controller.internalNiriEngine else { return }
            guard let wsId = controller.activeWorkspace()?.id else { return }
            var state = controller.internalWorkspaceManager.niriViewportState(for: wsId)

            guard let currentId = state.selectedNodeId,
                  let currentNode = engine.findNode(by: currentId),
                  let windowNode = currentNode as? NiriWindow
            else {
                return
            }

            guard let monitor = controller.internalWorkspaceManager.monitor(for: wsId) else { return }
            let workingFrame = controller.insetWorkingFrame(from: monitor.visibleFrame)
            let gaps = CGFloat(controller.internalWorkspaceManager.gaps)

            if engine.consumeWindow(into: windowNode, from: direction, in: wsId, state: &state, workingFrame: workingFrame, gaps: gaps) {
                controller.internalWorkspaceManager.updateNiriViewportState(state, for: wsId)
                controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()

                let updatedState = controller.internalWorkspaceManager.niriViewportState(for: wsId)
                if updatedState.viewOffsetPixels.isAnimating {
                    animatingWorkspaceId = wsId
                }
            }
        }

        if let wsId = animatingWorkspaceId {
            controller.internalLayoutRefreshController?.startScrollAnimation(for: wsId)
        }
    }

    private func expelWindowInNiri(direction: Direction) {
        guard let controller else { return }

        var animatingWorkspaceId: WorkspaceDescriptor.ID?

        controller.internalLayoutRefreshController?.runLightSession {
            guard let engine = controller.internalNiriEngine else { return }
            guard let wsId = controller.activeWorkspace()?.id else { return }
            var state = controller.internalWorkspaceManager.niriViewportState(for: wsId)

            guard let currentId = state.selectedNodeId,
                  let currentNode = engine.findNode(by: currentId),
                  let windowNode = currentNode as? NiriWindow
            else {
                return
            }

            guard let monitor = controller.internalWorkspaceManager.monitor(for: wsId) else { return }
            let workingFrame = controller.insetWorkingFrame(from: monitor.visibleFrame)
            let gaps = CGFloat(controller.internalWorkspaceManager.gaps)

            if engine.expelWindow(windowNode, to: direction, in: wsId, state: &state, workingFrame: workingFrame, gaps: gaps) {
                controller.internalWorkspaceManager.updateNiriViewportState(state, for: wsId)
                controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()

                let updatedState = controller.internalWorkspaceManager.niriViewportState(for: wsId)
                if updatedState.viewOffsetPixels.isAnimating {
                    animatingWorkspaceId = wsId
                }
            }
        }

        if let wsId = animatingWorkspaceId {
            controller.internalLayoutRefreshController?.startScrollAnimation(for: wsId)
        }
    }

    private func toggleColumnTabbedInNiri() {
        guard let controller else { return }

        controller.internalLayoutRefreshController?.runLightSession {
            guard let engine = controller.internalNiriEngine else { return }
            guard let wsId = controller.activeWorkspace()?.id else { return }
            let state = controller.internalWorkspaceManager.niriViewportState(for: wsId)

            if engine.toggleColumnTabbed(in: wsId, state: state) {
                controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()
            }
        }
    }

    private func balanceSizesInNiri() {
        guard let controller else { return }

        controller.internalLayoutRefreshController?.runLightSession {
            guard let engine = controller.internalNiriEngine else { return }
            guard let wsId = controller.activeWorkspace()?.id else { return }

            engine.balanceSizes(in: wsId)
            controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()
        }
    }
}

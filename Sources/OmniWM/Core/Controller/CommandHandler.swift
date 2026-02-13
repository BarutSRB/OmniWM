import AppKit
import Foundation

@MainActor
final class CommandHandler {
    private weak var controller: WMController?

    init(controller: WMController) {
        self.controller = controller
    }

    func handle(_ command: HotkeyCommand) {
        guard let controller else { return }
        guard controller.isEnabled else { return }

        let layoutType = currentLayoutType()

        switch command {
        case let .focus(direction):
            switch layoutType {
            case .dwindle:
                focusNeighborInDwindle(direction: direction)
            case .niri, .defaultLayout:
                focusNeighborInNiri(direction: direction)
            }
        case .focusPrevious:
            focusPreviousInNiri()
        case let .move(direction):
            if layoutType != .dwindle {
                moveWindowInNiri(direction: direction)
            }
        case let .swap(direction):
            switch layoutType {
            case .dwindle:
                swapWindowInDwindle(direction: direction)
            case .niri, .defaultLayout:
                swapWindowInNiri(direction: direction)
            }
        case let .moveToWorkspace(index):
            controller.internalWorkspaceNavigationHandler?.moveFocusedWindow(toWorkspaceIndex: index)
        case .moveWindowToWorkspaceUp:
            controller.internalWorkspaceNavigationHandler?.moveWindowToAdjacentWorkspace(direction: .up)
        case .moveWindowToWorkspaceDown:
            controller.internalWorkspaceNavigationHandler?.moveWindowToAdjacentWorkspace(direction: .down)
        case let .moveColumnToWorkspace(index):
            if layoutType != .dwindle {
                controller.internalWorkspaceNavigationHandler?.moveColumnToWorkspaceByIndex(index: index)
            }
        case .moveColumnToWorkspaceUp:
            if layoutType != .dwindle {
                controller.internalWorkspaceNavigationHandler?.moveColumnToAdjacentWorkspace(direction: .up)
            }
        case .moveColumnToWorkspaceDown:
            if layoutType != .dwindle {
                controller.internalWorkspaceNavigationHandler?.moveColumnToAdjacentWorkspace(direction: .down)
            }
        case let .switchWorkspace(index):
            controller.internalWorkspaceNavigationHandler?.switchWorkspace(index: index)
        case .switchWorkspaceNext:
            controller.internalWorkspaceNavigationHandler?.switchWorkspaceRelative(isNext: true)
        case .switchWorkspacePrevious:
            controller.internalWorkspaceNavigationHandler?.switchWorkspaceRelative(isNext: false)
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
            if layoutType != .dwindle {
                controller.internalWorkspaceNavigationHandler?.moveColumnToMonitorInDirection(direction)
            }
        case .toggleFullscreen:
            switch layoutType {
            case .dwindle:
                toggleDwindleFullscreen()
            case .niri, .defaultLayout:
                toggleNiriFullscreen()
            }
        case .toggleNativeFullscreen:
            toggleNativeFullscreenForFocused()
        case let .moveColumn(direction):
            if layoutType != .dwindle {
                moveColumnInNiri(direction: direction)
            }
        case let .consumeWindow(direction):
            if layoutType != .dwindle {
                consumeWindowInNiri(direction: direction)
            }
        case let .expelWindow(direction):
            if layoutType != .dwindle {
                expelWindowInNiri(direction: direction)
            }
        case .toggleColumnTabbed:
            if layoutType != .dwindle {
                toggleColumnTabbedInNiri()
            }
        case .focusDownOrLeft:
            if layoutType != .dwindle {
                focusDownOrLeftInNiri()
            }
        case .focusUpOrRight:
            if layoutType != .dwindle {
                focusUpOrRightInNiri()
            }
        case .focusColumnFirst:
            if layoutType != .dwindle {
                focusColumnFirstInNiri()
            }
        case .focusColumnLast:
            if layoutType != .dwindle {
                focusColumnLastInNiri()
            }
        case let .focusColumn(index):
            if layoutType != .dwindle {
                focusColumnInNiri(index: index)
            }
        case .focusWindowTop:
            if layoutType != .dwindle {
                focusWindowTopInNiri()
            }
        case .focusWindowBottom:
            if layoutType != .dwindle {
                focusWindowBottomInNiri()
            }
        case .cycleColumnWidthForward:
            switch layoutType {
            case .dwindle:
                cycleSplitRatioInDwindle(forward: true)
            case .niri, .defaultLayout:
                cycleColumnWidthInNiri(forwards: true)
            }
        case .cycleColumnWidthBackward:
            switch layoutType {
            case .dwindle:
                cycleSplitRatioInDwindle(forward: false)
            case .niri, .defaultLayout:
                cycleColumnWidthInNiri(forwards: false)
            }
        case .toggleColumnFullWidth:
            if layoutType != .dwindle {
                toggleColumnFullWidthInNiri()
            }
        case let .moveWorkspaceToMonitor(direction):
            controller.internalWorkspaceNavigationHandler?.moveCurrentWorkspaceToMonitor(direction: direction)
        case .moveWorkspaceToMonitorNext:
            controller.internalWorkspaceNavigationHandler?.moveCurrentWorkspaceToMonitorRelative(previous: false)
        case .moveWorkspaceToMonitorPrevious:
            controller.internalWorkspaceNavigationHandler?.moveCurrentWorkspaceToMonitorRelative(previous: true)
        case let .swapWorkspaceWithMonitor(direction):
            controller.internalWorkspaceNavigationHandler?.swapCurrentWorkspaceWithMonitor(direction: direction)
        case .balanceSizes:
            switch layoutType {
            case .dwindle:
                balanceSizesInDwindle()
            case .niri, .defaultLayout:
                balanceSizesInNiri()
            }
        case .moveToRoot:
            if layoutType == .dwindle {
                moveToRootInDwindle()
            }
        case .toggleSplit:
            if layoutType == .dwindle {
                toggleSplitInDwindle()
            }
        case .swapSplit:
            if layoutType == .dwindle {
                swapSplitInDwindle()
            }
        case let .resizeInDirection(direction, grow):
            if layoutType == .dwindle {
                resizeInDirectionInDwindle(direction: direction, grow: grow)
            }
        case let .preselect(direction):
            if layoutType == .dwindle {
                preselectInDwindle(direction: direction)
            }
        case .preselectClear:
            if layoutType == .dwindle {
                clearPreselectInDwindle()
            }
        case let .summonWorkspace(index):
            controller.internalWorkspaceNavigationHandler?.summonWorkspace(index: index)
        case .workspaceBackAndForth:
            controller.internalWorkspaceNavigationHandler?.workspaceBackAndForth()
        case let .focusWorkspaceAnywhere(index):
            controller.internalWorkspaceNavigationHandler?.focusWorkspaceAnywhere(index: index)
        case let .moveWindowToWorkspaceOnMonitor(wsIdx, monDir):
            controller.internalWorkspaceNavigationHandler?.moveWindowToWorkspaceOnMonitor(
                workspaceIndex: wsIdx,
                monitorDirection: monDir
            )
        case .openWindowFinder:
            controller.openWindowFinder()
        case .raiseAllFloatingWindows:
            controller.raiseAllFloatingWindows()
        case .openMenuAnywhere:
            controller.openMenuAnywhere()
        case .openMenuPalette:
            controller.openMenuPalette()
        case .toggleHiddenBar:
            controller.toggleHiddenBar()
        case .toggleQuakeTerminal:
            controller.toggleQuakeTerminal()
        case .toggleWorkspaceLayout:
            toggleWorkspaceLayout()
        case .toggleOverview:
            controller.toggleOverview()
        }
    }

    private func focusNeighborInNiri(direction: Direction) {
        guard let controller else { return }

        guard let engine = controller.internalNiriEngine else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }
        var state = controller.internalWorkspaceManager.niriViewportState(for: wsId)

        guard let currentId = state.selectedNodeId,
              let currentNode = engine.findNode(by: currentId)
        else {
            if let lastFocused = controller.internalLastFocusedByWorkspace[wsId],
               let lastNode = engine.findNode(for: lastFocused)
            {
                controller.activateNode(
                    lastNode, in: wsId, state: &state,
                    options: .init(activateWindow: false, ensureVisible: false, updateWorkspaceFocus: false, layoutRefresh: false, startAnimation: false)
                )
            } else if let firstHandle = controller.internalWorkspaceManager.entries(in: wsId).first?.handle,
                      let firstNode = engine.findNode(for: firstHandle)
            {
                controller.activateNode(
                    firstNode, in: wsId, state: &state,
                    options: .init(activateWindow: false, ensureVisible: false, updateWorkspaceFocus: false, layoutRefresh: false, startAnimation: false)
                )
            }
            return
        }

        guard let monitor = controller.internalWorkspaceManager.monitor(for: wsId) else { return }
        let gap = CGFloat(controller.internalWorkspaceManager.gaps)
        let workingFrame = controller.insetWorkingFrame(for: monitor)

        for col in engine.columns(in: wsId) where col.cachedWidth <= 0 {
            col.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gap)
        }

        if let newNode = engine.focusTarget(
            direction: direction,
            currentSelection: currentNode,
            in: wsId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        ) {
            controller.activateNode(
                newNode, in: wsId, state: &state,
                options: .init(activateWindow: false, ensureVisible: false, updateWorkspaceFocus: false)
            )
        }
    }

    private func focusPreviousInNiri() {
        guard let controller else { return }
        controller.withNiriWorkspaceContext { engine, wsId, state, _, workingFrame, gaps in
            if let currentId = state.selectedNodeId {
                engine.updateFocusTimestamp(for: currentId)
            }

            if let currentId = state.selectedNodeId {
                engine.activateWindow(currentId)
            }

            guard let previousWindow = engine.focusPrevious(
                currentNodeId: state.selectedNodeId,
                in: wsId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                limitToWorkspace: true
            ) else {
                return
            }

            controller.activateNode(
                previousWindow, in: wsId, state: &state,
                options: .init(ensureVisible: false, updateTimestamp: false, updateWorkspaceFocus: false, startAnimation: false)
            )

            let updatedState = controller.internalWorkspaceManager.niriViewportState(for: wsId)
            if updatedState.viewOffsetPixels.isAnimating {
                controller.internalLayoutRefreshController?.startScrollAnimation(for: wsId)
            }
        }
    }

    private func focusDownOrLeftInNiri() {
        executeCombinedNavigation { engine, currentNode, wsId, state, workingFrame, gaps in
            engine.focusDownOrLeft(
                currentSelection: currentNode,
                in: wsId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }
    }

    private func focusUpOrRightInNiri() {
        executeCombinedNavigation { engine, currentNode, wsId, state, workingFrame, gaps in
            engine.focusUpOrRight(
                currentSelection: currentNode,
                in: wsId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }
    }

    private func focusColumnFirstInNiri() {
        executeCombinedNavigation { engine, currentNode, wsId, state, workingFrame, gaps in
            engine.focusColumnFirst(
                currentSelection: currentNode,
                in: wsId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }
    }

    private func focusColumnLastInNiri() {
        executeCombinedNavigation { engine, currentNode, wsId, state, workingFrame, gaps in
            engine.focusColumnLast(
                currentSelection: currentNode,
                in: wsId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }
    }

    private func focusColumnInNiri(index: Int) {
        executeCombinedNavigation { engine, currentNode, wsId, state, workingFrame, gaps in
            engine.focusColumn(
                index,
                currentSelection: currentNode,
                in: wsId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }
    }

    private func focusWindowTopInNiri() {
        executeCombinedNavigation { engine, currentNode, wsId, state, workingFrame, gaps in
            engine.focusWindowTop(
                currentSelection: currentNode,
                in: wsId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }
    }

    private func focusWindowBottomInNiri() {
        executeCombinedNavigation { engine, currentNode, wsId, state, workingFrame, gaps in
            engine.focusWindowBottom(
                currentSelection: currentNode,
                in: wsId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }
    }

    private func cycleColumnWidthInNiri(forwards: Bool) {
        guard let controller else { return }
        controller.withNiriWorkspaceContext { engine, wsId, state, monitor, workingFrame, gaps in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId) as? NiriWindow,
                  let column = engine.findColumn(containing: windowNode, in: wsId)
            else { return }

            engine.toggleColumnWidth(
                column,
                forwards: forwards,
                in: wsId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
            controller.internalWorkspaceManager.updateNiriViewportState(state, for: wsId)
            controller.internalLayoutRefreshController?.startScrollAnimation(for: wsId)
        }
    }

    private func toggleColumnFullWidthInNiri() {
        guard let controller else { return }
        controller.withNiriWorkspaceContext { engine, wsId, state, monitor, workingFrame, gaps in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId) as? NiriWindow,
                  let column = engine.findColumn(containing: windowNode, in: wsId)
            else { return }

            engine.toggleFullWidth(
                column,
                in: wsId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
            controller.internalWorkspaceManager.updateNiriViewportState(state, for: wsId)
            controller.internalLayoutRefreshController?.startScrollAnimation(for: wsId)
        }
    }

    private func executeCombinedNavigation(
        _ navigationAction: (NiriLayoutEngine, NiriNode, WorkspaceDescriptor.ID, inout ViewportState, CGRect, CGFloat)
            -> NiriNode?
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
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        guard let newNode = navigationAction(engine, currentNode, wsId, &state, workingFrame, gap) else {
            return
        }

        controller.activateNode(
            newNode, in: wsId, state: &state,
            options: .init(activateWindow: false, ensureVisible: false, updateWorkspaceFocus: false)
        )
    }

    private func moveWindowInNiri(direction: Direction) {
        guard let controller else { return }
        controller.withNiriOperationContext { ctx, state in
            let oldFrames = ctx.engine.captureWindowFrames(in: ctx.wsId)
            guard ctx.engine.moveWindow(
                ctx.windowNode, direction: direction, in: ctx.wsId,
                state: &state, workingFrame: ctx.workingFrame, gaps: ctx.gaps
            ) else { return false }
            return ctx.commitWithPredictedAnimation(state: state, oldFrames: oldFrames)
        }
    }

    private func swapWindowInNiri(direction: Direction) {
        guard let controller else { return }
        controller.withNiriOperationContext { ctx, state in
            let oldFrames = ctx.engine.captureWindowFrames(in: ctx.wsId)
            guard ctx.engine.swapWindow(
                ctx.windowNode, direction: direction, in: ctx.wsId,
                state: &state, workingFrame: ctx.workingFrame, gaps: ctx.gaps
            ) else { return false }
            return ctx.commitWithPredictedAnimation(state: state, oldFrames: oldFrames)
        }
    }

    private func toggleNiriFullscreen() {
        guard let controller else { return }
        controller.withNiriWorkspaceContext { engine, wsId, state, _, _, _ in
            guard let currentId = state.selectedNodeId,
                  let currentNode = engine.findNode(by: currentId),
                  let windowNode = currentNode as? NiriWindow
            else { return }

            engine.toggleFullscreen(windowNode, state: &state)

            controller.internalWorkspaceManager.updateNiriViewportState(state, for: wsId)
            controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()
            if state.viewOffsetPixels.isAnimating {
                controller.internalLayoutRefreshController?.startScrollAnimation(for: wsId)
            }
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
        controller.withNiriOperationContext { ctx, state in
            guard let column = ctx.engine.findColumn(containing: ctx.windowNode, in: ctx.wsId) else { return false }
            let oldFrames = ctx.engine.captureWindowFrames(in: ctx.wsId)
            guard ctx.engine.moveColumn(
                column, direction: direction, in: ctx.wsId,
                state: &state, workingFrame: ctx.workingFrame, gaps: ctx.gaps
            ) else { return false }
            return ctx.commitWithCapturedAnimation(state: state, oldFrames: oldFrames)
        }
    }

    private func consumeWindowInNiri(direction: Direction) {
        guard let controller else { return }
        controller.withNiriOperationContext { ctx, state in
            guard ctx.engine.consumeWindow(
                into: ctx.windowNode, from: direction, in: ctx.wsId,
                state: &state, workingFrame: ctx.workingFrame, gaps: ctx.gaps
            ) else { return false }
            return ctx.commitSimple(state: state)
        }
    }

    private func expelWindowInNiri(direction: Direction) {
        guard let controller else { return }
        controller.withNiriOperationContext { ctx, state in
            guard ctx.engine.expelWindow(
                ctx.windowNode, to: direction, in: ctx.wsId,
                state: &state, workingFrame: ctx.workingFrame, gaps: ctx.gaps
            ) else { return false }
            return ctx.commitSimple(state: state)
        }
    }

    private func toggleColumnTabbedInNiri() {
        guard let controller else { return }
        controller.withNiriWorkspaceContext { engine, wsId, _, _, _, _ in
            let state = controller.internalWorkspaceManager.niriViewportState(for: wsId)
            if engine.toggleColumnTabbed(in: wsId, state: state) {
                controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()
                if engine.hasAnyWindowAnimationsRunning(in: wsId) {
                    controller.internalLayoutRefreshController?.startScrollAnimation(for: wsId)
                }
            }
        }
    }

    private func balanceSizesInNiri() {
        guard let controller else { return }
        controller.withNiriWorkspaceContext { engine, wsId, _, _, workingFrame, gaps in
            engine.balanceSizes(
                in: wsId,
                workingAreaWidth: workingFrame.width,
                gaps: gaps
            )
            controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()
            if engine.hasAnyColumnAnimationsRunning(in: wsId) {
                controller.internalLayoutRefreshController?.startScrollAnimation(for: wsId)
            }
        }
    }

    private func currentLayoutType() -> LayoutType {
        guard let controller else { return .niri }
        guard let ws = controller.activeWorkspace() else { return .niri }
        return controller.internalSettings.layoutType(for: ws.name)
    }

    private func focusNeighborInDwindle(direction: Direction) {
        guard let controller else { return }
        controller.withDwindleContext { engine, wsId in
            if let handle = engine.moveFocus(direction: direction, in: wsId) {
                controller.internalSetFocus(handle, in: wsId)
                controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()
                controller.focusWindow(handle)
            }
        }
    }

    private func swapWindowInDwindle(direction: Direction) {
        guard let controller else { return }
        controller.withDwindleContext { engine, wsId in
            if engine.swapWindows(direction: direction, in: wsId) {
                controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()
            }
        }
    }

    private func toggleDwindleFullscreen() {
        guard let controller else { return }
        controller.withDwindleContext { engine, wsId in
            if let handle = engine.toggleFullscreen(in: wsId) {
                controller.internalFocusedHandle = handle
                controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()
            }
        }
    }

    private func balanceSizesInDwindle() {
        guard let controller else { return }
        controller.withDwindleContext { engine, wsId in
            engine.balanceSizes(in: wsId)
            controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()
        }
    }

    private func moveToRootInDwindle() {
        guard let controller else { return }
        controller.withDwindleContext { engine, wsId in
            let stable = controller.internalSettings.dwindleMoveToRootStable
            engine.moveSelectionToRoot(stable: stable, in: wsId)
            controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()
        }
    }

    private func toggleSplitInDwindle() {
        guard let controller else { return }
        controller.withDwindleContext { engine, wsId in
            engine.toggleOrientation(in: wsId)
            controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()
        }
    }

    private func swapSplitInDwindle() {
        guard let controller else { return }
        controller.withDwindleContext { engine, wsId in
            engine.swapSplit(in: wsId)
            controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()
        }
    }

    private func cycleSplitRatioInDwindle(forward: Bool) {
        guard let controller else { return }
        controller.withDwindleContext { engine, wsId in
            engine.cycleSplitRatio(forward: forward, in: wsId)
            controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()
        }
    }

    private func resizeInDirectionInDwindle(direction: Direction, grow: Bool) {
        guard let controller else { return }
        controller.withDwindleContext { engine, wsId in
            let delta = grow ? engine.settings.resizeStep : -engine.settings.resizeStep
            engine.resizeSelected(by: delta, direction: direction, in: wsId)
            controller.internalLayoutRefreshController?.executeLayoutRefreshImmediate()
        }
    }

    private func preselectInDwindle(direction: Direction) {
        guard let controller else { return }
        controller.withDwindleContext { engine, wsId in
            engine.setPreselection(direction, in: wsId)
        }
    }

    private func clearPreselectInDwindle() {
        guard let controller else { return }
        controller.withDwindleContext { engine, wsId in
            engine.setPreselection(nil, in: wsId)
        }
    }

    private func toggleWorkspaceLayout() {
        guard let controller else { return }
        guard let workspace = controller.activeWorkspace() else { return }
        let workspaceName = workspace.name

        let settings = controller.internalSettings
        let currentLayout = settings.layoutType(for: workspaceName)

        let newLayout: LayoutType = switch currentLayout {
        case .niri, .defaultLayout: .dwindle
        case .dwindle: .niri
        }

        var configs = settings.workspaceConfigurations
        if let index = configs.firstIndex(where: { $0.name == workspaceName }) {
            configs[index] = configs[index].with(layoutType: newLayout)
        } else {
            configs.append(WorkspaceConfiguration(
                name: workspaceName,
                layoutType: newLayout
            ))
        }

        settings.workspaceConfigurations = configs
        controller.internalLayoutRefreshController?.refreshWindowsAndLayout()
    }
}

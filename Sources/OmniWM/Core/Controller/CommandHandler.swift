import AppKit
import Foundation

extension WMController {
    func handleCommand(_ command: HotkeyCommand) {
        guard isEnabled else { return }

        let layoutType = currentLayoutType()

        switch (command.layoutCompatibility, layoutType) {
        case (.niri, .dwindle), (.dwindle, .niri), (.dwindle, .defaultLayout):
            return
        default:
            break
        }

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
            moveWindowInNiri(direction: direction)
        case let .swap(direction):
            switch layoutType {
            case .dwindle:
                swapWindowInDwindle(direction: direction)
            case .niri, .defaultLayout:
                swapWindowInNiri(direction: direction)
            }
        case let .moveToWorkspace(index):
            moveFocusedWindow(toWorkspaceIndex: index)
        case .moveWindowToWorkspaceUp:
            moveWindowToAdjacentWorkspace(direction: .up)
        case .moveWindowToWorkspaceDown:
            moveWindowToAdjacentWorkspace(direction: .down)
        case let .moveColumnToWorkspace(index):
            moveColumnToWorkspaceByIndex(index: index)
        case .moveColumnToWorkspaceUp:
            moveColumnToAdjacentWorkspace(direction: .up)
        case .moveColumnToWorkspaceDown:
            moveColumnToAdjacentWorkspace(direction: .down)
        case let .switchWorkspace(index):
            switchWorkspace(index: index)
        case .switchWorkspaceNext:
            switchWorkspaceRelative(isNext: true)
        case .switchWorkspacePrevious:
            switchWorkspaceRelative(isNext: false)
        case let .moveToMonitor(direction):
            moveFocusedWindowToMonitor(direction: direction)
        case let .focusMonitor(direction):
            focusMonitorInDirection(direction)
        case .focusMonitorPrevious:
            focusMonitorCyclic(previous: true)
        case .focusMonitorNext:
            focusMonitorCyclic(previous: false)
        case .focusMonitorLast:
            focusLastMonitor()
        case let .moveColumnToMonitor(direction):
            moveColumnToMonitorInDirection(direction)
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
            toggleColumnFullWidthInNiri()
        case let .moveWorkspaceToMonitor(direction):
            moveCurrentWorkspaceToMonitor(direction: direction)
        case .moveWorkspaceToMonitorNext:
            moveCurrentWorkspaceToMonitorRelative(previous: false)
        case .moveWorkspaceToMonitorPrevious:
            moveCurrentWorkspaceToMonitorRelative(previous: true)
        case let .swapWorkspaceWithMonitor(direction):
            swapCurrentWorkspaceWithMonitor(direction: direction)
        case .balanceSizes:
            switch layoutType {
            case .dwindle:
                balanceSizesInDwindle()
            case .niri, .defaultLayout:
                balanceSizesInNiri()
            }
        case .moveToRoot:
            moveToRootInDwindle()
        case .toggleSplit:
            toggleSplitInDwindle()
        case .swapSplit:
            swapSplitInDwindle()
        case let .resizeInDirection(direction, grow):
            resizeInDirectionInDwindle(direction: direction, grow: grow)
        case let .preselect(direction):
            preselectInDwindle(direction: direction)
        case .preselectClear:
            clearPreselectInDwindle()
        case let .summonWorkspace(index):
            summonWorkspace(index: index)
        case .workspaceBackAndForth:
            workspaceBackAndForth()
        case let .focusWorkspaceAnywhere(index):
            focusWorkspaceAnywhere(index: index)
        case let .moveWindowToWorkspaceOnMonitor(wsIdx, monDir):
            moveWindowToWorkspaceOnMonitor(
                workspaceIndex: wsIdx,
                monitorDirection: monDir
            )
        case .openWindowFinder:
            openWindowFinder()
        case .raiseAllFloatingWindows:
            raiseAllFloatingWindows()
        case .openMenuAnywhere:
            openMenuAnywhere()
        case .openMenuPalette:
            openMenuPalette()
        case .toggleHiddenBar:
            toggleHiddenBar()
        case .toggleQuakeTerminal:
            toggleQuakeTerminal()
        case .toggleWorkspaceLayout:
            toggleWorkspaceLayout()
        case .toggleOverview:
            toggleOverview()
        }
    }

    private func focusNeighborInNiri(direction: Direction) {
        guard let engine = niriEngine else { return }
        guard let wsId = activeWorkspace()?.id else { return }
        var state = workspaceManager.niriViewportState(for: wsId)

        guard let currentId = state.selectedNodeId,
              let currentNode = engine.findNode(by: currentId)
        else {
            if let lastFocused = lastFocusedByWorkspace[wsId],
               let lastNode = engine.findNode(for: lastFocused)
            {
                activateNode(
                    lastNode, in: wsId, state: &state,
                    options: .init(activateWindow: false, ensureVisible: false, updateWorkspaceFocus: false, layoutRefresh: false, startAnimation: false)
                )
            } else if let firstHandle = workspaceManager.entries(in: wsId).first?.handle,
                      let firstNode = engine.findNode(for: firstHandle)
            {
                activateNode(
                    firstNode, in: wsId, state: &state,
                    options: .init(activateWindow: false, ensureVisible: false, updateWorkspaceFocus: false, layoutRefresh: false, startAnimation: false)
                )
            }
            return
        }

        guard let monitor = workspaceManager.monitor(for: wsId) else { return }
        let gap = CGFloat(workspaceManager.gaps)
        let workingFrame = insetWorkingFrame(for: monitor)

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
            activateNode(
                newNode, in: wsId, state: &state,
                options: .init(activateWindow: false, ensureVisible: false, updateWorkspaceFocus: false)
            )
        }
    }

    private func focusPreviousInNiri() {
        withNiriWorkspaceContext { engine, wsId, state, _, workingFrame, gaps in
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

            activateNode(
                previousWindow, in: wsId, state: &state,
                options: .init(ensureVisible: false, updateTimestamp: false, updateWorkspaceFocus: false, startAnimation: false)
            )

            let updatedState = workspaceManager.niriViewportState(for: wsId)
            if updatedState.viewOffsetPixels.isAnimating {
                startScrollAnimation(for: wsId)
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
        withNiriWorkspaceContext { engine, wsId, state, monitor, workingFrame, gaps in
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
            workspaceManager.updateNiriViewportState(state, for: wsId)
            startScrollAnimation(for: wsId)
        }
    }

    private func toggleColumnFullWidthInNiri() {
        withNiriWorkspaceContext { engine, wsId, state, monitor, workingFrame, gaps in
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
            workspaceManager.updateNiriViewportState(state, for: wsId)
            startScrollAnimation(for: wsId)
        }
    }

    private func executeCombinedNavigation(
        _ navigationAction: (NiriLayoutEngine, NiriNode, WorkspaceDescriptor.ID, inout ViewportState, CGRect, CGFloat)
            -> NiriNode?
    ) {
        guard let engine = niriEngine else { return }
        guard let wsId = activeWorkspace()?.id else { return }
        guard let monitor = workspaceManager.monitor(for: wsId) else { return }
        var state = workspaceManager.niriViewportState(for: wsId)

        guard let currentId = state.selectedNodeId,
              let currentNode = engine.findNode(by: currentId)
        else {
            return
        }

        let gap = CGFloat(workspaceManager.gaps)
        let workingFrame = insetWorkingFrame(for: monitor)
        guard let newNode = navigationAction(engine, currentNode, wsId, &state, workingFrame, gap) else {
            return
        }

        activateNode(
            newNode, in: wsId, state: &state,
            options: .init(activateWindow: false, ensureVisible: false, updateWorkspaceFocus: false)
        )
    }

    private func moveWindowInNiri(direction: Direction) {
        withNiriOperationContext { ctx, state in
            let oldFrames = ctx.engine.captureWindowFrames(in: ctx.wsId)
            guard ctx.engine.moveWindow(
                ctx.windowNode, direction: direction, in: ctx.wsId,
                state: &state, workingFrame: ctx.workingFrame, gaps: ctx.gaps
            ) else { return false }
            return ctx.commitWithPredictedAnimation(state: state, oldFrames: oldFrames)
        }
    }

    private func swapWindowInNiri(direction: Direction) {
        withNiriOperationContext { ctx, state in
            let oldFrames = ctx.engine.captureWindowFrames(in: ctx.wsId)
            guard ctx.engine.swapWindow(
                ctx.windowNode, direction: direction, in: ctx.wsId,
                state: &state, workingFrame: ctx.workingFrame, gaps: ctx.gaps
            ) else { return false }
            return ctx.commitWithPredictedAnimation(state: state, oldFrames: oldFrames)
        }
    }

    private func toggleNiriFullscreen() {
        withNiriWorkspaceContext { engine, wsId, state, _, _, _ in
            guard let currentId = state.selectedNodeId,
                  let currentNode = engine.findNode(by: currentId),
                  let windowNode = currentNode as? NiriWindow
            else { return }

            engine.toggleFullscreen(windowNode, state: &state)

            workspaceManager.updateNiriViewportState(state, for: wsId)
            executeLayoutRefreshImmediate()
            if state.viewOffsetPixels.isAnimating {
                startScrollAnimation(for: wsId)
            }
        }
    }

    private func toggleNativeFullscreenForFocused() {
        guard let handle = focusedHandle else { return }
        guard let entry = workspaceManager.entry(for: handle) else { return }

        let currentState = AXWindowService.isFullscreen(entry.axRef)
        let newState = !currentState

        _ = AXWindowService.setNativeFullscreen(entry.axRef, fullscreen: newState)

        if newState {
            borderManager.hideBorder()
        }
    }

    private func moveColumnInNiri(direction: Direction) {
        withNiriOperationContext { ctx, state in
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
        withNiriOperationContext { ctx, state in
            guard ctx.engine.consumeWindow(
                into: ctx.windowNode, from: direction, in: ctx.wsId,
                state: &state, workingFrame: ctx.workingFrame, gaps: ctx.gaps
            ) else { return false }
            return ctx.commitSimple(state: state)
        }
    }

    private func expelWindowInNiri(direction: Direction) {
        withNiriOperationContext { ctx, state in
            guard ctx.engine.expelWindow(
                ctx.windowNode, to: direction, in: ctx.wsId,
                state: &state, workingFrame: ctx.workingFrame, gaps: ctx.gaps
            ) else { return false }
            return ctx.commitSimple(state: state)
        }
    }

    private func toggleColumnTabbedInNiri() {
        withNiriWorkspaceContext { engine, wsId, _, _, _, _ in
            let state = workspaceManager.niriViewportState(for: wsId)
            if engine.toggleColumnTabbed(in: wsId, state: state) {
                executeLayoutRefreshImmediate()
                if engine.hasAnyWindowAnimationsRunning(in: wsId) {
                    startScrollAnimation(for: wsId)
                }
            }
        }
    }

    private func balanceSizesInNiri() {
        withNiriWorkspaceContext { engine, wsId, _, _, workingFrame, gaps in
            engine.balanceSizes(
                in: wsId,
                workingAreaWidth: workingFrame.width,
                gaps: gaps
            )
            executeLayoutRefreshImmediate()
            if engine.hasAnyColumnAnimationsRunning(in: wsId) {
                startScrollAnimation(for: wsId)
            }
        }
    }

    private func currentLayoutType() -> LayoutType {
        guard let ws = activeWorkspace() else { return .niri }
        return settings.layoutType(for: ws.name)
    }

    private func focusNeighborInDwindle(direction: Direction) {
        withDwindleContext { engine, wsId in
            if let handle = engine.moveFocus(direction: direction, in: wsId) {
                setFocus(handle, in: wsId)
                executeLayoutRefreshImmediate()
                focusWindow(handle)
            }
        }
    }

    private func swapWindowInDwindle(direction: Direction) {
        withDwindleContext { engine, wsId in
            if engine.swapWindows(direction: direction, in: wsId) {
                executeLayoutRefreshImmediate()
            }
        }
    }

    private func toggleDwindleFullscreen() {
        withDwindleContext { engine, wsId in
            if let handle = engine.toggleFullscreen(in: wsId) {
                focusedHandle = handle
                executeLayoutRefreshImmediate()
            }
        }
    }

    private func balanceSizesInDwindle() {
        withDwindleContext { engine, wsId in
            engine.balanceSizes(in: wsId)
            executeLayoutRefreshImmediate()
        }
    }

    private func moveToRootInDwindle() {
        withDwindleContext { engine, wsId in
            let stable = settings.dwindleMoveToRootStable
            engine.moveSelectionToRoot(stable: stable, in: wsId)
            executeLayoutRefreshImmediate()
        }
    }

    private func toggleSplitInDwindle() {
        withDwindleContext { engine, wsId in
            engine.toggleOrientation(in: wsId)
            executeLayoutRefreshImmediate()
        }
    }

    private func swapSplitInDwindle() {
        withDwindleContext { engine, wsId in
            engine.swapSplit(in: wsId)
            executeLayoutRefreshImmediate()
        }
    }

    private func cycleSplitRatioInDwindle(forward: Bool) {
        withDwindleContext { engine, wsId in
            engine.cycleSplitRatio(forward: forward, in: wsId)
            executeLayoutRefreshImmediate()
        }
    }

    private func resizeInDirectionInDwindle(direction: Direction, grow: Bool) {
        withDwindleContext { engine, wsId in
            let delta = grow ? engine.settings.resizeStep : -engine.settings.resizeStep
            engine.resizeSelected(by: delta, direction: direction, in: wsId)
            executeLayoutRefreshImmediate()
        }
    }

    private func preselectInDwindle(direction: Direction) {
        withDwindleContext { engine, wsId in
            engine.setPreselection(direction, in: wsId)
        }
    }

    private func clearPreselectInDwindle() {
        withDwindleContext { engine, wsId in
            engine.setPreselection(nil, in: wsId)
        }
    }

    private func toggleWorkspaceLayout() {
        guard let workspace = activeWorkspace() else { return }
        let workspaceName = workspace.name

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
        refreshWindowsAndLayout()
    }
}

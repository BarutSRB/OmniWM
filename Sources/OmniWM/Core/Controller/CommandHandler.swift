import AppKit
import Foundation

@MainActor
final class CommandHandler {
    weak var controller: WMController?

    init(controller: WMController) {
        self.controller = controller
    }

    func handleCommand(_ command: HotkeyCommand) {
        guard let controller else { return }
        guard controller.isEnabled else { return }

        let layoutType = currentLayoutType()

        switch (command.layoutCompatibility, layoutType) {
        case (.niri, .dwindle), (.dwindle, .niri), (.dwindle, .defaultLayout):
            return
        default:
            break
        }

        switch command {
        case let .focus(direction):
            layoutHandler(as: LayoutFocusable.self)?.focusNeighbor(direction: direction)
        case .focusPrevious:
            focusPreviousInNiri()
        case let .move(direction):
            moveWindowInNiri(direction: direction)
        case let .swap(direction):
            layoutHandler(as: LayoutSwappable.self)?.swapWindow(direction: direction)
        case let .moveToWorkspace(index):
            controller.workspaceNavigationHandler.moveFocusedWindow(toWorkspaceIndex: index)
        case .moveWindowToWorkspaceUp:
            controller.workspaceNavigationHandler.moveWindowToAdjacentWorkspace(direction: .up)
        case .moveWindowToWorkspaceDown:
            controller.workspaceNavigationHandler.moveWindowToAdjacentWorkspace(direction: .down)
        case let .moveColumnToWorkspace(index):
            controller.workspaceNavigationHandler.moveColumnToWorkspaceByIndex(index: index)
        case .moveColumnToWorkspaceUp:
            controller.workspaceNavigationHandler.moveColumnToAdjacentWorkspace(direction: .up)
        case .moveColumnToWorkspaceDown:
            controller.workspaceNavigationHandler.moveColumnToAdjacentWorkspace(direction: .down)
        case let .switchWorkspace(index):
            controller.workspaceNavigationHandler.switchWorkspace(index: index)
        case .switchWorkspaceNext:
            controller.workspaceNavigationHandler.switchWorkspaceRelative(isNext: true)
        case .switchWorkspacePrevious:
            controller.workspaceNavigationHandler.switchWorkspaceRelative(isNext: false)
        case let .moveToMonitor(direction):
            controller.workspaceNavigationHandler.moveFocusedWindowToMonitor(direction: direction)
        case let .focusMonitor(direction):
            controller.workspaceNavigationHandler.focusMonitorInDirection(direction)
        case .focusMonitorPrevious:
            controller.workspaceNavigationHandler.focusMonitorCyclic(previous: true)
        case .focusMonitorNext:
            controller.workspaceNavigationHandler.focusMonitorCyclic(previous: false)
        case .focusMonitorLast:
            controller.workspaceNavigationHandler.focusLastMonitor()
        case let .moveColumnToMonitor(direction):
            controller.workspaceNavigationHandler.moveColumnToMonitorInDirection(direction)
        case .toggleFullscreen:
            layoutHandler(as: LayoutSwappable.self)?.toggleFullscreen()
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
            layoutHandler(as: LayoutSizable.self)?.cycleSize(forward: true)
        case .cycleColumnWidthBackward:
            layoutHandler(as: LayoutSizable.self)?.cycleSize(forward: false)
        case .toggleColumnFullWidth:
            toggleColumnFullWidthInNiri()
        case let .moveWorkspaceToMonitor(direction):
            controller.workspaceNavigationHandler.moveCurrentWorkspaceToMonitor(direction: direction)
        case .moveWorkspaceToMonitorNext:
            controller.workspaceNavigationHandler.moveCurrentWorkspaceToMonitorRelative(previous: false)
        case .moveWorkspaceToMonitorPrevious:
            controller.workspaceNavigationHandler.moveCurrentWorkspaceToMonitorRelative(previous: true)
        case let .swapWorkspaceWithMonitor(direction):
            controller.workspaceNavigationHandler.swapCurrentWorkspaceWithMonitor(direction: direction)
        case .balanceSizes:
            layoutHandler(as: LayoutSizable.self)?.balanceSizes()
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
            controller.workspaceNavigationHandler.summonWorkspace(index: index)
        case .workspaceBackAndForth:
            controller.workspaceNavigationHandler.workspaceBackAndForth()
        case let .focusWorkspaceAnywhere(index):
            controller.workspaceNavigationHandler.focusWorkspaceAnywhere(index: index)
        case let .moveWindowToWorkspaceOnMonitor(wsIdx, monDir):
            controller.workspaceNavigationHandler.moveWindowToWorkspaceOnMonitor(
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

    private func layoutHandler<T>(as capability: T.Type) -> T? {
        guard let controller else { return nil }
        let layoutType = currentLayoutType()
        let handler: AnyObject = switch layoutType {
        case .dwindle:
            controller.layoutRefreshController.dwindleHandler
        case .niri, .defaultLayout:
            controller.layoutRefreshController.niriHandler
        }
        return handler as? T
    }

    private func focusPreviousInNiri() {
        guard let controller else { return }
        controller.niriLayoutHandler.withNiriWorkspaceContext { engine, wsId, state, _, workingFrame, gaps in
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

            controller.niriLayoutHandler.activateNode(
                previousWindow, in: wsId, state: &state,
                options: .init(ensureVisible: false, updateTimestamp: false, startAnimation: false)
            )

            if state.viewOffsetPixels.isAnimating {
                controller.layoutRefreshController.startScrollAnimation(for: wsId)
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

    private func toggleColumnFullWidthInNiri() {
        guard let controller else { return }
        controller.niriLayoutHandler.withNiriWorkspaceContext { engine, wsId, state, monitor, workingFrame, gaps in
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
            controller.layoutRefreshController.startScrollAnimation(for: wsId)
        }
    }

    private func executeCombinedNavigation(
        _ navigationAction: (NiriLayoutEngine, NiriNode, WorkspaceDescriptor.ID, inout ViewportState, CGRect, CGFloat)
            -> NiriNode?
    ) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }
        guard let monitor = controller.workspaceManager.monitor(for: wsId) else { return }

        controller.workspaceManager.withNiriViewportState(for: wsId) { state in
            guard let currentId = state.selectedNodeId,
                  let currentNode = engine.findNode(by: currentId)
            else {
                return
            }

            let gap = CGFloat(controller.workspaceManager.gaps)
            let workingFrame = controller.insetWorkingFrame(for: monitor)
            guard let newNode = navigationAction(engine, currentNode, wsId, &state, workingFrame, gap) else {
                return
            }

            controller.niriLayoutHandler.activateNode(
                newNode, in: wsId, state: &state,
                options: .init(activateWindow: false, ensureVisible: false)
            )
        }
    }

    private func moveWindowInNiri(direction: Direction) {
        guard let controller else { return }
        controller.niriLayoutHandler.withNiriOperationContext { ctx, state in
            let oldFrames = ctx.engine.captureWindowFrames(in: ctx.wsId)
            guard ctx.engine.moveWindow(
                ctx.windowNode, direction: direction, in: ctx.wsId,
                state: &state, workingFrame: ctx.workingFrame, gaps: ctx.gaps
            ) else { return false }
            return ctx.commitWithPredictedAnimation(state: state, oldFrames: oldFrames)
        }
    }

    private func toggleNativeFullscreenForFocused() {
        guard let controller else { return }
        guard let handle = controller.focusedHandle else { return }
        guard let entry = controller.workspaceManager.entry(for: handle) else { return }

        let currentState = AXWindowService.isFullscreen(entry.axRef)
        let newState = !currentState

        _ = AXWindowService.setNativeFullscreen(entry.axRef, fullscreen: newState)

        if newState {
            controller.borderManager.hideBorder()
        }
    }

    private func moveColumnInNiri(direction: Direction) {
        guard let controller else { return }
        controller.niriLayoutHandler.withNiriOperationContext { ctx, state in
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
        controller.niriLayoutHandler.withNiriOperationContext { ctx, state in
            guard ctx.engine.consumeWindow(
                into: ctx.windowNode, from: direction, in: ctx.wsId,
                state: &state, workingFrame: ctx.workingFrame, gaps: ctx.gaps
            ) else { return false }
            return ctx.commitSimple(state: state)
        }
    }

    private func expelWindowInNiri(direction: Direction) {
        guard let controller else { return }
        controller.niriLayoutHandler.withNiriOperationContext { ctx, state in
            guard ctx.engine.expelWindow(
                ctx.windowNode, to: direction, in: ctx.wsId,
                state: &state, workingFrame: ctx.workingFrame, gaps: ctx.gaps
            ) else { return false }
            return ctx.commitSimple(state: state)
        }
    }

    private func toggleColumnTabbedInNiri() {
        guard let controller else { return }
        controller.niriLayoutHandler.withNiriWorkspaceContext { engine, wsId, state, _, _, _ in
            if engine.toggleColumnTabbed(in: wsId, state: state) {
                controller.layoutRefreshController.executeLayoutRefreshImmediate()
                if engine.hasAnyWindowAnimationsRunning(in: wsId) {
                    controller.layoutRefreshController.startScrollAnimation(for: wsId)
                }
            }
        }
    }

    private func currentLayoutType() -> LayoutType {
        guard let controller else { return .niri }
        guard let ws = controller.activeWorkspace() else { return .niri }
        return controller.settings.layoutType(for: ws.name)
    }

    private func moveToRootInDwindle() {
        guard let controller else { return }
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            let stable = controller.settings.dwindleMoveToRootStable
            engine.moveSelectionToRoot(stable: stable, in: wsId)
            controller.layoutRefreshController.executeLayoutRefreshImmediate()
        }
    }

    private func toggleSplitInDwindle() {
        guard let controller else { return }
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            engine.toggleOrientation(in: wsId)
            controller.layoutRefreshController.executeLayoutRefreshImmediate()
        }
    }

    private func swapSplitInDwindle() {
        guard let controller else { return }
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            engine.swapSplit(in: wsId)
            controller.layoutRefreshController.executeLayoutRefreshImmediate()
        }
    }

    private func resizeInDirectionInDwindle(direction: Direction, grow: Bool) {
        guard let controller else { return }
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            let delta = grow ? engine.settings.resizeStep : -engine.settings.resizeStep
            engine.resizeSelected(by: delta, direction: direction, in: wsId)
            controller.layoutRefreshController.executeLayoutRefreshImmediate()
        }
    }

    private func preselectInDwindle(direction: Direction) {
        guard let controller else { return }
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            engine.setPreselection(direction, in: wsId)
        }
    }

    private func clearPreselectInDwindle() {
        guard let controller else { return }
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            engine.setPreselection(nil, in: wsId)
        }
    }

    private func toggleWorkspaceLayout() {
        guard let controller else { return }
        guard let workspace = controller.activeWorkspace() else { return }
        let workspaceName = workspace.name

        let currentLayout = controller.settings.layoutType(for: workspaceName)

        let newLayout: LayoutType = switch currentLayout {
        case .niri, .defaultLayout: .dwindle
        case .dwindle: .niri
        }

        var configs = controller.settings.workspaceConfigurations
        if let index = configs.firstIndex(where: { $0.name == workspaceName }) {
            configs[index] = configs[index].with(layoutType: newLayout)
        } else {
            configs.append(WorkspaceConfiguration(
                name: workspaceName,
                layoutType: newLayout
            ))
        }

        controller.settings.workspaceConfigurations = configs
        controller.layoutRefreshController.refreshWindowsAndLayout()
    }
}

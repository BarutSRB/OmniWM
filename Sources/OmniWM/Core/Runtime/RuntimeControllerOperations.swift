// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation
import OSLog

private let runtimeLayoutSwitchAuditLog = Logger(
    subsystem: "com.omniwm.core",
    category: "RuntimeControllerOperations.LayoutSwitch"
)

/// Narrow runtime-facing controller operations.
///
/// Domain runtimes use this adapter for presentation/layout side effects that
/// still live on controller-owned collaborators. The adapter keeps those
/// dependencies out of `WMRuntime` backreferences while the runtime remains
/// the transaction owner.
@MainActor
final class RuntimeControllerOperations {
    private weak var controller: WMController?

    init(controller: WMController?) {
        self.controller = controller
    }

    func cancelManagedFocusRequestAndDiscardPending() {
        let canceledRequest = controller?.focusBridge.cancelManagedRequest()
        if let canceledRequest {
            controller?.focusBridge.discardPendingFocus(canceledRequest.token)
        }
    }

    func clearKeyboardFocusTarget() {
        controller?.clearKeyboardFocusTarget()
    }

    func hideKeyboardFocusBorder(source: BorderReconcileSource, reason: String) {
        controller?.hideKeyboardFocusBorder(source: source, reason: reason)
    }

    @discardableResult
    func reconcileBorderOwnership(event: BorderReconcileEvent) -> Bool {
        controller?.borderCoordinator.reconcile(event: event) ?? false
    }

    func rekeyWindowReferences(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        axRef: AXWindowRef,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller else { return }
        _ = controller.niriEngine?.rekeyWindow(from: oldToken, to: newToken)
        _ = controller.dwindleEngine?.rekeyWindow(
            from: oldToken,
            to: newToken,
            in: workspaceId
        )
        controller.focusBridge.rekeyPendingFocus(from: oldToken, to: newToken)
        controller.focusBridge.rekeyManagedRequest(from: oldToken, to: newToken)
        controller.focusBridge.rekeyFocusedTarget(
            from: oldToken,
            to: newToken,
            axRef: axRef,
            workspaceId: workspaceId
        )
    }

    func niriNode(for token: WindowToken) -> NiriNode? {
        controller?.niriEngine?.findNode(for: token)
    }

    @discardableResult
    func performControllerAction(_ action: WMCommand.ControllerActionCommand) -> ExternalCommandResult {
        guard let controller else { return .invalidArguments }

        switch action {
        case let .focusWorkspaceAnywhere(rawWorkspaceID, source):
            let previousWorkspaceId = controller.activeWorkspace()?.id
            let previousMonitorId = controller.workspaceManager.interactionMonitorId
                ?? controller.monitorForInteraction()?.id
            controller.workspaceNavigationHandler.focusWorkspaceAnywhere(
                rawWorkspaceID: rawWorkspaceID,
                source: source
            )
            let currentWorkspaceId = controller.activeWorkspace()?.id
            let currentMonitorId = controller.workspaceManager.interactionMonitorId
                ?? controller.monitorForInteraction()?.id
            return currentWorkspaceId != previousWorkspaceId || currentMonitorId != previousMonitorId
                ? .executed
                : .notFound

        case let .moveFocusedWindow(rawWorkspaceID, source):
            guard let token = controller.workspaceManager.focusedToken else { return .notFound }
            let previousWorkspaceId = controller.workspaceManager.workspace(for: token)
            controller.workspaceNavigationHandler.moveFocusedWindow(
                toRawWorkspaceID: rawWorkspaceID,
                source: source
            )
            return controller.workspaceManager.workspace(for: token) != previousWorkspaceId
                ? .executed
                : .notFound

        case let .moveFocusedWindowOnMonitor(rawWorkspaceID, monitorDirection, source):
            guard let token = controller.workspaceManager.focusedToken else { return .notFound }
            let previousWorkspaceId = controller.workspaceManager.workspace(for: token)
            controller.workspaceNavigationHandler.moveWindowToWorkspaceOnMonitor(
                rawWorkspaceID: rawWorkspaceID,
                monitorDirection: monitorDirection,
                source: source
            )
            return controller.workspaceManager.workspace(for: token) != previousWorkspaceId
                ? .executed
                : .notFound

        case let .setWorkspaceLayout(layout, source):
            return setWorkspaceLayout(layout, source: source) ? .executed : .notFound

        case let .rescueOffscreenWindows(source):
            return controller.rescueOffscreenWindows(source: source) > 0
                ? .executed
                : .notFound

        case let .focusWorkspace(name, source):
            return controller.windowActionHandler.focusWorkspaceFromBar(named: name, source: source)
                ? .executed
                : .notFound

        case let .focusWindow(token, source):
            return controller.windowActionHandler.focusWindowFromBar(token: token, source: source)
                ? .executed
                : .notFound

        case let .navigateToWindow(handle, source):
            return controller.windowActionHandler.navigateToWindow(handle: handle, source: source)
                ? .executed
                : .notFound

        case let .summonWindowRight(handle, source):
            return controller.windowActionHandler.summonWindowRight(handle: handle, source: source)
                ? .executed
                : .notFound
        }
    }

    @discardableResult
    func performFocusAction(_ action: WMCommand.FocusActionCommand) -> ExternalCommandResult {
        guard let controller else { return .invalidArguments }
        switch action {
        case let .focusNeighbor(direction, source):
            layoutHandler(as: LayoutFocusable.self)?
                .focusNeighbor(direction: direction, source: source)
        case let .focusPrevious(source):
            focusPreviousInNiri(source: source)
        case let .focusDownOrLeft(source):
            focusDownOrLeftInNiri(source: source)
        case let .focusUpOrRight(source):
            focusUpOrRightInNiri(source: source)
        case let .focusColumnFirst(source):
            focusColumnFirstInNiri(source: source)
        case let .focusColumnLast(source):
            focusColumnLastInNiri(source: source)
        case let .focusColumn(index, source):
            focusColumnInNiri(index: index, source: source)
        case let .focusMonitorPrevious(source):
            controller.workspaceNavigationHandler.focusMonitorCyclic(previous: true, source: source)
        case let .focusMonitorNext(source):
            controller.workspaceNavigationHandler.focusMonitorCyclic(previous: false, source: source)
        case let .focusMonitorLast(source):
            controller.workspaceNavigationHandler.focusLastMonitor(source: source)
        }
        return .executed
    }

    @discardableResult
    func performWindowMoveAction(_ action: WMCommand.WindowMoveActionCommand) -> ExternalCommandResult {
        guard let controller else { return .invalidArguments }
        switch action {
        case let .moveWindow(direction, source):
            moveWindow(direction: direction, source: source)
        case let .moveColumn(direction, source):
            moveColumnInNiri(direction: direction, source: source)
        case let .moveWindowToWorkspaceUp(source):
            controller.workspaceNavigationHandler.moveWindowToAdjacentWorkspace(direction: .up, source: source)
        case let .moveWindowToWorkspaceDown(source):
            controller.workspaceNavigationHandler.moveWindowToAdjacentWorkspace(direction: .down, source: source)
        case let .moveColumnToWorkspace(index, source):
            controller.workspaceNavigationHandler.moveColumnToWorkspaceByIndex(index: index, source: source)
        case let .moveColumnToWorkspaceUp(source):
            controller.workspaceNavigationHandler.moveColumnToAdjacentWorkspace(direction: .up, source: source)
        case let .moveColumnToWorkspaceDown(source):
            controller.workspaceNavigationHandler.moveColumnToAdjacentWorkspace(direction: .down, source: source)
        }
        return .executed
    }

    @discardableResult
    func performWorkspaceNavigationAction(
        _ action: WMCommand.WorkspaceNavigationActionCommand
    ) -> ExternalCommandResult {
        guard let controller else { return .invalidArguments }
        switch action {
        case let .workspaceBackAndForth(source):
            controller.workspaceNavigationHandler.workspaceBackAndForth(source: source)
        }
        return .executed
    }

    @discardableResult
    func performLayoutMutationAction(
        _ action: WMCommand.LayoutMutationActionCommand
    ) -> ExternalCommandResult {
        guard let controller else { return .invalidArguments }
        switch action {
        case let .toggleFullscreen(source):
            toggleFullscreen(source: source)
        case let .toggleNativeFullscreen(source):
            toggleNativeFullscreenForFocused(source: source)
        case let .toggleColumnTabbed(source):
            toggleColumnTabbedInNiri(source: source)
        case let .toggleColumnFullWidth(source):
            controller.niriLayoutHandler.toggleColumnFullWidth(source: source)
        case let .cycleColumnWidthForward(source):
            layoutHandler(as: LayoutSizable.self)?
                .cycleSize(forward: true, source: source)
        case let .cycleColumnWidthBackward(source):
            layoutHandler(as: LayoutSizable.self)?
                .cycleSize(forward: false, source: source)
        case let .swapWorkspaceWithMonitor(direction, source):
            controller.workspaceNavigationHandler.swapCurrentWorkspaceWithMonitor(
                direction: direction,
                source: source
            )
        case let .cycleMonitors(source):
            return controller.workspaceNavigationHandler.cycleMonitors(source: source)
        case let .balanceSizes(source):
            layoutHandler(as: LayoutSizable.self)?
                .balanceSizes(source: source)
        case .moveToRoot:
            moveToRootInDwindle()
        case .toggleSplit:
            toggleSplitInDwindle()
        case .swapSplit:
            swapSplitInDwindle()
        case let .resizeInDirection(direction, grow, _):
            resizeInDirectionInDwindle(direction: direction, grow: grow)
        case let .preselect(direction, _):
            preselectInDwindle(direction: direction)
        case .preselectClear:
            clearPreselectInDwindle()
        case .toggleWorkspaceLayout:
            toggleWorkspaceLayout()
        case .raiseAllFloatingWindows:
            controller.raiseAllFloatingWindows()
        case let .toggleFocusedWindowFloating(source):
            controller.toggleFocusedWindowFloating(source: source)
        case let .assignFocusedWindowToScratchpad(source):
            controller.assignFocusedWindowToScratchpad(source: source)
        case let .toggleScratchpadWindow(source):
            controller.toggleScratchpadWindow(source: source)
        }
        return .executed
    }

    private func layoutHandler<T>(as capability: T.Type) -> T? {
        guard let controller else { return nil }
        let handler: AnyObject = switch currentLayoutType() {
        case .dwindle:
            controller.layoutRefreshController.dwindleHandler
        case .niri, .defaultLayout:
            controller.layoutRefreshController.niriHandler
        }
        return handler as? T
    }

    private func currentLayoutType() -> LayoutType {
        guard let controller else { return .niri }
        guard let workspace = controller.activeWorkspace() else { return .niri }
        return controller.settings.layoutType(for: workspace.name)
    }

    private func focusPreviousInNiri(source: WMEventSource) {
        guard let controller else { return }
        controller.niriLayoutHandler.withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps in
            if let currentId = state.selectedNodeId {
                engine.updateFocusTimestamp(for: currentId)
            }

            if let currentId = state.selectedNodeId {
                engine.activateWindow(currentId)
            }

            guard let previousWindow = engine.focusPrevious(
                currentNodeId: state.selectedNodeId,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                limitToWorkspace: true
            ) else {
                return
            }

            controller.niriLayoutHandler.activateNode(
                previousWindow,
                in: wsId,
                state: &state,
                source: source,
                options: .init(ensureVisible: false, updateTimestamp: false, startAnimation: false)
            )

            if state.viewOffsetPixels.isAnimating {
                controller.layoutRefreshController.startScrollAnimation(for: wsId)
            }
        }
    }

    private func focusDownOrLeftInNiri(source: WMEventSource) {
        executeCombinedNavigation(source: source) { engine, currentNode, wsId, motion, state, workingFrame, gaps in
            engine.focusDownOrLeft(
                currentSelection: currentNode,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }
    }

    private func focusUpOrRightInNiri(source: WMEventSource) {
        executeCombinedNavigation(source: source) { engine, currentNode, wsId, motion, state, workingFrame, gaps in
            engine.focusUpOrRight(
                currentSelection: currentNode,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }
    }

    private func focusColumnFirstInNiri(source: WMEventSource) {
        executeCombinedNavigation(source: source) { engine, currentNode, wsId, motion, state, workingFrame, gaps in
            engine.focusColumnFirst(
                currentSelection: currentNode,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }
    }

    private func focusColumnLastInNiri(source: WMEventSource) {
        executeCombinedNavigation(source: source) { engine, currentNode, wsId, motion, state, workingFrame, gaps in
            engine.focusColumnLast(
                currentSelection: currentNode,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }
    }

    private func focusColumnInNiri(index: Int, source: WMEventSource) {
        executeCombinedNavigation(source: source) { engine, currentNode, wsId, motion, state, workingFrame, gaps in
            engine.focusColumn(
                index,
                currentSelection: currentNode,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }
    }

    private func executeCombinedNavigation(
        source: WMEventSource,
        _ navigationAction: (
            NiriLayoutEngine,
            NiriNode,
            WorkspaceDescriptor.ID,
            MotionSnapshot,
            inout ViewportState,
            CGRect,
            CGFloat
        )
            -> NiriNode?
    ) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }
        guard let monitor = controller.workspaceManager.monitor(for: wsId) else { return }

        var state = controller.workspaceManager.niriViewportState(for: wsId)
        guard let currentId = state.selectedNodeId,
              let currentNode = engine.findNode(by: currentId)
        else {
            return
        }

        let gap = CGFloat(controller.workspaceManager.gaps)
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let motion = controller.motionPolicy.snapshot()
        guard let newNode = navigationAction(engine, currentNode, wsId, motion, &state, workingFrame, gap) else {
            return
        }

        controller.niriLayoutHandler.activateNode(
            newNode,
            in: wsId,
            state: &state,
            source: source,
            options: .init(activateWindow: false, ensureVisible: false)
        )
        let patch = WorkspaceSessionPatch(
            workspaceId: wsId,
            viewportState: state,
            rememberedFocusToken: nil
        )
        guard let runtime = controller.runtime else {
            preconditionFailure("RuntimeControllerOperations.executeCombinedNavigation requires WMRuntime to be attached")
        }
        _ = runtime.applySessionPatch(patch, source: source)
    }

    private func moveWindow(direction: Direction, source: WMEventSource) {
        switch currentLayoutType() {
        case .dwindle:
            controller?.dwindleLayoutHandler.swapWindow(direction: direction, source: source)
        case .niri, .defaultLayout:
            moveWindowInNiri(direction: direction, source: source)
        }
    }

    private func toggleFullscreen(source: WMEventSource) {
        switch currentLayoutType() {
        case .dwindle:
            controller?.dwindleLayoutHandler.toggleFullscreen(source: source)
        case .niri, .defaultLayout:
            controller?.niriLayoutHandler.toggleFullscreen(source: source)
        }
    }

    private func moveWindowInNiri(direction: Direction, source: WMEventSource) {
        guard let controller else { return }
        controller.niriLayoutHandler.withNiriOperationContext(source: source) { ctx, state in
            let oldFrames = direction == .left || direction == .right
                ? [:]
                : ctx.engine.captureWindowFrames(in: ctx.wsId)
            guard ctx.engine.moveWindow(
                ctx.windowNode,
                direction: direction,
                in: ctx.wsId,
                motion: ctx.motion,
                state: &state,
                workingFrame: ctx.workingFrame,
                gaps: ctx.gaps
            ) else {
                return nil
            }
            if direction == .left || direction == .right {
                return ctx.commitSimple()
            }
            return ctx.commitWithPredictedAnimation(oldFrames: oldFrames)
        }
    }

    private func toggleNativeFullscreenForFocused(source: WMEventSource) {
        guard let controller else { return }
        let setFullscreen = controller.nativeFullscreenSetterForCommand
            ?? { axRef, fullscreen in AXWindowService.setNativeFullscreen(axRef, fullscreen: fullscreen) }
        let isFullscreen = controller.nativeFullscreenStateProviderForCommand
            ?? { axRef in AXWindowService.isFullscreen(axRef) }

        if let token = controller.workspaceManager.focusedToken,
           let entry = controller.workspaceManager.entry(for: token)
        {
            let currentState = isFullscreen(entry.axRef)
            if currentState {
                guard let runtime = controller.runtime else {
                    preconditionFailure("RuntimeControllerOperations.toggleNativeFullscreen requires WMRuntime")
                }
                _ = runtime.requestNativeFullscreenExit(
                    token,
                    initiatedByCommand: true,
                    source: source
                )
                guard setFullscreen(entry.axRef, false) else {
                    _ = controller.suspendManagedWindowForNativeFullscreen(
                        token,
                        path: .commandExitSetFailure
                    )
                    return
                }
                return
            }

            _ = controller.requestManagedNativeFullscreenEnter(
                token,
                in: entry.workspaceId,
                path: .commandDrivenEnter
            )
            guard setFullscreen(entry.axRef, true) else {
                _ = controller.routeRestoreNativeFullscreenRecord(for: token, source: source)
                return
            }
            return
        }

        guard controller.workspaceManager.isAppFullscreenActive
            || controller.workspaceManager.hasPendingNativeFullscreenTransition
        else {
            return
        }

        let frontmostPid = controller.frontmostAppPidProviderForCommand?()
            ?? FrontmostApplicationState.shared.snapshot?.pid
        let frontmostToken = controller.frontmostFocusedWindowTokenProviderForCommand?()
            ?? frontmostPid.flatMap { controller.axEventHandler.focusedWindowToken(for: $0) }
        guard let token = controller.workspaceManager.nativeFullscreenCommandTarget(frontmostToken: frontmostToken),
              let entry = controller.workspaceManager.entry(for: token)
        else {
            return
        }

        guard let runtime = controller.runtime else {
            preconditionFailure("RuntimeControllerOperations.toggleNativeFullscreen requires WMRuntime")
        }
        _ = runtime.requestNativeFullscreenExit(
            token,
            initiatedByCommand: true,
            source: source
        )
        guard setFullscreen(entry.axRef, false) else {
            _ = controller.suspendManagedWindowForNativeFullscreen(
                token,
                path: .commandExitSetFailure
            )
            return
        }
    }

    private func moveColumnInNiri(direction: Direction, source: WMEventSource) {
        guard let controller else { return }
        controller.niriLayoutHandler.withNiriOperationContext(source: source) { ctx, state in
            guard let column = ctx.engine.findColumn(containing: ctx.windowNode, in: ctx.wsId) else { return nil }
            let oldFrames = ctx.engine.captureWindowFrames(in: ctx.wsId)
            guard ctx.engine.moveColumn(
                column,
                direction: direction,
                in: ctx.wsId,
                motion: ctx.motion,
                state: &state,
                workingFrame: ctx.workingFrame,
                gaps: ctx.gaps
            ) else {
                return nil
            }
            return ctx.commitWithCapturedAnimation(oldFrames: oldFrames)
        }
    }

    private func toggleColumnTabbedInNiri(source: WMEventSource) {
        guard let controller else { return }
        let result = controller.niriLayoutHandler.withNiriWorkspaceContext(source: source) {
            engine, wsId, motion, state, _, _, _ -> (NiriLayoutEngine, WorkspaceDescriptor.ID, Bool)? in
            guard engine.toggleColumnTabbed(in: wsId, state: state, motion: motion) else {
                return nil
            }
            return (engine, wsId, engine.hasAnyWindowAnimationsRunning(in: wsId))
        } ?? nil
        guard let (_, wsId, shouldStartAnimation) = result else { return }
        controller.layoutRefreshController.requestImmediateRelayout(
            reason: .layoutCommand,
            affectedWorkspaceIds: [wsId]
        )
        if shouldStartAnimation {
            controller.layoutRefreshController.startScrollAnimation(for: wsId)
        }
    }

    private func moveToRootInDwindle() {
        guard let controller else { return }
        controller.dwindleLayoutHandler.moveSelectionToRoot(stable: controller.settings.dwindleMoveToRootStable)
    }

    private func toggleSplitInDwindle() {
        controller?.dwindleLayoutHandler.toggleSplit()
    }

    private func swapSplitInDwindle() {
        controller?.dwindleLayoutHandler.swapSplit()
    }

    private func resizeInDirectionInDwindle(direction: Direction, grow: Bool) {
        controller?.dwindleLayoutHandler.resize(direction: direction, grow: grow)
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

        _ = setWorkspaceLayout(newLayout, forWorkspaceNamed: workspaceName, source: .command)
    }

    @discardableResult
    func setWorkspaceLayout(
        _ newLayout: LayoutType,
        forWorkspaceNamed workspaceName: String? = nil,
        source: WMEventSource = .command
    ) -> Bool {
        guard let controller else { return false }
        let resolvedWorkspaceName = workspaceName ?? controller.activeWorkspace()?.name
        guard let resolvedWorkspaceName else { return false }

        var configs = controller.settings.workspaceConfigurations
        guard let index = configs.firstIndex(where: { $0.name == resolvedWorkspaceName }) else { return false }

        let oldLayout = configs[index].layoutType
        guard oldLayout != newLayout else { return false }

        let preGraph = controller.workspaceManager.workspaceGraphSnapshot()

        configs[index] = configs[index].with(layoutType: newLayout)
        controller.settings.workspaceConfigurations = configs
        guard let runtime = controller.runtime else {
            preconditionFailure("RuntimeControllerOperations.setWorkspaceLayout requires WMRuntime to be attached")
        }
        _ = runtime.applyWorkspaceSettings(source: source)

        let postGraph = controller.workspaceManager.workspaceGraphSnapshot()
        if !preGraph.preservesLayoutSwitchInvariants(equals: postGraph) {
            runtimeLayoutSwitchAuditLog.warning(
                "layout_switch_graph_drift workspace=\(resolvedWorkspaceName, privacy: .public) old=\(oldLayout.rawValue, privacy: .public) new=\(newLayout.rawValue, privacy: .public)"
            )
            assertionFailure(
                "Layout switch broke graph preservation for workspace \(resolvedWorkspaceName)"
            )
        }

        controller.layoutRefreshController.requestRelayout(reason: .workspaceLayoutToggled)
        if let ipcApplicationBridge = controller.ipcApplicationBridge {
            Task {
                await ipcApplicationBridge.publishEvent(.layoutChanged)
            }
        }
        return true
    }

    @discardableResult
    func performUIAction(_ action: WMCommand.UIActionCommand) -> ExternalCommandResult {
        guard let controller else { return .invalidArguments }
        switch action {
        case .openCommandPalette:
            controller.openCommandPalette()
        case .openMenuAnywhere:
            controller.openMenuAnywhere()
        case .toggleWorkspaceBarVisibility:
            _ = controller.toggleWorkspaceBarVisibility()
        case .toggleHiddenBar:
            controller.toggleHiddenBar()
        case .toggleQuakeTerminal:
            controller.toggleQuakeTerminal()
        case .toggleOverview:
            controller.toggleOverview()
        }
        return .executed
    }
}

// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import OmniWMIPC

@MainActor
final class IPCCommandRouter {
    let controller: WMController
    private let sessionToken: String

    init(controller: WMController, sessionToken: String) {
        self.controller = controller
        self.sessionToken = sessionToken
    }

    func handle(_ request: IPCCommandRequest) -> ExternalCommandResult {
        if let result = handleFocusCommand(request) {
            return result
        }
        if let result = handleWorkspaceSwitchCommand(request) {
            return result
        }
        if let result = handleWorkspaceMoveCommand(request) {
            return result
        }
        if let result = handleMonitorCommand(request) {
            return result
        }
        if let result = handleColumnCommand(request) {
            return result
        }
        if let result = handleLayoutMutationCommand(request) {
            return result
        }
        if let result = handleWorkspaceLayoutCommand(request) {
            return result
        }
        if let result = handleWindowManagementCommand(request) {
            return result
        }
        return handleInterfaceCommand(request)
    }

    func handle(_ request: IPCWorkspaceRequest) -> ExternalCommandResult {
        if let guardResult = validateControllerState() {
            return guardResult
        }
        let rawWorkspaceID: String
        switch resolveWorkspaceTarget(request.target) {
        case let .success(resolved):
            rawWorkspaceID = resolved
        case let .failure(result):
            return result
        }

        return controller.windowActionHandler.focusWorkspaceFromBar(named: rawWorkspaceID) ? .executed : .notFound
    }

    func handle(_ request: IPCWindowRequest) -> ExternalCommandResult {
        if let guardResult = validateControllerState() {
            return guardResult
        }

        switch IPCWindowOpaqueID.validate(request.windowId, expectingSessionToken: sessionToken) {
        case .invalid:
            return .invalidArguments
        case .stale:
            return .staleWindowId
        case let .valid(pid, windowId):
            let token = WindowToken(pid: pid, windowId: windowId)
            switch request.name {
            case .focus:
                return controller.windowActionHandler.focusWindowFromBar(token: token)
                    ? .executed
                    : .notFound
            case .navigate:
                guard let handle = controller.workspaceManager.handle(for: token) else {
                    return .notFound
                }
                return controller.windowActionHandler.navigateToWindow(handle: handle)
                    ? .executed
                    : .notFound
            case .summonRight:
                guard let handle = controller.workspaceManager.handle(for: token) else {
                    return .notFound
                }
                return controller.windowActionHandler.summonWindowRight(handle: handle)
                    ? .executed
                    : .notFound
            }
        }
    }

    private func perform(_ command: HotkeyCommand) -> ExternalCommandResult {
        controller.commandHandler.performCommand(command)
    }

    private func validateControllerState() -> ExternalCommandResult? {
        guard controller.isEnabled else { return .ignoredDisabled }
        guard !controller.isOverviewOpen() else { return .ignoredOverview }
        return nil
    }

    private func direction(for value: IPCDirection) -> Direction {
        switch value {
        case .left:
            .left
        case .right:
            .right
        case .up:
            .up
        case .down:
            .down
        }
    }

    private func zeroBasedIndex(from oneBasedValue: Int) -> Int? {
        guard oneBasedValue > 0 else { return nil }
        return oneBasedValue - 1
    }

    private func workspaceTarget(from workspaceNumber: Int) -> WorkspaceTarget? {
        WorkspaceTarget(workspaceNumber: workspaceNumber)
    }
}
private extension IPCCommandRouter {
    func handleFocusCommand(_ request: IPCCommandRequest) -> ExternalCommandResult? {
        switch request {
        case let .focus(ipcDirection):
            return perform(.focus(direction(for: ipcDirection)))
        case .focusPrevious:
            return perform(.focusPrevious)
        case .focusDownOrLeft:
            return perform(.focusDownOrLeft)
        case .focusUpOrRight:
            return perform(.focusUpOrRight)
        case let .focusColumn(columnIndex):
            guard let zeroBasedIndex = zeroBasedIndex(from: columnIndex) else {
                return .invalidArguments
            }
            return perform(.focusColumn(zeroBasedIndex))
        case .focusColumnFirst:
            return perform(.focusColumnFirst)
        case .focusColumnLast:
            return perform(.focusColumnLast)
        case let .move(ipcDirection):
            return perform(.move(direction(for: ipcDirection)))
        default:
            return nil
        }
    }
    func handleWorkspaceSwitchCommand(_ request: IPCCommandRequest) -> ExternalCommandResult? {
        switch request {
        case let .switchWorkspace(workspaceNumber):
            guard let target = workspaceTarget(from: workspaceNumber) else {
                return .invalidArguments
            }
            return switchWorkspace(to: target)
        case .switchWorkspaceNext:
            return switchWorkspace(using: .switchWorkspaceNext)
        case .switchWorkspacePrevious:
            return switchWorkspace(using: .switchWorkspacePrevious)
        case .switchWorkspaceBackAndForth:
            return switchWorkspace(using: .workspaceBackAndForth)
        case let .switchWorkspaceAnywhere(workspaceNumber):
            guard let target = workspaceTarget(from: workspaceNumber) else {
                return .invalidArguments
            }
            return switchWorkspaceAnywhere(to: target)
        default:
            return nil
        }
    }
    func handleWorkspaceMoveCommand(_ request: IPCCommandRequest) -> ExternalCommandResult? {
        switch request {
        case let .moveToWorkspace(workspaceNumber):
            guard let target = workspaceTarget(from: workspaceNumber) else {
                return .invalidArguments
            }
            return moveFocusedWindow(to: target)
        case .moveToWorkspaceUp:
            return moveFocusedWindow(using: .moveWindowToWorkspaceUp)
        case .moveToWorkspaceDown:
            return moveFocusedWindow(using: .moveWindowToWorkspaceDown)
        case let .moveToWorkspaceOnMonitor(workspaceNumber, ipcDirection):
            guard let target = workspaceTarget(from: workspaceNumber) else {
                return .invalidArguments
            }
            return moveFocusedWindow(
                to: target,
                onMonitor: direction(for: ipcDirection)
            )
        default:
            return nil
        }
    }
    func handleMonitorCommand(_ request: IPCCommandRequest) -> ExternalCommandResult? {
        switch request {
        case .focusMonitorPrevious:
            return focusMonitor(previous: true)
        case .focusMonitorNext:
            return focusMonitor(previous: false)
        case .focusMonitorLast:
            return focusLastMonitor()
        case let .swapWorkspaceWithMonitor(ipcDirection):
            return swapWorkspaceWithMonitor(direction: direction(for: ipcDirection))
        default:
            return nil
        }
    }
    func handleColumnCommand(_ request: IPCCommandRequest) -> ExternalCommandResult? {
        switch request {
        case let .moveColumn(ipcDirection):
            return perform(.moveColumn(direction(for: ipcDirection)))
        case let .moveColumnToWorkspace(workspaceNumber):
            guard let workspaceIndex = zeroBasedIndex(from: workspaceNumber) else {
                return .invalidArguments
            }
            return perform(.moveColumnToWorkspace(workspaceIndex))
        case .moveColumnToWorkspaceUp:
            return perform(.moveColumnToWorkspaceUp)
        case .moveColumnToWorkspaceDown:
            return perform(.moveColumnToWorkspaceDown)
        case .toggleColumnTabbed:
            return perform(.toggleColumnTabbed)
        case .cycleColumnWidthForward:
            return perform(.cycleColumnWidthForward)
        case .cycleColumnWidthBackward:
            return perform(.cycleColumnWidthBackward)
        case .toggleColumnFullWidth:
            return perform(.toggleColumnFullWidth)
        default:
            return nil
        }
    }
    func handleLayoutMutationCommand(_ request: IPCCommandRequest) -> ExternalCommandResult? {
        switch request {
        case .balanceSizes:
            return perform(.balanceSizes)
        case .moveToRoot:
            return perform(.moveToRoot)
        case .toggleSplit:
            return perform(.toggleSplit)
        case .swapSplit:
            return perform(.swapSplit)
        case let .resize(ipcDirection, operation):
            return perform(
                .resizeInDirection(direction(for: ipcDirection), operation == .grow)
            )
        case let .preselect(ipcDirection):
            return perform(.preselect(direction(for: ipcDirection)))
        case .preselectClear:
            return perform(.preselectClear)
        default:
            return nil
        }
    }
    func handleWorkspaceLayoutCommand(_ request: IPCCommandRequest) -> ExternalCommandResult? {
        switch request {
        case .toggleWorkspaceLayout:
            return perform(.toggleWorkspaceLayout)
        case let .setWorkspaceLayout(layout):
            if let guardResult = validateControllerState() {
                return guardResult
            }
            return controller.commandHandler.setWorkspaceLayout(layoutType(for: layout))
                ? .executed
                : .notFound
        default:
            return nil
        }
    }
    func handleWindowManagementCommand(_ request: IPCCommandRequest) -> ExternalCommandResult? {
        switch request {
        case .raiseAllFloatingWindows:
            return raiseAllFloatingWindows()
        case .rescueOffscreenWindows:
            return rescueOffscreenWindows()
        case .toggleFullscreen:
            return perform(.toggleFullscreen)
        case .toggleNativeFullscreen:
            return perform(.toggleNativeFullscreen)
        case .toggleFocusedWindowFloating:
            return toggleFocusedWindowFloating()
        case .scratchpadAssign:
            return assignFocusedWindowToScratchpad()
        case .scratchpadToggle:
            return toggleScratchpad()
        default:
            return nil
        }
    }
    func handleInterfaceCommand(_ request: IPCCommandRequest) -> ExternalCommandResult {
        switch request {
        case .openCommandPalette:
            return perform(.openCommandPalette)
        case .toggleOverview:
            return perform(.toggleOverview)
        case .toggleQuakeTerminal:
            return perform(.toggleQuakeTerminal)
        case .toggleWorkspaceBar:
            return perform(.toggleWorkspaceBarVisibility)
        case .toggleHiddenBar:
            return perform(.toggleHiddenBar)
        case .openMenuAnywhere:
            return perform(.openMenuAnywhere)
        default:
            return .invalidArguments
        }
    }
}
private extension IPCCommandRouter {
    func focusMonitor(previous: Bool) -> ExternalCommandResult {
        let previousMonitorId = controller.workspaceManager.interactionMonitorId
            ?? controller.monitorForInteraction()?.id
        _ = perform(previous ? .focusMonitorPrevious : .focusMonitorNext)
        let currentMonitorId = controller.workspaceManager.interactionMonitorId
            ?? controller.monitorForInteraction()?.id
        return currentMonitorId == previousMonitorId ? .notFound : .executed
    }
    func focusLastMonitor() -> ExternalCommandResult {
        let previousMonitorId = controller.workspaceManager.interactionMonitorId
            ?? controller.monitorForInteraction()?.id
        _ = perform(.focusMonitorLast)
        let currentMonitorId = controller.workspaceManager.interactionMonitorId
            ?? controller.monitorForInteraction()?.id
        return currentMonitorId == previousMonitorId ? .notFound : .executed
    }
    func layoutType(for value: IPCWorkspaceLayout) -> LayoutType {
        switch value {
        case .defaultLayout:
            .defaultLayout
        case .niri:
            .niri
        case .dwindle:
            .dwindle
        }
    }
    func switchWorkspace(using command: HotkeyCommand) -> ExternalCommandResult {
        let previousWorkspaceId = controller.activeWorkspace()?.id
        let result = perform(command)
        guard result == .executed else { return result }
        return controller.activeWorkspace()?.id == previousWorkspaceId ? .notFound : .executed
    }
    func moveFocusedWindow(using command: HotkeyCommand) -> ExternalCommandResult {
        guard let token = controller.workspaceManager.focusedToken else { return .notFound }
        let previousWorkspaceId = controller.workspaceManager.workspace(for: token)
        let result = perform(command)
        guard result == .executed else { return result }
        return controller.workspaceManager.workspace(for: token) == previousWorkspaceId ? .notFound : .executed
    }
    func swapWorkspaceWithMonitor(direction: Direction) -> ExternalCommandResult {
        let previousWorkspaceId = controller.activeWorkspace()?.id
        let result = perform(.swapWorkspaceWithMonitor(direction))
        guard result == .executed else { return result }
        return controller.activeWorkspace()?.id == previousWorkspaceId ? .notFound : .executed
    }
    func raiseAllFloatingWindows() -> ExternalCommandResult {
        if let guardResult = validateControllerState() {
            return guardResult
        }
        guard controller.windowActionHandler.hasRaisableFloatingWindows() else {
            return .notFound
        }
        return perform(.raiseAllFloatingWindows)
    }
    func rescueOffscreenWindows() -> ExternalCommandResult {
        if let guardResult = validateControllerState() {
            return guardResult
        }
        return controller.rescueOffscreenWindows() > 0 ? .executed : .notFound
    }
    func toggleFocusedWindowFloating() -> ExternalCommandResult {
        guard let token = controller.workspaceManager.focusedToken else { return .notFound }
        let previousOverride = controller.workspaceManager.manualLayoutOverride(for: token)
        let previousMode = controller.workspaceManager.windowMode(for: token)
        _ = perform(.toggleFocusedWindowFloating)
        let currentOverride = controller.workspaceManager.manualLayoutOverride(for: token)
        let currentMode = controller.workspaceManager.windowMode(for: token)
        return currentOverride == previousOverride && currentMode == previousMode ? .notFound : .executed
    }
    func assignFocusedWindowToScratchpad() -> ExternalCommandResult {
        let previousScratchpadToken = controller.workspaceManager.scratchpadToken()
        _ = perform(.assignFocusedWindowToScratchpad)
        return controller.workspaceManager.scratchpadToken() == previousScratchpadToken ? .notFound : .executed
    }
    func toggleScratchpad() -> ExternalCommandResult {
        guard let scratchpadToken = controller.workspaceManager.scratchpadToken() else { return .notFound }
        let wasHidden = controller.workspaceManager.hiddenState(for: scratchpadToken) != nil
        _ = perform(.toggleScratchpadWindow)
        let isHidden = controller.workspaceManager.hiddenState(for: scratchpadToken) != nil
        return wasHidden == isHidden ? .notFound : .executed
    }
    func switchWorkspace(to target: WorkspaceTarget) -> ExternalCommandResult {
        if let guardResult = validateControllerState() {
            return guardResult
        }
        let rawWorkspaceID: String
        switch resolveWorkspaceTarget(target) {
        case let .failure(result):
            return result
        case let .success(resolved):
            rawWorkspaceID = resolved
        }

        let previousWorkspaceId = controller.activeWorkspace()?.id
        controller.workspaceNavigationHandler.switchWorkspace(rawWorkspaceID: rawWorkspaceID)
        return controller.activeWorkspace()?.id == previousWorkspaceId ? .notFound : .executed
    }
    func switchWorkspaceAnywhere(to target: WorkspaceTarget) -> ExternalCommandResult {
        if let guardResult = validateControllerState() {
            return guardResult
        }
        let rawWorkspaceID: String
        switch resolveWorkspaceTarget(target) {
        case let .failure(result):
            return result
        case let .success(resolved):
            rawWorkspaceID = resolved
        }

        let previousWorkspaceId = controller.activeWorkspace()?.id
        let previousMonitorId = controller.workspaceManager.interactionMonitorId
            ?? controller.monitorForInteraction()?.id
        controller.workspaceNavigationHandler.focusWorkspaceAnywhere(rawWorkspaceID: rawWorkspaceID)
        let currentWorkspaceId = controller.activeWorkspace()?.id
        let currentMonitorId = controller.workspaceManager.interactionMonitorId
            ?? controller.monitorForInteraction()?.id
        return currentWorkspaceId == previousWorkspaceId
            && currentMonitorId == previousMonitorId
            ? .notFound
            : .executed
    }
    func moveFocusedWindow(to target: WorkspaceTarget) -> ExternalCommandResult {
        if let guardResult = validateControllerState() {
            return guardResult
        }
        guard let token = controller.workspaceManager.focusedToken else { return .notFound }
        let rawWorkspaceID: String
        switch resolveWorkspaceTarget(target) {
        case let .failure(result):
            return result
        case let .success(resolved):
            rawWorkspaceID = resolved
        }

        let previousWorkspaceId = controller.workspaceManager.workspace(for: token)
        controller.workspaceNavigationHandler.moveFocusedWindow(toRawWorkspaceID: rawWorkspaceID)
        return controller.workspaceManager.workspace(for: token) == previousWorkspaceId ? .notFound : .executed
    }
    func moveFocusedWindow(
        to target: WorkspaceTarget,
        onMonitor monitorDirection: Direction
    ) -> ExternalCommandResult {
        if let guardResult = validateControllerState() {
            return guardResult
        }
        guard let token = controller.workspaceManager.focusedToken else { return .notFound }
        let rawWorkspaceID: String
        switch resolveWorkspaceTarget(target) {
        case let .failure(result):
            return result
        case let .success(resolved):
            rawWorkspaceID = resolved
        }

        let previousWorkspaceId = controller.workspaceManager.workspace(for: token)
        controller.workspaceNavigationHandler.moveWindowToWorkspaceOnMonitor(
            rawWorkspaceID: rawWorkspaceID,
            monitorDirection: monitorDirection
        )
        return controller.workspaceManager.workspace(for: token) == previousWorkspaceId ? .notFound : .executed
    }
    func resolveWorkspaceTarget(_ target: WorkspaceTarget) -> Result<String, ExternalCommandResult> {
        let resolver = WorkspaceTargetResolver(
            settings: controller.settings,
            workspaceManager: controller.workspaceManager
        )

        switch resolver.resolve(target) {
        case let .success(rawWorkspaceID):
            return .success(rawWorkspaceID)
        case .failure(.notFound):
            return .failure(.notFound)
        case .failure(.invalidTarget), .failure(.ambiguousDisplayName):
            return .failure(.invalidArguments)
        }
    }
}

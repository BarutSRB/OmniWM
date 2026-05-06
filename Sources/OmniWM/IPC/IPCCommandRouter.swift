// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import OSLog
import OmniWMIPC

private let ipcShutdownRaceLog = Logger(
    subsystem: "com.omniwm.core",
    category: "IPCCommandRouter.ShutdownRace"
)

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

        return perform(.focusWorkspace(named: rawWorkspaceID, source: .ipc))
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
                return perform(.focusWindow(token, source: .ipc))
            case .navigate:
                guard let handle = controller.workspaceManager.handle(for: token) else {
                    return .notFound
                }
                return perform(.navigateToWindow(handle, source: .ipc))
            case .summonRight:
                guard let handle = controller.workspaceManager.handle(for: token) else {
                    return .notFound
                }
                return perform(.summonWindowRight(handle, source: .ipc))
            }
        }
    }

    private func perform(_ command: InputBindingTrigger) -> ExternalCommandResult {
        // The IPC server's read loop can deliver a request after WMRuntime
        // (held strongly by AppDelegate) has begun teardown but before
        // IPCServer.stop() has finished closing the socket. Soft-fail to
        // .invalidArguments rather than crashing the WM mid-shutdown — a
        // same-user client process otherwise has a deliberate way to crash
        // the WM by racing the teardown window.
        guard let runtime = controller.runtime else {
            ipcShutdownRaceLog.notice("IPCCommandRouter.perform: WMRuntime detached during shutdown; rejecting IPC command as invalidArguments")
            return .invalidArguments
        }
        return runtime.dispatchHotkey(command, source: .ipc)
    }

    private func perform(_ action: WMCommand.ControllerActionCommand) -> ExternalCommandResult {
        perform(.controllerAction(action))
    }

    private func perform(_ command: WMCommand) -> ExternalCommandResult {
        guard let runtime = optionalRuntime("IPCCommandRouter.perform(command)") else {
            return .invalidArguments
        }
        return runtime.dispatchCommand(command)
    }

    private func validateControllerState() -> ExternalCommandResult? {
        guard let runtime = optionalRuntime("IPCCommandRouter.validateControllerState") else {
            return .invalidArguments
        }
        return runtime.preflightCommand()
    }

    /// Soft accessor for `controller.runtime`. Logs and returns nil when the
    /// weak runtime has been released — typically because IPC delivery raced
    /// AppKit teardown. Callers must treat nil as a shutdown-race signal and
    /// return a non-crashing `ExternalCommandResult` (typically
    /// `.invalidArguments`).
    private func optionalRuntime(_ context: String) -> WMRuntime? {
        guard let runtime = controller.runtime else {
            ipcShutdownRaceLog.notice("\(context): WMRuntime detached during shutdown; soft-failing")
            return nil
        }
        return runtime
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
            if let guardResult = validateControllerState() {
                return guardResult
            }
            return perform(.focus(direction(for: ipcDirection)))
        case .focusPrevious:
            if let guardResult = validateControllerState() {
                return guardResult
            }
            return perform(.focusPrevious)
        case .focusDownOrLeft:
            if let guardResult = validateControllerState() {
                return guardResult
            }
            return perform(.focusDownOrLeft)
        case .focusUpOrRight:
            if let guardResult = validateControllerState() {
                return guardResult
            }
            return perform(.focusUpOrRight)
        case let .focusColumn(columnIndex):
            guard let zeroBasedIndex = zeroBasedIndex(from: columnIndex) else {
                return .invalidArguments
            }
            if let guardResult = validateControllerState() {
                return guardResult
            }
            return perform(.focusColumn(zeroBasedIndex))
        case .focusColumnFirst:
            if let guardResult = validateControllerState() {
                return guardResult
            }
            return perform(.focusColumnFirst)
        case .focusColumnLast:
            if let guardResult = validateControllerState() {
                return guardResult
            }
            return perform(.focusColumnLast)
        case let .move(ipcDirection):
            if let guardResult = validateControllerState() {
                return guardResult
            }
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
        case .cycleMonitors:
            return perform(.cycleMonitors)
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
            return perform(.setWorkspaceLayout(layoutType(for: layout), source: .ipc))
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
        if let guardResult = validateControllerState() {
            return guardResult
        }
        let previousMonitorId = controller.workspaceManager.interactionMonitorId
            ?? controller.monitorForInteraction()?.id
        let result = perform(previous ? .focusMonitorPrevious : .focusMonitorNext)
        guard result == .executed else { return result }
        let currentMonitorId = controller.workspaceManager.interactionMonitorId
            ?? controller.monitorForInteraction()?.id
        return currentMonitorId == previousMonitorId ? .notFound : .executed
    }
    func focusLastMonitor() -> ExternalCommandResult {
        if let guardResult = validateControllerState() {
            return guardResult
        }
        let previousMonitorId = controller.workspaceManager.interactionMonitorId
            ?? controller.monitorForInteraction()?.id
        let result = perform(.focusMonitorLast)
        guard result == .executed else { return result }
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
    func switchWorkspace(using command: InputBindingTrigger) -> ExternalCommandResult {
        if let guardResult = validateControllerState() {
            return guardResult
        }
        let previousWorkspaceId = controller.activeWorkspace()?.id
        let result = perform(command)
        guard result == .executed else { return result }
        return controller.activeWorkspace()?.id == previousWorkspaceId ? .notFound : .executed
    }
    func moveFocusedWindow(using command: InputBindingTrigger) -> ExternalCommandResult {
        if let guardResult = validateControllerState() {
            return guardResult
        }
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
        return perform(.rescueOffscreenWindows(source: .ipc))
    }
    func toggleFocusedWindowFloating() -> ExternalCommandResult {
        if let guardResult = validateControllerState() {
            return guardResult
        }
        guard let token = controller.workspaceManager.focusedToken else { return .notFound }
        let previousOverride = controller.workspaceManager.manualLayoutOverride(for: token)
        let previousMode = controller.workspaceManager.windowMode(for: token)
        let result = perform(.toggleFocusedWindowFloating)
        guard result == .executed else { return result }
        let currentOverride = controller.workspaceManager.manualLayoutOverride(for: token)
        let currentMode = controller.workspaceManager.windowMode(for: token)
        return currentOverride == previousOverride && currentMode == previousMode ? .notFound : .executed
    }
    func assignFocusedWindowToScratchpad() -> ExternalCommandResult {
        if let guardResult = validateControllerState() {
            return guardResult
        }
        let previousScratchpadToken = controller.workspaceManager.scratchpadToken()
        let result = perform(.assignFocusedWindowToScratchpad)
        guard result == .executed else { return result }
        return controller.workspaceManager.scratchpadToken() == previousScratchpadToken ? .notFound : .executed
    }
    func toggleScratchpad() -> ExternalCommandResult {
        if let guardResult = validateControllerState() {
            return guardResult
        }
        guard let scratchpadToken = controller.workspaceManager.scratchpadToken() else { return .notFound }
        let wasHidden = controller.workspaceManager.hiddenState(for: scratchpadToken) != nil
        let result = perform(.toggleScratchpadWindow)
        guard result == .executed else { return result }
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
        let result = perform(.workspaceSwitch(.explicitFrom(
            rawWorkspaceID: rawWorkspaceID,
            source: .ipc
        )))
        guard result == .executed else { return result }
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

        return perform(.focusWorkspaceAnywhere(rawWorkspaceID: rawWorkspaceID, source: .ipc))
    }
    func moveFocusedWindow(to target: WorkspaceTarget) -> ExternalCommandResult {
        if let guardResult = validateControllerState() {
            return guardResult
        }
        guard controller.workspaceManager.focusedToken != nil else { return .notFound }
        let rawWorkspaceID: String
        switch resolveWorkspaceTarget(target) {
        case let .failure(result):
            return result
        case let .success(resolved):
            rawWorkspaceID = resolved
        }

        return perform(.moveFocusedWindow(rawWorkspaceID: rawWorkspaceID, source: .ipc))
    }
    func moveFocusedWindow(
        to target: WorkspaceTarget,
        onMonitor monitorDirection: Direction
    ) -> ExternalCommandResult {
        if let guardResult = validateControllerState() {
            return guardResult
        }
        guard controller.workspaceManager.focusedToken != nil else { return .notFound }
        let rawWorkspaceID: String
        switch resolveWorkspaceTarget(target) {
        case let .failure(result):
            return result
        case let .success(resolved):
            rawWorkspaceID = resolved
        }

        return perform(.moveFocusedWindowOnMonitor(
            rawWorkspaceID: rawWorkspaceID,
            monitorDirection: monitorDirection,
            source: .ipc
        ))
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

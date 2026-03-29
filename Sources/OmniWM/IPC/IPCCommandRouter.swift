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
        switch request {
        case let .focus(ipcDirection):
            return controller.commandHandler.performCommand(.focus(direction(for: ipcDirection)))
        case .focusPrevious:
            return controller.commandHandler.performCommand(.focusPrevious)
        case .focusDownOrLeft:
            return controller.commandHandler.performCommand(.focusDownOrLeft)
        case .focusUpOrRight:
            return controller.commandHandler.performCommand(.focusUpOrRight)
        case let .focusColumn(columnIndex):
            guard let zeroBasedIndex = zeroBasedIndex(from: columnIndex) else {
                return .invalidArguments
            }
            return controller.commandHandler.performCommand(.focusColumn(zeroBasedIndex))
        case .focusColumnFirst:
            return controller.commandHandler.performCommand(.focusColumnFirst)
        case .focusColumnLast:
            return controller.commandHandler.performCommand(.focusColumnLast)
        case let .move(ipcDirection):
            return controller.commandHandler.performCommand(.move(direction(for: ipcDirection)))
        case let .switchWorkspace(workspaceNumber):
            guard let workspaceIndex = zeroBasedIndex(from: workspaceNumber) else {
                return .invalidArguments
            }
            return switchWorkspace(using: .switchWorkspace(workspaceIndex))
        case .switchWorkspaceNext:
            return switchWorkspace(using: .switchWorkspaceNext)
        case .switchWorkspacePrevious:
            return switchWorkspace(using: .switchWorkspacePrevious)
        case .switchWorkspaceBackAndForth:
            return switchWorkspace(using: .workspaceBackAndForth)
        case let .switchWorkspaceAnywhere(workspaceNumber):
            guard let workspaceIndex = zeroBasedIndex(from: workspaceNumber) else {
                return .invalidArguments
            }
            return switchWorkspaceAnywhere(to: workspaceIndex)
        case let .moveToWorkspace(workspaceNumber):
            guard let workspaceIndex = zeroBasedIndex(from: workspaceNumber) else {
                return .invalidArguments
            }
            return moveFocusedWindow(using: .moveToWorkspace(workspaceIndex))
        case .moveToWorkspaceUp:
            return moveFocusedWindow(using: .moveWindowToWorkspaceUp)
        case .moveToWorkspaceDown:
            return moveFocusedWindow(using: .moveWindowToWorkspaceDown)
        case let .moveToWorkspaceOnMonitor(workspaceNumber, ipcDirection):
            guard let workspaceIndex = zeroBasedIndex(from: workspaceNumber) else {
                return .invalidArguments
            }
            return moveFocusedWindow(
                using: .moveWindowToWorkspaceOnMonitor(
                    workspaceIndex: workspaceIndex,
                    monitorDirection: direction(for: ipcDirection)
                )
            )
        case .focusMonitorPrevious:
            return focusMonitor(previous: true)
        case .focusMonitorNext:
            return focusMonitor(previous: false)
        case .focusMonitorLast:
            return focusLastMonitor()
        case let .moveColumn(ipcDirection):
            return controller.commandHandler.performCommand(.moveColumn(direction(for: ipcDirection)))
        case let .moveColumnToWorkspace(workspaceNumber):
            guard let workspaceIndex = zeroBasedIndex(from: workspaceNumber) else {
                return .invalidArguments
            }
            return controller.commandHandler.performCommand(.moveColumnToWorkspace(workspaceIndex))
        case .moveColumnToWorkspaceUp:
            return controller.commandHandler.performCommand(.moveColumnToWorkspaceUp)
        case .moveColumnToWorkspaceDown:
            return controller.commandHandler.performCommand(.moveColumnToWorkspaceDown)
        case .toggleColumnTabbed:
            return controller.commandHandler.performCommand(.toggleColumnTabbed)
        case .cycleColumnWidthForward:
            return controller.commandHandler.performCommand(.cycleColumnWidthForward)
        case .cycleColumnWidthBackward:
            return controller.commandHandler.performCommand(.cycleColumnWidthBackward)
        case .toggleColumnFullWidth:
            return controller.commandHandler.performCommand(.toggleColumnFullWidth)
        case let .swapWorkspaceWithMonitor(ipcDirection):
            return swapWorkspaceWithMonitor(direction: direction(for: ipcDirection))
        case .balanceSizes:
            return controller.commandHandler.performCommand(.balanceSizes)
        case .moveToRoot:
            return controller.commandHandler.performCommand(.moveToRoot)
        case .toggleSplit:
            return controller.commandHandler.performCommand(.toggleSplit)
        case .swapSplit:
            return controller.commandHandler.performCommand(.swapSplit)
        case let .resize(ipcDirection, operation):
            return controller.commandHandler.performCommand(
                .resizeInDirection(direction(for: ipcDirection), operation == .grow)
            )
        case let .preselect(ipcDirection):
            return controller.commandHandler.performCommand(.preselect(direction(for: ipcDirection)))
        case .preselectClear:
            return controller.commandHandler.performCommand(.preselectClear)
        case .openCommandPalette:
            return controller.commandHandler.performCommand(.openCommandPalette)
        case .raiseAllFloatingWindows:
            return raiseAllFloatingWindows()
        case .toggleWorkspaceLayout:
            return controller.commandHandler.performCommand(.toggleWorkspaceLayout)
        case let .setWorkspaceLayout(layout):
            if let guardResult = validateControllerState() {
                return guardResult
            }
            return controller.commandHandler.setWorkspaceLayout(layoutType(for: layout)) ? .executed : .notFound
        case .toggleFullscreen:
            return controller.commandHandler.performCommand(.toggleFullscreen)
        case .toggleNativeFullscreen:
            return controller.commandHandler.performCommand(.toggleNativeFullscreen)
        case .toggleOverview:
            return controller.commandHandler.performCommand(.toggleOverview)
        case .toggleQuakeTerminal:
            return controller.commandHandler.performCommand(.toggleQuakeTerminal)
        case .toggleWorkspaceBar:
            return controller.commandHandler.performCommand(.toggleWorkspaceBarVisibility)
        case .toggleHiddenBar:
            return controller.commandHandler.performCommand(.toggleHiddenBar)
        case .toggleFocusedWindowFloating:
            return toggleFocusedWindowFloating()
        case .scratchpadAssign:
            return assignFocusedWindowToScratchpad()
        case .scratchpadToggle:
            return toggleScratchpad()
        case .openMenuAnywhere:
            return controller.commandHandler.performCommand(.openMenuAnywhere)
        }
    }

    func handle(_ request: IPCWorkspaceRequest) -> ExternalCommandResult {
        if let guardResult = validateControllerState() {
            return guardResult
        }
        guard !request.workspaceName.isEmpty else {
            return .invalidArguments
        }
        let resolvedName = resolveWorkspaceName(from: request.workspaceName) ?? request.workspaceName
        return controller.windowActionHandler.focusWorkspaceFromBar(named: resolvedName)
            ? .executed
            : .notFound
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

    private func focusMonitor(previous: Bool) -> ExternalCommandResult {
        let previousMonitorId = controller.workspaceManager.interactionMonitorId ?? controller.monitorForInteraction()?.id
        _ = controller.commandHandler.performCommand(previous ? .focusMonitorPrevious : .focusMonitorNext)
        let currentMonitorId = controller.workspaceManager.interactionMonitorId ?? controller.monitorForInteraction()?.id
        return currentMonitorId == previousMonitorId ? .notFound : .executed
    }

    private func focusLastMonitor() -> ExternalCommandResult {
        let previousMonitorId = controller.workspaceManager.interactionMonitorId ?? controller.monitorForInteraction()?.id
        _ = controller.commandHandler.performCommand(.focusMonitorLast)
        let currentMonitorId = controller.workspaceManager.interactionMonitorId ?? controller.monitorForInteraction()?.id
        return currentMonitorId == previousMonitorId ? .notFound : .executed
    }

    private func layoutType(for value: IPCWorkspaceLayout) -> LayoutType {
        switch value {
        case .defaultLayout:
            .defaultLayout
        case .niri:
            .niri
        case .dwindle:
            .dwindle
        }
    }

    private func switchWorkspace(using command: HotkeyCommand) -> ExternalCommandResult {
        let previousWorkspaceId = controller.activeWorkspace()?.id
        let result = controller.commandHandler.performCommand(command)
        guard result == .executed else { return result }
        return controller.activeWorkspace()?.id == previousWorkspaceId ? .notFound : .executed
    }

    private func switchWorkspaceAnywhere(to workspaceIndex: Int) -> ExternalCommandResult {
        let previousWorkspaceId = controller.activeWorkspace()?.id
        let previousMonitorId = controller.workspaceManager.interactionMonitorId ?? controller.monitorForInteraction()?.id
        let result = controller.commandHandler.performCommand(.focusWorkspaceAnywhere(workspaceIndex))
        guard result == .executed else { return result }
        let currentWorkspaceId = controller.activeWorkspace()?.id
        let currentMonitorId = controller.workspaceManager.interactionMonitorId ?? controller.monitorForInteraction()?.id
        return currentWorkspaceId == previousWorkspaceId && currentMonitorId == previousMonitorId ? .notFound : .executed
    }

    private func moveFocusedWindow(using command: HotkeyCommand) -> ExternalCommandResult {
        guard let token = controller.workspaceManager.focusedToken else { return .notFound }
        let previousWorkspaceId = controller.workspaceManager.workspace(for: token)
        let result = controller.commandHandler.performCommand(command)
        guard result == .executed else { return result }
        return controller.workspaceManager.workspace(for: token) == previousWorkspaceId ? .notFound : .executed
    }

    private func swapWorkspaceWithMonitor(direction: Direction) -> ExternalCommandResult {
        let previousWorkspaceId = controller.activeWorkspace()?.id
        let result = controller.commandHandler.performCommand(.swapWorkspaceWithMonitor(direction))
        guard result == .executed else { return result }
        return controller.activeWorkspace()?.id == previousWorkspaceId ? .notFound : .executed
    }

    private func raiseAllFloatingWindows() -> ExternalCommandResult {
        if let guardResult = validateControllerState() {
            return guardResult
        }
        guard controller.windowActionHandler.makeRaiseAllFloatingPlan() != nil else {
            return .notFound
        }
        return controller.commandHandler.performCommand(.raiseAllFloatingWindows)
    }

    private func toggleFocusedWindowFloating() -> ExternalCommandResult {
        guard let token = controller.workspaceManager.focusedToken else { return .notFound }
        let previousOverride = controller.workspaceManager.manualLayoutOverride(for: token)
        let previousMode = controller.workspaceManager.windowMode(for: token)
        _ = controller.commandHandler.performCommand(.toggleFocusedWindowFloating)
        let currentOverride = controller.workspaceManager.manualLayoutOverride(for: token)
        let currentMode = controller.workspaceManager.windowMode(for: token)
        return currentOverride == previousOverride && currentMode == previousMode ? .notFound : .executed
    }

    private func assignFocusedWindowToScratchpad() -> ExternalCommandResult {
        let previousScratchpadToken = controller.workspaceManager.scratchpadToken()
        _ = controller.commandHandler.performCommand(.assignFocusedWindowToScratchpad)
        return controller.workspaceManager.scratchpadToken() == previousScratchpadToken ? .notFound : .executed
    }

    private func toggleScratchpad() -> ExternalCommandResult {
        guard let scratchpadToken = controller.workspaceManager.scratchpadToken() else { return .notFound }
        let wasHidden = controller.workspaceManager.hiddenState(for: scratchpadToken) != nil
        _ = controller.commandHandler.performCommand(.toggleScratchpadWindow)
        let isHidden = controller.workspaceManager.hiddenState(for: scratchpadToken) != nil
        return wasHidden == isHidden ? .notFound : .executed
    }

    private func resolveWorkspaceName(from candidate: String) -> String? {
        if controller.workspaceManager.workspaceId(for: candidate, createIfMissing: false) != nil {
            return candidate
        }

        return controller.settings.workspaceConfigurations.first {
            $0.effectiveDisplayName.caseInsensitiveCompare(candidate) == .orderedSame
        }?.name
    }
}

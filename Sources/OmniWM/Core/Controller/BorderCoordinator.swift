import AppKit
import Foundation

@MainActor
final class BorderCoordinator {
    private enum UpdateEligibility {
        case hide
        case update(activeWorkspaceId: WorkspaceDescriptor.ID)
    }

    weak var controller: WMController?

    init(controller: WMController) {
        self.controller = controller
    }

    func updateBorderIfAllowed(token: WindowToken, frame: CGRect, windowId: Int) {
        guard let controller else { return }
        switch eligibilityForBorderUpdate(token: token) {
        case .hide:
            controller.borderManager.hideBorder()
        case let .update(activeWorkspaceId):
            if shouldDeferBorderUpdates(for: activeWorkspaceId) {
                return
            }
            controller.borderManager.updateFocusedWindow(frame: frame, windowId: windowId)
        }
    }

    func updateDirectBorderIfAllowed(token: WindowToken, frame: CGRect, windowId: Int) {
        guard let controller else { return }

        switch eligibilityForBorderUpdate(token: token) {
        case .hide:
            controller.borderManager.hideBorder()
        case .update:
            controller.borderManager.updateFocusedWindow(frame: frame, windowId: windowId)
        }
    }

    func updateBorderIfAllowed(handle: WindowHandle, frame: CGRect, windowId: Int) {
        updateBorderIfAllowed(token: handle.id, frame: frame, windowId: windowId)
    }

    private func eligibilityForBorderUpdate(token: WindowToken) -> UpdateEligibility {
        guard let controller,
              let activeWorkspace = controller.activeWorkspace(),
              controller.workspaceManager.workspace(for: token) == activeWorkspace.id
        else {
            return .hide
        }

        if controller.workspaceManager.isNonManagedFocusActive {
            return .hide
        }

        if controller.workspaceManager.hasPendingNativeFullscreenTransition {
            return .hide
        }

        if controller.workspaceManager.isAppFullscreenActive || isManagedWindowFullscreen(token) {
            return .hide
        }

        return .update(activeWorkspaceId: activeWorkspace.id)
    }

    private func shouldDeferBorderUpdates(for workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let controller else { return false }

        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        if state.viewOffsetPixels.isAnimating {
            return true
        }

        if controller.layoutRefreshController.hasDwindleAnimationRunning(in: workspaceId) {
            return true
        }

        guard let engine = controller.niriEngine else { return false }
        if engine.hasAnyWindowAnimationsRunning(in: workspaceId) {
            return true
        }
        if engine.hasAnyColumnAnimationsRunning(in: workspaceId) {
            return true
        }
        return false
    }

    private func isManagedWindowFullscreen(_ token: WindowToken) -> Bool {
        guard let controller else { return false }
        guard let engine = controller.niriEngine,
              let windowNode = engine.findNode(for: token)
        else {
            return false
        }
        return windowNode.isFullscreen
    }
}

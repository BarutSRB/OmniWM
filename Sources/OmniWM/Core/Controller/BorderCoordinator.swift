import AppKit
import Foundation

@MainActor
final class BorderCoordinator {
    weak var controller: WMController?

    init(controller: WMController) {
        self.controller = controller
    }

    func updateBorderIfAllowed(handle: WindowHandle, frame: CGRect, windowId: Int) {
        guard let controller else { return }

        guard let activeWs = controller.activeWorkspace(),
              controller.workspaceManager.workspace(for: handle) == activeWs.id
        else {
            controller.borderManager.hideBorder()
            return
        }

        if controller.focusManager.isNonManagedFocusActive {
            controller.borderManager.hideBorder()
            return
        }

        if shouldDeferBorderUpdates(for: activeWs.id) {
            return
        }

        if let entry = controller.workspaceManager.entry(for: handle) {
            controller.focusManager.setAppFullscreen(active: AXWindowService.isFullscreen(entry.axRef))
        } else {
            controller.focusManager.setAppFullscreen(active: false)
        }

        if controller.focusManager.isAppFullscreenActive || isManagedWindowFullscreen(handle) {
            controller.borderManager.hideBorder()
            return
        }
        controller.borderManager.updateFocusedWindow(frame: frame, windowId: windowId)
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

    private func isManagedWindowFullscreen(_ handle: WindowHandle) -> Bool {
        guard let controller else { return false }
        guard let engine = controller.niriEngine,
              let windowNode = engine.findNode(for: handle)
        else {
            return false
        }
        return windowNode.isFullscreen
    }
}

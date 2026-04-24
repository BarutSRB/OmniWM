// SPDX-License-Identifier: GPL-2.0-only
import Foundation

// Live implementation of `WMEffectPlatform` that delegates to the existing
// controller + workspace-manager surface.
//
// Phase 01 Milestone A keeps this adapter thin: effects reuse the same
// primitives handlers called directly before the transaction path existed,
// so that migrating a handler is purely a boundary change. Later phases
// will narrow the surface further by promoting intermediate observations
// into confirmation `WMEvent`s.
@MainActor
final class WMLiveEffectPlatform: WMEffectPlatform {
    private weak var controller: WMController?

    init(controller: WMController) {
        self.controller = controller
    }

    func hideKeyboardFocusBorder(reason: String) {
        controller?.hideKeyboardFocusBorder(
            source: .workspaceActivation,
            reason: reason
        )
    }

    func saveWorkspaceViewport(for workspaceId: WorkspaceDescriptor.ID) {
        controller?.workspaceNavigationHandler.saveNiriViewportState(for: workspaceId)
    }

    @discardableResult
    func activateTargetWorkspace(
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID
    ) -> Bool {
        guard let controller else { return false }
        return controller.workspaceManager.setActiveWorkspace(
            workspaceId,
            on: monitorId
        )
    }

    func setInteractionMonitor(monitorId: Monitor.ID) {
        _ = controller?.workspaceManager.setInteractionMonitor(monitorId)
    }

    func syncMonitorsToNiri() {
        controller?.syncMonitorsToNiriEngine()
    }

    func stopScrollAnimation(monitorId: Monitor.ID) {
        guard let controller,
              let monitor = controller.workspaceManager.monitor(byId: monitorId)
        else { return }
        controller.layoutRefreshController.stopScrollAnimation(for: monitor.displayId)
    }

    func applyWorkspaceSessionPatch(
        workspaceId: WorkspaceDescriptor.ID,
        rememberedFocusToken: WindowToken?
    ) {
        _ = controller?.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: nil,
                rememberedFocusToken: rememberedFocusToken
            )
        )
    }

    func commitWorkspaceTransition(
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        postAction: @escaping @MainActor () -> Void
    ) {
        controller?.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: affectedWorkspaceIds,
            reason: .workspaceTransition,
            postLayout: postAction
        )
    }

    func focusWindow(_ token: WindowToken) {
        controller?.focusWindow(token)
    }

    func clearManagedFocusAfterEmptyWorkspaceTransition() {
        controller?.workspaceNavigationHandler.clearManagedFocusAfterEmptyWorkspaceTransition()
    }
}

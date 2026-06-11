import CoreGraphics
import Foundation

@MainActor
struct WorldView {
    private let controller: WMController

    init(controller: WMController) {
        self.controller = controller
    }

    var hasStartedServices: Bool {
        controller.hasStartedServices
    }

    var monitors: [Monitor] {
        controller.workspaceManager.monitors
    }

    var renderableFocusToken: WindowToken? {
        controller.workspaceManager.renderableFocusToken
    }

    var isNonManagedFocusActive: Bool {
        controller.workspaceManager.isNonManagedFocusActive
    }

    var suppressedFocusToken: WindowToken? {
        controller.workspaceManager.suppressedFocusToken
    }

    var hasPendingNativeFullscreenTransition: Bool {
        controller.workspaceManager.hasPendingNativeFullscreenTransition
    }

    var isAppFullscreenActive: Bool {
        controller.workspaceManager.isAppFullscreenActive
    }

    var borderConfig: BorderConfig {
        BorderConfig.from(settings: controller.settings)
    }

    func entry(for token: WindowToken) -> WindowModel.Entry? {
        controller.workspaceManager.entry(for: token)
    }

    func isOwnedWindow(windowId: Int) -> Bool {
        controller.isOwnedWindow(windowNumber: windowId)
    }

    func isWindowFullscreenInLayout(_ token: WindowToken) -> Bool {
        if controller.niriEngine?.findNode(for: token)?.isFullscreen == true {
            return true
        }
        return controller.dwindleEngine?.findNode(for: token)?.isFullscreen == true
    }

    func isManagedWindowDisplayable(_ handle: WindowHandle) -> Bool {
        controller.isManagedWindowDisplayable(handle)
    }

    func isWorkspaceVisible(_ workspaceId: WorkspaceDescriptor.ID) -> Bool {
        controller.workspaceManager.visibleWorkspaceIds().contains(workspaceId)
    }

    func borderFrame(forWindowId windowId: Int) -> CGRect? {
        if let pending = controller.axManager.pendingFrameWrite(for: windowId) {
            return pending
        }
        return observedWindowBounds(windowId: windowId)
    }

    func observedWindowBounds(windowId: Int) -> CGRect? {
        guard windowId > 0,
              let bounds = SkyLight.shared.getWindowBounds(UInt32(windowId)),
              bounds.width > 0, bounds.height > 0
        else {
            return nil
        }
        return ScreenCoordinateSpace.toAppKit(rect: bounds)
    }
}

import CoreGraphics
import Foundation

struct DesiredBorderSurface: Equatable {
    var windowId: Int
    var frame: CGRect
    var config: BorderConfig
}

struct DesiredSurfaceScene: Equatable {
    var border: DesiredBorderSurface?

    static let empty = DesiredSurfaceScene()
}

enum SurfaceDerivation {
    @MainActor
    static func derive(world: WorldView) -> DesiredSurfaceScene {
        guard world.hasStartedServices else { return .empty }
        return DesiredSurfaceScene(border: deriveBorder(world: world))
    }

    @MainActor
    static func deriveBorder(world: WorldView) -> DesiredBorderSurface? {
        let config = world.borderConfig
        guard config.enabled else { return nil }
        guard let token = world.renderableFocusToken else { return nil }
        guard !world.isOwnedWindow(windowId: token.windowId) else { return nil }
        guard !world.hasPendingNativeFullscreenTransition else { return nil }

        if let entry = world.entry(for: token) {
            guard world.suppressedFocusToken != token,
                  !world.isAppFullscreenActive,
                  !world.isWindowFullscreenInLayout(token),
                  world.isManagedWindowDisplayable(entry.handle),
                  world.isWorkspaceVisible(entry.workspaceId)
            else {
                return nil
            }
            guard let frame = world.borderFrame(forWindowId: entry.windowId),
                  frame.width > 0, frame.height > 0
            else {
                return nil
            }
            return DesiredBorderSurface(windowId: entry.windowId, frame: frame, config: config)
        }

        guard world.isNonManagedFocusActive else { return nil }
        guard let frame = world.observedWindowBounds(windowId: token.windowId) else { return nil }
        return DesiredBorderSurface(windowId: token.windowId, frame: frame, config: config)
    }
}

@MainActor
final class SurfaceReconciler {
    private weak var controller: WMController?
    private var reconcileScheduled = false
    private var forceOrderingOnNextReconcile = false
    private let borderApplier = BorderSurfaceApplier()
    private(set) var appliedScene = DesiredSurfaceScene.empty

    init(controller: WMController) {
        self.controller = controller
    }

    func noteWorldChanged() {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated {
                self.flushScheduledReconcile()
            }
        }
        CFRunLoopWakeUp(mainRunLoop)
    }

    func noteRestackOccurred() {
        forceOrderingOnNextReconcile = true
        noteWorldChanged()
    }

    func reconcileNow() {
        reconcileScheduled = false
        let forceOrdering = forceOrderingOnNextReconcile
        forceOrderingOnNextReconcile = false
        guard let controller else { return }
        let desired = SurfaceDerivation.derive(world: WorldView(controller: controller))
        apply(desired, forceOrdering: forceOrdering)
    }

    func cleanup() {
        borderApplier.cleanup()
        appliedScene = .empty
    }

    private func flushScheduledReconcile() {
        guard reconcileScheduled else { return }
        reconcileNow()
    }

    private func apply(_ desired: DesiredSurfaceScene, forceOrdering: Bool) {
        guard desired != appliedScene || forceOrdering else { return }
        borderApplier.apply(desired.border, forceOrdering: forceOrdering)
        appliedScene = desired
    }
}

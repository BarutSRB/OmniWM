import CoreGraphics
import Foundation
import QuartzCore

/// Shared deterministic backend surface for Dwindle runtime and test reference engines.
protocol DwindleDeterministicBackend: AnyObject {
    var settings: DwindleSettings { get set }
    var animationClock: AnimationClock? { get set }
    var displayRefreshRate: Double { get set }
    var windowMovementAnimationConfig: CubicConfig { get set }

    func updateWindowConstraints(for handle: WindowHandle, constraints: WindowSizeConstraints)
    func constraints(for handle: WindowHandle) -> WindowSizeConstraints
    func updateMonitorSettings(_ resolved: ResolvedDwindleSettings, for monitorId: Monitor.ID)
    func cleanupRemovedMonitor(_ monitorId: Monitor.ID)
    func effectiveSettings(for monitorId: Monitor.ID) -> DwindleSettings

    func root(for workspaceId: WorkspaceDescriptor.ID) -> DwindleNode?
    func ensureRoot(for workspaceId: WorkspaceDescriptor.ID) -> DwindleNode
    func removeLayout(for workspaceId: WorkspaceDescriptor.ID)
    func containsWindow(_ handle: WindowHandle, in workspaceId: WorkspaceDescriptor.ID) -> Bool
    func findNode(for handle: WindowHandle) -> DwindleNode?
    func windowCount(in workspaceId: WorkspaceDescriptor.ID) -> Int
    func selectedNode(in workspaceId: WorkspaceDescriptor.ID) -> DwindleNode?
    func selectedWindowHandle(in workspaceId: WorkspaceDescriptor.ID) -> WindowHandle?
    func setSelectedNode(_ node: DwindleNode?, in workspaceId: WorkspaceDescriptor.ID)
    func setPreselection(_ direction: Direction?, in workspaceId: WorkspaceDescriptor.ID)
    func getPreselection(in workspaceId: WorkspaceDescriptor.ID) -> Direction?

    @discardableResult
    func addWindow(
        handle: WindowHandle,
        to workspaceId: WorkspaceDescriptor.ID,
        activeWindowFrame: CGRect?
    ) -> DwindleNode

    func removeWindow(handle: WindowHandle, from workspaceId: WorkspaceDescriptor.ID)

    func syncWindows(
        _ handles: [WindowHandle],
        in workspaceId: WorkspaceDescriptor.ID,
        focusedHandle: WindowHandle?
    ) -> Set<WindowHandle>

    func calculateLayout(
        for workspaceId: WorkspaceDescriptor.ID,
        screen: CGRect
    ) -> [WindowHandle: CGRect]

    func currentFrames(in workspaceId: WorkspaceDescriptor.ID) -> [WindowHandle: CGRect]

    func findGeometricNeighbor(
        from handle: WindowHandle,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> WindowHandle?

    func moveFocus(direction: Direction, in workspaceId: WorkspaceDescriptor.ID) -> WindowHandle?
    func swapWindows(direction: Direction, in workspaceId: WorkspaceDescriptor.ID) -> Bool
    func toggleOrientation(in workspaceId: WorkspaceDescriptor.ID)
    func toggleFullscreen(in workspaceId: WorkspaceDescriptor.ID) -> WindowHandle?
    func moveSelectionToRoot(stable: Bool, in workspaceId: WorkspaceDescriptor.ID)

    func resizeSelected(
        by delta: CGFloat,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID
    )

    func balanceSizes(in workspaceId: WorkspaceDescriptor.ID)
    func swapSplit(in workspaceId: WorkspaceDescriptor.ID)
    func cycleSplitRatio(forward: Bool, in workspaceId: WorkspaceDescriptor.ID)
    func tickAnimations(at time: TimeInterval, in workspaceId: WorkspaceDescriptor.ID)
    func hasActiveAnimations(in workspaceId: WorkspaceDescriptor.ID, at time: TimeInterval) -> Bool

    func animateWindowMovements(
        oldFrames: [WindowHandle: CGRect],
        newFrames: [WindowHandle: CGRect]
    )

    func calculateAnimatedFrames(
        baseFrames: [WindowHandle: CGRect],
        in workspaceId: WorkspaceDescriptor.ID,
        at time: TimeInterval
    ) -> [WindowHandle: CGRect]
}

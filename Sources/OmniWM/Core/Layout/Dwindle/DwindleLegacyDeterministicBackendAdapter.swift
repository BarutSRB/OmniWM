#if OMNI_DWINDLE_LEGACY_TEST_BACKEND
import CoreGraphics
import Foundation
import QuartzCore

/// Internal legacy test/reference backend adapter.
/// This backend is not part of production deterministic runtime behavior.
final class DwindleLegacyDeterministicBackendAdapter: DwindleDeterministicBackend {
    private let legacyEngine = LegacyDwindleLayoutEngine()

    var settings: DwindleSettings {
        get { legacyEngine.settings }
        set { legacyEngine.settings = newValue }
    }

    var animationClock: AnimationClock? {
        get { legacyEngine.animationClock }
        set { legacyEngine.animationClock = newValue }
    }

    var displayRefreshRate: Double {
        get { legacyEngine.displayRefreshRate }
        set { legacyEngine.displayRefreshRate = newValue }
    }

    var windowMovementAnimationConfig: CubicConfig {
        get { legacyEngine.windowMovementAnimationConfig }
        set { legacyEngine.windowMovementAnimationConfig = newValue }
    }

    func updateWindowConstraints(for handle: WindowHandle, constraints: WindowSizeConstraints) {
        legacyEngine.updateWindowConstraints(for: handle, constraints: constraints)
    }

    func constraints(for handle: WindowHandle) -> WindowSizeConstraints {
        legacyEngine.constraints(for: handle)
    }

    func updateMonitorSettings(_ resolved: ResolvedDwindleSettings, for monitorId: Monitor.ID) {
        legacyEngine.updateMonitorSettings(resolved, for: monitorId)
    }

    func cleanupRemovedMonitor(_ monitorId: Monitor.ID) {
        legacyEngine.cleanupRemovedMonitor(monitorId)
    }

    func effectiveSettings(for monitorId: Monitor.ID) -> DwindleSettings {
        legacyEngine.effectiveSettings(for: monitorId)
    }

    func root(for workspaceId: WorkspaceDescriptor.ID) -> DwindleNode? {
        legacyEngine.root(for: workspaceId)
    }

    func ensureRoot(for workspaceId: WorkspaceDescriptor.ID) -> DwindleNode {
        legacyEngine.ensureRoot(for: workspaceId)
    }

    func removeLayout(for workspaceId: WorkspaceDescriptor.ID) {
        legacyEngine.removeLayout(for: workspaceId)
    }

    func containsWindow(_ handle: WindowHandle, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        legacyEngine.containsWindow(handle, in: workspaceId)
    }

    func findNode(for handle: WindowHandle) -> DwindleNode? {
        legacyEngine.findNode(for: handle)
    }

    func windowCount(in workspaceId: WorkspaceDescriptor.ID) -> Int {
        legacyEngine.windowCount(in: workspaceId)
    }

    func selectedNode(in workspaceId: WorkspaceDescriptor.ID) -> DwindleNode? {
        legacyEngine.selectedNode(in: workspaceId)
    }

    func selectedWindowHandle(in workspaceId: WorkspaceDescriptor.ID) -> WindowHandle? {
        legacyEngine.selectedNode(in: workspaceId)?.windowHandle
    }

    func setSelectedNode(_ node: DwindleNode?, in workspaceId: WorkspaceDescriptor.ID) {
        legacyEngine.setSelectedNode(node, in: workspaceId)
    }

    func setPreselection(_ direction: Direction?, in workspaceId: WorkspaceDescriptor.ID) {
        legacyEngine.setPreselection(direction, in: workspaceId)
    }

    func getPreselection(in workspaceId: WorkspaceDescriptor.ID) -> Direction? {
        legacyEngine.getPreselection(in: workspaceId)
    }

    @discardableResult
    func addWindow(
        handle: WindowHandle,
        to workspaceId: WorkspaceDescriptor.ID,
        activeWindowFrame: CGRect?
    ) -> DwindleNode {
        legacyEngine.addWindow(handle: handle, to: workspaceId, activeWindowFrame: activeWindowFrame)
    }

    func removeWindow(handle: WindowHandle, from workspaceId: WorkspaceDescriptor.ID) {
        legacyEngine.removeWindow(handle: handle, from: workspaceId)
    }

    func syncWindows(
        _ handles: [WindowHandle],
        in workspaceId: WorkspaceDescriptor.ID,
        focusedHandle: WindowHandle?
    ) -> Set<WindowHandle> {
        legacyEngine.syncWindows(handles, in: workspaceId, focusedHandle: focusedHandle)
    }

    func calculateLayout(
        for workspaceId: WorkspaceDescriptor.ID,
        screen: CGRect
    ) -> [WindowHandle: CGRect] {
        legacyEngine.calculateLayout(for: workspaceId, screen: screen)
    }

    func currentFrames(in workspaceId: WorkspaceDescriptor.ID) -> [WindowHandle: CGRect] {
        legacyEngine.currentFrames(in: workspaceId)
    }

    func findGeometricNeighbor(
        from handle: WindowHandle,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> WindowHandle? {
        legacyEngine.findGeometricNeighbor(from: handle, direction: direction, in: workspaceId)
    }

    func moveFocus(direction: Direction, in workspaceId: WorkspaceDescriptor.ID) -> WindowHandle? {
        legacyEngine.moveFocus(direction: direction, in: workspaceId)
    }

    func swapWindows(direction: Direction, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        legacyEngine.swapWindows(direction: direction, in: workspaceId)
    }

    func toggleOrientation(in workspaceId: WorkspaceDescriptor.ID) {
        legacyEngine.toggleOrientation(in: workspaceId)
    }

    func toggleFullscreen(in workspaceId: WorkspaceDescriptor.ID) -> WindowHandle? {
        legacyEngine.toggleFullscreen(in: workspaceId)
    }

    func moveSelectionToRoot(stable: Bool, in workspaceId: WorkspaceDescriptor.ID) {
        legacyEngine.moveSelectionToRoot(stable: stable, in: workspaceId)
    }

    func resizeSelected(
        by delta: CGFloat,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        legacyEngine.resizeSelected(by: delta, direction: direction, in: workspaceId)
    }

    func balanceSizes(in workspaceId: WorkspaceDescriptor.ID) {
        legacyEngine.balanceSizes(in: workspaceId)
    }

    func swapSplit(in workspaceId: WorkspaceDescriptor.ID) {
        legacyEngine.swapSplit(in: workspaceId)
    }

    func cycleSplitRatio(forward: Bool, in workspaceId: WorkspaceDescriptor.ID) {
        legacyEngine.cycleSplitRatio(forward: forward, in: workspaceId)
    }

    func tickAnimations(at time: TimeInterval, in workspaceId: WorkspaceDescriptor.ID) {
        legacyEngine.tickAnimations(at: time, in: workspaceId)
    }

    func hasActiveAnimations(in workspaceId: WorkspaceDescriptor.ID, at time: TimeInterval) -> Bool {
        legacyEngine.hasActiveAnimations(in: workspaceId, at: time)
    }

    func animateWindowMovements(
        oldFrames: [WindowHandle: CGRect],
        newFrames: [WindowHandle: CGRect]
    ) {
        legacyEngine.animateWindowMovements(oldFrames: oldFrames, newFrames: newFrames)
    }

    func calculateAnimatedFrames(
        baseFrames: [WindowHandle: CGRect],
        in workspaceId: WorkspaceDescriptor.ID,
        at time: TimeInterval
    ) -> [WindowHandle: CGRect] {
        legacyEngine.calculateAnimatedFrames(baseFrames: baseFrames, in: workspaceId, at: time)
    }
}
#endif

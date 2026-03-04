import CoreGraphics
import Foundation
import QuartzCore

final class DwindleLayoutEngine {
    enum Backend {
        case zigContext
#if OMNI_DWINDLE_LEGACY_TEST_BACKEND
        case legacyDeterministic
#endif
    }

    let backend: Backend
    private let deterministicBackend: any DwindleDeterministicBackend

    var settings: DwindleSettings {
        get { deterministicBackend.settings }
        set { deterministicBackend.settings = newValue }
    }

    var animationClock: AnimationClock? {
        get { deterministicBackend.animationClock }
        set { deterministicBackend.animationClock = newValue }
    }

    var displayRefreshRate: Double {
        get { deterministicBackend.displayRefreshRate }
        set { deterministicBackend.displayRefreshRate = newValue }
    }

    var windowMovementAnimationConfig: CubicConfig {
        get { deterministicBackend.windowMovementAnimationConfig }
        set { deterministicBackend.windowMovementAnimationConfig = newValue }
    }

    init(backend: Backend = .zigContext) {
        self.backend = backend

        switch backend {
        case .zigContext:
            deterministicBackend = DwindleZigDeterministicBackend()
#if OMNI_DWINDLE_LEGACY_TEST_BACKEND
        case .legacyDeterministic:
            guard Self.isRunningUnderXCTest else {
                preconditionFailure("Dwindle legacy backend is test-only and unavailable in this runtime")
            }
            deterministicBackend = DwindleLegacyDeterministicBackendAdapter()
#endif
        }
    }

#if OMNI_DWINDLE_LEGACY_TEST_BACKEND
    private static var isRunningUnderXCTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment.keys.contains(where: { $0.hasPrefix("SWIFT_TESTING") })
        {
            return true
        }

        if NSClassFromString("XCTestCase") != nil {
            return true
        }

        if Bundle.allBundles.contains(where: { $0.bundlePath.hasSuffix(".xctest") }) {
            return true
        }

        let processName = ProcessInfo.processInfo.processName.lowercased()
        if processName.contains("xctest") || processName.contains("packagetests") {
            return true
        }

        let arguments = ProcessInfo.processInfo.arguments.joined(separator: " ").lowercased()
        if arguments.contains("xctest")
            || arguments.contains("swift-testing")
            || arguments.contains("packagetests")
        {
            return true
        }

        return Bundle.main.bundlePath.hasSuffix(".xctest")
    }
#endif

    func updateWindowConstraints(for handle: WindowHandle, constraints: WindowSizeConstraints) {
        deterministicBackend.updateWindowConstraints(for: handle, constraints: constraints)
    }

    func constraints(for handle: WindowHandle) -> WindowSizeConstraints {
        deterministicBackend.constraints(for: handle)
    }

    func updateMonitorSettings(_ resolved: ResolvedDwindleSettings, for monitorId: Monitor.ID) {
        deterministicBackend.updateMonitorSettings(resolved, for: monitorId)
    }

    func cleanupRemovedMonitor(_ monitorId: Monitor.ID) {
        deterministicBackend.cleanupRemovedMonitor(monitorId)
    }

    func effectiveSettings(for monitorId: Monitor.ID) -> DwindleSettings {
        deterministicBackend.effectiveSettings(for: monitorId)
    }

    func root(for workspaceId: WorkspaceDescriptor.ID) -> DwindleNode? {
        deterministicBackend.root(for: workspaceId)
    }

    func ensureRoot(for workspaceId: WorkspaceDescriptor.ID) -> DwindleNode {
        deterministicBackend.ensureRoot(for: workspaceId)
    }

    func removeLayout(for workspaceId: WorkspaceDescriptor.ID) {
        deterministicBackend.removeLayout(for: workspaceId)
    }

    func containsWindow(_ handle: WindowHandle, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        deterministicBackend.containsWindow(handle, in: workspaceId)
    }

    func findNode(for handle: WindowHandle) -> DwindleNode? {
        deterministicBackend.findNode(for: handle)
    }

    func windowCount(in workspaceId: WorkspaceDescriptor.ID) -> Int {
        deterministicBackend.windowCount(in: workspaceId)
    }

    func selectedNode(in workspaceId: WorkspaceDescriptor.ID) -> DwindleNode? {
        deterministicBackend.selectedNode(in: workspaceId)
    }

    func selectedWindowHandle(in workspaceId: WorkspaceDescriptor.ID) -> WindowHandle? {
        deterministicBackend.selectedWindowHandle(in: workspaceId)
    }

    func setSelectedNode(_ node: DwindleNode?, in workspaceId: WorkspaceDescriptor.ID) {
        deterministicBackend.setSelectedNode(node, in: workspaceId)
    }

    func setPreselection(_ direction: Direction?, in workspaceId: WorkspaceDescriptor.ID) {
        deterministicBackend.setPreselection(direction, in: workspaceId)
    }

    func getPreselection(in workspaceId: WorkspaceDescriptor.ID) -> Direction? {
        deterministicBackend.getPreselection(in: workspaceId)
    }

    @discardableResult
    func addWindow(
        handle: WindowHandle,
        to workspaceId: WorkspaceDescriptor.ID,
        activeWindowFrame: CGRect?
    ) -> DwindleNode {
        deterministicBackend.addWindow(handle: handle, to: workspaceId, activeWindowFrame: activeWindowFrame)
    }

    func removeWindow(handle: WindowHandle, from workspaceId: WorkspaceDescriptor.ID) {
        deterministicBackend.removeWindow(handle: handle, from: workspaceId)
    }

    func syncWindows(
        _ handles: [WindowHandle],
        in workspaceId: WorkspaceDescriptor.ID,
        focusedHandle: WindowHandle?
    ) -> Set<WindowHandle> {
        deterministicBackend.syncWindows(handles, in: workspaceId, focusedHandle: focusedHandle)
    }

    func calculateLayout(
        for workspaceId: WorkspaceDescriptor.ID,
        screen: CGRect
    ) -> [WindowHandle: CGRect] {
        deterministicBackend.calculateLayout(for: workspaceId, screen: screen)
    }

    func currentFrames(in workspaceId: WorkspaceDescriptor.ID) -> [WindowHandle: CGRect] {
        deterministicBackend.currentFrames(in: workspaceId)
    }

    func findGeometricNeighbor(
        from handle: WindowHandle,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> WindowHandle? {
        deterministicBackend.findGeometricNeighbor(from: handle, direction: direction, in: workspaceId)
    }

    func moveFocus(direction: Direction, in workspaceId: WorkspaceDescriptor.ID) -> WindowHandle? {
        deterministicBackend.moveFocus(direction: direction, in: workspaceId)
    }

    func swapWindows(direction: Direction, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        deterministicBackend.swapWindows(direction: direction, in: workspaceId)
    }

    func toggleOrientation(in workspaceId: WorkspaceDescriptor.ID) {
        deterministicBackend.toggleOrientation(in: workspaceId)
    }

    func toggleFullscreen(in workspaceId: WorkspaceDescriptor.ID) -> WindowHandle? {
        deterministicBackend.toggleFullscreen(in: workspaceId)
    }

    func moveSelectionToRoot(stable: Bool, in workspaceId: WorkspaceDescriptor.ID) {
        deterministicBackend.moveSelectionToRoot(stable: stable, in: workspaceId)
    }

    func resizeSelected(
        by delta: CGFloat,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        deterministicBackend.resizeSelected(by: delta, direction: direction, in: workspaceId)
    }

    func balanceSizes(in workspaceId: WorkspaceDescriptor.ID) {
        deterministicBackend.balanceSizes(in: workspaceId)
    }

    func swapSplit(in workspaceId: WorkspaceDescriptor.ID) {
        deterministicBackend.swapSplit(in: workspaceId)
    }

    func cycleSplitRatio(forward: Bool, in workspaceId: WorkspaceDescriptor.ID) {
        deterministicBackend.cycleSplitRatio(forward: forward, in: workspaceId)
    }

    func tickAnimations(at time: TimeInterval, in workspaceId: WorkspaceDescriptor.ID) {
        deterministicBackend.tickAnimations(at: time, in: workspaceId)
    }

    func hasActiveAnimations(in workspaceId: WorkspaceDescriptor.ID, at time: TimeInterval) -> Bool {
        deterministicBackend.hasActiveAnimations(in: workspaceId, at: time)
    }

    func animateWindowMovements(
        oldFrames: [WindowHandle: CGRect],
        newFrames: [WindowHandle: CGRect]
    ) {
        deterministicBackend.animateWindowMovements(oldFrames: oldFrames, newFrames: newFrames)
    }

    func calculateAnimatedFrames(
        baseFrames: [WindowHandle: CGRect],
        in workspaceId: WorkspaceDescriptor.ID,
        at time: TimeInterval
    ) -> [WindowHandle: CGRect] {
        deterministicBackend.calculateAnimatedFrames(baseFrames: baseFrames, in: workspaceId, at: time)
    }
}

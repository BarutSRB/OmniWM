import AppKit
import CoreGraphics
import Foundation

final class NiriMonitor {
    let id: Monitor.ID

    let displayId: CGDirectDisplayID

    let outputName: String

    private(set) var frame: CGRect

    private(set) var visibleFrame: CGRect

    private(set) var scale: CGFloat

    private(set) var orientation: Monitor.Orientation = .horizontal

    var workspaceRoots: [WorkspaceDescriptor.ID: NiriRoot] = [:]

    var workspaceSwitch: WorkspaceSwitch?

    var animationClock: AnimationClock?

    var workspaceSwitchConfig: SpringConfig = .balanced.with(
        epsilon: 0.01,
        velocityEpsilon: 0.05
    )

    var resolvedSettings: ResolvedNiriSettings?

    var workspaceCount: Int {
        workspaceRoots.count
    }

    var hasWorkspaces: Bool {
        !workspaceRoots.isEmpty
    }

    init(monitor: Monitor, orientation: Monitor.Orientation? = nil) {
        id = monitor.id
        displayId = monitor.displayId
        outputName = monitor.name
        frame = monitor.frame
        visibleFrame = monitor.visibleFrame
        self.orientation = orientation ?? monitor.autoOrientation

        if let screen = NSScreen.screens.first(where: { $0.displayId == monitor.displayId }) {
            scale = screen.backingScaleFactor
        } else {
            scale = 2.0
        }
    }

    func updateOutputSize(monitor: Monitor, orientation: Monitor.Orientation? = nil) {
        frame = monitor.frame
        visibleFrame = monitor.visibleFrame
        self.orientation = orientation ?? monitor.autoOrientation

        if let screen = NSScreen.screens.first(where: { $0.displayId == monitor.displayId }) {
            scale = screen.backingScaleFactor
        }
    }

    func updateOrientation(_ orientation: Monitor.Orientation) {
        self.orientation = orientation
    }
}

extension NiriMonitor {
    func root(for workspaceId: WorkspaceDescriptor.ID) -> NiriRoot? {
        workspaceRoots[workspaceId]
    }

    func ensureRoot(for workspaceId: WorkspaceDescriptor.ID) -> NiriRoot {
        if let existing = workspaceRoots[workspaceId] {
            return existing
        }

        let root = NiriRoot(workspaceId: workspaceId)
        workspaceRoots[workspaceId] = root
        return root
    }

    func containsWorkspace(_ workspaceId: WorkspaceDescriptor.ID) -> Bool {
        workspaceRoots[workspaceId] != nil
    }
}

extension NiriMonitor {
    func startWorkspaceSwitch(
        orderedWorkspaceIds: [WorkspaceDescriptor.ID],
        from fromWorkspaceId: WorkspaceDescriptor.ID,
        to toWorkspaceId: WorkspaceDescriptor.ID,
        animated: Bool
    ) {
        guard let targetIdx = orderedWorkspaceIds.firstIndex(of: toWorkspaceId),
              let fromIdx = orderedWorkspaceIds.firstIndex(of: fromWorkspaceId) else {
            return
        }
        guard animated else {
            workspaceSwitch = nil
            return
        }
        guard targetIdx != fromIdx || workspaceSwitch != nil else { return }

        let now = animationClock?.now() ?? CACurrentMediaTime()
        let currentRenderIdx = workspaceSwitch?.currentIndex(at: now) ?? Double(fromIdx)

        let animation = SpringAnimation(
            from: currentRenderIdx,
            to: Double(targetIdx),
            startTime: now,
            config: workspaceSwitchConfig
        )
        workspaceSwitch = WorkspaceSwitch(
            orderedWorkspaceIds: orderedWorkspaceIds,
            fromWorkspaceId: fromWorkspaceId,
            toWorkspaceId: toWorkspaceId,
            animation: animation
        )
    }

    func tickWorkspaceSwitchAnimation(at time: TimeInterval) -> Bool {
        guard var switch_ = workspaceSwitch else { return false }

        let running = switch_.tick(at: time)
        if running {
            workspaceSwitch = switch_
        } else {
            workspaceSwitch = nil
        }
        return running
    }

    var isWorkspaceSwitchAnimating: Bool {
        workspaceSwitch?.isAnimating() ?? false
    }
}

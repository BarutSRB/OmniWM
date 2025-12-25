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

    var workspaceRoots: [WorkspaceDescriptor.ID: NiriRoot] = [:]

    var workspaceOrder: [WorkspaceDescriptor.ID] = []

    private(set) var activeWorkspaceIdx: Int = 0

    private(set) var previousWorkspaceId: WorkspaceDescriptor.ID?

    var viewportStates: [WorkspaceDescriptor.ID: ViewportState] = [:]

    var activeWorkspaceId: WorkspaceDescriptor.ID? {
        guard workspaceOrder.indices.contains(activeWorkspaceIdx) else { return nil }
        return workspaceOrder[activeWorkspaceIdx]
    }

    var activeRoot: NiriRoot? {
        guard let wsId = activeWorkspaceId else { return nil }
        return workspaceRoots[wsId]
    }

    var activeViewportState: ViewportState? {
        get {
            guard let wsId = activeWorkspaceId else { return nil }
            return viewportStates[wsId]
        }
        set {
            guard let wsId = activeWorkspaceId, let newValue else { return }
            viewportStates[wsId] = newValue
        }
    }

    var workspaceCount: Int {
        workspaceOrder.count
    }

    var hasWorkspaces: Bool {
        !workspaceOrder.isEmpty
    }

    init(monitor: Monitor) {
        id = monitor.id
        displayId = monitor.id.displayId
        outputName = monitor.name
        frame = monitor.frame
        visibleFrame = monitor.visibleFrame

        if let screen = NSScreen.screens.first(where: { $0.displayId == monitor.id.displayId }) {
            scale = screen.backingScaleFactor
        } else {
            scale = 2.0
        }
    }

    func updateOutputSize(monitor: Monitor) {
        frame = monitor.frame
        visibleFrame = monitor.visibleFrame

        if let screen = NSScreen.screens.first(where: { $0.frame == monitor.frame }) {
            scale = screen.backingScaleFactor
        }
    }
}

extension NiriMonitor {
    func addWorkspace(_ workspaceId: WorkspaceDescriptor.ID, at index: Int? = nil) {
        guard !workspaceOrder.contains(workspaceId) else { return }

        let insertIdx = index ?? workspaceOrder.count
        let clampedIdx = min(max(0, insertIdx), workspaceOrder.count)

        workspaceOrder.insert(workspaceId, at: clampedIdx)
        workspaceRoots[workspaceId] = NiriRoot(workspaceId: workspaceId)
        viewportStates[workspaceId] = ViewportState()

        if clampedIdx <= activeWorkspaceIdx, workspaceOrder.count > 1 {
            activeWorkspaceIdx += 1
        }
    }

    func root(for workspaceId: WorkspaceDescriptor.ID) -> NiriRoot? {
        workspaceRoots[workspaceId]
    }

    func ensureRoot(for workspaceId: WorkspaceDescriptor.ID) -> NiriRoot {
        if let existing = workspaceRoots[workspaceId] {
            return existing
        }

        let root = NiriRoot(workspaceId: workspaceId)
        workspaceRoots[workspaceId] = root

        if !workspaceOrder.contains(workspaceId) {
            workspaceOrder.append(workspaceId)
        }

        if viewportStates[workspaceId] == nil {
            viewportStates[workspaceId] = ViewportState()
        }

        return root
    }

    func containsWorkspace(_ workspaceId: WorkspaceDescriptor.ID) -> Bool {
        workspaceOrder.contains(workspaceId)
    }
}

extension NiriMonitor {
    func activateWorkspace(at idx: Int) {
        let clampedIdx = max(0, min(idx, workspaceOrder.count - 1))
        if clampedIdx == activeWorkspaceIdx {
            return
        }
        previousWorkspaceId = activeWorkspaceId
        activeWorkspaceIdx = clampedIdx
    }

    func activateWorkspace(_ workspaceId: WorkspaceDescriptor.ID) {
        guard let idx = workspaceOrder.firstIndex(of: workspaceId) else { return }
        activateWorkspace(at: idx)
    }
}

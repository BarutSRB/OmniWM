import AppKit
import Foundation
import QuartzCore

@MainActor final class DwindleLayoutHandler {
    weak var controller: WMController?

    var dwindleAnimationByDisplay: [CGDirectDisplayID: (WorkspaceDescriptor.ID, Monitor)] = [:]

    init(controller: WMController?) {
        self.controller = controller
    }

    func registerDwindleAnimation(_ workspaceId: WorkspaceDescriptor.ID, monitor: Monitor, on displayId: CGDirectDisplayID) -> Bool {
        if dwindleAnimationByDisplay[displayId]?.0 == workspaceId {
            return false
        }
        dwindleAnimationByDisplay[displayId] = (workspaceId, monitor)
        return true
    }

    func hasDwindleAnimationRunning(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        dwindleAnimationByDisplay.values.contains { $0.0 == workspaceId }
    }

    func tickDwindleAnimation(targetTime: CFTimeInterval, displayId: CGDirectDisplayID) {
        guard let (wsId, monitor) = dwindleAnimationByDisplay[displayId] else { return }
        guard let controller, let engine = controller.dwindleEngine else {
            controller?.layoutRefreshController.stopDwindleAnimation(for: displayId)
            return
        }

        engine.tickAnimations(at: targetTime, in: wsId)

        let insetFrame = controller.insetWorkingFrame(for: monitor)
        let baseFrames = engine.calculateLayout(for: wsId, screen: insetFrame)
        let animatedFrames = engine.calculateAnimatedFrames(
            baseFrames: baseFrames,
            in: wsId,
            at: targetTime
        )

        var frameUpdates: [(pid: pid_t, windowId: Int, frame: CGRect)] = []

        for (handle, frame) in animatedFrames {
            if let entry = controller.workspaceManager.entry(for: handle) {
                frameUpdates.append((handle.pid, entry.windowId, frame))
            }
        }

        controller.axManager.applyFramesParallel(frameUpdates)

        if !engine.hasActiveAnimations(in: wsId, at: targetTime) {
            if let focusedHandle = controller.focusedHandle,
               let frame = animatedFrames[focusedHandle],
               let entry = controller.workspaceManager.entry(for: focusedHandle) {
                controller.borderCoordinator.updateBorderIfAllowed(handle: focusedHandle, frame: frame, windowId: entry.windowId)
            }
            controller.layoutRefreshController.stopDwindleAnimation(for: displayId)
        }
    }

    func layoutWithDwindleEngine(activeWorkspaces: Set<WorkspaceDescriptor.ID>) async {
        guard let controller, let engine = controller.dwindleEngine else { return }
        let lrc = controller.layoutRefreshController

        for monitor in controller.workspaceManager.monitors {
            guard let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) else { continue }
            let wsId = workspace.id

            guard activeWorkspaces.contains(wsId) else { continue }

            let wsName = workspace.name
            let layoutType = controller.settings.layoutType(for: wsName)
            guard layoutType == .dwindle else { continue }

            let oldFrames = engine.currentFrames(in: wsId)

            let windowHandles = controller.workspaceManager.entries(in: wsId).map(\.handle)
            let currentFocusedHandle = controller.focusedHandle

            _ = engine.syncWindows(windowHandles, in: wsId, focusedHandle: currentFocusedHandle)

            lrc.updateWindowConstraints(in: wsId) { engine.updateWindowConstraints(for: $0, constraints: $1) }

            let insetFrame = controller.insetWorkingFrame(for: monitor)

            let newFrames = engine.calculateLayout(for: wsId, screen: insetFrame)

            for entry in controller.workspaceManager.entries(in: wsId) {
                if newFrames[entry.handle] != nil {
                    print("[WS-DEBUG] dwindleLayout: unhiding window \(entry.handle) in workspace \(wsName)(\(wsId.uuidString.prefix(8)))")
                    lrc.unhideWindow(entry, monitor: monitor)
                }
            }

            if let selected = engine.selectedNode(in: wsId),
               case let .leaf(handle, _) = selected.kind,
               let handle {
                controller.focusManager.updateWorkspaceFocusMemory(handle, for: wsId)
                if let currentFocused = controller.focusedHandle {
                    if controller.workspaceManager.workspace(for: currentFocused) == wsId {
                        controller.focusManager.setFocus(handle, in: wsId)
                    }
                } else {
                    controller.focusManager.setFocus(handle, in: wsId)
                }
            }

            if controller.settings.animationsEnabled {
                engine.animateWindowMovements(oldFrames: oldFrames, newFrames: newFrames)
            }

            let now = CACurrentMediaTime()
            if controller.settings.animationsEnabled, engine.hasActiveAnimations(in: wsId, at: now) {
                lrc.startDwindleAnimation(for: wsId, monitor: monitor)

                if let focusedHandle = controller.focusedHandle,
                   let frame = newFrames[focusedHandle],
                   let entry = controller.workspaceManager.entry(for: focusedHandle) {
                    controller.borderManager.updateFocusedWindow(frame: frame, windowId: entry.windowId)
                }
            } else {
                var frameUpdates: [(pid: pid_t, windowId: Int, frame: CGRect)] = []

                for (handle, frame) in newFrames {
                    if let entry = controller.workspaceManager.entry(for: handle) {
                        frameUpdates.append((handle.pid, entry.windowId, frame))
                    }
                }

                controller.axManager.applyFramesParallel(frameUpdates)

                if let focusedHandle = controller.focusedHandle,
                   let frame = newFrames[focusedHandle],
                   let entry = controller.workspaceManager.entry(for: focusedHandle) {
                    controller.borderCoordinator.updateBorderIfAllowed(handle: focusedHandle, frame: frame, windowId: entry.windowId)
                }
            }

            await Task.yield()
        }

        controller.updateWorkspaceBar()
    }

    // MARK: - Layout Capability Commands

    func focusNeighbor(direction: Direction) {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            if let handle = engine.moveFocus(direction: direction, in: wsId) {
                controller.focusManager.setFocus(handle, in: wsId)
                controller.layoutRefreshController.executeLayoutRefreshImmediate { [weak controller] in
                    controller?.focusWindow(handle)
                }
            }
        }
    }

    func swapWindow(direction: Direction) {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            if engine.swapWindows(direction: direction, in: wsId) {
                controller.layoutRefreshController.executeLayoutRefreshImmediate()
            }
        }
    }

    func toggleFullscreen() {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            if let handle = engine.toggleFullscreen(in: wsId) {
                controller.focusManager.setFocus(handle, in: wsId)
                controller.layoutRefreshController.executeLayoutRefreshImmediate()
            }
        }
    }

    func cycleSize(forward: Bool) {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            engine.cycleSplitRatio(forward: forward, in: wsId)
            controller.layoutRefreshController.executeLayoutRefreshImmediate()
        }
    }

    func balanceSizes() {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            engine.balanceSizes(in: wsId)
            controller.layoutRefreshController.executeLayoutRefreshImmediate()
        }
    }

    // MARK: - Layout Engine Configuration

    func enableDwindleLayout() {
        guard let controller else { return }
        let engine = DwindleLayoutEngine()
        engine.animationClock = controller.animationClock
        controller.dwindleEngine = engine
        controller.layoutRefreshController.refreshWindowsAndLayout()
    }

    func updateDwindleConfig(
        smartSplit: Bool? = nil,
        defaultSplitRatio: CGFloat? = nil,
        splitWidthMultiplier: CGFloat? = nil,
        singleWindowAspectRatio: CGSize? = nil,
        innerGap: CGFloat? = nil,
        outerGapTop: CGFloat? = nil,
        outerGapBottom: CGFloat? = nil,
        outerGapLeft: CGFloat? = nil,
        outerGapRight: CGFloat? = nil
    ) {
        guard let controller, let engine = controller.dwindleEngine else { return }
        if let v = smartSplit { engine.settings.smartSplit = v }
        if let v = defaultSplitRatio { engine.settings.defaultSplitRatio = v }
        if let v = splitWidthMultiplier { engine.settings.splitWidthMultiplier = v }
        if let v = singleWindowAspectRatio { engine.settings.singleWindowAspectRatio = v }
        if let v = innerGap { engine.settings.innerGap = v }
        if let v = outerGapTop { engine.settings.outerGapTop = v }
        if let v = outerGapBottom { engine.settings.outerGapBottom = v }
        if let v = outerGapLeft { engine.settings.outerGapLeft = v }
        if let v = outerGapRight { engine.settings.outerGapRight = v }
        controller.layoutRefreshController.refreshWindowsAndLayout()
    }

    func withDwindleContext(
        perform: (DwindleLayoutEngine, WorkspaceDescriptor.ID) -> Void
    ) {
        guard let controller,
              let engine = controller.dwindleEngine,
              let wsId = controller.activeWorkspace()?.id
        else { return }
        perform(engine, wsId)
    }
}

extension DwindleLayoutHandler: LayoutFocusable, LayoutSwappable, LayoutSizable {}

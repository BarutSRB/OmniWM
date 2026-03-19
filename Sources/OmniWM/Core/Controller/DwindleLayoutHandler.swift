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

    func applyFramesOnDemand(workspaceId wsId: WorkspaceDescriptor.ID, monitor: Monitor) {
        guard let controller,
              let activeWorkspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let engine = controller.dwindleEngine,
              let snapshot = makeWorkspaceSnapshot(
                  workspaceId: wsId,
                  monitor: monitor,
                  resolveConstraints: false,
                  isActiveWorkspace: activeWorkspaceId == wsId
              )
        else {
            return
        }

        let plan = buildOnDemandLayoutPlan(
            snapshot: snapshot,
            engine: engine
        )
        controller.layoutRefreshController.executeLayoutPlan(plan)
    }

    func tickDwindleAnimation(targetTime: CFTimeInterval, displayId: CGDirectDisplayID) {
        guard let (wsId, _) = dwindleAnimationByDisplay[displayId] else { return }
        guard let controller, let engine = controller.dwindleEngine else {
            controller?.layoutRefreshController.stopDwindleAnimation(for: displayId)
            return
        }

        guard let monitor = controller.workspaceManager.monitors.first(where: { $0.displayId == displayId }) else {
            controller.layoutRefreshController.stopDwindleAnimation(for: displayId)
            return
        }

        guard controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == wsId else {
            controller.layoutRefreshController.stopDwindleAnimation(for: displayId)
            return
        }

        engine.tickAnimations(at: targetTime, in: wsId)
        guard let snapshot = makeWorkspaceSnapshot(
            workspaceId: wsId,
            monitor: monitor,
            resolveConstraints: false,
            isActiveWorkspace: true
        ) else {
            return
        }

        let plan = buildAnimationPlan(
            snapshot: snapshot,
            engine: engine,
            targetTime: targetTime
        )
        controller.layoutRefreshController.executeLayoutPlan(plan)

        if !engine.hasActiveAnimations(in: wsId, at: targetTime) {
            controller.layoutRefreshController.stopDwindleAnimation(for: displayId)
        }
    }

    func layoutWithDwindleEngine(activeWorkspaces: Set<WorkspaceDescriptor.ID>) async throws -> [WorkspaceLayoutPlan] {
        guard let controller, let engine = controller.dwindleEngine else { return [] }
        var plans: [WorkspaceLayoutPlan] = []
        for monitor in controller.workspaceManager.monitors {
            try Task.checkCancellation()
            guard let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) else { continue }
            let wsId = workspace.id

            guard activeWorkspaces.contains(wsId) else { continue }

            let wsName = workspace.name
            let layoutType = controller.settings.layoutType(for: wsName)
            guard layoutType == .dwindle else { continue }

            guard let snapshot = makeWorkspaceSnapshot(
                workspaceId: wsId,
                monitor: monitor,
                resolveConstraints: true,
                isActiveWorkspace: activeWorkspaces.contains(wsId)
            ) else { continue }

            plans.append(
                buildRelayoutPlan(
                    snapshot: snapshot,
                    engine: engine
                )
            )

            try Task.checkCancellation()
            await Task.yield()
        }

        try Task.checkCancellation()
        return plans
    }

    // MARK: - Layout Capability Commands

    func focusNeighbor(direction: Direction) {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            if let token = engine.moveFocus(direction: direction, in: wsId) {
                _ = controller.workspaceManager.applySessionPatch(
                    .init(
                        workspaceId: wsId,
                        viewportState: nil,
                        rememberedFocusToken: token
                    )
                )
                controller.layoutRefreshController.requestImmediateRelayout(
                    reason: .layoutCommand
                ) { [weak controller] in
                    controller?.focusWindow(token)
                }
            }
        }
    }

    func activateWindow(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) {
        guard let controller,
              let engine = controller.dwindleEngine,
              controller.workspaceManager.entry(for: token)?.workspaceId == workspaceId,
              let node = engine.findNode(for: token),
              node.isLeaf
        else {
            return
        }

        engine.setSelectedNode(node, in: workspaceId)
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: nil,
                rememberedFocusToken: token
            )
        )
        controller.layoutRefreshController.requestImmediateRelayout(
            reason: .layoutCommand
        ) { [weak controller] in
            controller?.focusWindow(token)
        }
    }

    func swapWindow(direction: Direction) {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            if engine.swapWindows(direction: direction, in: wsId) {
                controller.layoutRefreshController.requestImmediateRelayout(reason: .layoutCommand)
            }
        }
    }

    func toggleFullscreen() {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            if let token = engine.toggleFullscreen(in: wsId) {
                _ = controller.workspaceManager.applySessionPatch(
                    .init(
                        workspaceId: wsId,
                        viewportState: nil,
                        rememberedFocusToken: token
                    )
                )
                controller.layoutRefreshController.requestImmediateRelayout(reason: .layoutCommand)
            }
        }
    }

    func cycleSize(forward: Bool) {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            engine.cycleSplitRatio(forward: forward, in: wsId)
            controller.layoutRefreshController.requestImmediateRelayout(reason: .layoutCommand)
        }
    }

    func balanceSizes() {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            engine.balanceSizes(in: wsId)
            controller.layoutRefreshController.requestImmediateRelayout(reason: .layoutCommand)
        }
    }

    // MARK: - Layout Engine Configuration

    func enableDwindleLayout() {
        guard let controller else { return }
        let engine = DwindleLayoutEngine()
        engine.animationClock = controller.animationClock
        controller.dwindleEngine = engine
        controller.layoutRefreshController.requestRelayout(reason: .layoutConfigChanged)
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
        controller.layoutRefreshController.requestRelayout(reason: .layoutConfigChanged)
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

    private func makeWorkspaceSnapshot(
        workspaceId wsId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        resolveConstraints: Bool,
        isActiveWorkspace: Bool
    ) -> DwindleWorkspaceSnapshot? {
        guard let controller else { return nil }

        let entries = controller.workspaceManager.tiledEntries(in: wsId)
        let windows = controller.layoutRefreshController.buildWindowSnapshots(
            for: entries,
            resolveConstraints: resolveConstraints
        )
        let monitorSnapshot = controller.layoutRefreshController.buildMonitorSnapshot(for: monitor)
        let selectedToken: WindowToken?
        if let selected = controller.dwindleEngine?.selectedNode(in: wsId),
           case let .leaf(handle, _) = selected.kind
        {
            selectedToken = handle
        } else {
            selectedToken = nil
        }

        return DwindleWorkspaceSnapshot(
            workspaceId: wsId,
            monitor: monitorSnapshot,
            windows: windows,
            preferredFocusToken: controller.workspaceManager.preferredFocusToken(in: wsId),
            confirmedFocusedToken: controller.workspaceManager.focusedToken,
            selectedToken: selectedToken,
            settings: controller.settings.resolvedDwindleSettings(for: monitor),
            isActiveWorkspace: isActiveWorkspace
        )
    }

    private func buildRelayoutPlan(
        snapshot: DwindleWorkspaceSnapshot,
        engine: DwindleLayoutEngine
    ) -> WorkspaceLayoutPlan {
        applyResolvedSettings(snapshot.settings, to: engine)

        let oldFrames = engine.currentFrames(in: snapshot.workspaceId)
        let windowTokens = snapshot.windows.map(\.token)
        _ = engine.syncWindows(
            windowTokens,
            in: snapshot.workspaceId,
            focusedToken: snapshot.preferredFocusToken
        )

        for window in snapshot.windows {
            engine.updateWindowConstraints(for: window.token, constraints: window.constraints)
        }

        let newFrames = engine.calculateLayout(
            for: snapshot.workspaceId,
            screen: snapshot.monitor.workingFrame
        )

        let rememberedFocusToken: WindowToken?
        if let selected = engine.selectedNode(in: snapshot.workspaceId),
           case let .leaf(handle, _) = selected.kind
        {
            rememberedFocusToken = handle
        } else {
            rememberedFocusToken = nil
        }

        engine.animateWindowMovements(oldFrames: oldFrames, newFrames: newFrames)

        let now = CACurrentMediaTime()
        let animationsActive = engine.hasActiveAnimations(in: snapshot.workspaceId, at: now)
        let diff = layoutDiff(
            windows: snapshot.windows,
            frames: newFrames,
            confirmedFocusedToken: snapshot.confirmedFocusedToken,
            directBorderUpdate: animationsActive,
            canRestoreHiddenWorkspaceWindows: snapshot.isActiveWorkspace
        )
        let directives: [AnimationDirective] = animationsActive
            ? [.startDwindleAnimation(workspaceId: snapshot.workspaceId, monitorId: snapshot.monitor.monitorId)]
            : []

        return WorkspaceLayoutPlan(
            workspaceId: snapshot.workspaceId,
            monitor: snapshot.monitor,
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: snapshot.workspaceId,
                rememberedFocusToken: rememberedFocusToken
            ),
            diff: diff,
            animationDirectives: directives
        )
    }

    private func buildOnDemandLayoutPlan(
        snapshot: DwindleWorkspaceSnapshot,
        engine: DwindleLayoutEngine
    ) -> WorkspaceLayoutPlan {
        applyResolvedSettings(snapshot.settings, to: engine)

        let frames = engine.calculateLayout(
            for: snapshot.workspaceId,
            screen: snapshot.monitor.workingFrame
        )
        let diff = layoutDiff(
            windows: snapshot.windows,
            frames: frames,
            confirmedFocusedToken: snapshot.confirmedFocusedToken,
            directBorderUpdate: true,
            canRestoreHiddenWorkspaceWindows: snapshot.isActiveWorkspace
        )

        return WorkspaceLayoutPlan(
            workspaceId: snapshot.workspaceId,
            monitor: snapshot.monitor,
            sessionPatch: WorkspaceSessionPatch(workspaceId: snapshot.workspaceId),
            diff: diff
        )
    }

    private func buildAnimationPlan(
        snapshot: DwindleWorkspaceSnapshot,
        engine: DwindleLayoutEngine,
        targetTime: TimeInterval
    ) -> WorkspaceLayoutPlan {
        applyResolvedSettings(snapshot.settings, to: engine)

        let baseFrames = engine.calculateLayout(
            for: snapshot.workspaceId,
            screen: snapshot.monitor.workingFrame
        )
        let animatedFrames = engine.calculateAnimatedFrames(
            baseFrames: baseFrames,
            in: snapshot.workspaceId,
            at: targetTime
        )
        let animationsActive = engine.hasActiveAnimations(in: snapshot.workspaceId, at: targetTime)
        let diff = layoutDiff(
            windows: snapshot.windows,
            frames: animatedFrames,
            confirmedFocusedToken: snapshot.confirmedFocusedToken,
            directBorderUpdate: animationsActive,
            borderMode: animationsActive ? .direct : .coordinated,
            canRestoreHiddenWorkspaceWindows: snapshot.isActiveWorkspace
        )

        return WorkspaceLayoutPlan(
            workspaceId: snapshot.workspaceId,
            monitor: snapshot.monitor,
            sessionPatch: WorkspaceSessionPatch(workspaceId: snapshot.workspaceId),
            diff: diff
        )
    }

    private func layoutDiff(
        windows: [LayoutWindowSnapshot],
        frames: [WindowToken: CGRect],
        confirmedFocusedToken: WindowToken?,
        directBorderUpdate: Bool,
        borderMode: BorderUpdateMode? = nil,
        canRestoreHiddenWorkspaceWindows: Bool
    ) -> WorkspaceLayoutDiff {
        var diff = WorkspaceLayoutDiff()
        let suspendedTokens = Set(
            windows.lazy
                .filter(\.isNativeFullscreenSuspended)
                .map(\.token)
        )
        if let confirmedFocusedToken {
            let ownsFocusedToken = windows.contains {
                $0.token == confirmedFocusedToken && !$0.isNativeFullscreenSuspended
            }
            diff.borderMode = ownsFocusedToken
                ? (borderMode ?? (directBorderUpdate ? .direct : .coordinated))
                : .none
        } else {
            diff.borderMode = borderMode ?? (directBorderUpdate ? .direct : .coordinated)
        }

        for window in windows {
            if window.isNativeFullscreenSuspended {
                continue
            }
            if canRestoreHiddenWorkspaceWindows,
               let hiddenState = window.hiddenState,
               hiddenState.workspaceInactive
            {
                diff.restoreChanges.append(
                    .init(token: window.token, hiddenState: hiddenState)
                )
            }
            guard let frame = frames[window.token] else { continue }
            diff.frameChanges.append(
                LayoutFrameChange(
                    token: window.token,
                    frame: frame,
                    forceApply: false
                )
            )
        }

        if let confirmedFocusedToken,
           !suspendedTokens.contains(confirmedFocusedToken),
           let frame = frames[confirmedFocusedToken]
        {
            diff.focusedFrame = LayoutFocusedFrame(
                token: confirmedFocusedToken,
                frame: frame
            )
        }

        return diff
    }

    private func applyResolvedSettings(
        _ settings: ResolvedDwindleSettings,
        to engine: DwindleLayoutEngine
    ) {
        engine.settings.smartSplit = settings.smartSplit
        engine.settings.defaultSplitRatio = settings.defaultSplitRatio
        engine.settings.splitWidthMultiplier = settings.splitWidthMultiplier
        engine.settings.singleWindowAspectRatio = settings.singleWindowAspectRatio.size
        engine.settings.innerGap = settings.innerGap
        engine.settings.outerGapTop = settings.outerGapTop
        engine.settings.outerGapBottom = settings.outerGapBottom
        engine.settings.outerGapLeft = settings.outerGapLeft
        engine.settings.outerGapRight = settings.outerGapRight
    }
}

extension DwindleLayoutHandler: LayoutFocusable, LayoutSizable {}

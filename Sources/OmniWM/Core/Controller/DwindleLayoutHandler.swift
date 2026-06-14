import AppKit
import Foundation
import QuartzCore

@MainActor final class DwindleLayoutHandler {
    weak var controller: WMController?

    var dwindleAnimationByDisplay: [CGDirectDisplayID: (WorkspaceDescriptor.ID, Monitor)] = [:]

    init(controller: WMController?) {
        self.controller = controller
    }

    func registerDwindleAnimation(
        _ workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        on displayId: CGDirectDisplayID
    ) -> Bool {
        if dwindleAnimationByDisplay[displayId]?.0 == workspaceId {
            return false
        }
        dwindleAnimationByDisplay[displayId] = (workspaceId, monitor)
        return true
    }

    func hasDwindleAnimationRunning(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        dwindleAnimationByDisplay.values.contains { $0.0 == workspaceId }
    }

    @discardableResult
    func applyFramesOnDemand(workspaceId wsId: WorkspaceDescriptor.ID, monitor: Monitor) -> Bool {
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
            return false
        }

        let plan = buildOnDemandLayoutPlan(
            snapshot: snapshot,
            engine: engine
        )
        return controller.layoutRefreshController.executeLayoutPlan(plan)
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
        let didExecute = controller.layoutRefreshController.executeLayoutPlan(plan)
        guard didExecute else {
            controller.layoutRefreshController.requestRelayout(
                reason: .staleLayoutPlan,
                affectedWorkspaceIds: [wsId]
            )
            return
        }

        if !engine.hasActiveAnimations(in: wsId, at: targetTime) {
            if let settleSnapshot = makeWorkspaceSnapshot(
                workspaceId: wsId,
                monitor: monitor,
                resolveConstraints: false,
                isActiveWorkspace: true
            ) {
                var settlePlan = buildAnimationPlan(
                    snapshot: settleSnapshot,
                    engine: engine,
                    targetTime: targetTime
                )
                settlePlan.isAnimationTick = false
                _ = controller.layoutRefreshController.executeLayoutPlan(settlePlan)
            }
            controller.layoutRefreshController.stopDwindleAnimation(for: displayId)
            controller.surfaceReconciler.noteRestackOccurred()
        }
    }

    func layoutWithDwindleEngine(activeWorkspaces: Set<WorkspaceDescriptor.ID>) -> [WorkspaceLayoutPlan] {
        guard let controller, let engine = controller.dwindleEngine else { return [] }
        var plans: [WorkspaceLayoutPlan] = []
        let workspaceIds = activeWorkspaces.sorted(by: { $0.uuidString < $1.uuidString })
        for wsId in workspaceIds {
            guard let workspace = controller.workspaceManager.descriptor(for: wsId),
                  let monitor = controller.workspaceManager.monitor(for: wsId)
            else { continue }

            let wsName = workspace.name
            let layoutType = controller.settings.layoutType(for: wsName)
            guard layoutType == .dwindle else { continue }
            let isActiveWorkspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == wsId

            guard let snapshot = makeWorkspaceSnapshot(
                workspaceId: wsId,
                monitor: monitor,
                resolveConstraints: true,
                isActiveWorkspace: isActiveWorkspace
            ) else { continue }

            plans.append(
                buildRelayoutPlan(
                    snapshot: snapshot,
                    engine: engine
                )
            )
        }

        return plans
    }

    func recordLayoutOperation(
        _ operation: LayoutOperation,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        controller?.workspaceManager.recordLayoutOperation(operation, in: workspaceId)
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
                        rememberedFocusToken: token,
                        plannedSeq: controller.workspaceManager.worldSeq
                    )
                )
                controller.layoutRefreshController.requestLayoutCommandRelayout(
                    affectedWorkspaceIds: [wsId]
                ) { [weak controller] in
                    controller?.focusWindow(token)
                }
            }
        }
    }

    func activateWindow(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        origin: ManagedFocusOrigin = .keyboardOrProgrammatic,
        layoutRefresh: Bool = true
    ) {
        guard let controller,
              let engine = controller.dwindleEngine,
              controller.workspaceManager.entry(for: token)?.workspaceId == workspaceId,
              let node = engine.findNode(for: token),
              node.isLeaf
        else {
            return
        }

        controller.workspaceManager.withEngineMutationScope {
            engine.setSelectedNode(node, in: workspaceId)
        }
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: nil,
                rememberedFocusToken: token,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )

        if layoutRefresh {
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [workspaceId]
            ) { [weak controller] in
                controller?.focusWindow(token, origin: origin)
            }
        } else {
            controller.focusWindow(token, origin: origin)
        }
    }

    func swapWindow(direction: Direction) {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            if engine.swapWindows(direction: direction, in: wsId) {
                recordLayoutOperation(.windowsSwapped, in: wsId)
                controller.layoutRefreshController.requestLayoutCommandRelayout(
                    affectedWorkspaceIds: [wsId]
                )
            }
        }
    }

    func toggleFullscreen() {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            if let token = engine.toggleFullscreen(in: wsId) {
                recordLayoutOperation(.fullscreenToggled(token: token), in: wsId)
                _ = controller.workspaceManager.applySessionPatch(
                    .init(
                        workspaceId: wsId,
                        viewportState: nil,
                        rememberedFocusToken: token,
                        plannedSeq: controller.workspaceManager.worldSeq
                    )
                )
                controller.layoutRefreshController.requestLayoutCommandRelayout(
                    affectedWorkspaceIds: [wsId]
                )
            }
        }
    }

    func cycleSize(forward: Bool) {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            if engine.cycleSplitRatio(forward: forward, in: wsId) {
                recordLayoutOperation(.splitRatioChanged, in: wsId)
            }
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
    }

    func balanceSizes() {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            if engine.balanceSizes(in: wsId) {
                recordLayoutOperation(.sizesBalanced, in: wsId)
            }
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
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
        controller.workspaceManager.withEngineMutationScope {
            if let v = smartSplit { engine.settings.smartSplit = v }
            if let v = defaultSplitRatio { engine.settings.defaultSplitRatio = v }
            if let v = splitWidthMultiplier { engine.settings.splitWidthMultiplier = v }
            if let v = singleWindowAspectRatio { engine.settings.singleWindowAspectRatio = v }
            if let v = innerGap { engine.settings.innerGap = v }
            if let v = outerGapTop { engine.settings.outerGapTop = v }
            if let v = outerGapBottom { engine.settings.outerGapBottom = v }
            if let v = outerGapLeft { engine.settings.outerGapLeft = v }
            if let v = outerGapRight { engine.settings.outerGapRight = v }
        }
        controller.layoutRefreshController.requestRelayout(reason: .layoutConfigChanged)
    }

    func withDwindleContext(
        perform: (DwindleLayoutEngine, WorkspaceDescriptor.ID) -> Void
    ) {
        guard let controller,
              let engine = controller.dwindleEngine,
              let wsId = controller.activeWorkspace()?.id
        else { return }
        controller.workspaceManager.withEngineMutationScope {
            perform(engine, wsId)
        }
    }

    private func makeWorkspaceSnapshot(
        workspaceId wsId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        resolveConstraints: Bool,
        isActiveWorkspace: Bool
    ) -> DwindleWorkspaceSnapshot? {
        guard let controller else { return nil }

        guard let refreshInput = controller.layoutRefreshController.buildRefreshInput(
            workspaceId: wsId,
            monitor: monitor,
            resolveConstraints: resolveConstraints,
            isActiveWorkspace: isActiveWorkspace
        ) else {
            return nil
        }
        return DwindleWorkspaceSnapshot(
            workspaceId: wsId,
            monitor: refreshInput.monitor,
            windows: refreshInput.windows,
            plannedSeq: refreshInput.plannedSeq,
            preferredFocusToken: controller.workspaceManager.preferredFocusToken(in: wsId),
            settings: controller.settings.resolvedDwindleSettings(for: monitor),
            isActiveWorkspace: refreshInput.isActiveWorkspace
        )
    }

    private func buildRelayoutPlan(
        snapshot: DwindleWorkspaceSnapshot,
        engine: DwindleLayoutEngine
    ) -> WorkspaceLayoutPlan {
        applyResolvedSettings(snapshot.settings, to: engine)

        let now = controller?.animationClock.now() ?? CACurrentMediaTime()
        let previousTargetFrames = engine.currentFrames(in: snapshot.workspaceId)
        let oldFrames = engine.presentedFrames(in: snapshot.workspaceId, at: now)
        let windowTokens = snapshot.windows.map(\.token)
        _ = engine.syncWindows(
            windowTokens,
            in: snapshot.workspaceId,
            focusedToken: snapshot.preferredFocusToken,
            bootstrapScreen: snapshot.monitor.workingFrame
        )

        for window in snapshot.windows {
            engine.updateWindowConstraints(for: window.token, constraints: window.layoutConstraints)
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

        engine.animateWindowMovements(
            oldFrames: oldFrames,
            previousTargetFrames: previousTargetFrames,
            newFrames: newFrames,
            startTime: now,
            motion: controller?.motionPolicy.snapshot() ?? .enabled
        )

        let animationsActive = engine.hasActiveAnimations(in: snapshot.workspaceId, at: now)
        let diffFrames = animationsActive
            ? engine.calculateAnimatedFrames(
                baseFrames: newFrames,
                in: snapshot.workspaceId,
                at: now
            )
            : newFrames
        let diff = layoutDiff(
            windows: snapshot.windows,
            frames: diffFrames,
            canRestoreHiddenWorkspaceWindows: snapshot.isActiveWorkspace,
            scale: snapshot.monitor.scale
        )
        let directives: [AnimationDirective] = animationsActive
            ? [.startDwindleAnimation(workspaceId: snapshot.workspaceId, monitorId: snapshot.monitor.monitorId)]
            : []

        return WorkspaceLayoutPlan(
            workspaceId: snapshot.workspaceId,
            monitor: snapshot.monitor,
            plannedSeq: snapshot.plannedSeq,
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: snapshot.workspaceId,
                rememberedFocusToken: rememberedFocusToken,
                plannedSeq: snapshot.plannedSeq
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
            canRestoreHiddenWorkspaceWindows: snapshot.isActiveWorkspace,
            scale: snapshot.monitor.scale
        )

        return WorkspaceLayoutPlan(
            workspaceId: snapshot.workspaceId,
            monitor: snapshot.monitor,
            plannedSeq: snapshot.plannedSeq,
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: snapshot.workspaceId,
                plannedSeq: snapshot.plannedSeq
            ),
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
        let diff = layoutDiff(
            windows: snapshot.windows,
            frames: animatedFrames,
            canRestoreHiddenWorkspaceWindows: snapshot.isActiveWorkspace,
            scale: snapshot.monitor.scale
        )

        return WorkspaceLayoutPlan(
            workspaceId: snapshot.workspaceId,
            monitor: snapshot.monitor,
            plannedSeq: snapshot.plannedSeq,
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: snapshot.workspaceId,
                plannedSeq: snapshot.plannedSeq
            ),
            diff: diff,
            isAnimationTick: true
        )
    }

    private func layoutDiff(
        windows: [LayoutWindowSnapshot],
        frames: [WindowToken: CGRect],
        canRestoreHiddenWorkspaceWindows: Bool,
        scale: CGFloat
    ) -> WorkspaceLayoutDiff {
        var diff = WorkspaceLayoutDiff()
        let effectiveScale = max(scale, 1.0)
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
            guard let frame = frames[window.token]?.roundedToPhysicalPixels(scale: effectiveScale) else { continue }
            diff.frameChanges.append(
                LayoutFrameChange(
                    token: window.token,
                    frame: frame,
                    forceApply: false
                )
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

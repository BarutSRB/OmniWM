// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation
import QuartzCore

@MainActor final class DwindleLayoutHandler {
    weak var controller: WMController?

    var dwindleAnimationByDisplay: [CGDirectDisplayID: (WorkspaceDescriptor.ID, Monitor)] = [:]
    var pendingAnimationStartFrames: [WorkspaceDescriptor.ID: [WindowToken: CGRect]] = [:]

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
        for wsId in activeWorkspaces.sorted(by: { $0.uuidString < $1.uuidString }) {
            try Task.checkCancellation()
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

            try Task.checkCancellation()
            await Task.yield()
        }

        try Task.checkCancellation()
        return plans
    }



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
                    reason: .layoutCommand,
                    affectedWorkspaceIds: [wsId]
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
            reason: .layoutCommand,
            affectedWorkspaceIds: [workspaceId]
        ) { [weak controller] in
            controller?.focusWindow(token)
        }
    }

    func swapWindow(direction: Direction) {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            capturePresentationForNextRelayout(workspaceId: wsId)
            if engine.swapWindows(direction: direction, in: wsId) {
                controller.layoutRefreshController.requestImmediateRelayout(
                    reason: .layoutCommand,
                    affectedWorkspaceIds: [wsId]
                )
            } else {
                discardPresentationForNextRelayout(workspaceId: wsId)
            }
        }
    }

    func toggleFullscreen() {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            capturePresentationForNextRelayout(workspaceId: wsId)
            if let token = engine.toggleFullscreen(in: wsId) {
                _ = controller.workspaceManager.applySessionPatch(
                    .init(
                        workspaceId: wsId,
                        viewportState: nil,
                        rememberedFocusToken: token
                    )
                )
                controller.layoutRefreshController.requestImmediateRelayout(
                    reason: .layoutCommand,
                    affectedWorkspaceIds: [wsId]
                )
            } else {
                discardPresentationForNextRelayout(workspaceId: wsId)
            }
        }
    }

    func cycleSize(forward: Bool) {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            capturePresentationForNextRelayout(workspaceId: wsId)
            engine.cycleSplitRatio(forward: forward, in: wsId)
            controller.layoutRefreshController.requestImmediateRelayout(
                reason: .layoutCommand,
                affectedWorkspaceIds: [wsId]
            )
        }
    }

    func balanceSizes() {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            capturePresentationForNextRelayout(workspaceId: wsId)
            engine.balanceSizes(in: wsId)
            controller.layoutRefreshController.requestImmediateRelayout(
                reason: .layoutCommand,
                affectedWorkspaceIds: [wsId]
            )
        }
    }

    func moveSelectionToRoot(stable: Bool) {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            capturePresentationForNextRelayout(workspaceId: wsId)
            engine.moveSelectionToRoot(stable: stable, in: wsId)
            controller.layoutRefreshController.requestImmediateRelayout(
                reason: .layoutCommand,
                affectedWorkspaceIds: [wsId]
            )
        }
    }

    func toggleSplit() {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            capturePresentationForNextRelayout(workspaceId: wsId)
            engine.toggleOrientation(in: wsId)
            controller.layoutRefreshController.requestImmediateRelayout(
                reason: .layoutCommand,
                affectedWorkspaceIds: [wsId]
            )
        }
    }

    func swapSplit() {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            capturePresentationForNextRelayout(workspaceId: wsId)
            engine.swapSplit(in: wsId)
            controller.layoutRefreshController.requestImmediateRelayout(
                reason: .layoutCommand,
                affectedWorkspaceIds: [wsId]
            )
        }
    }

    func resize(direction: Direction, grow: Bool) {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            let delta = grow ? engine.settings.resizeStep : -engine.settings.resizeStep
            capturePresentationForNextRelayout(workspaceId: wsId)
            engine.resizeSelected(by: delta, direction: direction, in: wsId)
            controller.layoutRefreshController.requestImmediateRelayout(
                reason: .layoutCommand,
                affectedWorkspaceIds: [wsId]
            )
        }
    }

    func summonWindowRight(
        _ token: WindowToken,
        beside anchorToken: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let engine = controller?.dwindleEngine else { return false }
        capturePresentationForNextRelayout(workspaceId: workspaceId)
        guard engine.summonWindowRight(token, beside: anchorToken, in: workspaceId) else {
            discardPresentationForNextRelayout(workspaceId: workspaceId)
            return false
        }
        return true
    }



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

    func capturePresentationForNextRelayout(workspaceId wsId: WorkspaceDescriptor.ID) {
        guard let controller,
              let engine = controller.dwindleEngine,
              let monitor = controller.workspaceManager.monitor(for: wsId)
        else {
            return
        }

        let sampleTime = engine.animationClock?.now() ?? CACurrentMediaTime()
        pendingAnimationStartFrames[wsId] = engine.capturePresentedFrames(
            in: wsId,
            at: sampleTime,
            scale: monitorScale(for: monitor.displayId)
        )
    }

    func discardPresentationForNextRelayout(workspaceId wsId: WorkspaceDescriptor.ID) {
        pendingAnimationStartFrames.removeValue(forKey: wsId)
    }

    private func consumePresentationForNextRelayout(
        workspaceId wsId: WorkspaceDescriptor.ID
    ) -> [WindowToken: CGRect]? {
        pendingAnimationStartFrames.removeValue(forKey: wsId)
    }

    private func monitorScale(for displayId: CGDirectDisplayID) -> CGFloat {
        guard let monitor = controller?.workspaceManager.monitors.first(where: { $0.displayId == displayId }),
              let controller
        else {
            return ScreenLookupCache.shared.backingScale(for: displayId)
        }
        return controller.layoutRefreshController.backingScale(for: monitor)
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
            monitor: refreshInput.monitor,
            windows: refreshInput.windows,
            preferredFocusToken: controller.workspaceManager.preferredFocusToken(in: wsId),
            confirmedFocusedToken: controller.workspaceManager.focusedToken,
            selectedToken: selectedToken,
            settings: controller.settings.resolvedDwindleSettings(for: monitor),
            displayRefreshRate: controller.layoutRefreshController.layoutState.refreshRateByDisplay[monitor.displayId] ?? 60.0,
            isActiveWorkspace: refreshInput.isActiveWorkspace
        )
    }

    private func buildRelayoutPlan(
        snapshot: DwindleWorkspaceSnapshot,
        engine: DwindleLayoutEngine
    ) -> WorkspaceLayoutPlan {
        syncEngineContext(snapshot, to: engine)

        let sampleTime = engine.animationClock?.now() ?? CACurrentMediaTime()
        let hasNativeFullscreenRestoreCycle = snapshot.windows.contains {
            $0.isRestoringNativeFullscreen
        }
        if hasNativeFullscreenRestoreCycle {
            discardPresentationForNextRelayout(workspaceId: snapshot.workspaceId)
        }
        let oldFrames = hasNativeFullscreenRestoreCycle
            ? engine.currentFrames(in: snapshot.workspaceId)
            : consumePresentationForNextRelayout(workspaceId: snapshot.workspaceId)
                ?? engine.capturePresentedFrames(
                    in: snapshot.workspaceId,
                    at: sampleTime,
                    scale: snapshot.monitor.scale
                )
        let windowTokens = snapshot.windows.map(\.token)
        _ = engine.syncWindows(
            windowTokens,
            in: snapshot.workspaceId,
            focusedToken: snapshot.preferredFocusToken,
            bootstrapScreen: snapshot.monitor.workingFrame
        )

        for window in snapshot.windows {
            engine.updateWindowConstraints(for: window.token, constraints: window.constraints)
        }

        let newFrames = engine.calculateLayout(
            for: snapshot.workspaceId,
            screen: snapshot.monitor.workingFrame,
            scale: snapshot.monitor.scale
        )

        let rememberedFocusToken: WindowToken?
        if let selected = engine.selectedNode(in: snapshot.workspaceId),
           case let .leaf(handle, _) = selected.kind
        {
            rememberedFocusToken = handle
        } else {
            rememberedFocusToken = nil
        }

        let restoreFrameOverrides = resolvedNativeFullscreenRestoreFrames(
            for: snapshot.windows,
            workspaceId: snapshot.workspaceId
        )
        let frames: [WindowToken: CGRect]
        let animationsActive: Bool
        if hasNativeFullscreenRestoreCycle {
            engine.clearAnimations(in: snapshot.workspaceId)
            for (token, restoreFrame) in restoreFrameOverrides {
                engine.findNode(for: token)?.cachedFrame = restoreFrame
            }
            frames = newFrames.merging(restoreFrameOverrides) { _, restoreFrame in restoreFrame }
            animationsActive = false
        } else {
            let animationFrames = engine.prepareAnimationFramesForRelayout(
                oldFrames: oldFrames,
                newFrames: newFrames,
                in: snapshot.workspaceId,
                motion: controller?.motionPolicy.snapshot() ?? .enabled,
                scale: snapshot.monitor.scale,
                at: sampleTime
            )
            frames = animationFrames.frames
            animationsActive = animationFrames.animationsActive
        }

        let diff = layoutDiff(
            windows: snapshot.windows,
            frames: frames,
            confirmedFocusedToken: snapshot.confirmedFocusedToken,
            directBorderUpdate: animationsActive,
            canRestoreHiddenWorkspaceWindows: snapshot.isActiveWorkspace
        )
        let directives: [AnimationDirective] = animationsActive
            ? [.startDwindleAnimation(workspaceId: snapshot.workspaceId, monitorId: snapshot.monitor.monitorId)]
            : []

        var plan = WorkspaceLayoutPlan(
            workspaceId: snapshot.workspaceId,
            monitor: snapshot.monitor,
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: snapshot.workspaceId,
                rememberedFocusToken: rememberedFocusToken
            ),
            diff: diff,
            animationDirectives: directives
        )
        plan.nativeFullscreenRestoreFinalizeTokens = nativeFullscreenRestoreFinalizeTokens(
            windows: snapshot.windows,
            frames: frames
        )
        plan.managedRestoreMaterialStateChanges = managedRestoreMaterialStateChanges(
            windows: snapshot.windows,
            oldFrames: oldFrames,
            newFrames: frames
        )
        plan.persistManagedRestoreSnapshots = false
        return plan
    }

    private func buildOnDemandLayoutPlan(
        snapshot: DwindleWorkspaceSnapshot,
        engine: DwindleLayoutEngine
    ) -> WorkspaceLayoutPlan {
        syncEngineContext(snapshot, to: engine)

        let frames = engine.calculateLayout(
            for: snapshot.workspaceId,
            screen: snapshot.monitor.workingFrame,
            scale: snapshot.monitor.scale
        )
        let diff = layoutDiff(
            windows: snapshot.windows,
            frames: frames,
            confirmedFocusedToken: snapshot.confirmedFocusedToken,
            directBorderUpdate: true,
            canRestoreHiddenWorkspaceWindows: snapshot.isActiveWorkspace
        )

        var plan = WorkspaceLayoutPlan(
            workspaceId: snapshot.workspaceId,
            monitor: snapshot.monitor,
            sessionPatch: WorkspaceSessionPatch(workspaceId: snapshot.workspaceId),
            diff: diff
        )
        plan.persistManagedRestoreSnapshots = false
        return plan
    }

    private func buildAnimationPlan(
        snapshot: DwindleWorkspaceSnapshot,
        engine: DwindleLayoutEngine,
        targetTime: TimeInterval
    ) -> WorkspaceLayoutPlan {
        syncEngineContext(snapshot, to: engine)

        let baseFrames = engine.calculateLayout(
            for: snapshot.workspaceId,
            screen: snapshot.monitor.workingFrame,
            scale: snapshot.monitor.scale
        )
        let animationFrames = engine.animationFrames(
            from: baseFrames,
            in: snapshot.workspaceId,
            at: targetTime,
            scale: snapshot.monitor.scale
        )
        let diff = layoutDiff(
            windows: snapshot.windows,
            frames: animationFrames.frames,
            confirmedFocusedToken: snapshot.confirmedFocusedToken,
            directBorderUpdate: animationFrames.animationsActive,
            borderMode: animationFrames.animationsActive ? .direct : .coordinated,
            canRestoreHiddenWorkspaceWindows: snapshot.isActiveWorkspace
        )

        var plan = WorkspaceLayoutPlan(
            workspaceId: snapshot.workspaceId,
            monitor: snapshot.monitor,
            sessionPatch: WorkspaceSessionPatch(workspaceId: snapshot.workspaceId),
            diff: diff
        )
        plan.persistManagedRestoreSnapshots = false
        return plan
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
                    forceApply: window.isRestoringNativeFullscreen
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

    private func syncEngineContext(
        _ snapshot: DwindleWorkspaceSnapshot,
        to engine: DwindleLayoutEngine
    ) {
        engine.settings.smartSplit = snapshot.settings.smartSplit
        engine.settings.defaultSplitRatio = snapshot.settings.defaultSplitRatio
        engine.settings.splitWidthMultiplier = snapshot.settings.splitWidthMultiplier
        engine.settings.singleWindowAspectRatio = snapshot.settings.singleWindowAspectRatio.size
        engine.settings.innerGap = snapshot.settings.innerGap
        engine.settings.outerGapTop = snapshot.settings.outerGapTop
        engine.settings.outerGapBottom = snapshot.settings.outerGapBottom
        engine.settings.outerGapLeft = snapshot.settings.outerGapLeft
        engine.settings.outerGapRight = snapshot.settings.outerGapRight
        engine.displayRefreshRate = snapshot.displayRefreshRate
    }

    private func managedRestoreMaterialStateChanges(
        windows: [LayoutWindowSnapshot],
        oldFrames: [WindowToken: CGRect],
        newFrames: [WindowToken: CGRect]
    ) -> [ManagedRestoreMaterialStateChange] {
        guard framesMatchSemantically(oldFrames, newFrames) else { return [] }
        return windows.compactMap { window in
            guard !window.isNativeFullscreenSuspended else { return nil }
            return ManagedRestoreMaterialStateChange(
                token: window.token,
                reason: .topologyChanged
            )
        }
    }

    private func framesMatchSemantically(
        _ lhs: [WindowToken: CGRect],
        _ rhs: [WindowToken: CGRect]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (token, frame) in lhs {
            guard let otherFrame = rhs[token],
                  frame.approximatelyEqual(to: otherFrame, tolerance: 0.5)
            else {
                return false
            }
        }
        return true
    }
}

extension DwindleLayoutHandler: LayoutFocusable, LayoutSizable {}

private extension DwindleLayoutHandler {
    func resolvedNativeFullscreenRestoreFrames(
        for windows: [LayoutWindowSnapshot],
        workspaceId: WorkspaceDescriptor.ID
    ) -> [WindowToken: CGRect] {
        guard let topologyProfile = controller?.workspaceManager.topologyProfile else { return [:] }

        var restoreFrames: [WindowToken: CGRect] = [:]
        for window in windows {
            guard let restoreContext = window.nativeFullscreenRestore,
                  restoreContext.currentToken == window.token,
                  restoreContext.workspaceId == workspaceId,
                  restoreContext.capturedTopologyProfile == topologyProfile,
                  let restoreFrame = restoreContext.restoreFrame
            else {
                continue
            }
            restoreFrames[window.token] = restoreFrame
        }
        return restoreFrames
    }

    func nativeFullscreenRestoreFinalizeTokens(
        windows: [LayoutWindowSnapshot],
        frames: [WindowToken: CGRect]
    ) -> [WindowToken] {
        return windows.compactMap { window in
            guard window.isRestoringNativeFullscreen,
                  window.restoreFrame != nil,
                  frames[window.token] != nil
            else {
                return nil
            }
            return window.token
        }
    }
}

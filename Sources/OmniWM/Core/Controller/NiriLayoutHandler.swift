// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation
import QuartzCore

private func hasPendingNiriAnimationWork(
    state: ViewportState,
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID
) -> Bool {
    state.viewOffsetPixels.isAnimating
        || engine.hasAnyWindowAnimationsRunning(in: workspaceId)
        || engine.hasAnyColumnAnimationsRunning(in: workspaceId)
}

@MainActor final class NiriLayoutHandler {
    weak var controller: WMController?

    struct NiriLayoutPass {
        let wsId: WorkspaceDescriptor.ID
        let engine: NiriLayoutEngine
        let monitor: Monitor
        let insetFrame: CGRect
        let gap: CGFloat
    }

    var scrollAnimationByDisplay: [CGDirectDisplayID: WorkspaceDescriptor.ID] = [:]

    init(controller: WMController?) {
        self.controller = controller
    }

    private func hiddenPlacementMonitorContexts() -> [HiddenPlacementMonitorContext] {
        guard let controller else { return [] }
        return Monitor.sortedByPosition(controller.workspaceManager.monitors)
            .map(HiddenPlacementMonitorContext.init)
    }

    @discardableResult
    func startScrollAnimationIfNeeded(
        for workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        engine: NiriLayoutEngine
    ) -> Bool {
        guard let controller else { return false }
        guard controller.motionPolicy.animationsEnabled else { return false }
        guard hasPendingNiriAnimationWork(state: state, engine: engine, workspaceId: workspaceId) else {
            return false
        }
        controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
        return true
    }

    func registerScrollAnimation(_ workspaceId: WorkspaceDescriptor.ID, on displayId: CGDirectDisplayID) -> Bool {
        if scrollAnimationByDisplay[displayId] == workspaceId {
            return false
        }
        scrollAnimationByDisplay[displayId] = workspaceId
        return true
    }

    func hasScrollAnimationRunning(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        scrollAnimationByDisplay.values.contains(workspaceId)
    }

    func tickScrollAnimation(targetTime: CFTimeInterval, displayId: CGDirectDisplayID) {
        guard let wsId = scrollAnimationByDisplay[displayId] else { return }
        guard let controller, let engine = controller.niriEngine else {
            controller?.layoutRefreshController.stopScrollAnimation(for: displayId)
            return
        }

        guard let monitor = controller.workspaceManager.monitors.first(where: { $0.displayId == displayId }) else {
            controller.layoutRefreshController.stopScrollAnimation(for: displayId)
            return
        }

        guard controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == wsId else {
            controller.layoutRefreshController.stopScrollAnimation(for: displayId)
            return
        }

        let windowAnimationsRunning = engine.tickAllWindowAnimations(in: wsId, at: targetTime)
        let columnAnimationsRunning = engine.tickAllColumnAnimations(in: wsId, at: targetTime)

        controller.workspaceManager.withNiriViewportState(for: wsId) { state in
            let viewportAnimationRunning = state.advanceAnimations(at: targetTime)

            self.applyFramesOnDemand(
                wsId: wsId,
                state: state,
                engine: engine,
                monitor: monitor,
                animationTime: targetTime
            )

            let animationsOngoing = viewportAnimationRunning
                || windowAnimationsRunning
                || columnAnimationsRunning

            if !animationsOngoing {
                self.finalizeAnimation()
                var activeIds = Set<WorkspaceDescriptor.ID>()
                for mon in controller.workspaceManager.monitors {
                    if let ws = controller.workspaceManager.activeWorkspaceOrFirst(on: mon.id) {
                        activeIds.insert(ws.id)
                    }
                }
                controller.layoutRefreshController.hideInactiveWorkspaces(activeWorkspaceIds: activeIds)
                controller.layoutRefreshController.stopScrollAnimation(for: displayId)
            }
        }
    }

    func applyFramesOnDemand(
        wsId: WorkspaceDescriptor.ID,
        state: ViewportState,
        engine: NiriLayoutEngine,
        monitor: Monitor,
        animationTime: TimeInterval? = nil
    ) {
        guard let controller,
              let activeWorkspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let snapshot = makeWorkspaceSnapshot(
                  workspaceId: wsId,
                  monitor: monitor,
                  viewportState: state,
                  useScrollAnimationPath: true,
                  removalSeed: nil,
                  isActiveWorkspace: activeWorkspaceId == wsId
              )
        else {
            return
        }

        let plan = buildOnDemandLayoutPlan(
            snapshot: snapshot,
            engine: engine,
            monitor: monitor,
            animationTime: animationTime
        )
        controller.layoutRefreshController.executeLayoutPlan(plan)
    }

    private func finalizeAnimation() {
        guard let controller else { return }

        let focusedTarget = controller.currentKeyboardFocusTargetForRendering()
        let preferredFrame: CGRect? = if let focusedTarget,
                                         focusedTarget.isManaged,
                                         let node = controller.niriEngine?.findNode(for: focusedTarget.token)
        {
            node.renderedFrame ?? node.frame
        } else {
            nil
        }
        if let token = focusedTarget?.token {
            _ = controller.reapplyKeyboardFocusBorderIfMatching(
                token: token,
                preferredFrame: preferredFrame,
                phase: .animationSettled,
                policy: .coordinated
            )
        } else {
            _ = controller.renderKeyboardFocusBorder(
                policy: .coordinated,
                source: .borderReapplyAnimationSettled
            )
        }

        if controller.moveMouseToFocusedWindowEnabled,
           let token = controller.workspaceManager.focusedToken
        {
            controller.moveMouseToWindow(token)
        }
    }

    func cancelActiveAnimations(for workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }

        for (displayId, wsId) in scrollAnimationByDisplay where wsId == workspaceId {
            controller.layoutRefreshController.stopScrollAnimation(for: displayId)
        }

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.cancelAnimation()
        }
    }

    func layoutWithNiriEngine(
        activeWorkspaces: Set<WorkspaceDescriptor.ID>,
        useScrollAnimationPath: Bool = false,
        removalSeeds: [WorkspaceDescriptor.ID: NiriWindowRemovalSeed] = [:]
    ) async throws -> [WorkspaceLayoutPlan] {
        guard let controller, let engine = controller.niriEngine else { return [] }
        var plans: [WorkspaceLayoutPlan] = []
        for wsId in activeWorkspaces.sorted(by: { $0.uuidString < $1.uuidString }) {
            try Task.checkCancellation()
            guard let workspace = controller.workspaceManager.descriptor(for: wsId),
                  let monitor = controller.workspaceManager.monitor(for: wsId)
            else { continue }

            let layoutType = controller.settings.layoutType(for: workspace.name)
            if layoutType == .dwindle { continue }
            let isActiveWorkspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == wsId

            guard let snapshot = makeWorkspaceSnapshot(
                workspaceId: wsId,
                monitor: monitor,
                viewportState: nil,
                useScrollAnimationPath: useScrollAnimationPath,
                removalSeed: removalSeeds[wsId],
                isActiveWorkspace: isActiveWorkspace
            ) else { continue }

            plans.append(
                buildRelayoutPlan(
                    snapshot: snapshot,
                    engine: engine,
                    monitor: monitor
                )
            )

            try Task.checkCancellation()
            await Task.yield()
        }

        try Task.checkCancellation()
        return plans
    }

    private func makeWorkspaceSnapshot(
        workspaceId wsId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        viewportState: ViewportState?,
        useScrollAnimationPath: Bool,
        removalSeed: NiriWindowRemovalSeed?,
        isActiveWorkspace: Bool
    ) -> NiriWorkspaceSnapshot? {
        guard let controller else { return nil }

        let shouldResolveConstraints = viewportState == nil
        let orientation = controller.niriEngine?.monitor(for: monitor.id)?.orientation
            ?? controller.settings.effectiveOrientation(for: monitor)
        guard let refreshInput = controller.layoutRefreshController.buildRefreshInput(
            workspaceId: wsId,
            monitor: monitor,
            resolveConstraints: shouldResolveConstraints,
            orientation: orientation,
            isActiveWorkspace: isActiveWorkspace
        ) else {
            return nil
        }

        let effectiveViewportState = viewportState ?? controller.workspaceManager.niriViewportState(for: wsId)
        let interactionWorkspaceId = controller.activeWorkspace()?.id

        return NiriWorkspaceSnapshot(
            workspaceId: wsId,
            monitor: refreshInput.monitor,
            windows: refreshInput.windows,
            viewportState: effectiveViewportState,
            preferredFocusToken: controller.workspaceManager.preferredFocusToken(in: wsId),
            confirmedFocusedToken: controller.workspaceManager.focusedToken,
            pendingFocusedToken: controller.workspaceManager.pendingFocusedToken,
            pendingFocusedWorkspaceId: controller.workspaceManager.pendingFocusedWorkspaceId,
            isNonManagedFocusActive: controller.workspaceManager.isNonManagedFocusActive,
            hasCompletedInitialRefresh: controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh,
            useScrollAnimationPath: useScrollAnimationPath,
            removalSeed: removalSeed,
            gap: CGFloat(controller.workspaceManager.gaps),
            outerGaps: controller.workspaceManager.outerGaps,
            displayRefreshRate: controller.layoutRefreshController.layoutState.refreshRateByDisplay[monitor.displayId] ?? 60.0,
            isActiveWorkspace: refreshInput.isActiveWorkspace,
            isInteractionWorkspace: interactionWorkspaceId == wsId
        )
    }

    func syncAnimationRefreshRate(
        for monitor: Monitor,
        engine: NiriLayoutEngine,
        state: inout ViewportState
    ) {
        let refreshRate = controller?.layoutRefreshController.layoutState.refreshRateByDisplay[monitor.displayId] ?? 60.0
        syncAnimationRefreshRate(refreshRate, engine: engine, state: &state)
    }

    private func syncAnimationRefreshRate(
        _ refreshRate: Double,
        engine: NiriLayoutEngine,
        state: inout ViewportState
    ) {
        engine.displayRefreshRate = refreshRate
        state.displayRefreshRate = refreshRate
    }

    private func buildOnDemandLayoutPlan(
        snapshot: NiriWorkspaceSnapshot,
        engine: NiriLayoutEngine,
        monitor: Monitor,
        animationTime: TimeInterval?
    ) -> WorkspaceLayoutPlan {
        let gaps = LayoutGaps(
            horizontal: snapshot.gap,
            vertical: snapshot.gap,
            outer: snapshot.outerGaps
        )

        let area = WorkingAreaContext(
            workingFrame: snapshot.monitor.workingFrame,
            viewFrame: snapshot.monitor.frame,
            scale: snapshot.monitor.scale
        )

        let (frames, hiddenHandles) = engine.calculateCombinedLayoutUsingPools(
            in: snapshot.workspaceId,
            monitor: monitor,
            gaps: gaps,
            state: snapshot.viewportState,
            workingArea: area,
            animationTime: animationTime,
            hiddenPlacementMonitors: hiddenPlacementMonitorContexts()
        )

        let diff = layoutDiff(
            windows: snapshot.windows,
            frames: frames,
            hiddenHandles: hiddenHandles,
            confirmedFocusedToken: snapshot.confirmedFocusedToken,
            pendingFocusedToken: snapshot.pendingFocusedToken,
            pendingFocusedWorkspaceId: snapshot.pendingFocusedWorkspaceId,
            isNonManagedFocusActive: snapshot.isNonManagedFocusActive,
            workspaceId: snapshot.workspaceId,
            engine: engine,
            directBorderUpdate: true,
            isInteractionWorkspace: snapshot.isInteractionWorkspace,
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

    private func buildRelayoutPlan(
        snapshot: NiriWorkspaceSnapshot,
        engine: NiriLayoutEngine,
        monitor: Monitor
    ) -> WorkspaceLayoutPlan {
        let hasNativeFullscreenRestoreCycle = snapshot.windows.contains {
            $0.isRestoringNativeFullscreen
        }
        let motion = hasNativeFullscreenRestoreCycle
            ? .disabled
            : (controller?.motionPolicy.snapshot() ?? .enabled)
        var state = snapshot.viewportState
        let pass = NiriLayoutPass(
            wsId: snapshot.workspaceId,
            engine: engine,
            monitor: monitor,
            insetFrame: snapshot.monitor.workingFrame,
            gap: snapshot.gap
        )
        if hasNativeFullscreenRestoreCycle {
            suppressAnimationsForNativeFullscreenRestore(pass: pass, state: &state)
        }
        let restoreContexts = resolvedNativeFullscreenRestoreContexts(
            for: snapshot.windows,
            workspaceId: snapshot.workspaceId
        )
        let topologySync = syncTopology(
            pass: pass,
            motion: motion,
            state: &state,
            snapshot: snapshot
        )

        for window in snapshot.windows {
            engine.updateWindowConstraints(for: window.token, constraints: window.constraints)
        }

        applyNativeFullscreenNiriState(
            restoreContexts,
            in: engine,
            workspaceId: snapshot.workspaceId
        )

        return computeLayoutPlan(
            pass: pass,
            motion: motion,
            state: state,
            rememberedFocusToken: topologySync.rememberedFocusToken,
            newWindowToken: topologySync.newWindowToken,
            viewportNeedsRecalc: topologySync.viewportNeedsRecalc,
            topologyDidApply: topologySync.topologyDidApply,
            snapshot: snapshot,
            restoreContexts: restoreContexts,
            suppressAnimationDirectives: hasNativeFullscreenRestoreCycle
        )
    }

    private struct TopologySyncResult {
        var viewportNeedsRecalc: Bool
        var rememberedFocusToken: WindowToken?
        var newWindowToken: WindowToken?
        var topologyDidApply: Bool
    }

    private func syncTopology(
        pass: NiriLayoutPass,
        motion: MotionSnapshot,
        state: inout ViewportState,
        snapshot: NiriWorkspaceSnapshot
    ) -> TopologySyncResult {
        syncAnimationRefreshRate(snapshot.displayRefreshRate, engine: pass.engine, state: &state)
        let windowTokens = snapshot.windows.map(\.token)
        let existingHandleIds = pass.engine.root(for: pass.wsId)?.windowIdSet ?? []
        let newTokens = windowTokens.filter { !existingHandleIds.contains($0) }
        let offsetBefore = state.viewOffsetPixels.current()

        pass.engine.prepareColumnWidths(
            in: pass.wsId,
            workingAreaWidth: pass.insetFrame.width,
            gaps: pass.gap
        )

        let resetForSingleWindow = windowTokens.count == 1
            && pass.engine.effectiveSingleWindowAspectRatio(in: pass.wsId).ratio != nil
        guard let plan = pass.engine.callTopologyKernel(
            operation: .syncWindows,
            workspaceId: pass.wsId,
            state: state,
            workingFrame: pass.insetFrame,
            gaps: pass.gap,
            focusedToken: snapshot.preferredFocusToken,
            desiredTokens: windowTokens,
            removedNodeIds: snapshot.removalSeed?.removedNodeIds ?? [],
            resetForSingleWindow: resetForSingleWindow,
            motion: motion,
            isActiveWorkspace: snapshot.isActiveWorkspace,
            hasCompletedInitialRefresh: snapshot.hasCompletedInitialRefresh
        ) else {
            return TopologySyncResult(
                viewportNeedsRecalc: false,
                rememberedFocusToken: nil,
                newWindowToken: nil,
                topologyDidApply: false
            )
        }

        if plan.effectKind == .removeColumn,
           plan.result.source_column_index >= 0
        {
            var animationState = state
            _ = pass.engine.animateColumnsForRemoval(
                columnIndex: Int(plan.result.source_column_index),
                in: pass.wsId,
                motion: motion,
                state: &animationState,
                gaps: pass.gap
            )
        }

        _ = pass.engine.applyTopologyPlan(
            plan,
            in: pass.wsId,
            state: &state,
            motion: motion
        )

        pass.engine.prepareColumnWidths(
            in: pass.wsId,
            workingAreaWidth: pass.insetFrame.width,
            gaps: pass.gap
        )

        if !existingHandleIds.isEmpty,
           plan.effectKind == .addColumn,
           plan.result.target_column_index >= 0
        {
            pass.engine.animateColumnsForAddition(
                columnIndex: Int(plan.result.target_column_index),
                in: pass.wsId,
                motion: motion,
                state: state,
                gaps: pass.gap,
                workingAreaWidth: pass.insetFrame.width
            )
        }

        let selectedToken = state.selectedNodeId
            .flatMap { pass.engine.findNode(by: $0) as? NiriWindow }?
            .token
        let rememberedFocusToken: WindowToken? = if plan.result.remembered_focus_window_id != 0 {
            pass.engine.findWindow(in: plan, id: plan.result.remembered_focus_window_id)?.token
        } else {
            selectedToken
        }
        let newWindowToken: WindowToken? = if snapshot.hasCompletedInitialRefresh,
                                              snapshot.isActiveWorkspace,
                                              plan.result.new_window_id != 0
        {
            pass.engine.findWindow(in: plan, id: plan.result.new_window_id)?.token
        } else {
            nil
        }
        if let selectedId = state.selectedNodeId {
            pass.engine.updateFocusTimestamp(for: selectedId)
        }

        if snapshot.hasCompletedInitialRefresh,
           snapshot.isActiveWorkspace,
           !newTokens.isEmpty
        {
            let reduceMotionScale: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.25 : 1.0
            let appearOffset = 16.0 * reduceMotionScale

            for token in newTokens {
                guard let window = pass.engine.findNode(for: token),
                      !window.isHiddenInTabbedMode else { continue }

                if abs(appearOffset) > 0.1 {
                    window.animateMoveFrom(
                        displacement: CGPoint(x: 0, y: -appearOffset),
                        clock: pass.engine.animationClock,
                        config: pass.engine.windowMovementAnimationConfig,
                        displayRefreshRate: state.displayRefreshRate,
                        animated: motion.animationsEnabled
                    )
                }
            }
        }

        return TopologySyncResult(
            viewportNeedsRecalc: abs(state.viewOffsetPixels.current() - offsetBefore) > 1,
            rememberedFocusToken: rememberedFocusToken,
            newWindowToken: newWindowToken,
            topologyDidApply: plan.didApply
        )
    }

    private func computeLayoutPlan(
        pass: NiriLayoutPass,
        motion: MotionSnapshot,
        state: ViewportState,
        rememberedFocusToken: WindowToken?,
        newWindowToken: WindowToken?,
        viewportNeedsRecalc: Bool,
        topologyDidApply: Bool,
        snapshot: NiriWorkspaceSnapshot,
        restoreContexts: [WindowToken: NativeFullscreenRestoreContext] = [:],
        suppressAnimationDirectives: Bool = false
    ) -> WorkspaceLayoutPlan {
        let gaps = LayoutGaps(
            horizontal: pass.gap,
            vertical: pass.gap,
            outer: snapshot.outerGaps
        )

        let area = WorkingAreaContext(
            workingFrame: pass.insetFrame,
            viewFrame: snapshot.monitor.frame,
            scale: snapshot.monitor.scale
        )

        let (frames, hiddenHandles) = pass.engine.calculateCombinedLayoutUsingPools(
            in: pass.wsId,
            monitor: pass.monitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: nil,
            hiddenPlacementMonitors: hiddenPlacementMonitorContexts()
        )

        let restoreFrameOverrides = restoreContexts.compactMapValues(\.restoreFrame)
        let resolvedFrames = frames.merging(restoreFrameOverrides) { _, restoreFrame in restoreFrame }

        let hasColumnAnimations = suppressAnimationDirectives
            ? false
            : pass.engine.hasAnyColumnAnimationsRunning(in: pass.wsId)
        var directives: [AnimationDirective] = []

        if !snapshot.useScrollAnimationPath && !suppressAnimationDirectives {
            if viewportNeedsRecalc, newWindowToken == nil {
                directives.append(.startNiriScroll(workspaceId: pass.wsId))
            } else if hasColumnAnimations {
                directives.append(.startNiriScroll(workspaceId: pass.wsId))
            }
        }

        if let newWindowToken, !suppressAnimationDirectives {
            directives.append(.startNiriScroll(workspaceId: pass.wsId))
            directives.append(.activateWindow(token: newWindowToken))
        }

        if let removalSeed = snapshot.removalSeed,
           !removalSeed.oldFrames.isEmpty,
           !suppressAnimationDirectives
        {
            let newFrames = pass.engine.captureWindowFrames(in: pass.wsId)
            let animationsTriggered = pass.engine.triggerMoveAnimations(
                in: pass.wsId,
                oldFrames: removalSeed.oldFrames,
                newFrames: newFrames,
                motion: motion
            )
            let hasWindowAnimations = pass.engine.hasAnyWindowAnimationsRunning(in: pass.wsId)
            let hasColumnAnimations = pass.engine.hasAnyColumnAnimationsRunning(in: pass.wsId)
            if animationsTriggered || hasWindowAnimations || hasColumnAnimations {
                directives.append(.startNiriScroll(workspaceId: pass.wsId))
            }
        }

        let diff = layoutDiff(
            windows: snapshot.windows,
            frames: resolvedFrames,
            hiddenHandles: hiddenHandles,
            confirmedFocusedToken: snapshot.confirmedFocusedToken,
            pendingFocusedToken: snapshot.pendingFocusedToken,
            pendingFocusedWorkspaceId: snapshot.pendingFocusedWorkspaceId,
            isNonManagedFocusActive: snapshot.isNonManagedFocusActive,
            workspaceId: pass.wsId,
            engine: pass.engine,
            directBorderUpdate: snapshot.useScrollAnimationPath,
            isInteractionWorkspace: snapshot.isInteractionWorkspace,
            canRestoreHiddenWorkspaceWindows: snapshot.isActiveWorkspace,
            forceHiddenReapply: snapshot.windows.contains { $0.isRestoringNativeFullscreen }
        )

        var plan = WorkspaceLayoutPlan(
            workspaceId: pass.wsId,
            monitor: snapshot.monitor,
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: pass.wsId,
                viewportState: state,
                rememberedFocusToken: rememberedFocusToken
            ),
            diff: diff,
            animationDirectives: directives
        )
        plan.nativeFullscreenRestoreFinalizeTokens = nativeFullscreenRestoreFinalizeTokens(
            windows: snapshot.windows,
            frames: resolvedFrames
        )
        plan.managedRestoreMaterialStateChanges = managedRestoreMaterialStateChanges(
            snapshot: snapshot,
            rememberedFocusToken: rememberedFocusToken,
            viewportNeedsRecalc: viewportNeedsRecalc,
            topologyDidApply: topologyDidApply
        )
        plan.persistManagedRestoreSnapshots = false
        plan.skipFrameApplicationForAnimation = !suppressAnimationDirectives
            && snapshot.useScrollAnimationPath
            && hasScrollAnimationRunning(in: snapshot.workspaceId)
        return plan
    }

    private func managedRestoreMaterialStateChanges(
        snapshot: NiriWorkspaceSnapshot,
        rememberedFocusToken: WindowToken?,
        viewportNeedsRecalc: Bool,
        topologyDidApply: Bool
    ) -> [ManagedRestoreMaterialStateChange] {
        var changes: [ManagedRestoreMaterialStateChange] = []
        var seenTokens: Set<WindowToken> = []

        if topologyDidApply {
            for window in snapshot.windows where !window.isNativeFullscreenSuspended {
                guard seenTokens.insert(window.token).inserted else { continue }
                changes.append(
                    ManagedRestoreMaterialStateChange(
                        token: window.token,
                        reason: .topologyChanged
                    )
                )
            }
        }

        if snapshot.useScrollAnimationPath,
           viewportNeedsRecalc,
           let candidateToken = rememberedFocusToken
           ?? snapshot.pendingFocusedToken
           ?? snapshot.confirmedFocusedToken
           ?? snapshot.preferredFocusToken,
           snapshot.windows.contains(where: {
               $0.token == candidateToken && !$0.isNativeFullscreenSuspended
           }),
           seenTokens.insert(candidateToken).inserted
        {
            changes.append(
                ManagedRestoreMaterialStateChange(
                    token: candidateToken,
                    reason: .niriStateChanged
                )
            )
        }

        return changes
    }

    private func layoutDiff(
        windows: [LayoutWindowSnapshot],
        frames: [WindowToken: CGRect],
        hiddenHandles: [WindowToken: HideSide],
        confirmedFocusedToken: WindowToken?,
        pendingFocusedToken: WindowToken?,
        pendingFocusedWorkspaceId: WorkspaceDescriptor.ID?,
        isNonManagedFocusActive: Bool,
        workspaceId: WorkspaceDescriptor.ID,
        engine: NiriLayoutEngine,
        directBorderUpdate: Bool,
        isInteractionWorkspace: Bool,
        canRestoreHiddenWorkspaceWindows: Bool,
        forceHiddenReapply: Bool = false
    ) -> WorkspaceLayoutDiff {
        var diff = WorkspaceLayoutDiff()
        let suspendedTokens = Set(
            windows.lazy
                .filter(\.isNativeFullscreenSuspended)
                .map(\.token)
        )
        let effectiveBorderToken: WindowToken? = if directBorderUpdate && isInteractionWorkspace {
            if !isNonManagedFocusActive,
               pendingFocusedWorkspaceId == workspaceId,
               let pendingFocusedToken
            {
                pendingFocusedToken
            } else if let confirmedFocusedToken {
                confirmedFocusedToken
            } else {
                nil
            }
        } else {
            confirmedFocusedToken
        }

        if let effectiveBorderToken {
            let ownsFocusedToken = windows.contains {
                $0.token == effectiveBorderToken && !$0.isNativeFullscreenSuspended
            }
            diff.borderMode = ownsFocusedToken ? (directBorderUpdate ? .direct : .coordinated) : .none
        } else {
            diff.borderMode = directBorderUpdate ? .direct : .coordinated
        }

        for window in windows {
            let token = window.token
            if window.isNativeFullscreenSuspended {
                continue
            }
            let previousOffscreenSide = window.hiddenState?.offscreenSide
            if let side = hiddenHandles[token], !window.isRestoringNativeFullscreen {
                guard let hiddenFrame = frames[token] else { continue }
                let request = LayoutHideRequest(
                    token: token,
                    side: side,
                    hiddenFrame: hiddenFrame
                )
                let roundedOrigin = controller?
                    .layoutRefreshController
                    .hiddenOriginForComparison(request.hiddenFrame.origin, token: token)
                    ?? request.hiddenFrame.origin
                let lastAppliedOrigin = controller?.layoutRefreshController.lastAppliedHideOrigin(for: token)
                let shouldEmitHide = if let lastAppliedOrigin {
                    lastAppliedOrigin != roundedOrigin
                } else {
                    previousOffscreenSide != side
                }
                if forceHiddenReapply || shouldEmitHide {
                    diff.visibilityChanges.append(.hide(request))
                }
                continue
            }

            if previousOffscreenSide != nil {
                diff.visibilityChanges.append(.show(token))
            }

            if canRestoreHiddenWorkspaceWindows,
               let hiddenState = window.hiddenState,
               hiddenState.workspaceInactive
            {
                diff.restoreChanges.append(
                    .init(token: token, hiddenState: hiddenState)
                )
            }

            guard let frame = frames[token] else { continue }
            let forceApply = if let node = engine.findNode(for: token) {
                window.isRestoringNativeFullscreen || node.sizingMode == .fullscreen
            } else {
                window.isRestoringNativeFullscreen
            }
            diff.frameChanges.append(
                LayoutFrameChange(
                    token: token,
                    frame: frame,
                    forceApply: forceApply
                )
            )
        }

        if let effectiveBorderToken,
           !suspendedTokens.contains(effectiveBorderToken),
           hiddenHandles[effectiveBorderToken] == nil,
           let frame = frames[effectiveBorderToken]
        {
            diff.focusedFrame = LayoutFocusedFrame(
                token: effectiveBorderToken,
                frame: frame
            )
        } else {
            diff.focusedFrame = nil
        }

        return diff
    }

    func updateTabbedColumnOverlays() {
        guard let controller else { return }
        guard let engine = controller.niriEngine else {
            controller.tabbedOverlayManager.removeAll()
            return
        }

        var infos: [TabbedColumnOverlayInfo] = []
        for monitor in controller.workspaceManager.monitors {
            guard let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
            else { continue }

            for column in engine.columns(in: workspace.id) where column.isTabbed {
                guard let frame = column.renderedFrame ?? column.frame else { continue }
                guard TabbedColumnOverlayManager.shouldShowOverlay(
                    columnFrame: frame,
                    visibleFrame: monitor.visibleFrame
                ) else { continue }

                let windows = column.windowNodes
                guard !windows.isEmpty else { continue }

                guard let activeWindow = column.activeWindow else { continue }
                let activeWindowId = controller.workspaceManager.entry(for: activeWindow.handle)?.windowId

                infos.append(
                    TabbedColumnOverlayInfo(
                        workspaceId: workspace.id,
                        columnId: column.id,
                        columnFrame: frame,
                        tabCount: windows.count,
                        activeVisualIndex: column.activeVisualTileIdx,
                        activeWindowId: activeWindowId
                    )
                )
            }
        }

        controller.tabbedOverlayManager.updateOverlays(infos)
    }

    func selectTabInNiri(workspaceId: WorkspaceDescriptor.ID, columnId: NodeId, visualIndex: Int) {
        guard let controller, let engine = controller.niriEngine else { return }
        guard let column = engine.columns(in: workspaceId).first(where: { $0.id == columnId }) else { return }

        let windows = column.windowNodes
        guard let storageIndex = column.storageTileIndex(forVisualTileIndex: visualIndex),
              windows.indices.contains(storageIndex)
        else {
            return
        }

        column.setActiveTileIdx(storageIndex)
        engine.updateTabbedColumnVisibility(column: column)

        let target = windows[storageIndex]
        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        if let monitor = controller.workspaceManager.monitor(for: workspaceId) {
            syncAnimationRefreshRate(for: monitor, engine: engine, state: &state)
            let gap = CGFloat(controller.workspaceManager.gaps)
            engine.ensureSelectionVisible(
                node: target,
                in: workspaceId,
                motion: controller.motionPolicy.snapshot(),
                state: &state,
                workingFrame: monitor.visibleFrame,
                gaps: gap
            )
        }
        activateNode(
            target, in: workspaceId, state: &state,
            options: .init(activateWindow: false, ensureVisible: false, startAnimation: false)
        )
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: state,
                rememberedFocusToken: nil
            )
        )
        let updatedState = controller.workspaceManager.niriViewportState(for: workspaceId)
        if updatedState.viewOffsetPixels.isAnimating || engine.hasAnyWindowAnimationsRunning(in: workspaceId) {
            controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
        }
        updateTabbedColumnOverlays()
    }



    func focusNeighbor(direction: Direction) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }

        var state = controller.workspaceManager.niriViewportState(for: wsId)
        guard let currentId = state.selectedNodeId,
              let currentNode = engine.findNode(by: currentId)
        else {
            if let lastFocused = controller.workspaceManager.lastFocusedToken(in: wsId),
               let lastNode = engine.findNode(for: lastFocused)
            {
                activateNode(
                    lastNode, in: wsId, state: &state,
                    options: .init(activateWindow: false, ensureVisible: false, layoutRefresh: false, startAnimation: false)
                )
            } else if let firstToken = controller.workspaceManager.tiledEntries(in: wsId).first?.token,
                      let firstNode = engine.findNode(for: firstToken)
            {
                activateNode(
                    firstNode, in: wsId, state: &state,
                    options: .init(activateWindow: false, ensureVisible: false, layoutRefresh: false, startAnimation: false)
                )
            }
            _ = controller.workspaceManager.applySessionPatch(
                .init(
                    workspaceId: wsId,
                    viewportState: state,
                    rememberedFocusToken: nil
                )
            )
            return
        }

        guard let monitor = controller.workspaceManager.monitor(for: wsId) else { return }
        syncAnimationRefreshRate(for: monitor, engine: engine, state: &state)
        let gap = CGFloat(controller.workspaceManager.gaps)
        let workingFrame = controller.insetWorkingFrame(for: monitor)

        engine.prepareColumnWidths(
            in: wsId,
            workingAreaWidth: workingFrame.width,
            gaps: gap
        )

        if let newNode = engine.focusTarget(
            direction: direction,
            currentSelection: currentNode,
            in: wsId,
            motion: controller.motionPolicy.snapshot(),
            state: &state,
            workingFrame: workingFrame,
            gaps: gap
        ) {
            activateNode(
                newNode, in: wsId, state: &state,
                options: .init(activateWindow: false, ensureVisible: false)
            )
        }
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: wsId,
                viewportState: state,
                rememberedFocusToken: nil
            )
        )
    }

    func toggleFullscreen() {
        guard let controller else { return }
        withNiriWorkspaceContext { engine, wsId, motion, state, _, _, _ in
            guard let currentId = state.selectedNodeId,
                  let currentNode = engine.findNode(by: currentId),
                  let windowNode = currentNode as? NiriWindow
            else { return }

            engine.toggleFullscreen(windowNode, motion: motion, state: &state)

            controller.layoutRefreshController.requestImmediateRelayout(
                reason: .layoutCommand,
                affectedWorkspaceIds: [wsId]
            )
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func cycleSize(forward: Bool) {
        guard let controller else { return }
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId) as? NiriWindow,
                  let column = engine.findColumn(containing: windowNode, in: wsId)
            else { return }

            engine.toggleColumnWidth(
                column,
                forwards: forward,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
            controller.layoutRefreshController.requestImmediateRelayout(
                reason: .layoutCommand,
                affectedWorkspaceIds: [wsId]
            )
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func toggleColumnFullWidth() {
        guard let controller else { return }
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId) as? NiriWindow,
                  let column = engine.findColumn(containing: windowNode, in: wsId)
            else { return }

            engine.toggleFullWidth(
                column,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
            controller.layoutRefreshController.requestImmediateRelayout(
                reason: .layoutCommand,
                affectedWorkspaceIds: [wsId]
            )
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func balanceSizes() {
        guard let controller else { return }
        withNiriWorkspaceContext { engine, wsId, motion, _, _, workingFrame, gaps in
            engine.balanceSizes(
                in: wsId,
                motion: motion,
                workingAreaWidth: workingFrame.width,
                gaps: gaps
            )
            controller.layoutRefreshController.requestImmediateRelayout(
                reason: .layoutCommand,
                affectedWorkspaceIds: [wsId]
            )
            if engine.hasAnyColumnAnimationsRunning(in: wsId) {
                controller.layoutRefreshController.startScrollAnimation(for: wsId)
            }
        }
    }



    func enableNiriLayout(
        maxWindowsPerColumn: Int = 3,
        centerFocusedColumn: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false
    ) {
        guard let controller else { return }
        let engine = NiriLayoutEngine(maxWindowsPerColumn: maxWindowsPerColumn)
        engine.centerFocusedColumn = centerFocusedColumn
        engine.alwaysCenterSingleColumn = alwaysCenterSingleColumn
        engine.renderStyle.tabIndicatorWidth = TabbedColumnOverlayManager.tabIndicatorWidth
        engine.animationClock = controller.animationClock
        controller.niriEngine = engine

        syncMonitorsToNiriEngine()

        controller.layoutRefreshController.requestRelayout(reason: .layoutConfigChanged)
    }

    func syncMonitorsToNiriEngine() {
        guard let controller, let engine = controller.niriEngine else { return }

        let currentMonitors = controller.workspaceManager.monitors
        engine.updateMonitors(currentMonitors)

        let workspaceAssignments: [(workspaceId: WorkspaceDescriptor.ID, monitor: Monitor)] =
            controller.workspaceManager.workspaces.compactMap { workspace in
                guard let monitor = controller.workspaceManager.monitor(for: workspace.id) else { return nil }
                return (workspaceId: workspace.id, monitor: monitor)
        }
        engine.syncWorkspaceAssignments(workspaceAssignments)

        refreshResolvedMonitorSettings()
    }

    func refreshResolvedMonitorSettings() {
        guard let controller, let engine = controller.niriEngine else { return }

        for monitor in controller.workspaceManager.monitors {
            let resolved = controller.settings.resolvedNiriSettings(for: monitor)
            engine.updateMonitorSettings(resolved, for: monitor.id)
        }
    }

    func updateNiriConfig(
        maxWindowsPerColumn: Int? = nil,
        maxVisibleColumns: Int? = nil,
        infiniteLoop: Bool? = nil,
        centerFocusedColumn: CenterFocusedColumn? = nil,
        alwaysCenterSingleColumn: Bool? = nil,
        singleWindowAspectRatio: SingleWindowAspectRatio? = nil,
        columnWidthPresets: [Double]? = nil,
        defaultColumnWidth: Double?? = nil
    ) {
        guard let controller else { return }
        controller.niriEngine?.updateConfiguration(
            maxWindowsPerColumn: maxWindowsPerColumn,
            maxVisibleColumns: maxVisibleColumns,
            infiniteLoop: infiniteLoop,
            centerFocusedColumn: centerFocusedColumn,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            singleWindowAspectRatio: singleWindowAspectRatio,
            presetColumnWidths: columnWidthPresets?.map { .proportion($0) },
            defaultColumnWidth: defaultColumnWidth.map { $0.map { CGFloat($0) } }
        )
        refreshResolvedMonitorSettings()
        controller.layoutRefreshController.requestRelayout(reason: .layoutConfigChanged)
    }



    func activateNode(
        _ node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        options: NodeActivationOptions = NodeActivationOptions()
    ) {
        guard let controller, let engine = controller.niriEngine else { return }

        state.selectedNodeId = node.id

        if options.activateWindow {
            engine.activateWindow(node.id)
        }

        if options.ensureVisible, let monitor = controller.workspaceManager.monitor(for: workspaceId) {
            syncAnimationRefreshRate(for: monitor, engine: engine, state: &state)
            let gap = CGFloat(controller.workspaceManager.gaps)
            let workingFrame = controller.insetWorkingFrame(for: monitor)
            engine.ensureSelectionVisible(
                node: node,
                in: workspaceId,
                motion: controller.motionPolicy.snapshot(),
                state: &state,
                workingFrame: workingFrame,
                gaps: gap
            )
        }

        let focusedToken = (node as? NiriWindow)?.token
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: node.id,
            focusedToken: focusedToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        if let windowNode = node as? NiriWindow {
            if options.updateTimestamp {
                engine.updateFocusTimestamp(for: windowNode.id)
            }
            if !options.layoutRefresh {
                controller.recordManagedRestoreGeometryIfMaterialStateChanged(
                    for: CGWindowID(windowNode.token.windowId),
                    reason: .niriStateChanged
                )
            }
        }

        if options.layoutRefresh {
            let focusToken = options.axFocus ? (node as? NiriWindow)?.token : nil
            let materialStateWindowId = (node as? NiriWindow)?.token.windowId
            if let focusToken {
                _ = controller.workspaceManager.beginManagedFocusRequest(
                    focusToken,
                    in: workspaceId,
                    onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
                )
            }
            controller.layoutRefreshController.requestImmediateRelayout(
                reason: .layoutCommand,
                affectedWorkspaceIds: [workspaceId]
            ) { [weak controller] in
                if let materialStateWindowId {
                    controller?.recordManagedRestoreGeometryIfMaterialStateChanged(
                        for: CGWindowID(materialStateWindowId),
                        reason: .niriStateChanged
                    )
                }
                if let focusToken {
                    controller?.focusWindow(focusToken)
                }
            }
            if options.startAnimation, state.viewOffsetPixels.isAnimating {
                controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
            }
        } else {
            if options.axFocus, let windowNode = node as? NiriWindow {
                controller.focusWindow(windowNode.token)
            }
            if options.startAnimation, state.viewOffsetPixels.isAnimating {
                controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
            }
        }
    }

    func withNiriOperationContext(
        perform operation: (NiriOperationContext, inout ViewportState) -> Bool
    ) {
        guard let controller else { return }
        var animatingWorkspaceId: WorkspaceDescriptor.ID?

        guard let engine = controller.niriEngine else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }

        controller.workspaceManager.withNiriViewportState(for: wsId) { state in
            guard let currentId = state.selectedNodeId,
                  let currentNode = engine.findNode(by: currentId),
                  let windowNode = currentNode as? NiriWindow
            else { return }

            guard let monitor = controller.workspaceManager.monitor(for: wsId) else { return }
            syncAnimationRefreshRate(for: monitor, engine: engine, state: &state)
            let workingFrame = controller.insetWorkingFrame(for: monitor)
            let gaps = CGFloat(controller.workspaceManager.gaps)

            let ctx = NiriOperationContext(
                controller: controller,
                engine: engine,
                motion: controller.motionPolicy.snapshot(),
                wsId: wsId,
                windowNode: windowNode,
                monitor: monitor,
                workingFrame: workingFrame,
                gaps: gaps
            )

            if operation(ctx, &state) {
                animatingWorkspaceId = wsId
            }
        }

        if let wsId = animatingWorkspaceId {
            controller.layoutRefreshController.startScrollAnimation(for: wsId)
        }
    }

    func withNiriWorkspaceContext(
        perform: (NiriLayoutEngine, WorkspaceDescriptor.ID, MotionSnapshot, inout ViewportState, Monitor, CGRect, CGFloat) -> Void
    ) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }
        guard let monitor = controller.workspaceManager.monitor(for: wsId) else { return }
        let motion = controller.motionPolicy.snapshot()
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let gaps = CGFloat(controller.workspaceManager.gaps)
        controller.workspaceManager.withNiriViewportState(for: wsId) { state in
            syncAnimationRefreshRate(for: monitor, engine: engine, state: &state)
            perform(engine, wsId, motion, &state, monitor, workingFrame, gaps)
        }
    }

    func withNiriWorkspaceContext(
        for workspaceId: WorkspaceDescriptor.ID,
        perform: (NiriLayoutEngine, WorkspaceDescriptor.ID, MotionSnapshot, inout ViewportState, Monitor, CGRect, CGFloat) -> Void
    ) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }
        guard let monitor = controller.workspaceManager.monitor(for: workspaceId) else { return }
        let motion = controller.motionPolicy.snapshot()
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let gaps = CGFloat(controller.workspaceManager.gaps)
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            syncAnimationRefreshRate(for: monitor, engine: engine, state: &state)
            perform(engine, workspaceId, motion, &state, monitor, workingFrame, gaps)
        }
    }

    @discardableResult
    func insertWindow(
        handle: WindowHandle,
        targetHandle: WindowHandle,
        position: InsertPosition,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        var didMove = false
        withNiriWorkspaceContext(for: workspaceId) { engine, wsId, motion, state, monitor, workingFrame, gaps in
            guard let source = engine.findNode(for: handle) else { return }
            guard let target = engine.findNode(for: targetHandle) else { return }
            didMove = engine.insertWindowByMove(
                sourceWindowId: source.id,
                targetWindowId: target.id,
                position: position,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }
        return didMove
    }

    @discardableResult
    func insertWindowInNewColumn(
        handle: WindowHandle,
        insertIndex: Int,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        var didMove = false
        withNiriWorkspaceContext(for: workspaceId) { engine, wsId, motion, state, monitor, workingFrame, gaps in
            guard let window = engine.findNode(for: handle) else { return }
            didMove = engine.insertWindowInNewColumn(
                window,
                insertIndex: insertIndex,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }
        return didMove
    }
}

private extension NiriLayoutHandler {
    func suppressAnimationsForNativeFullscreenRestore(
        pass: NiriLayoutPass,
        state: inout ViewportState
    ) {
        if let controller {
            let displayIds = scrollAnimationByDisplay.compactMap { displayId, workspaceId in
                workspaceId == pass.wsId ? displayId : nil
            }
            for displayId in displayIds {
                controller.layoutRefreshController.stopScrollAnimation(for: displayId)
            }
        }

        state.cancelAnimation()

        for column in pass.engine.columns(in: pass.wsId) {
            column.moveAnimation = nil
            column.widthAnimation = nil
            column.targetWidth = nil
        }

        if let root = pass.engine.root(for: pass.wsId) {
            for window in root.allWindows {
                window.stopMoveAnimations()
            }
        }
    }

    func resolvedNativeFullscreenRestoreContexts(
        for windows: [LayoutWindowSnapshot],
        workspaceId: WorkspaceDescriptor.ID
    ) -> [WindowToken: NativeFullscreenRestoreContext] {
        guard let topologyProfile = controller?.workspaceManager.topologyProfile else { return [:] }

        var restoreContexts: [WindowToken: NativeFullscreenRestoreContext] = [:]
        for window in windows {
            guard let restoreContext = window.nativeFullscreenRestore,
                  restoreContext.currentToken == window.token,
                  restoreContext.workspaceId == workspaceId,
                  restoreContext.capturedTopologyProfile == topologyProfile,
                  restoreContext.restoreFrame != nil
            else {
                continue
            }
            restoreContexts[window.token] = restoreContext
        }
        return restoreContexts
    }

    func applyNativeFullscreenNiriState(
        _ restoreContexts: [WindowToken: NativeFullscreenRestoreContext],
        in engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        for (token, restoreContext) in restoreContexts {
            applyNativeFullscreenNiriState(
                restoreContext.niriState,
                for: token,
                in: engine,
                workspaceId: workspaceId
            )
        }
    }

    func applyNativeFullscreenNiriState(
        _ niriState: ManagedWindowRestoreSnapshot.NiriState?,
        for token: WindowToken,
        in engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let niriState else {
            return
        }
        guard let window = engine.findNode(for: token) else {
            return
        }

        reconcileNativeFullscreenColumn(
            restoringWindow: window,
            niriState: niriState,
            in: engine,
            workspaceId: workspaceId
        )

        let currentColumn = engine.column(of: window)
        if let column = currentColumn {
            let sizing = niriState.columnSizing
            column.widthAnimation = nil
            column.targetWidth = nil
            column.width = sizing.width
            column.cachedWidth = sizing.cachedWidth
            column.presetWidthIdx = sizing.presetWidthIdx
            column.isFullWidth = sizing.isFullWidth
            column.savedWidth = sizing.savedWidth
            column.hasManualSingleWindowWidthOverride = sizing.hasManualSingleWindowWidthOverride
            column.height = sizing.height
            column.cachedHeight = sizing.cachedHeight
            column.isFullHeight = sizing.isFullHeight
            column.savedHeight = sizing.savedHeight
        }

        let sizing = niriState.windowSizing
        window.height = sizing.height
        window.savedHeight = sizing.savedHeight
        window.windowWidth = sizing.windowWidth
        window.sizingMode = sizing.sizingMode
        window.resolvedHeight = nil
        window.resolvedWidth = nil
        window.stopMoveAnimations()
    }

    /// Native fullscreen exits often leave the restoring window in a fresh single-window
    /// column because the macOS space transition removes it from the Niri tree and topology
    /// sync re-adds it as a new column. If the captured `niriState` says the window shared a
    /// column with one or more siblings, re-attach it to the column that currently hosts those
    /// siblings so alt-left/right and visibility match the pre-fullscreen state.
    private func reconcileNativeFullscreenColumn(
        restoringWindow window: NiriWindow,
        niriState: ManagedWindowRestoreSnapshot.NiriState,
        in engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        let storedMembers = niriState.columnWindowTokens
        guard storedMembers.count > 1 else { return }
        guard let currentColumn = engine.column(of: window) else { return }
        let token = window.token
        guard let currentRoot = currentColumn.findRoot(),
              currentRoot.workspaceId == workspaceId
        else { return }

        let siblingTokens = storedMembers.filter { $0 != token }
        var sameWorkspaceColumns: [ObjectIdentifier: NiriContainer] = [:]
        var hasForeignSibling = false
        for siblingToken in siblingTokens {
            guard let siblingNode = engine.findNode(for: siblingToken),
                  let siblingColumn = engine.column(of: siblingNode)
            else {
                continue
            }
            guard siblingColumn.findRoot()?.workspaceId == workspaceId else {
                hasForeignSibling = true
                continue
            }
            sameWorkspaceColumns[ObjectIdentifier(siblingColumn)] = siblingColumn
        }

        guard !hasForeignSibling else { return }
        guard !sameWorkspaceColumns.isEmpty else { return }

        guard sameWorkspaceColumns.count == 1,
              let targetColumn = sameWorkspaceColumns.values.first
        else { return }

        guard targetColumn !== currentColumn else {
            return
        }

        let storedIndex = niriState.tileIndex
            ?? storedMembers.firstIndex(of: token)
            ?? targetColumn.children.count
        let insertIndex = max(0, min(storedIndex, targetColumn.children.count))

        window.detach()
        targetColumn.insertChild(window, at: insertIndex)

        if currentColumn.children.isEmpty, currentColumn !== targetColumn {
            currentColumn.remove()
            if let root = engine.root(for: currentRoot.workspaceId), root.columns.isEmpty {
                root.appendChild(NiriContainer())
            }
        }
    }

    func nativeFullscreenRestoreFinalizeTokens(
        windows: [LayoutWindowSnapshot],
        frames _: [WindowToken: CGRect]
    ) -> [WindowToken] {
        return windows.compactMap { window in
            guard window.isRestoringNativeFullscreen,
                  window.restoreFrame != nil
            else {
                return nil
            }
            return window.token
        }
    }
}

struct NodeActivationOptions {
    var activateWindow: Bool = true
    var ensureVisible: Bool = true
    var updateTimestamp: Bool = true
    var layoutRefresh: Bool = true
    var axFocus: Bool = true
    var startAnimation: Bool = true
}

@MainActor struct NiriOperationContext {
    let controller: WMController
    let engine: NiriLayoutEngine
    let motion: MotionSnapshot
    let wsId: WorkspaceDescriptor.ID
    let windowNode: NiriWindow
    let monitor: Monitor
    let workingFrame: CGRect
    let gaps: CGFloat

    private func hasPendingAnimationWork(state: ViewportState) -> Bool {
        hasPendingNiriAnimationWork(state: state, engine: engine, workspaceId: wsId)
    }

    func commitWithPredictedAnimation(
        state: ViewportState,
        oldFrames: [WindowToken: CGRect]
    ) -> Bool {
        let scale = controller.layoutRefreshController.backingScale(for: monitor)
        let workingArea = WorkingAreaContext(
            workingFrame: workingFrame,
            viewFrame: monitor.frame,
            scale: scale
        )
        let layoutGaps = LayoutGaps(
            horizontal: gaps,
            vertical: gaps,
            outer: controller.workspaceManager.outerGaps
        )
        let animationTime = (engine.animationClock?.now() ?? CACurrentMediaTime()) + 2.0
        let newFrames = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: layoutGaps,
            state: state,
            workingArea: workingArea,
            animationTime: animationTime,
            hiddenPlacementMonitors: Monitor.sortedByPosition(controller.workspaceManager.monitors)
                .map(HiddenPlacementMonitorContext.init)
        ).frames
        _ = engine.triggerMoveAnimations(
            in: wsId,
            oldFrames: oldFrames,
            newFrames: newFrames,
            motion: motion
        )
        controller.layoutRefreshController.requestImmediateRelayout(
            reason: .layoutCommand,
            affectedWorkspaceIds: [wsId]
        )
        return hasPendingAnimationWork(state: state)
    }

    func commitWithCapturedAnimation(
        state: ViewportState,
        oldFrames: [WindowToken: CGRect]
    ) -> Bool {
        controller.layoutRefreshController.requestImmediateRelayout(
            reason: .layoutCommand,
            affectedWorkspaceIds: [wsId]
        )
        let newFrames = engine.captureWindowFrames(in: wsId)
        _ = engine.triggerMoveAnimations(
            in: wsId,
            oldFrames: oldFrames,
            newFrames: newFrames,
            motion: motion
        )
        return hasPendingAnimationWork(state: state)
    }

    func commitSimple(state: ViewportState) -> Bool {
        controller.layoutRefreshController.requestImmediateRelayout(
            reason: .layoutCommand,
            affectedWorkspaceIds: [wsId]
        )
        return hasPendingAnimationWork(state: state)
    }
}

extension NiriLayoutHandler: LayoutFocusable, LayoutSizable {}

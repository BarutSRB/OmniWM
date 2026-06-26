// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

@MainActor private func hasPendingNiriAnimationWork(
    state: ViewportState,
    driver: AnimationDriver,
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID
) -> Bool {
    state.hasPendingOffsetAnimation
        || driver.hasMotion(in: workspaceId)
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

    struct RemovalContext {
        var existingHandleIds: Set<WindowToken>
        var wasEmptyBeforeSync: Bool
        var removalResult: NiriLayoutEngine.NiriRemovalResult
    }

    private struct InsertionContext {
        var newTokens: [WindowToken]
        var tabLocalTokens: Set<WindowToken>
        var viewOriginBeforeInsertion: CGFloat?
    }

    private struct ArrivalContext {
        var activateWindowToken: WindowToken?
        var rememberedFocusToken: WindowToken?
        var hasNewWindowArrival: Bool
        var shouldStartScrollForNewWindow: Bool
    }

    var scrollAnimationByDisplay: [CGDirectDisplayID: WorkspaceDescriptor.ID] = [:]

    init(controller: WMController?) {
        self.controller = controller
    }

    private func startScrollAnimationIfNeeded(
        for workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        engine: NiriLayoutEngine
    ) {
        guard let controller else { return }
        guard hasPendingNiriAnimationWork(
            state: state,
            driver: controller.workspaceManager.animationDriver,
            engine: engine,
            workspaceId: workspaceId
        ) else {
            return
        }
        controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
    }

    func registerScrollAnimation(_ workspaceId: WorkspaceDescriptor.ID, on displayId: CGDirectDisplayID) -> Bool {
        if scrollAnimationByDisplay[displayId] == workspaceId {
            return false
        }
        scrollAnimationByDisplay[displayId] = workspaceId
        return true
    }

    func hasScrollAnimation(for workspaceId: WorkspaceDescriptor.ID) -> Bool {
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

        let scrollTrace = ScrollTickTrace.shared.isActive
        let animsStart = scrollTrace ? CACurrentMediaTime() : 0
        let windowAnimationsRunning = engine.tickAllWindowAnimations(in: wsId, at: targetTime)
        let columnAnimationsRunning = engine.tickAllColumnAnimations(in: wsId, at: targetTime)
        let viewportMotionRunning = controller.workspaceManager.animationDriver.tick(in: wsId, at: targetTime)
        let animsMs = scrollTrace ? (CACurrentMediaTime() - animsStart) * 1000 : 0
        let state = controller.workspaceManager.niriViewportState(for: wsId)

        let didApplyFrames = applyFramesOnDemand(
            wsId: wsId,
            state: state,
            engine: engine,
            monitor: monitor,
            animationTime: targetTime,
            animsMs: animsMs
        )
        guard didApplyFrames else {
            controller.layoutRefreshController.requestRelayout(
                reason: .staleLayoutPlan,
                affectedWorkspaceIds: [wsId]
            )
            return
        }
        let animationsOngoing = viewportMotionRunning
            || windowAnimationsRunning
            || columnAnimationsRunning

        if !animationsOngoing {
            applyFramesOnDemand(
                wsId: wsId,
                state: controller.workspaceManager.niriViewportState(for: wsId),
                engine: engine,
                monitor: monitor
            )
            finalizeAnimation()
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

    @discardableResult
    func applyFramesOnDemand(
        wsId: WorkspaceDescriptor.ID,
        state: ViewportState,
        engine: NiriLayoutEngine,
        monitor: Monitor,
        animationTime: TimeInterval? = nil,
        animsMs: Double = 0
    ) -> Bool {
        guard let controller,
              let activeWorkspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            return false
        }

        let trace = ScrollTickTrace.shared.isActive && animationTime != nil
        let snapshotStart = trace ? CACurrentMediaTime() : 0
        guard let snapshot = makeWorkspaceSnapshot(
            workspaceId: wsId,
            monitor: monitor,
            viewportState: state,
            useScrollAnimationPath: true,
            removalSeed: nil,
            isActiveWorkspace: activeWorkspaceId == wsId
        ) else {
            return false
        }
        let snapshotMs = trace ? (CACurrentMediaTime() - snapshotStart) * 1000 : 0

        let buildStart = CACurrentMediaTime()
        let plan = buildOnDemandLayoutPlan(
            snapshot: snapshot,
            engine: engine,
            monitor: monitor,
            animationTime: animationTime
        )
        let buildSeconds = CACurrentMediaTime() - buildStart
        controller.layoutRefreshController.recordScrollBuild(
            seconds: buildSeconds,
            workspaceCount: 1,
            windowCount: controller.workspaceManager.entries(in: wsId).count
        )

        let commitStart = trace ? CACurrentMediaTime() : 0
        let applied = controller.layoutRefreshController.executeLayoutPlan(plan)
        if trace {
            recordScrollTickBreakdown(
                plan: plan,
                monitor: monitor,
                windowCount: snapshot.windows.count,
                spans: ScrollTickSpans(
                    anims: animsMs,
                    snapshot: snapshotMs,
                    build: buildSeconds * 1000,
                    commit: (CACurrentMediaTime() - commitStart) * 1000
                )
            )
        }
        return applied
    }

    private struct ScrollTickSpans {
        let anims: Double
        let snapshot: Double
        let build: Double
        let commit: Double
    }

    private func recordScrollTickBreakdown(
        plan: WorkspaceLayoutPlan,
        monitor: Monitor,
        windowCount: Int,
        spans: ScrollTickSpans
    ) {
        var show = 0
        var hide = 0
        for change in plan.diff.visibilityChanges {
            switch change {
            case .show: show += 1
            case .hide: hide += 1
            }
        }
        ScrollTickTrace.shared.record(
            ScrollTickTrace.Record(
                mediaTime: CACurrentMediaTime(),
                displayId: monitor.displayId,
                animsMs: spans.anims,
                snapshotMs: spans.snapshot,
                buildMs: spans.build,
                commitMs: spans.commit,
                totalMs: spans.anims + spans.snapshot + spans.build + spans.commit,
                show: show,
                hide: hide,
                frames: plan.diff.frameChanges.count,
                windowCount: windowCount,
                isAnimationTick: true
            )
        )
    }

    private func finalizeAnimation() {
        guard let controller else { return }

        controller.surfaceReconciler.noteRestackOccurred()

        if controller.moveMouseToFocusedWindowEnabled,
           controller.workspaceManager.pendingFocusedToken == nil,
           let token = controller.workspaceManager.focusedToken,
           controller.intentLedger.allowsMouseToFocusedWarp(for: token)
        {
            controller.moveMouseToWindow(token, preferredFrame: controller.preferredKeyboardFocusFrame(for: token))
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

    private func requestLayoutCommandRelayout(
        in workspaceId: WorkspaceDescriptor.ID,
        postLayout: LayoutRefreshController.PostLayoutAction? = nil
    ) {
        controller?.layoutRefreshController.requestLayoutCommandRelayout(
            affectedWorkspaceIds: [workspaceId],
            postLayout: postLayout,
            postLayoutDomains: .layoutCommit
        )
    }

    private func recordLayoutOperation(
        _ operation: LayoutOperation,
        in workspaceId: WorkspaceDescriptor.ID,
        source: WMEventSource = .command
    ) {
        controller?.workspaceManager.recordLayoutOperation(operation, in: workspaceId, source: source)
    }

    func focusSelectedWindowAndRequestRelayout(in workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        let viewportState = controller.workspaceManager.niriViewportState(for: workspaceId)
        if let selectedNodeId = viewportState.selectedNodeId,
           let selectedWindow = controller.niriEngine?.findNode(by: selectedNodeId) as? NiriWindow,
           controller.workspaceManager.entry(for: selectedWindow.token)?.workspaceId == workspaceId
        {
            controller.focusWindow(selectedWindow.token)
        }
        requestLayoutCommandRelayout(in: workspaceId)
    }

    func layoutWithNiriEngine(
        activeWorkspaces: Set<WorkspaceDescriptor.ID>,
        useScrollAnimationPath: Bool = false,
        removalSeeds: [WorkspaceDescriptor.ID: NiriWindowRemovalSeed] = [:]
    ) -> [WorkspaceLayoutPlan] {
        guard let controller, let engine = controller.niriEngine else { return [] }
        var plans: [WorkspaceLayoutPlan] = []
        let workspaceIds = activeWorkspaces.sorted(by: { $0.uuidString < $1.uuidString })
        for wsId in workspaceIds {
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
        }

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

        return NiriWorkspaceSnapshot(
            workspaceId: wsId,
            monitor: refreshInput.monitor,
            windows: refreshInput.windows,
            viewportState: effectiveViewportState,
            preferredFocusToken: controller.workspaceManager.preferredFocusToken(in: wsId),
            hasCompletedInitialRefresh: controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh,
            useScrollAnimationPath: useScrollAnimationPath,
            removalSeed: removalSeed,
            gap: CGFloat(controller.workspaceManager.gaps),
            outerGaps: controller.workspaceManager.outerGaps,
            displayRefreshRate: controller.layoutRefreshController.layoutState
                .refreshRateByDisplay[monitor.displayId] ?? 60.0,
            isActiveWorkspace: refreshInput.isActiveWorkspace
        )
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
            fullscreenLayoutFrame: snapshot.monitor.fullscreenLayoutFrame,
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
            viewOffsetOverride: controller?.workspaceManager.animationDriver.liveViewOffset(
                in: snapshot.workspaceId,
                semanticOffset: snapshot.viewportState.viewOffset,
                at: animationTime ?? CACurrentMediaTime()
            )
        )

        let diff = layoutDiff(
            windows: snapshot.windows,
            frames: frames,
            hiddenHandles: hiddenHandles,
            engine: engine,
            canRestoreHiddenWorkspaceWindows: snapshot.isActiveWorkspace
        )

        return WorkspaceLayoutPlan(
            workspaceId: snapshot.workspaceId,
            monitor: snapshot.monitor,
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: snapshot.workspaceId,
                viewportState: nil
            ),
            diff: diff,
            isAnimationTick: animationTime != nil
        )
    }

    private func buildRelayoutPlan(
        snapshot: NiriWorkspaceSnapshot,
        engine: NiriLayoutEngine,
        monitor: Monitor
    ) -> WorkspaceLayoutPlan {
        let motion = controller?.motionPolicy.snapshot() ?? .enabled
        var state = snapshot.viewportState
        let pass = NiriLayoutPass(
            wsId: snapshot.workspaceId,
            engine: engine,
            monitor: monitor,
            insetFrame: snapshot.monitor.workingFrame,
            gap: snapshot.gap
        )
        let windowTokens = snapshot.windows.map(\.token)
        let currentSelection = state.selectedNodeId

        let removal = processWindowRemovals(
            pass: pass,
            motion: motion,
            state: &state,
            windowTokens: windowTokens,
            currentSelection: currentSelection,
            removedNodeIds: snapshot.removalSeed?.removedNodeIds ?? []
        )

        let viewOriginBeforeInsertion = currentViewOrigin(pass: pass, state: state)

        restoreInitialNiriPlacementsIfNeeded(pass: pass, windowTokens: windowTokens)

        let insertion = syncAndInsert(
            pass: pass,
            motion: motion,
            state: &state,
            windowTokens: windowTokens,
            removal: removal,
            preferredFocusToken: snapshot.preferredFocusToken,
            viewOriginBeforeInsertion: viewOriginBeforeInsertion
        )

        for window in snapshot.windows {
            engine.updateWindowConstraints(for: window.token, constraints: window.layoutConstraints)
        }

        let selection = resolveSelection(
            pass: pass,
            motion: motion,
            state: &state,
            windowTokens: windowTokens,
            removal: removal,
            snapshot: snapshot
        )

        let arrival = handleNewWindowArrival(
            pass: pass,
            motion: motion,
            state: &state,
            insertion: insertion,
            existingHandleIds: removal.existingHandleIds,
            snapshot: snapshot
        )

        var plan = computeLayoutPlan(
            pass: pass,
            motion: motion,
            state: state,
            rememberedFocusToken: arrival.rememberedFocusToken ?? selection.rememberedFocusToken,
            activateWindowToken: arrival.activateWindowToken,
            hasNewWindowArrival: arrival.hasNewWindowArrival,
            shouldStartScrollForNewWindow: arrival.shouldStartScrollForNewWindow,
            viewportNeedsRecalc: selection.viewportNeedsRecalc,
            snapshot: snapshot
        )
        plan.niriRestorePlacements = pass.engine.persistedPlacements(in: pass.wsId)

        return plan
    }

    private func restoreInitialNiriPlacementsIfNeeded(
        pass: NiriLayoutPass,
        windowTokens: [WindowToken]
    ) {
        guard let controller else { return }

        var placements: [WindowToken: PersistedNiriPlacement] = [:]
        placements.reserveCapacity(windowTokens.count)

        for token in windowTokens {
            if let placement = controller.workspaceManager.restoreIntent(for: token)?.niriPlacement {
                placements[token] = placement
            }
        }

        pass.engine.restoreInitialPlacements(placements, matching: windowTokens, in: pass.wsId)
    }

    private func processWindowRemovals(
        pass: NiriLayoutPass,
        motion: MotionSnapshot,
        state: inout ViewportState,
        windowTokens: [WindowToken],
        currentSelection: NodeId?,
        removedNodeIds: [NodeId]
    ) -> RemovalContext {
        let existingHandleIds = pass.engine.root(for: pass.wsId)?.windowIdSet ?? []
        let removedHandleIds = existingHandleIds.subtracting(Set(windowTokens))
        let wasEmptyBeforeSync = pass.engine.columns(in: pass.wsId).isEmpty

        let removalResult = pass.engine.removeWindows(
            removedHandleIds,
            in: pass.wsId,
            state: &state,
            motion: motion,
            workingFrame: pass.insetFrame,
            gaps: pass.gap,
            selectedNodeId: currentSelection,
            removedNodeIds: removedNodeIds
        )

        return RemovalContext(
            existingHandleIds: existingHandleIds,
            wasEmptyBeforeSync: wasEmptyBeforeSync,
            removalResult: removalResult
        )
    }

    private func syncAndInsert(
        pass: NiriLayoutPass,
        motion: MotionSnapshot,
        state: inout ViewportState,
        windowTokens: [WindowToken],
        removal: RemovalContext,
        preferredFocusToken: WindowToken?,
        viewOriginBeforeInsertion: CGFloat?
    ) -> InsertionContext {
        let currentSelection = state.selectedNodeId
        _ = pass.engine.syncWindows(
            windowTokens,
            in: pass.wsId,
            selectedNodeId: currentSelection,
            focusedToken: preferredFocusToken
        )
        let newTokens = windowTokens.filter { !removal.existingHandleIds.contains($0) }
        var tabLocalTokens = Set<WindowToken>()

        let columns = pass.engine.columns(in: pass.wsId)
        resolveColumnWidthsIfNeeded(pass: pass)

        if !removal.wasEmptyBeforeSync, !newTokens.isEmpty {
            let newTokenSet = Set(newTokens)
            let preexistingSurvivingTokens = Set(windowTokens).intersection(removal.existingHandleIds)
            var newColumnData: [(col: NiriContainer, colIdx: Int)] = []

            for (colIdx, col) in columns.enumerated() {
                var columnNewTokens: [WindowToken] = []
                var hasPreexistingToken = false
                for window in col.windowNodes {
                    if newTokenSet.contains(window.token) {
                        columnNewTokens.append(window.token)
                    }
                    if preexistingSurvivingTokens.contains(window.token) {
                        hasPreexistingToken = true
                    }
                }
                guard !columnNewTokens.isEmpty else { continue }

                if hasPreexistingToken {
                    if col.displayMode == .tabbed {
                        tabLocalTokens.formUnion(columnNewTokens)
                    }
                } else {
                    newColumnData.append((col, colIdx))
                }
            }

            let originalActiveIdx = state.activeColumnIndex
            let insertedBeforeActive = newColumnData.filter { $0.colIdx <= originalActiveIdx }
            if !insertedBeforeActive.isEmpty, removal.removalResult.removedColumnIndicesBefore.isEmpty {
                let totalInsertedWidth = insertedBeforeActive.reduce(CGFloat(0)) { total, data in
                    total + data.col.cachedWidth + pass.gap
                }
                state.rebaseOffset(by: -totalInsertedWidth)
                state.activeColumnIndex = originalActiveIdx + insertedBeforeActive.count
            }

            let sortedNewColumns = newColumnData.sorted { $0.colIdx < $1.colIdx }
            for addedData in sortedNewColumns {
                pass.engine.animateColumnsForAddition(
                    columnIndex: addedData.colIdx,
                    in: pass.wsId,
                    motion: motion,
                    state: state,
                    gaps: pass.gap,
                    workingAreaWidth: pass.insetFrame.width
                )
            }
        }

        return InsertionContext(
            newTokens: newTokens,
            tabLocalTokens: tabLocalTokens,
            viewOriginBeforeInsertion: viewOriginBeforeInsertion
        )
    }

    private func resolveSelection(
        pass: NiriLayoutPass,
        motion: MotionSnapshot,
        state: inout ViewportState,
        windowTokens: [WindowToken],
        removal: RemovalContext,
        snapshot: NiriWorkspaceSnapshot
    ) -> (viewportNeedsRecalc: Bool, rememberedFocusToken: WindowToken?) {
        state.displayRefreshRate = snapshot.displayRefreshRate

        if let finalSelectionId = removal.removalResult.finalSelectionId {
            state.selectedNodeId = finalSelectionId
        } else if let selectedId = state.selectedNodeId,
                  pass.engine.findNode(by: selectedId) == nil
        {
            state.selectedNodeId = pass.engine.validateSelection(selectedId, in: pass.wsId)
        }

        if state.selectedNodeId == nil {
            if let firstToken = windowTokens.first,
               let firstNode = pass.engine.findNode(for: firstToken)
            {
                state.selectedNodeId = firstNode.id
            }
        }

        let usesSingleWindowFit = pass.engine.singleWindowLayoutContext(in: pass.wsId) != nil
        if usesSingleWindowFit {
            resetViewportForSingleWindowFit(state: &state)
        }

        let offsetBefore = state.viewOffset
        let rebaseDeltaBefore = state.offsetTransition.rebaseDelta
        var viewportNeedsRecalc = removal.removalResult.viewportNeedsRecalc

        let isGestureOrAnimation = controller?.workspaceManager.animationDriver.hasMotion(in: pass.wsId) == true

        resolveColumnWidthsIfNeeded(pass: pass)

        if !usesSingleWindowFit,
           !isGestureOrAnimation,
           snapshot.isActiveWorkspace,
           let selectedId = state.selectedNodeId,
           let selectedNode = pass.engine.findNode(by: selectedId),
           !removal.removalResult.visibilityWasCorrected,
           removal.removalResult.removedTokens.isEmpty || removal.removalResult.fromIndexForVisibility != nil
        {
            pass.engine.ensureSelectionVisible(
                node: selectedNode,
                in: pass.wsId,
                motion: motion,
                state: &state,
                workingFrame: pass.insetFrame,
                gaps: pass.gap,
                fromContainerIndex: removal.removalResult.fromIndexForVisibility
            )
            let liveOffsetDelta = state.hasPendingOffsetAnimation
                ? state.offsetTransition.rebaseDelta - rebaseDeltaBefore
                : state.viewOffset - offsetBefore
            if abs(liveOffsetDelta) > 1 {
                viewportNeedsRecalc = true
            }
        }

        let rememberedFocusToken: WindowToken?
        if let selectedId = state.selectedNodeId,
           let selectedNode = pass.engine.findNode(by: selectedId) as? NiriWindow
        {
            rememberedFocusToken = selectedNode.token
        } else {
            rememberedFocusToken = nil
        }

        return (viewportNeedsRecalc, rememberedFocusToken)
    }

    private func handleNewWindowArrival(
        pass: NiriLayoutPass,
        motion: MotionSnapshot,
        state: inout ViewportState,
        insertion: InsertionContext,
        existingHandleIds: Set<WindowToken>,
        snapshot: NiriWorkspaceSnapshot
    ) -> ArrivalContext {
        let wasEmpty = existingHandleIds.isEmpty
        let newTokens = insertion.newTokens

        var activateWindowToken: WindowToken?
        var rememberedFocusToken: WindowToken?
        var hasNewWindowArrival = false
        var shouldStartScrollForNewWindow = false
        if snapshot.hasCompletedInitialRefresh,
           let newToken = newTokens.last,
           let newNode = pass.engine.findNode(for: newToken),
           snapshot.isActiveWorkspace
        {
            let isTabLocalArrival = insertion.tabLocalTokens.contains(newToken)
            state.selectedNodeId = newNode.id

            if wasEmpty {
                if pass.engine.singleWindowLayoutContext(in: pass.wsId) != nil {
                    resetViewportForSingleWindowFit(state: &state)
                } else {
                    let cols = pass.engine.columns(in: pass.wsId)
                    let settings = pass.engine.effectiveSettings(in: pass.wsId)
                    state.transitionToColumn(
                        0,
                        columns: cols,
                        gap: pass.gap,
                        viewportWidth: pass.insetFrame.width,
                        motion: motion,
                        animate: false,
                        centerMode: settings.centerFocusedColumn,
                        alwaysCenterSingleColumn: settings.alwaysCenterSingleColumn,
                        scale: pass.engine.displayScale(in: pass.wsId),
                        workingArea: pass.insetFrame,
                        viewFrame: pass.monitor.frame
                    )
                }
            } else if isTabLocalArrival {
                activateTabLocalWindow(
                    newNode,
                    pass: pass,
                    state: &state,
                    viewOrigin: insertion.viewOriginBeforeInsertion
                )
            } else if let newCol = pass.engine.column(of: newNode),
                      let newColIdx = pass.engine.columnIndex(of: newCol, in: pass.wsId)
            {
                if newCol.cachedWidth <= 0 {
                    newCol.resolveAndCacheWidth(workingAreaWidth: pass.insetFrame.width, gaps: pass.gap)
                }

                let shouldRestorePrevOffset = newColIdx == state.activeColumnIndex + 1
                let offsetBeforeActivation = state.viewOffset

                pass.engine.ensureSelectionVisible(
                    node: newNode,
                    in: pass.wsId,
                    motion: motion,
                    state: &state,
                    workingFrame: pass.insetFrame,
                    gaps: pass.gap,
                    fromContainerIndex: state.activeColumnIndex
                )

                if shouldRestorePrevOffset {
                    state.activatePrevColumnOnRemoval = offsetBeforeActivation
                }
            }
            rememberedFocusToken = newToken
            pass.engine.updateFocusTimestamp(for: newNode.id)
            activateWindowToken = newToken
            hasNewWindowArrival = true
            shouldStartScrollForNewWindow = !isTabLocalArrival
        }

        let animatedNewTokens = newTokens.filter { !insertion.tabLocalTokens.contains($0) }
        if snapshot.hasCompletedInitialRefresh,
           snapshot.isActiveWorkspace,
           !animatedNewTokens.isEmpty
        {
            let reduceMotionScale: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.25 : 1.0
            let appearOffset = 16.0 * reduceMotionScale

            for token in animatedNewTokens {
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

        return ArrivalContext(
            activateWindowToken: activateWindowToken,
            rememberedFocusToken: rememberedFocusToken,
            hasNewWindowArrival: hasNewWindowArrival,
            shouldStartScrollForNewWindow: shouldStartScrollForNewWindow
        )
    }

    private func activateTabLocalWindow(
        _ node: NiriNode,
        pass: NiriLayoutPass,
        state: inout ViewportState,
        viewOrigin: CGFloat?
    ) {
        guard let column = pass.engine.column(of: node),
              let columnIndex = pass.engine.columnIndex(of: column, in: pass.wsId)
        else { return }

        if let window = node as? NiriWindow,
           let tileIndex = column.windowNodes.firstIndex(where: { $0 === window })
        {
            column.setActiveTileIdx(tileIndex)
            pass.engine.updateTabbedColumnVisibility(column: column)
        }

        state.activeColumnIndex = columnIndex
        state.activatePrevColumnOnRemoval = nil
        state.viewOffsetToRestore = nil
        state.selectionProgress = 0

        if let viewOrigin {
            restoreViewOrigin(viewOrigin, pass: pass, state: &state)
        } else {
            state.jumpOffset(to: state.viewOffset)
        }
    }

    private func resolveColumnWidthsIfNeeded(pass: NiriLayoutPass) {
        for column in pass.engine.columns(in: pass.wsId) where column.cachedWidth <= 0 {
            column.resolveAndCacheWidth(workingAreaWidth: pass.insetFrame.width, gaps: pass.gap)
        }
    }

    private func currentViewOrigin(pass: NiriLayoutPass, state: ViewportState) -> CGFloat? {
        let columns = pass.engine.columns(in: pass.wsId)
        guard !columns.isEmpty else { return nil }
        resolveColumnWidthsIfNeeded(pass: pass)
        return state.viewPosPixels(columns: columns, gap: pass.gap)
    }

    private func restoreViewOrigin(_ viewOrigin: CGFloat, pass: NiriLayoutPass, state: inout ViewportState) {
        let columns = pass.engine.columns(in: pass.wsId)
        guard !columns.isEmpty else { return }
        resolveColumnWidthsIfNeeded(pass: pass)
        let activeColumnIndex = state.activeColumnIndex.clamped(to: 0 ... columns.count - 1)
        state.activeColumnIndex = activeColumnIndex
        let activeColumnX = state.columnX(at: activeColumnIndex, columns: columns, gap: pass.gap)
        state.jumpOffset(to: viewOrigin - activeColumnX)
    }

    private func resetViewportForSingleWindowFit(state: inout ViewportState) {
        state.activeColumnIndex = 0
        state.jumpOffset(to: 0)
        state.activatePrevColumnOnRemoval = nil
        state.viewOffsetToRestore = nil
        state.selectionProgress = 0
    }

    private func computeLayoutPlan(
        pass: NiriLayoutPass,
        motion: MotionSnapshot,
        state: ViewportState,
        rememberedFocusToken: WindowToken?,
        activateWindowToken: WindowToken?,
        hasNewWindowArrival: Bool,
        shouldStartScrollForNewWindow: Bool,
        viewportNeedsRecalc: Bool,
        snapshot: NiriWorkspaceSnapshot
    ) -> WorkspaceLayoutPlan {
        let gaps = LayoutGaps(
            horizontal: pass.gap,
            vertical: pass.gap,
            outer: snapshot.outerGaps
        )

        let area = WorkingAreaContext(
            workingFrame: pass.insetFrame,
            fullscreenLayoutFrame: snapshot.monitor.fullscreenLayoutFrame,
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
            viewOffsetOverride: controller.map {
                $0.workspaceManager.animationDriver.plannedRenderOffset(
                    in: pass.wsId,
                    localState: state,
                    storeOffset: $0.workspaceManager.niriViewportState(for: pass.wsId).viewOffset
                )
            }
        )

        let hasColumnAnimations = pass.engine.hasAnyColumnAnimationsRunning(in: pass.wsId)
        var directives: [AnimationDirective] = []

        if !snapshot.useScrollAnimationPath {
            if viewportNeedsRecalc, !hasNewWindowArrival {
                directives.append(.startNiriScroll(workspaceId: pass.wsId))
            } else if hasColumnAnimations {
                directives.append(.startNiriScroll(workspaceId: pass.wsId))
            }
        }

        if let activateWindowToken {
            if shouldStartScrollForNewWindow {
                directives.append(.startNiriScroll(workspaceId: pass.wsId))
            }
            directives.append(.activateWindow(token: activateWindowToken))
        }

        if let removalSeed = snapshot.removalSeed, !removalSeed.oldFrames.isEmpty {
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
            frames: frames,
            hiddenHandles: hiddenHandles,
            engine: pass.engine,
            canRestoreHiddenWorkspaceWindows: snapshot.isActiveWorkspace
        )
        return WorkspaceLayoutPlan(
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
    }

    private func layoutDiff(
        windows: [LayoutWindowSnapshot],
        frames: [WindowToken: CGRect],
        hiddenHandles: [WindowToken: HideSide],
        engine: NiriLayoutEngine,
        canRestoreHiddenWorkspaceWindows: Bool
    ) -> WorkspaceLayoutDiff {
        var diff = WorkspaceLayoutDiff()
        for window in windows {
            let token = window.token
            if window.isNativeFullscreenSuspended {
                continue
            }
            let previousOffscreenSide = window.hiddenState?.offscreenSide
            if let side = hiddenHandles[token] {
                if previousOffscreenSide != side {
                    diff.visibilityChanges.append(.hide(token, side: side))
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
                node.sizingMode == .fullscreen
            } else {
                false
            }
            diff.frameChanges.append(
                LayoutFrameChange(
                    token: token,
                    frame: frame,
                    forceApply: forceApply
                )
            )
        }

        return diff
    }

    func desiredTabRailInfos() -> [TabbedColumnOverlayInfo] {
        guard let controller, let engine = controller.niriEngine else { return [] }

        var infos: [TabbedColumnOverlayInfo] = []
        for monitor in controller.workspaceManager.monitors {
            guard let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
            else { continue }

            infos.append(contentsOf: tabbedColumnOverlayInfos(
                engine: engine,
                workspaceId: workspace.id,
                monitor: monitor
            ))
        }
        return infos
    }

    private func tabbedColumnOverlayInfos(
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor
    ) -> [TabbedColumnOverlayInfo] {
        guard let controller else { return [] }
        var infos: [TabbedColumnOverlayInfo] = []
        for column in engine.columns(in: workspaceId) where column.isTabbed {
            guard let frame = column.renderedFrame ?? column.frame else { continue }
            let visibleColumnFrame = frame.intersection(monitor.visibleFrame)
            guard TabbedColumnOverlayManager.shouldShowOverlay(
                columnFrame: frame,
                visibleFrame: monitor.visibleFrame
            ) else { continue }

            let windows = column.windowNodes
            guard !windows.isEmpty else { continue }

            guard let activeWindow = column.activeWindow else { continue }
            let activeWindowId = controller.workspaceManager.entry(for: activeWindow.handle)?.windowId
            let activeVisualIndex = column.activeVisualTileIdx
            let tabs = tabbedColumnTabs(
                column: column,
                windows: windows,
                activeVisualIndex: activeVisualIndex,
                controller: controller
            )

            infos.append(
                TabbedColumnOverlayInfo(
                    workspaceId: workspaceId,
                    columnId: column.id,
                    plannedSeq: controller.workspaceManager.worldSeq,
                    columnFrame: frame,
                    visibleColumnFrame: visibleColumnFrame,
                    tabCount: windows.count,
                    activeVisualIndex: activeVisualIndex,
                    activeWindowId: activeWindowId,
                    tabs: tabs
                )
            )
        }
        return infos
    }

    private func tabbedColumnTabs(
        column: NiriContainer,
        windows: [NiriWindow],
        activeVisualIndex: Int,
        controller: WMController
    ) -> [TabbedColumnOverlayTabInfo] {
        guard !windows.isEmpty else { return [] }
        let clampedActiveVisualIndex = min(max(0, activeVisualIndex), windows.count - 1)
        var tabs: [TabbedColumnOverlayTabInfo] = []
        tabs.reserveCapacity(windows.count)
        for visualIndex in 0 ..< windows.count {
            guard let storageIndex = column.storageTileIndex(forVisualTileIndex: visualIndex),
                  windows.indices.contains(storageIndex)
            else {
                continue
            }
            let window = windows[storageIndex]
            let entry = controller.workspaceManager.entry(for: window.handle)
            let appName: String?
            if let entry, controller.appInfoCache.hasCachedInfo(for: entry.pid) {
                appName = controller.appInfoCache.name(for: entry.pid)
            } else {
                appName = nil
            }
            let title = entry?.managedReplacementMetadata?.title
            tabs.append(
                TabbedColumnOverlayTabInfo(
                    visualIndex: visualIndex,
                    token: window.token,
                    windowId: entry?.windowId,
                    appName: appName,
                    title: title,
                    isActive: visualIndex == clampedActiveVisualIndex
                )
            )
        }
        return tabs
    }

    func selectTabInNiri(
        info: TabbedColumnOverlayInfo,
        visualIndex: Int,
        expectedToken: WindowToken?
    ) {
        guard let controller, let engine = controller.niriEngine else { return }
        let workspaceId = info.workspaceId
        guard controller.workspaceManager.isSeqCurrent(
            info.plannedSeq,
            for: workspaceId,
            domains: .layoutCommit
        ) else {
            return
        }
        let columnId = info.columnId
        guard let column = engine.columns(in: workspaceId).first(where: { $0.id == columnId }) else { return }

        let windows = column.windowNodes
        guard let storageIndex = column.storageTileIndex(forVisualTileIndex: visualIndex),
              windows.indices.contains(storageIndex)
        else {
            return
        }

        let target = windows[storageIndex]
        if let expectedToken, target.token != expectedToken {
            return
        }

        let activeTileChanged = column.activeTileIdx != storageIndex
        controller.workspaceManager.withEngineMutationScope {
            column.setActiveTileIdx(storageIndex)
            engine.updateTabbedColumnVisibility(column: column)
        }
        if activeTileChanged {
            recordLayoutOperation(.tabActivated(token: target.token), in: workspaceId, source: .mouse)
        }

        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        controller.workspaceManager.withEngineMutationScope {
            if let monitor = controller.workspaceManager.monitor(for: workspaceId) {
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
        }
        activateNode(
            target, in: workspaceId, state: &state,
            options: .init(activateWindow: false, ensureVisible: false, startAnimation: false)
        )
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: state,
                rememberedFocusToken: nil,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
        if controller.workspaceManager.animationDriver.hasMotion(in: workspaceId)
            || engine.hasAnyWindowAnimationsRunning(in: workspaceId)
        {
            controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
        }
    }

    // MARK: - Layout Capability Commands

    func focusNeighbor(direction: Direction) -> Bool {
        guard let controller else { return false }
        guard let engine = controller.niriEngine else { return false }
        guard let wsId = controller.activeWorkspace()?.id else { return false }

        var state = controller.workspaceManager.niriViewportState(for: wsId)
        guard let currentId = state.selectedNodeId,
              let currentNode = engine.findNode(by: currentId)
        else {
            var recovered = false
            if let lastFocused = controller.workspaceManager.lastFocusedToken(in: wsId),
               let lastNode = engine.findNode(for: lastFocused)
            {
                activateNode(
                    lastNode, in: wsId, state: &state,
                    options: .init(
                        activateWindow: false,
                        ensureVisible: false,
                        layoutRefresh: false,
                        startAnimation: false
                    )
                )
                recovered = true
            } else if let firstToken = controller.workspaceManager.tiledEntries(in: wsId).first?.token,
                      let firstNode = engine.findNode(for: firstToken)
            {
                activateNode(
                    firstNode, in: wsId, state: &state,
                    options: .init(
                        activateWindow: false,
                        ensureVisible: false,
                        layoutRefresh: false,
                        startAnimation: false
                    )
                )
                recovered = true
            }
            _ = controller.workspaceManager.applySessionPatch(
                .init(
                    workspaceId: wsId,
                    viewportState: state,
                    rememberedFocusToken: nil,
                    plannedSeq: controller.workspaceManager.worldSeq
                )
            )
            return recovered
        }

        guard let monitor = controller.workspaceManager.monitor(for: wsId) else { return false }
        let gap = CGFloat(controller.workspaceManager.gaps)
        let workingFrame = controller.insetWorkingFrame(for: monitor)

        let newNode = controller.workspaceManager.withEngineMutationScope { () -> NiriNode? in
            for col in engine.columns(in: wsId) where col.cachedWidth <= 0 {
                col.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gap)
            }

            return engine.focusTarget(
                direction: direction,
                currentSelection: currentNode,
                in: wsId,
                motion: controller.motionPolicy.snapshot(),
                state: &state,
                workingFrame: workingFrame,
                gaps: gap
            )
        }
        guard let newNode else { return false }
        activateNode(
            newNode, in: wsId, state: &state,
            options: .init(
                activateWindow: false,
                ensureVisible: false,
                layoutRefresh: false,
                axFocus: false
            )
        )
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: wsId,
                viewportState: state,
                rememberedFocusToken: nil,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
        focusSelectedWindowAndRequestRelayout(in: wsId)
        return true
    }

    func toggleFullscreen() {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, _, _ in
            guard let currentId = state.selectedNodeId,
                  let currentNode = engine.findNode(by: currentId),
                  let windowNode = currentNode as? NiriWindow
            else { return }

            engine.toggleFullscreen(windowNode, motion: motion, state: &state)

            recordLayoutOperation(.fullscreenToggled(token: windowNode.token), in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func cycleSize(forward: Bool) {
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
            recordLayoutOperation(.columnWidthChanged, in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func cycleWindowWidth(forward: Bool) {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId) as? NiriWindow
            else { return }

            engine.toggleWindowWidth(
                windowNode,
                forwards: forward,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
            recordLayoutOperation(.windowSizeChanged(token: windowNode.token), in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func cycleWindowHeight(forward: Bool) {
        withNiriWorkspaceContext { engine, wsId, _, state, _, workingFrame, gaps in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId) as? NiriWindow
            else { return }

            engine.toggleWindowHeight(
                windowNode,
                forwards: forward,
                in: wsId,
                workingFrame: workingFrame,
                gaps: gaps
            )
            recordLayoutOperation(.windowSizeChanged(token: windowNode.token), in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func toggleColumnFullWidth() {
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
            recordLayoutOperation(.columnWidthChanged, in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func expandColumnToAvailableWidth() {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId) as? NiriWindow,
                  let column = engine.findColumn(containing: windowNode, in: wsId)
            else { return }

            engine.expandColumnToAvailableWidth(
                column,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
            recordLayoutOperation(.columnWidthChanged, in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func resetWindowHeight() {
        withNiriWorkspaceContext { engine, wsId, _, state, _, _, _ in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId) as? NiriWindow
            else { return }

            engine.resetWindowHeight(windowNode, in: wsId)
            recordLayoutOperation(.windowSizeChanged(token: windowNode.token), in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func centerColumn() {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps in
            guard engine.centerColumn(
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            ) else { return }

            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func centerVisibleColumns() {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps in
            guard engine.centerVisibleColumns(
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            ) else { return }

            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func setColumnWidth(_ change: NiriSizeChange) {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId) as? NiriWindow,
                  let column = engine.findColumn(containing: windowNode, in: wsId)
            else { return }

            engine.setColumnWidth(
                column,
                change: change,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
            recordLayoutOperation(.columnWidthChanged, in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func setWindowWidth(_ change: NiriSizeChange) {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId) as? NiriWindow
            else { return }

            engine.setWindowWidth(
                windowNode,
                change: change,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
            recordLayoutOperation(.windowSizeChanged(token: windowNode.token), in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func setWindowHeight(_ change: NiriSizeChange) {
        withNiriWorkspaceContext { engine, wsId, _, state, _, workingFrame, gaps in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId) as? NiriWindow
            else { return }

            engine.setWindowHeight(
                windowNode,
                change: change,
                in: wsId,
                workingFrame: workingFrame,
                gaps: gaps
            )
            recordLayoutOperation(.windowSizeChanged(token: windowNode.token), in: wsId)
            requestLayoutCommandRelayout(in: wsId)
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
            recordLayoutOperation(.sizesBalanced, in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            if engine.hasAnyColumnAnimationsRunning(in: wsId) {
                controller.layoutRefreshController.startScrollAnimation(for: wsId)
            }
        }
    }

    // MARK: - Layout Engine Configuration

    func enableNiriLayout(
        centerFocusedColumn: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false
    ) {
        guard let controller else { return }
        let engine = NiriLayoutEngine()
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
        var orientations: [Monitor.ID: Monitor.Orientation] = [:]
        orientations.reserveCapacity(currentMonitors.count)
        for monitor in currentMonitors {
            orientations[monitor.id] = controller.settings.effectiveOrientation(for: monitor)
        }
        let workspaceAssignments: [(workspaceId: WorkspaceDescriptor.ID, monitor: Monitor)] =
            controller.workspaceManager.workspaces.compactMap { workspace in
                guard let monitor = controller.workspaceManager.monitor(for: workspace.id) else { return nil }
                return (workspaceId: workspace.id, monitor: monitor)
            }
        controller.workspaceManager.withEngineMutationScope {
            engine.updateMonitors(currentMonitors, orientations: orientations)
            engine.syncWorkspaceAssignments(workspaceAssignments, orientations: orientations)
        }

        refreshResolvedMonitorSettings()
    }

    func refreshResolvedMonitorSettings() {
        guard let controller, let engine = controller.niriEngine else { return }

        controller.workspaceManager.withEngineMutationScope {
            for monitor in controller.workspaceManager.monitors {
                let resolved = controller.settings.resolvedNiriSettings(for: monitor)
                engine.updateMonitorSettings(resolved, for: monitor.id)
            }
        }
    }

    func updateNiriConfig(
        maxVisibleColumns: Int? = nil,
        infiniteLoop: Bool? = nil,
        centerFocusedColumn: CenterFocusedColumn? = nil,
        alwaysCenterSingleColumn: Bool? = nil,
        singleWindowFit: SingleWindowFit? = nil,
        columnWidthPresets: [Double]? = nil,
        defaultColumnWidth: Double?? = nil
    ) {
        guard let controller else { return }
        controller.workspaceManager.withEngineMutationScope {
            controller.niriEngine?.updateConfiguration(
                maxVisibleColumns: maxVisibleColumns,
                infiniteLoop: infiniteLoop,
                centerFocusedColumn: centerFocusedColumn,
                alwaysCenterSingleColumn: alwaysCenterSingleColumn,
                singleWindowFit: singleWindowFit,
                presetColumnWidths: columnWidthPresets?.map { .proportion($0) },
                defaultColumnWidth: defaultColumnWidth.map { $0.map { CGFloat($0) } }
            )
        }
        refreshResolvedMonitorSettings()
        controller.layoutRefreshController.requestRelayout(reason: .layoutConfigChanged)
    }

    // MARK: - Node Activation & Operation Context

    func activateNode(
        _ node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        options: NodeActivationOptions = NodeActivationOptions()
    ) {
        guard let controller, let engine = controller.niriEngine else { return }

        state.selectedNodeId = node.id
        controller.workspaceManager.withEngineMutationScope {
            if !options.ensureVisible, !options.preserveViewportAnchor {
                rebaseViewportAnchor(to: node, in: workspaceId, state: &state)
            }

            if options.activateWindow {
                engine.activateWindow(node.id)
            }

            if options.ensureVisible, let monitor = controller.workspaceManager.monitor(for: workspaceId) {
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
        }

        let focusedToken = (node as? NiriWindow)?.token
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: node.id,
            focusedToken: focusedToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        if options.updateTimestamp, let windowNode = node as? NiriWindow {
            controller.workspaceManager.withEngineMutationScope {
                engine.updateFocusTimestamp(for: windowNode.id)
            }
        }

        if options.layoutRefresh {
            let focusToken = options.axFocus ? (node as? NiriWindow)?.token : nil
            requestLayoutCommandRelayout(
                in: workspaceId
            ) { [weak controller] in
                if let focusToken {
                    controller?.focusWindow(focusToken, origin: options.focusOrigin)
                }
            }
            if options.startAnimation, state.hasPendingOffsetAnimation {
                controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
            }
        } else {
            if options.axFocus, let windowNode = node as? NiriWindow {
                controller.focusWindow(windowNode.token, origin: options.focusOrigin)
            }
            if options.startAnimation, state.hasPendingOffsetAnimation {
                controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
            }
        }
    }

    private func rebaseViewportAnchor(
        to node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) {
        guard let controller, let engine = controller.niriEngine else { return }
        guard let column = engine.column(of: node) else { return }
        let columns = engine.columns(in: workspaceId)
        guard let targetIndex = columns.firstIndex(where: { $0 === column }) else { return }
        let currentIndex = min(max(state.activeColumnIndex, 0), columns.count - 1)
        guard currentIndex != targetIndex else { return }

        guard let monitor = controller.workspaceManager.monitor(for: workspaceId) else {
            state.activeColumnIndex = targetIndex
            return
        }

        let gap = CGFloat(controller.workspaceManager.gaps)
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let orientation = engine.monitor(for: monitor.id)?.orientation
            ?? controller.settings.effectiveOrientation(for: monitor)

        switch orientation {
        case .horizontal:
            for column in columns where column.cachedWidth <= 0 {
                column.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gap)
            }
            rebaseViewportAnchor(
                from: currentIndex,
                to: targetIndex,
                workspaceId: workspaceId,
                columns: columns,
                gap: gap,
                state: &state,
                sizeKeyPath: \.cachedWidth
            )
        case .vertical:
            for column in columns where column.cachedHeight <= 0 {
                column.resolveAndCacheHeight(workingAreaHeight: workingFrame.height, gaps: gap)
            }
            rebaseViewportAnchor(
                from: currentIndex,
                to: targetIndex,
                workspaceId: workspaceId,
                columns: columns,
                gap: gap,
                state: &state,
                sizeKeyPath: \.cachedHeight
            )
        }
    }

    private func rebaseViewportAnchor(
        from currentIndex: Int,
        to targetIndex: Int,
        workspaceId: WorkspaceDescriptor.ID,
        columns: [NiriContainer],
        gap: CGFloat,
        state: inout ViewportState,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>
    ) {
        let previousPosition = state.containerPosition(
            at: currentIndex,
            containers: columns,
            gap: gap,
            sizeKeyPath: sizeKeyPath
        )
        let targetPosition = state.containerPosition(
            at: targetIndex,
            containers: columns,
            gap: gap,
            sizeKeyPath: sizeKeyPath
        )
        state.rebaseOffset(by: previousPosition - targetPosition)
        state.activeColumnIndex = targetIndex
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

    @discardableResult
    func moveWindow(direction: Direction) -> WindowMoveOutcome {
        let allowEdgeWrap = !(controller?.settings.moveCrossesMonitorAtEdge ?? false)
        var result = WindowMoveOutcome.blocked

        withNiriOperationContext { ctx, state in
            let edgeOutcome = windowMoveOutcomeAtEdge(
                for: ctx.windowNode,
                direction: direction,
                engine: ctx.engine,
                in: ctx.wsId
            )
            let oldFrames = direction == .left || direction == .right
                ? [:]
                : ctx.engine.captureWindowFrames(in: ctx.wsId)
            guard ctx.engine.moveWindow(
                ctx.windowNode,
                direction: direction,
                in: ctx.wsId,
                motion: ctx.motion,
                state: &state,
                workingFrame: ctx.workingFrame,
                gaps: ctx.gaps,
                allowEdgeWrap: allowEdgeWrap
            ) else {
                result = edgeOutcome
                return false
            }

            result = .movedWithinWorkspace
            if direction == .left || direction == .right {
                ctx.record(.windowConsumedOrExpelled(token: ctx.windowNode.token))
                return ctx.commitSimple(state: state)
            }
            ctx.record(.windowMovedInColumn(token: ctx.windowNode.token))
            return ctx.commitWithPredictedAnimation(state: state, oldFrames: oldFrames)
        }

        return result
    }

    func moveWindowOrToAdjacentWorkspace(direction: Direction) {
        guard direction == .down || direction == .up else { return }
        guard moveWindow(direction: direction) == .atWorkspaceEdge else { return }
        controller?.workspaceNavigationHandler.moveWindowToAdjacentWorkspace(direction: direction)
    }

    func consumeTransferredWindow(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        enteringFrom direction: Direction,
        anchorToken: WindowToken?
    ) {
        guard let controller, let engine = controller.niriEngine else { return }
        guard let monitor = controller.workspaceManager.monitor(for: workspaceId) else { return }
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let gaps = CGFloat(controller.workspaceManager.gaps)
        var targetState = controller.workspaceManager.niriViewportState(for: workspaceId)

        var consumed = false

        controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
            guard let movedNode = engine.findNode(for: token),
                  let column = engine.findColumn(containing: movedNode, in: workspaceId)
            else { return }

            movedNode.stopMoveAnimations()

            let anchorColumn = anchorToken
                .flatMap { engine.findNode(for: $0) }
                .flatMap { engine.findColumn(containing: $0, in: workspaceId) }

            if let anchorColumn, anchorColumn.id != column.id {
                consumed = engine.consumeWindow(
                    movedNode, into: anchorColumn, enteringFrom: direction,
                    in: workspaceId, motion: .disabled, state: &targetState,
                    workingFrame: workingFrame, gaps: gaps
                )
            }

            if !consumed {
                engine.activateWindow(movedNode.id)
                targetState.selectedNodeId = movedNode.id
                engine.ensureSelectionVisible(
                    node: movedNode, in: workspaceId, motion: .disabled, state: &targetState,
                    workingFrame: workingFrame, gaps: gaps
                )
            }
        }

        targetState.cancelAnimation()

        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: targetState,
                rememberedFocusToken: token,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
    }

    func consumeOrExpelWindow(direction: Direction) {
        guard direction == .left || direction == .right else { return }
        withNiriOperationContext { ctx, state in
            guard ctx.engine.consumeOrExpelWindow(
                ctx.windowNode,
                direction: direction,
                in: ctx.wsId,
                motion: ctx.motion,
                state: &state,
                workingFrame: ctx.workingFrame,
                gaps: ctx.gaps,
                allowEdgeWrap: false
            ) else {
                return false
            }
            ctx.record(.windowConsumedOrExpelled(token: ctx.windowNode.token))
            return ctx.commitSimple(state: state)
        }
    }

    func consumeWindowIntoColumn() {
        withNiriOperationContext { ctx, state in
            guard let column = ctx.engine.findColumn(containing: ctx.windowNode, in: ctx.wsId) else {
                return false
            }
            guard ctx.engine.consumeWindowIntoColumn(
                focusedColumn: column,
                in: ctx.wsId,
                motion: ctx.motion,
                state: &state,
                gaps: ctx.gaps
            ) else {
                return false
            }
            ctx.record(.windowConsumedOrExpelled(token: ctx.windowNode.token))
            return ctx.commitSimple(state: state)
        }
    }

    func expelWindowFromColumn() {
        withNiriOperationContext { ctx, state in
            guard let column = ctx.engine.findColumn(containing: ctx.windowNode, in: ctx.wsId) else {
                return false
            }
            guard ctx.engine.expelWindowFromColumn(
                focusedColumn: column,
                in: ctx.wsId,
                motion: ctx.motion,
                state: &state,
                workingFrame: ctx.workingFrame,
                gaps: ctx.gaps
            ) else {
                return false
            }
            ctx.record(.windowConsumedOrExpelled(token: ctx.windowNode.token))
            return ctx.commitSimple(state: state)
        }
    }

    private func windowMoveOutcomeAtEdge(
        for node: NiriWindow,
        direction: Direction,
        engine: NiriLayoutEngine,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> WindowMoveOutcome {
        guard node.parent is NiriContainer else {
            return .blocked
        }

        switch direction {
        case .down:
            return node.prevSibling() == nil ? .atWorkspaceEdge : .blocked
        case .up:
            return node.nextSibling() == nil ? .atWorkspaceEdge : .blocked
        case .left,
             .right:
            return isAtHorizontalWorkspaceEdge(node, direction: direction, engine: engine, in: workspaceId)
                ? .atWorkspaceEdge : .blocked
        }
    }

    private func isAtHorizontalWorkspaceEdge(
        _ node: NiriWindow,
        direction: Direction,
        engine: NiriLayoutEngine,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let column = engine.findColumn(containing: node, in: workspaceId),
              column.windowNodes.count == 1,
              let index = engine.columnIndex(of: column, in: workspaceId)
        else {
            return false
        }

        switch direction {
        case .left:
            return index == 0
        case .right:
            return index == engine.columns(in: workspaceId).count - 1
        case .up,
             .down:
            return false
        }
    }

    func withNiriWorkspaceContext(
        perform: (
            NiriLayoutEngine,
            WorkspaceDescriptor.ID,
            MotionSnapshot,
            inout ViewportState,
            Monitor,
            CGRect,
            CGFloat
        ) -> Void
    ) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }
        guard let monitor = controller.workspaceManager.monitor(for: wsId) else { return }
        let motion = controller.motionPolicy.snapshot()
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let gaps = CGFloat(controller.workspaceManager.gaps)
        controller.workspaceManager.withNiriViewportState(for: wsId) { state in
            perform(engine, wsId, motion, &state, monitor, workingFrame, gaps)
        }
    }

    func withNiriWorkspaceContext(
        for workspaceId: WorkspaceDescriptor.ID,
        perform: (
            NiriLayoutEngine,
            WorkspaceDescriptor.ID,
            MotionSnapshot,
            inout ViewportState,
            Monitor,
            CGRect,
            CGFloat
        ) -> Void
    ) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }
        guard let monitor = controller.workspaceManager.monitor(for: workspaceId) else { return }
        let motion = controller.motionPolicy.snapshot()
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let gaps = CGFloat(controller.workspaceManager.gaps)
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            perform(engine, workspaceId, motion, &state, monitor, workingFrame, gaps)
        }
    }

    @discardableResult
    func insertWindow(
        handle: WindowHandle,
        targetHandle: WindowHandle,
        position: InsertPosition,
        in workspaceId: WorkspaceDescriptor.ID,
        source: WMEventSource = .command
    ) -> Bool {
        var didMove = false
        withNiriWorkspaceContext(for: workspaceId) { engine, wsId, motion, state, monitor, workingFrame, gaps in
            guard let sourceNode = engine.findNode(for: handle) else { return }
            guard let target = engine.findNode(for: targetHandle) else { return }
            didMove = engine.insertWindowByMove(
                sourceWindowId: sourceNode.id,
                targetWindowId: target.id,
                position: position,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }
        if didMove {
            recordLayoutOperation(.windowInserted(token: handle.id), in: workspaceId, source: source)
        }
        return didMove
    }

    @discardableResult
    func insertWindowInNewColumn(
        handle: WindowHandle,
        insertIndex: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        source: WMEventSource = .command
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
        if didMove {
            recordLayoutOperation(.windowInserted(token: handle.id), in: workspaceId, source: source)
        }
        return didMove
    }
}

struct NodeActivationOptions {
    var activateWindow: Bool = true
    var ensureVisible: Bool = true
    var preserveViewportAnchor: Bool = false
    var updateTimestamp: Bool = true
    var layoutRefresh: Bool = true
    var axFocus: Bool = true
    var focusOrigin: ManagedFocusOrigin = .keyboardOrProgrammatic
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
        hasPendingNiriAnimationWork(
            state: state,
            driver: controller.workspaceManager.animationDriver,
            engine: engine,
            workspaceId: wsId
        )
    }

    private func requestLayoutCommandRelayout() {
        controller.layoutRefreshController.requestLayoutCommandRelayout(
            affectedWorkspaceIds: [wsId]
        )
    }

    func record(_ operation: LayoutOperation) {
        controller.workspaceManager.recordLayoutOperation(operation, in: wsId)
    }

    func commitWithPredictedAnimation(
        state: ViewportState,
        oldFrames: [WindowToken: CGRect]
    ) -> Bool {
        let scale = NSScreen.screens.first(where: { $0.displayId == monitor.displayId })?
            .backingScaleFactor ?? 2.0
        let workingArea = WorkingAreaContext(
            workingFrame: workingFrame,
            fullscreenLayoutFrame: controller.fullscreenLayoutFrame(for: monitor),
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
            animationTime: animationTime
        ).frames
        _ = engine.triggerMoveAnimations(
            in: wsId,
            oldFrames: oldFrames,
            newFrames: newFrames,
            motion: motion
        )
        requestLayoutCommandRelayout()
        return hasPendingAnimationWork(state: state)
    }

    func commitWithCapturedAnimation(
        state: ViewportState,
        oldFrames: [WindowToken: CGRect]
    ) -> Bool {
        requestLayoutCommandRelayout()
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
        requestLayoutCommandRelayout()
        return hasPendingAnimationWork(state: state)
    }
}

extension NiriLayoutHandler: LayoutFocusable, LayoutSizable {}

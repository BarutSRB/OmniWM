import AppKit
import Foundation
import QuartzCore

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
        var columnRemovalResult: NiriLayoutEngine.ColumnRemovalResult?
        var precomputedFallback: NodeId?
        var originalColumnIndex: Int?
    }

    var scrollAnimationByDisplay: [CGDirectDisplayID: WorkspaceDescriptor.ID] = [:]

    init(controller: WMController?) {
        self.controller = controller
    }

    func registerScrollAnimation(_ workspaceId: WorkspaceDescriptor.ID, on displayId: CGDirectDisplayID) -> Bool {
        if scrollAnimationByDisplay[displayId] == workspaceId {
            return false
        }
        scrollAnimationByDisplay[displayId] = workspaceId
        return true
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
        let workspaceSwitchRunning = engine.tickWorkspaceSwitchAnimation(for: wsId, at: targetTime)

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
                || workspaceSwitchRunning

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
        guard let controller,
              let focusedToken = controller.workspaceManager.focusedToken,
              let entry = controller.workspaceManager.entry(for: focusedToken),
              let engine = controller.niriEngine
        else { return }

        if let node = engine.findNode(for: focusedToken),
           let frame = node.renderedFrame ?? node.frame {
            controller.borderCoordinator.updateBorderIfAllowed(token: focusedToken, frame: frame, windowId: entry.windowId)
        }

        if controller.moveMouseToFocusedWindowEnabled {
            controller.moveMouseToWindow(focusedToken)
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
        var processedWorkspaces: Set<WorkspaceDescriptor.ID> = []
        for monitor in controller.workspaceManager.monitors {
            try Task.checkCancellation()
            guard let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) else { continue }
            let wsId = workspace.id
            guard activeWorkspaces.contains(wsId) else { continue }
            guard !processedWorkspaces.contains(wsId) else { continue }
            processedWorkspaces.insert(wsId)

            let layoutType = controller.settings.layoutType(for: workspace.name)
            if layoutType == .dwindle { continue }

            guard let snapshot = makeWorkspaceSnapshot(
                workspaceId: wsId,
                monitor: monitor,
                viewportState: nil,
                useScrollAnimationPath: useScrollAnimationPath,
                removalSeed: removalSeeds[wsId],
                isActiveWorkspace: activeWorkspaces.contains(wsId)
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

        let entries = controller.workspaceManager.tiledEntries(in: wsId)
        let shouldResolveConstraints = viewportState == nil
        let windows = controller.layoutRefreshController.buildWindowSnapshots(
            for: entries,
            resolveConstraints: shouldResolveConstraints
        )
        let effectiveViewportState = viewportState ?? controller.workspaceManager.niriViewportState(for: wsId)
        let orientation = controller.niriEngine?.monitor(for: monitor.id)?.orientation
            ?? controller.settings.effectiveOrientation(for: monitor)
        let monitorSnapshot = controller.layoutRefreshController.buildMonitorSnapshot(
            for: monitor,
            orientation: orientation
        )
        let interactionWorkspaceId = controller.activeWorkspace()?.id

        return NiriWorkspaceSnapshot(
            workspaceId: wsId,
            monitor: monitorSnapshot,
            windows: windows,
            viewportState: effectiveViewportState,
            preferredFocusToken: controller.workspaceManager.preferredFocusToken(in: wsId),
            confirmedFocusedToken: controller.workspaceManager.focusedToken,
            hasCompletedInitialRefresh: controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh,
            useScrollAnimationPath: useScrollAnimationPath,
            removalSeed: removalSeed,
            gap: CGFloat(controller.workspaceManager.gaps),
            outerGaps: controller.workspaceManager.outerGaps,
            displayRefreshRate: controller.layoutRefreshController.layoutState.refreshRateByDisplay[monitor.displayId] ?? 60.0,
            isActiveWorkspace: isActiveWorkspace,
            isInteractionWorkspace: interactionWorkspaceId == wsId
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
            viewFrame: snapshot.monitor.frame,
            scale: snapshot.monitor.scale
        )

        let (frames, hiddenHandles) = engine.calculateCombinedLayoutUsingPools(
            in: snapshot.workspaceId,
            monitor: monitor,
            gaps: gaps,
            state: snapshot.viewportState,
            workingArea: area,
            animationTime: animationTime
        )

        let diff = layoutDiff(
            windows: snapshot.windows,
            frames: frames,
            hiddenHandles: hiddenHandles,
            confirmedFocusedToken: snapshot.confirmedFocusedToken,
            borderFocusToken: snapshot.preferredFocusToken,
            engine: engine,
            directBorderUpdate: true,
            isInteractionWorkspace: snapshot.isInteractionWorkspace,
            canRestoreHiddenWorkspaceWindows: snapshot.isActiveWorkspace
        )

        return WorkspaceLayoutPlan(
            workspaceId: snapshot.workspaceId,
            monitor: snapshot.monitor,
            sessionPatch: WorkspaceSessionPatch(workspaceId: snapshot.workspaceId),
            diff: diff
        )
    }

    private func buildRelayoutPlan(
        snapshot: NiriWorkspaceSnapshot,
        engine: NiriLayoutEngine,
        monitor: Monitor
    ) -> WorkspaceLayoutPlan {
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
            state: &state,
            windowTokens: windowTokens,
            currentSelection: currentSelection,
            removedNodeId: snapshot.removalSeed?.removedNodeId
        )

        let newTokens = syncAndInsert(
            pass: pass,
            state: &state,
            windowTokens: windowTokens,
            removal: removal,
            preferredFocusToken: snapshot.preferredFocusToken
        )

        for window in snapshot.windows {
            engine.updateWindowConstraints(for: window.token, constraints: window.constraints)
        }

        let selection = resolveSelection(
            pass: pass,
            state: &state,
            windowTokens: windowTokens,
            removal: removal,
            snapshot: snapshot
        )

        let arrival = handleNewWindowArrival(
            pass: pass,
            state: &state,
            newTokens: newTokens,
            existingHandleIds: removal.existingHandleIds,
            snapshot: snapshot
        )

        return computeLayoutPlan(
            pass: pass,
            state: state,
            rememberedFocusToken: arrival.rememberedFocusToken ?? selection.rememberedFocusToken,
            newWindowToken: arrival.newWindowToken,
            viewportNeedsRecalc: selection.viewportNeedsRecalc,
            snapshot: snapshot
        )
    }

    private func processWindowRemovals(
        pass: NiriLayoutPass,
        state: inout ViewportState,
        windowTokens: [WindowToken],
        currentSelection: NodeId?,
        removedNodeId: NodeId?
    ) -> RemovalContext {
        let existingHandleIds = pass.engine.root(for: pass.wsId)?.windowIdSet ?? []
        let currentHandleIds = Set(windowTokens)
        let removedHandleIds = existingHandleIds.subtracting(currentHandleIds)

        var precomputedFallback: NodeId?
        var originalColumnIndex: Int?
        var columnRemovalResult: NiriLayoutEngine.ColumnRemovalResult?

        let wasEmptyBeforeSync = pass.engine.columns(in: pass.wsId).isEmpty

        for removedHandleId in removedHandleIds {
            guard let window = pass.engine.findNode(for: removedHandleId),
                  let col = pass.engine.column(of: window),
                  let colIdx = pass.engine.columnIndex(of: col, in: pass.wsId) else { continue }

            let allWindowsInColumnRemoved = col.windowNodes.allSatisfy { w in
                !currentHandleIds.contains(w.token)
            }

            if allWindowsInColumnRemoved && columnRemovalResult == nil {
                originalColumnIndex = colIdx
                columnRemovalResult = pass.engine.animateColumnsForRemoval(
                    columnIndex: colIdx,
                    in: pass.wsId,
                    state: &state,
                    gaps: pass.gap
                )
            }

            let nodeIdForFallback = removedNodeId ?? currentSelection
            if window.id == nodeIdForFallback {
                precomputedFallback = pass.engine.fallbackSelectionOnRemoval(
                    removing: window.id,
                    in: pass.wsId
                )
            }
        }

        return RemovalContext(
            existingHandleIds: existingHandleIds,
            wasEmptyBeforeSync: wasEmptyBeforeSync,
            columnRemovalResult: columnRemovalResult,
            precomputedFallback: precomputedFallback,
            originalColumnIndex: originalColumnIndex
        )
    }

    private func syncAndInsert(
        pass: NiriLayoutPass,
        state: inout ViewportState,
        windowTokens: [WindowToken],
        removal: RemovalContext,
        preferredFocusToken: WindowToken?
    ) -> [WindowToken] {
        let currentSelection = state.selectedNodeId
        _ = pass.engine.syncWindows(
            windowTokens,
            in: pass.wsId,
            selectedNodeId: currentSelection,
            focusedToken: preferredFocusToken
        )
        let newTokens = windowTokens.filter { !removal.existingHandleIds.contains($0) }

        for col in pass.engine.columns(in: pass.wsId) {
            if col.cachedWidth <= 0 {
                col.resolveAndCacheWidth(workingAreaWidth: pass.insetFrame.width, gaps: pass.gap)
            }
        }

        if !removal.wasEmptyBeforeSync, !newTokens.isEmpty {
            var newColumnData: [(col: NiriContainer, colIdx: Int)] = []
            for newToken in newTokens {
                if let node = pass.engine.findNode(for: newToken),
                   let col = pass.engine.column(of: node),
                   let colIdx = pass.engine.columnIndex(of: col, in: pass.wsId)
                {
                    if !newColumnData.contains(where: { $0.col.id == col.id }) {
                        newColumnData.append((col, colIdx))
                    }
                }
            }

            let originalActiveIdx = state.activeColumnIndex
            let insertedBeforeActive = newColumnData.filter { $0.colIdx <= originalActiveIdx }
            if !insertedBeforeActive.isEmpty, removal.columnRemovalResult == nil {
                let totalInsertedWidth = insertedBeforeActive.reduce(CGFloat(0)) { total, data in
                    total + data.col.cachedWidth + pass.gap
                }
                state.viewOffsetPixels.offset(delta: Double(-totalInsertedWidth))
                state.activeColumnIndex = originalActiveIdx + insertedBeforeActive.count
            }

            let sortedNewColumns = newColumnData.sorted { $0.colIdx < $1.colIdx }
            for addedData in sortedNewColumns {
                pass.engine.animateColumnsForAddition(
                    columnIndex: addedData.colIdx,
                    in: pass.wsId,
                    state: state,
                    gaps: pass.gap,
                    workingAreaWidth: pass.insetFrame.width
                )
            }
        }

        return newTokens
    }

    private func resolveSelection(
        pass: NiriLayoutPass,
        state: inout ViewportState,
        windowTokens: [WindowToken],
        removal: RemovalContext,
        snapshot: NiriWorkspaceSnapshot
    ) -> (viewportNeedsRecalc: Bool, rememberedFocusToken: WindowToken?) {
        state.displayRefreshRate = snapshot.displayRefreshRate

        if let result = removal.columnRemovalResult {
            if let prevOffset = state.activatePrevColumnOnRemoval {
                state.viewOffsetPixels = .static(prevOffset)
                state.activatePrevColumnOnRemoval = nil
            }

            if let fallback = result.fallbackSelectionId {
                state.selectedNodeId = fallback
            } else if let selectedId = state.selectedNodeId, pass.engine.findNode(by: selectedId) == nil {
                state.selectedNodeId = removal.precomputedFallback
                    ?? pass.engine.validateSelection(selectedId, in: pass.wsId)
            }
        } else {
            if let selectedId = state.selectedNodeId {
                if pass.engine.findNode(by: selectedId) == nil {
                    state.selectedNodeId = removal.precomputedFallback
                        ?? pass.engine.validateSelection(selectedId, in: pass.wsId)
                }
            }
        }

        if state.selectedNodeId == nil {
            if let firstToken = windowTokens.first,
               let firstNode = pass.engine.findNode(for: firstToken)
            {
                state.selectedNodeId = firstNode.id
            }
        }

        let usesSingleWindowAspectRatio = pass.engine.singleWindowLayoutContext(in: pass.wsId) != nil
        if usesSingleWindowAspectRatio {
            resetViewportForSingleWindowAspectRatio(state: &state)
        }

        let offsetBefore = state.viewOffsetPixels.current()
        var viewportNeedsRecalc = false

        let isGestureOrAnimation = state.viewOffsetPixels.isGesture || state.viewOffsetPixels.isAnimating

        for col in pass.engine.columns(in: pass.wsId) {
            if col.cachedWidth <= 0 {
                col.resolveAndCacheWidth(workingAreaWidth: pass.insetFrame.width, gaps: pass.gap)
            }
        }

        if !usesSingleWindowAspectRatio,
           !isGestureOrAnimation,
           snapshot.isActiveWorkspace,
           let selectedId = state.selectedNodeId,
           let selectedNode = pass.engine.findNode(by: selectedId)
        {
            if let restoreOffset = removal.columnRemovalResult?.restorePreviousViewOffset {
                state.viewOffsetPixels = .static(restoreOffset)
            } else {
                pass.engine.ensureSelectionVisible(
                    node: selectedNode,
                    in: pass.wsId,
                    state: &state,
                    workingFrame: pass.insetFrame,
                    gaps: pass.gap,
                    fromContainerIndex: removal.originalColumnIndex
                )
            }
            if abs(state.viewOffsetPixels.current() - offsetBefore) > 1 {
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
        state: inout ViewportState,
        newTokens: [WindowToken],
        existingHandleIds: Set<WindowToken>,
        snapshot: NiriWorkspaceSnapshot
    ) -> (newWindowToken: WindowToken?, rememberedFocusToken: WindowToken?) {
        let wasEmpty = existingHandleIds.isEmpty

        var newWindowToken: WindowToken?
        var rememberedFocusToken: WindowToken?
        if snapshot.hasCompletedInitialRefresh,
           let newToken = newTokens.last,
           let newNode = pass.engine.findNode(for: newToken),
           snapshot.isActiveWorkspace
        {
            state.selectedNodeId = newNode.id

            if wasEmpty {
                if pass.engine.singleWindowLayoutContext(in: pass.wsId) != nil {
                    resetViewportForSingleWindowAspectRatio(state: &state)
                } else {
                    let cols = pass.engine.columns(in: pass.wsId)
                    let settings = pass.engine.effectiveSettings(in: pass.wsId)
                    state.transitionToColumn(
                        0,
                        columns: cols,
                        gap: pass.gap,
                        viewportWidth: pass.insetFrame.width,
                        animate: false,
                        centerMode: settings.centerFocusedColumn,
                        alwaysCenterSingleColumn: settings.alwaysCenterSingleColumn
                    )
                }
            } else if let newCol = pass.engine.column(of: newNode),
                      let newColIdx = pass.engine.columnIndex(of: newCol, in: pass.wsId) {
                if newCol.cachedWidth <= 0 {
                    newCol.resolveAndCacheWidth(workingAreaWidth: pass.insetFrame.width, gaps: pass.gap)
                }

                let shouldRestorePrevOffset = newColIdx == state.activeColumnIndex + 1
                let offsetBeforeActivation = state.stationary()

                pass.engine.ensureSelectionVisible(
                    node: newNode,
                    in: pass.wsId,
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
            newWindowToken = newToken
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
                        displayRefreshRate: state.displayRefreshRate
                    )
                }
            }
        }

        return (newWindowToken, rememberedFocusToken)
    }

    private func resetViewportForSingleWindowAspectRatio(state: inout ViewportState) {
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)
        state.activatePrevColumnOnRemoval = nil
        state.viewOffsetToRestore = nil
        state.selectionProgress = 0
    }

    private func computeLayoutPlan(
        pass: NiriLayoutPass,
        state: ViewportState,
        rememberedFocusToken: WindowToken?,
        newWindowToken: WindowToken?,
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
            viewFrame: snapshot.monitor.frame,
            scale: snapshot.monitor.scale
        )

        let (frames, hiddenHandles) = pass.engine.calculateCombinedLayoutUsingPools(
            in: pass.wsId,
            monitor: pass.monitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: nil
        )

        let hasColumnAnimations = pass.engine.hasAnyColumnAnimationsRunning(in: pass.wsId)
        var directives: [AnimationDirective] = []

        if !snapshot.useScrollAnimationPath {
            if viewportNeedsRecalc, newWindowToken == nil {
                directives.append(.startNiriScroll(workspaceId: pass.wsId))
            } else if hasColumnAnimations {
                directives.append(.startNiriScroll(workspaceId: pass.wsId))
            }
        }

        if let newWindowToken {
            directives.append(.startNiriScroll(workspaceId: pass.wsId))
            directives.append(.activateWindow(token: newWindowToken))
        }

        if let removalSeed = snapshot.removalSeed, !removalSeed.oldFrames.isEmpty {
            let newFrames = pass.engine.captureWindowFrames(in: pass.wsId)
            let animationsTriggered = pass.engine.triggerMoveAnimations(
                in: pass.wsId,
                oldFrames: removalSeed.oldFrames,
                newFrames: newFrames
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
            confirmedFocusedToken: snapshot.confirmedFocusedToken,
            borderFocusToken: rememberedFocusToken,
            engine: pass.engine,
            directBorderUpdate: snapshot.useScrollAnimationPath,
            isInteractionWorkspace: snapshot.isInteractionWorkspace,
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
        confirmedFocusedToken: WindowToken?,
        borderFocusToken: WindowToken?,
        engine: NiriLayoutEngine,
        directBorderUpdate: Bool,
        isInteractionWorkspace: Bool,
        canRestoreHiddenWorkspaceWindows: Bool
    ) -> WorkspaceLayoutDiff {
        var diff = WorkspaceLayoutDiff()
        let suspendedTokens = Set(
            windows.lazy
                .filter(\.isNativeFullscreenSuspended)
                .map(\.token)
        )
        let effectiveBorderToken = if directBorderUpdate && isInteractionWorkspace {
            borderFocusToken ?? confirmedFocusedToken
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

                let activeIndex = min(max(0, column.activeTileIdx), windows.count - 1)
                let activeHandle = windows[activeIndex].handle
                let activeWindowId = controller.workspaceManager.entry(for: activeHandle)?.windowId

                infos.append(
                    TabbedColumnOverlayInfo(
                        workspaceId: workspace.id,
                        columnId: column.id,
                        columnFrame: frame,
                        tabCount: windows.count,
                        activeIndex: activeIndex,
                        activeWindowId: activeWindowId
                    )
                )
            }
        }

        controller.tabbedOverlayManager.updateOverlays(infos)
    }

    func selectTabInNiri(workspaceId: WorkspaceDescriptor.ID, columnId: NodeId, index: Int) {
        guard let controller, let engine = controller.niriEngine else { return }
        guard let column = engine.columns(in: workspaceId).first(where: { $0.id == columnId }) else { return }

        let windows = column.windowNodes
        guard windows.indices.contains(index) else { return }

        column.setActiveTileIdx(index)
        engine.updateTabbedColumnVisibility(column: column)

        let target = windows[index]
        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        if let monitor = controller.workspaceManager.monitor(for: workspaceId) {
            let gap = CGFloat(controller.workspaceManager.gaps)
            engine.ensureSelectionVisible(
                node: target,
                in: workspaceId,
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

    // MARK: - Layout Capability Commands

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
        let gap = CGFloat(controller.workspaceManager.gaps)
        let workingFrame = controller.insetWorkingFrame(for: monitor)

        for col in engine.columns(in: wsId) where col.cachedWidth <= 0 {
            col.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gap)
        }

        if let newNode = engine.focusTarget(
            direction: direction,
            currentSelection: currentNode,
            in: wsId,
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
        withNiriWorkspaceContext { engine, wsId, state, _, _, _ in
            guard let currentId = state.selectedNodeId,
                  let currentNode = engine.findNode(by: currentId),
                  let windowNode = currentNode as? NiriWindow
            else { return }

            engine.toggleFullscreen(windowNode, state: &state)

            controller.layoutRefreshController.requestImmediateRelayout(reason: .layoutCommand)
            if state.viewOffsetPixels.isAnimating {
                controller.layoutRefreshController.startScrollAnimation(for: wsId)
            }
        }
    }

    func cycleSize(forward: Bool) {
        guard let controller else { return }
        withNiriWorkspaceContext { engine, wsId, state, monitor, workingFrame, gaps in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId) as? NiriWindow,
                  let column = engine.findColumn(containing: windowNode, in: wsId)
            else { return }

            engine.toggleColumnWidth(
                column,
                forwards: forward,
                in: wsId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
            controller.layoutRefreshController.requestImmediateRelayout(reason: .layoutCommand)
            controller.layoutRefreshController.startScrollAnimation(for: wsId)
        }
    }

    func balanceSizes() {
        guard let controller else { return }
        withNiriWorkspaceContext { engine, wsId, _, _, workingFrame, gaps in
            engine.balanceSizes(
                in: wsId,
                workingAreaWidth: workingFrame.width,
                gaps: gaps
            )
            controller.layoutRefreshController.requestImmediateRelayout(reason: .layoutCommand)
            if engine.hasAnyColumnAnimationsRunning(in: wsId) {
                controller.layoutRefreshController.startScrollAnimation(for: wsId)
            }
        }
    }

    // MARK: - Layout Engine Configuration

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

        for workspace in controller.workspaceManager.workspaces {
            guard let monitor = controller.workspaceManager.monitor(for: workspace.id) else { continue }
            engine.moveWorkspace(workspace.id, to: monitor.id, monitor: monitor)
        }

        for monitor in currentMonitors {
            if let niriMonitor = engine.monitor(for: monitor.id) {
                niriMonitor.animationClock = controller.animationClock
            }
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

        if options.activateWindow {
            engine.activateWindow(node.id)
        }

        if options.ensureVisible, let monitor = controller.workspaceManager.monitor(for: workspaceId) {
            let gap = CGFloat(controller.workspaceManager.gaps)
            let workingFrame = controller.insetWorkingFrame(for: monitor)
            engine.ensureSelectionVisible(
                node: node,
                in: workspaceId,
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
        }

        if options.layoutRefresh {
            let focusToken = options.axFocus ? (node as? NiriWindow)?.token : nil
            controller.layoutRefreshController.requestImmediateRelayout(
                reason: .layoutCommand
            ) { [weak controller] in
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
            let workingFrame = controller.insetWorkingFrame(for: monitor)
            let gaps = CGFloat(controller.workspaceManager.gaps)

            let ctx = NiriOperationContext(
                controller: controller,
                engine: engine,
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
        perform: (NiriLayoutEngine, WorkspaceDescriptor.ID, inout ViewportState, Monitor, CGRect, CGFloat) -> Void
    ) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }
        guard let monitor = controller.workspaceManager.monitor(for: wsId) else { return }
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let gaps = CGFloat(controller.workspaceManager.gaps)
        controller.workspaceManager.withNiriViewportState(for: wsId) { state in
            perform(engine, wsId, &state, monitor, workingFrame, gaps)
        }
    }

    func withNiriWorkspaceContext(
        for workspaceId: WorkspaceDescriptor.ID,
        perform: (NiriLayoutEngine, WorkspaceDescriptor.ID, inout ViewportState, Monitor, CGRect, CGFloat) -> Void
    ) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }
        guard let monitor = controller.workspaceManager.monitor(for: workspaceId) else { return }
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let gaps = CGFloat(controller.workspaceManager.gaps)
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            perform(engine, workspaceId, &state, monitor, workingFrame, gaps)
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
        withNiriWorkspaceContext(for: workspaceId) { engine, wsId, state, monitor, workingFrame, gaps in
            guard let source = engine.findNode(for: handle) else { return }
            guard let target = engine.findNode(for: targetHandle) else { return }
            didMove = engine.insertWindowByMove(
                sourceWindowId: source.id,
                targetWindowId: target.id,
                position: position,
                in: wsId,
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
        withNiriWorkspaceContext(for: workspaceId) { engine, wsId, state, monitor, workingFrame, gaps in
            guard let window = engine.findNode(for: handle) else { return }
            didMove = engine.insertWindowInNewColumn(
                window,
                insertIndex: insertIndex,
                in: wsId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }
        return didMove
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
    let wsId: WorkspaceDescriptor.ID
    let windowNode: NiriWindow
    let monitor: Monitor
    let workingFrame: CGRect
    let gaps: CGFloat

    private func hasPendingAnimationWork(state: ViewportState) -> Bool {
        state.viewOffsetPixels.isAnimating
            || engine.hasAnyWindowAnimationsRunning(in: wsId)
            || engine.hasAnyColumnAnimationsRunning(in: wsId)
    }

    func commitWithPredictedAnimation(
        state: ViewportState,
        oldFrames: [WindowToken: CGRect]
    ) -> Bool {
        let scale = NSScreen.screens.first(where: { $0.displayId == monitor.displayId })?
            .backingScaleFactor ?? 2.0
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
            animationTime: animationTime
        ).frames
        _ = engine.triggerMoveAnimations(in: wsId, oldFrames: oldFrames, newFrames: newFrames)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .layoutCommand)
        return hasPendingAnimationWork(state: state)
    }

    func commitWithCapturedAnimation(
        state: ViewportState,
        oldFrames: [WindowToken: CGRect]
    ) -> Bool {
        controller.layoutRefreshController.requestImmediateRelayout(reason: .layoutCommand)
        let newFrames = engine.captureWindowFrames(in: wsId)
        _ = engine.triggerMoveAnimations(in: wsId, oldFrames: oldFrames, newFrames: newFrames)
        return hasPendingAnimationWork(state: state)
    }

    func commitSimple(state: ViewportState) -> Bool {
        controller.layoutRefreshController.requestImmediateRelayout(reason: .layoutCommand)
        return hasPendingAnimationWork(state: state)
    }
}

extension NiriLayoutHandler: LayoutFocusable, LayoutSizable {}

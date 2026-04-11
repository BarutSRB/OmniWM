import AppKit
import COmniWMKernels
import Foundation

enum NiriTopologyKernelOperation {
    case addWindow
    case removeWindow
    case syncWindows
    case focus
    case focusColumn
    case focusWindowInColumn
    case focusCombined
    case ensureVisible
    case moveColumn
    case moveWindow
    case columnRemoval
    case insertWindowInNewColumn
    case swapWindows
    case insertWindowByMove

    var rawValue: UInt32 {
        switch self {
        case .addWindow: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_ADD_WINDOW)
        case .removeWindow: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_REMOVE_WINDOW)
        case .syncWindows: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_SYNC_WINDOWS)
        case .focus: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_FOCUS)
        case .focusColumn: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_FOCUS_COLUMN)
        case .focusWindowInColumn: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_FOCUS_WINDOW_IN_COLUMN)
        case .focusCombined: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_FOCUS_COMBINED)
        case .ensureVisible: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_ENSURE_VISIBLE)
        case .moveColumn: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_MOVE_COLUMN)
        case .moveWindow: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_MOVE_WINDOW)
        case .columnRemoval: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_COLUMN_REMOVAL)
        case .insertWindowInNewColumn: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_INSERT_WINDOW_IN_NEW_COLUMN)
        case .swapWindows: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_SWAP_WINDOWS)
        case .insertWindowByMove: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_INSERT_WINDOW_BY_MOVE)
        }
    }
}

private enum NiriTopologyViewportAction: UInt32 {
    case none = 0
    case deltaOnly = 1
    case setStatic = 2
    case animate = 3
}

enum NiriTopologyEffectKind: UInt32 {
    case none = 0
    case removeColumn = 1
    case addColumn = 2
    case moveColumn = 3
    case expelWindow = 4
    case consumeWindow = 5
    case reorderWindow = 6
}

private extension Direction {
    var niriTopologyRawValue: UInt32 {
        switch self {
        case .left: UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_LEFT)
        case .right: UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_RIGHT)
        case .up: UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_UP)
        case .down: UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_DOWN)
        }
    }
}

private extension Monitor.Orientation {
    var niriTopologyRawValue: UInt32 {
        switch self {
        case .horizontal: UInt32(OMNIWM_NIRI_ORIENTATION_HORIZONTAL)
        case .vertical: UInt32(OMNIWM_NIRI_ORIENTATION_VERTICAL)
        }
    }
}

private extension CenterFocusedColumn {
    var niriTopologyRawValue: UInt32 {
        switch self {
        case .never: UInt32(OMNIWM_CENTER_FOCUSED_COLUMN_NEVER)
        case .always: UInt32(OMNIWM_CENTER_FOCUSED_COLUMN_ALWAYS)
        case .onOverflow: UInt32(OMNIWM_CENTER_FOCUSED_COLUMN_ON_OVERFLOW)
        }
    }
}

private extension SizingMode {
    var niriTopologyRawValue: UInt8 {
        switch self {
        case .normal:
            UInt8(OMNIWM_NIRI_WINDOW_SIZING_NORMAL)
        case .fullscreen:
            UInt8(OMNIWM_NIRI_WINDOW_SIZING_FULLSCREEN)
        }
    }
}

private extension InsertPosition {
    var niriTopologyInsertRawValue: Int {
        switch self {
        case .before, .swap:
            Int(OMNIWM_NIRI_TOPOLOGY_INSERT_BEFORE)
        case .after:
            Int(OMNIWM_NIRI_TOPOLOGY_INSERT_AFTER)
        }
    }
}

struct NiriTopologyKernelSnapshot {
    var rawColumns: ContiguousArray<omniwm_niri_topology_column_input>
    var rawWindows: ContiguousArray<omniwm_niri_topology_window_input>
    var columnById: [UInt64: NiriContainer]
    var windowById: [UInt64: NiriWindow]
    var windowIdByNodeId: [NodeId: UInt64]
    var windowIdByToken: [WindowToken: UInt64]
    var tokenByWindowId: [UInt64: WindowToken]
}

struct NiriTopologyKernelPlan {
    var result: omniwm_niri_topology_result
    var columns: ContiguousArray<omniwm_niri_topology_column_output>
    var windows: ContiguousArray<omniwm_niri_topology_window_output>
    var snapshot: NiriTopologyKernelSnapshot

    var effectKind: NiriTopologyEffectKind {
        NiriTopologyEffectKind(rawValue: result.effect_kind) ?? .none
    }

    var didApply: Bool {
        result.did_apply != 0
    }
}

extension NiriLayoutEngine {
    struct NiriTopologyAnimationPreparation {
        var columnPositionSnapshot: [NodeId: CGFloat]?
    }

    private func makeTopologyKernelSnapshot(
        in workspaceId: WorkspaceDescriptor.ID,
        extraTokens: [WindowToken]
    ) -> NiriTopologyKernelSnapshot {
        let root = ensureRoot(for: workspaceId)
        let columns = root.columns

        var columnById: [UInt64: NiriContainer] = [:]
        var windowById: [UInt64: NiriWindow] = [:]
        var windowIdByNodeId: [NodeId: UInt64] = [:]
        var windowIdByToken: [WindowToken: UInt64] = [:]
        var tokenByWindowId: [UInt64: WindowToken] = [:]
        var rawColumns = ContiguousArray<omniwm_niri_topology_column_input>()
        var rawWindows = ContiguousArray<omniwm_niri_topology_window_input>()

        rawColumns.reserveCapacity(columns.count)
        rawWindows.reserveCapacity(root.allWindows.count)

        var nextColumnId: UInt64 = 1
        var nextWindowId: UInt64 = 1

        for column in columns {
            let columnId = nextColumnId
            nextColumnId += 1
            columnById[columnId] = column

            let windowStart = rawWindows.count
            for window in column.windowNodes {
                let windowId = nextWindowId
                nextWindowId += 1
                rawWindows.append(
                    omniwm_niri_topology_window_input(
                        id: windowId,
                        sizing_mode: window.sizingMode.niriTopologyRawValue
                    )
                )
                windowById[windowId] = window
                windowIdByNodeId[window.id] = windowId
                windowIdByToken[window.token] = windowId
                tokenByWindowId[windowId] = window.token
            }

            rawColumns.append(
                omniwm_niri_topology_column_input(
                    id: columnId,
                    span: column.cachedWidth,
                    window_start_index: numericCast(windowStart),
                    window_count: numericCast(column.windowNodes.count),
                    active_window_index: Int32(clamping: column.activeTileIdx),
                    is_tabbed: column.isTabbed ? 1 : 0
                )
            )
        }

        for token in extraTokens where windowIdByToken[token] == nil {
            let windowId = nextWindowId
            nextWindowId += 1
            windowIdByToken[token] = windowId
            tokenByWindowId[windowId] = token
        }

        return NiriTopologyKernelSnapshot(
            rawColumns: rawColumns,
            rawWindows: rawWindows,
            columnById: columnById,
            windowById: windowById,
            windowIdByNodeId: windowIdByNodeId,
            windowIdByToken: windowIdByToken,
            tokenByWindowId: tokenByWindowId
        )
    }

    private func defaultNewColumnSpan(
        in workspaceId: WorkspaceDescriptor.ID,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> CGFloat {
        let resolved = resolvedColumnResetWidth(in: workspaceId)
        return max(1, (workingFrame.width - gaps) * resolved.proportion)
    }

    private func makeTopologyKernelInput(
        operation: NiriTopologyKernelOperation,
        workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        direction: Direction?,
        subjectWindowId: UInt64,
        targetWindowId: UInt64 = 0,
        insertIndex: Int = 0,
        targetIndex: Int = 0,
        fromColumnIndex: Int? = nil,
        previousActivePosition: CGFloat? = nil,
        resetForSingleWindow: Bool = false,
        motion: MotionSnapshot = .enabled,
        orientation: Monitor.Orientation = .horizontal,
        isActiveWorkspace: Bool = true,
        hasCompletedInitialRefresh: Bool = true
    ) -> omniwm_niri_topology_input {
        let settings = effectiveSettings(in: workspaceId)
        return omniwm_niri_topology_input(
            operation: operation.rawValue,
            direction: direction?.niriTopologyRawValue ?? UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_RIGHT),
            orientation: orientation.niriTopologyRawValue,
            center_mode: settings.centerFocusedColumn.niriTopologyRawValue,
            subject_window_id: subjectWindowId,
            target_window_id: targetWindowId,
            selected_window_id: 0,
            focused_window_id: 0,
            active_column_index: Int32(clamping: state.activeColumnIndex),
            insert_index: Int32(clamping: insertIndex),
            target_index: Int32(clamping: targetIndex),
            from_column_index: Int32(fromColumnIndex ?? -1),
            max_windows_per_column: UInt32(clamping: effectiveMaxWindowsPerColumn(in: workspaceId)),
            gap: gaps,
            viewport_span: orientation == .horizontal ? workingFrame.width : workingFrame.height,
            current_view_offset: state.viewOffsetPixels.current(),
            stationary_view_offset: state.stationary(),
            scale: displayScale(in: workspaceId),
            default_new_column_span: defaultNewColumnSpan(in: workspaceId, workingFrame: workingFrame, gaps: gaps),
            previous_active_position: previousActivePosition ?? 0,
            activate_prev_column_on_removal: state.activatePrevColumnOnRemoval ?? 0,
            infinite_loop: effectiveInfiniteLoop(in: workspaceId) ? 1 : 0,
            always_center_single_column: settings.alwaysCenterSingleColumn ? 1 : 0,
            animate: motion.animationsEnabled ? 1 : 0,
            has_previous_active_position: previousActivePosition == nil ? 0 : 1,
            has_activate_prev_column_on_removal: state.activatePrevColumnOnRemoval == nil ? 0 : 1,
            reset_for_single_window: resetForSingleWindow ? 1 : 0,
            is_active_workspace: isActiveWorkspace ? 1 : 0,
            has_completed_initial_refresh: hasCompletedInitialRefresh ? 1 : 0,
            viewport_is_gesture_or_animation: (state.viewOffsetPixels.isGesture || state.viewOffsetPixels.isAnimating) ?
                1 : 0
        )
    }

    func callTopologyKernel(
        operation: NiriTopologyKernelOperation,
        workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        direction: Direction? = nil,
        subject: NiriWindow? = nil,
        subjectToken: WindowToken? = nil,
        target: NiriWindow? = nil,
        focusedToken: WindowToken? = nil,
        desiredTokens: [WindowToken] = [],
        removedNodeIds: [NodeId] = [],
        insertIndex: Int = 0,
        targetIndex: Int = -1,
        fromColumnIndex: Int? = nil,
        previousActivePosition: CGFloat? = nil,
        resetForSingleWindow: Bool = false,
        motion: MotionSnapshot = .enabled,
        orientation: Monitor.Orientation = .horizontal,
        isActiveWorkspace: Bool = true,
        hasCompletedInitialRefresh: Bool = true
    ) -> NiriTopologyKernelPlan? {
        let extras = desiredTokens + [subjectToken].compactMap(\.self)
        let snapshot = makeTopologyKernelSnapshot(in: workspaceId, extraTokens: extras)
        let subjectId = subject.map { snapshot.windowIdByNodeId[$0.id] ?? 0 }
            ?? subjectToken.flatMap { snapshot.windowIdByToken[$0] }
            ?? 0
        let targetId = target.map { snapshot.windowIdByNodeId[$0.id] ?? 0 } ?? 0
        let selectedId = state.selectedNodeId.flatMap { snapshot.windowIdByNodeId[$0] } ?? 0
        let desiredIds = desiredTokens.compactMap { snapshot.windowIdByToken[$0] }
        let removedIds = removedNodeIds.compactMap { snapshot.windowIdByNodeId[$0] }

        var rawInput = makeTopologyKernelInput(
            operation: operation,
            workspaceId: workspaceId,
            state: state,
            workingFrame: workingFrame,
            gaps: gaps,
            direction: direction,
            subjectWindowId: subjectId,
            targetWindowId: targetId,
            insertIndex: insertIndex,
            targetIndex: targetIndex,
            fromColumnIndex: fromColumnIndex,
            previousActivePosition: previousActivePosition,
            resetForSingleWindow: resetForSingleWindow,
            motion: motion,
            orientation: orientation,
            isActiveWorkspace: isActiveWorkspace,
            hasCompletedInitialRefresh: hasCompletedInitialRefresh
        )
        rawInput.selected_window_id = selectedId
        rawInput.focused_window_id = focusedToken.flatMap { snapshot.windowIdByToken[$0] } ?? 0

        let columnCapacity = max(snapshot.rawColumns.count + desiredIds.count + 2, 1)
        let windowCapacity = max(snapshot.rawWindows.count + desiredIds.count + 1, 1)
        var columnOutputs = ContiguousArray(
            repeating: omniwm_niri_topology_column_output(
                id: 0,
                window_start_index: 0,
                window_count: 0,
                active_window_index: 0,
                is_tabbed: 0
            ),
            count: columnCapacity
        )
        var windowOutputs = ContiguousArray(
            repeating: omniwm_niri_topology_window_output(id: 0),
            count: windowCapacity
        )
        var result = omniwm_niri_topology_result()

        let status = snapshot.rawColumns.withUnsafeBufferPointer { columnBuffer in
            snapshot.rawWindows.withUnsafeBufferPointer { windowBuffer in
                desiredIds.withUnsafeBufferPointer { desiredBuffer in
                    removedIds.withUnsafeBufferPointer { removedBuffer in
                        columnOutputs.withUnsafeMutableBufferPointer { columnOutputBuffer in
                            windowOutputs.withUnsafeMutableBufferPointer { windowOutputBuffer in
                                omniwm_niri_topology_plan(
                                    &rawInput,
                                    columnBuffer.baseAddress,
                                    columnBuffer.count,
                                    windowBuffer.baseAddress,
                                    windowBuffer.count,
                                    desiredBuffer.baseAddress,
                                    desiredBuffer.count,
                                    removedBuffer.baseAddress,
                                    removedBuffer.count,
                                    columnOutputBuffer.baseAddress,
                                    columnOutputBuffer.count,
                                    windowOutputBuffer.baseAddress,
                                    windowOutputBuffer.count,
                                    &result
                                )
                            }
                        }
                    }
                }
            }
        }

        precondition(
            status == OMNIWM_KERNELS_STATUS_OK,
            "omniwm_niri_topology_plan returned \(status)"
        )

        columnOutputs.removeSubrange(Int(result.column_count) ..< columnOutputs.count)
        windowOutputs.removeSubrange(Int(result.window_count) ..< windowOutputs.count)
        return NiriTopologyKernelPlan(
            result: result,
            columns: columnOutputs,
            windows: windowOutputs,
            snapshot: snapshot
        )
    }

    private func applyTopology(_ plan: NiriTopologyKernelPlan, in workspaceId: WorkspaceDescriptor.ID) {
        let root = ensureRoot(for: workspaceId)
        let outputWindowIds = Set(plan.windows.map(\.id))
        let existingWindows = root.allWindows

        for window in existingWindows where !outputWindowIds.contains(plan.snapshot.windowIdByNodeId[window.id] ?? 0) {
            closingTokens.remove(window.token)
            tokenToNode.removeValue(forKey: window.token)
        }

        var windowById = plan.snapshot.windowById
        for output in plan.windows where windowById[output.id] == nil {
            guard let token = plan.snapshot.tokenByWindowId[output.id] else { continue }
            let window = NiriWindow(token: token)
            windowById[output.id] = window
            tokenToNode[token] = window
        }

        var newColumns: [NiriContainer] = []
        newColumns.reserveCapacity(plan.columns.count)

        for columnOutput in plan.columns {
            let column = plan.snapshot.columnById[columnOutput.id] ?? {
                let column = NiriContainer()
                initializeNewColumnWidth(column, in: workspaceId)
                return column
            }()
            if column.windowNodes.isEmpty, columnOutput.window_count > 0 {
                initializeNewColumnWidth(column, in: workspaceId)
            }
            let start = Int(columnOutput.window_start_index)
            let count = Int(columnOutput.window_count)
            let end = min(start + count, plan.windows.count)
            let columnWindows = plan.windows[start ..< end].compactMap { windowById[$0.id] }
            column.replaceChildren(columnWindows)
            column.setActiveTileIdx(Int(columnOutput.active_window_index))
            if column.isTabbed {
                updateTabbedColumnVisibility(column: column)
            } else {
                for window in column.windowNodes {
                    window.isHiddenInTabbedMode = false
                }
            }
            newColumns.append(column)
        }

        root.replaceChildren(newColumns)
    }

    func applyTopologyViewport(
        _ result: omniwm_niri_topology_result,
        state: inout ViewportState,
        motion: MotionSnapshot,
        animationConfig: SpringConfig? = nil,
        scale: CGFloat = 2.0
    ) {
        if abs(result.viewport_offset_delta) > .ulpOfOne {
            state.viewOffsetPixels.offset(delta: result.viewport_offset_delta)
        }

        if result.has_restore_previous_view_offset != 0 {
            state.viewOffsetPixels = .static(CGFloat(result.restore_previous_view_offset))
        } else {
            switch NiriTopologyViewportAction(rawValue: result.viewport_action) ?? .none {
            case .deltaOnly, .none:
                if !motion.animationsEnabled, state.viewOffsetPixels.isAnimating {
                    state.viewOffsetPixels = .static(state.viewOffsetPixels.target())
                }
                break
            case .setStatic:
                state.viewOffsetPixels = .static(CGFloat(result.viewport_target_offset))
            case .animate:
                state.animateToOffset(
                    CGFloat(result.viewport_target_offset),
                    motion: motion,
                    config: animationConfig,
                    scale: scale
                )
            }
        }

        if result.active_column_index >= 0 {
            state.activeColumnIndex = Int(result.active_column_index)
        }
        if result.should_clear_activate_prev_column_on_removal != 0 {
            state.activatePrevColumnOnRemoval = nil
        }
        if result.has_activate_prev_column_on_removal != 0 {
            state.activatePrevColumnOnRemoval = CGFloat(result.activate_prev_column_on_removal)
        }
        state.viewOffsetToRestore = nil
        state.selectionProgress = 0
    }

    @discardableResult
    func applyTopologyPlan(
        _ plan: NiriTopologyKernelPlan,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        motion: MotionSnapshot,
        animationConfig: SpringConfig? = nil
    ) -> NiriWindow? {
        let previousSelectedNodeId = state.selectedNodeId
        applyTopology(plan, in: workspaceId)
        applyTopologyViewport(
            plan.result,
            state: &state,
            motion: motion,
            animationConfig: animationConfig,
            scale: displayScale(in: workspaceId)
        )

        if !plan.didApply {
            state.selectedNodeId = previousSelectedNodeId
            return nil
        }

        state.selectedNodeId = nil
        if plan.result.selected_window_id != 0,
           let selected = findWindow(in: plan, id: plan.result.selected_window_id)
        {
            state.selectedNodeId = selected.id
            activateWindow(selected.id)
            return selected
        }
        return nil
    }

    func applyTopologyPlan(_ plan: NiriTopologyKernelPlan, in workspaceId: WorkspaceDescriptor.ID) {
        applyTopology(plan, in: workspaceId)
    }

    func findWindow(in plan: NiriTopologyKernelPlan, id: UInt64) -> NiriWindow? {
        guard let token = plan.snapshot.tokenByWindowId[id] else { return nil }
        return findNode(for: token)
    }

    func prepareAnimationsForTopologyPlan(
        _ plan: NiriTopologyKernelPlan,
        in workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        gaps: CGFloat,
        motion: MotionSnapshot
    ) -> NiriTopologyAnimationPreparation {
        var preparation = NiriTopologyAnimationPreparation()

        switch plan.effectKind {
        case .moveColumn:
            let cols = columns(in: workspaceId)
            var positions: [NodeId: CGFloat] = [:]
            positions.reserveCapacity(cols.count)
            for (index, column) in cols.enumerated() {
                positions[column.id] = state.columnX(at: index, columns: cols, gap: gaps)
            }
            preparation.columnPositionSnapshot = positions

        case .consumeWindow, .removeColumn:
            if plan.result.source_column_index >= 0 {
                var animationState = state
                _ = animateColumnsForRemoval(
                    columnIndex: Int(plan.result.source_column_index),
                    in: workspaceId,
                    motion: motion,
                    state: &animationState,
                    gaps: gaps
                )
            }

        case .none, .addColumn, .expelWindow, .reorderWindow:
            break
        }

        return preparation
    }

    func finalizeAnimationsForTopologyPlan(
        _ plan: NiriTopologyKernelPlan,
        preparation: NiriTopologyAnimationPreparation,
        in workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        motion: MotionSnapshot
    ) {
        switch plan.effectKind {
        case .moveColumn:
            guard let positions = preparation.columnPositionSnapshot else { return }
            let cols = columns(in: workspaceId)
            for (index, column) in cols.enumerated() {
                guard let oldPosition = positions[column.id] else { continue }
                let newPosition = state.columnX(at: index, columns: cols, gap: gaps)
                let displacement = oldPosition - newPosition
                guard abs(displacement) > 0.5 else { continue }
                if column.hasMoveAnimationRunning {
                    column.offsetMoveAnimCurrent(displacement)
                } else {
                    column.animateMoveFrom(
                        displacement: CGPoint(x: displacement, y: 0),
                        clock: animationClock,
                        config: windowMovementAnimationConfig,
                        displayRefreshRate: displayRefreshRate,
                        animated: motion.animationsEnabled
                    )
                }
            }

        case .addColumn, .expelWindow:
            if plan.result.target_column_index >= 0 {
                animateColumnsForAddition(
                    columnIndex: Int(plan.result.target_column_index),
                    in: workspaceId,
                    motion: motion,
                    state: state,
                    gaps: gaps,
                    workingAreaWidth: workingFrame.width
                )
            }

        case .none, .removeColumn, .consumeWindow, .reorderWindow:
            break
        }
    }

    func topologyInsertIndex(for position: InsertPosition) -> Int {
        position.niriTopologyInsertRawValue
    }

    func topologyFallbackSelectionOnRemoval(
        removing nodeId: NodeId,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NodeId? {
        let state = ViewportState()
        let subject = findNode(by: nodeId) as? NiriWindow
        guard let subject,
              let plan = callTopologyKernel(
                  operation: .removeWindow,
                  workspaceId: workspaceId,
                  state: state,
                  workingFrame: .zero,
                  gaps: 0,
                  subject: subject
              ) else { return nil }

        if plan.result.fallback_window_id != 0,
           let window = findWindow(in: plan, id: plan.result.fallback_window_id)
        {
            return window.id
        }
        return nil
    }
}

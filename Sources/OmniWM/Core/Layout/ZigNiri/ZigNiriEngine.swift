import CZigLayout
import CoreGraphics
import Foundation
import QuartzCore

final class ZigNiriEngine {
    private struct RuntimeSelectionAnchor {
        let windowId: NodeId?
        let columnId: NodeId?
        let rowIndex: Int?
    }

    private struct RuntimeStateMutationOutcome {
        let rc: Int32
        let applied: Bool
    }

    private struct ActiveInteractiveResize {
        let windowId: NodeId
        let workspaceId: WorkspaceDescriptor.ID
        let edges: ZigNiriResizeEdge
        let startMouseLocation: CGPoint
        let columnId: NodeId?
        let originalColumnWidth: CGFloat
        let minColumnWidth: CGFloat
        let maxColumnWidth: CGFloat
        let originalWindowWeight: CGFloat
        let minWindowWeight: CGFloat
        let maxWindowWeight: CGFloat
        let pixelsPerWeight: CGFloat
        let originalViewOffset: CGFloat?
        let orientation: Monitor.Orientation
    }

    private enum StructuralAnimationKind {
        case mutation(fromFramesByNodeId: [NodeId: CGRect])
        case workspaceSwitch
    }

    private struct StructuralAnimationState {
        let kind: StructuralAnimationKind
        let startedAt: TimeInterval
        let duration: TimeInterval
    }

    private var maxVisibleColumns: Int
    private var maxWindowsPerColumn: Int
    private var infiniteLoop: Bool

    private var workspaceViews: [WorkspaceDescriptor.ID: ZigNiriWorkspaceView] = [:]
    private var windowNodeIdsByHandle: [WindowHandle: NodeId] = [:]
    private var windowHandlesByNodeId: [NodeId: WindowHandle] = [:]
    private var windowHandlesByUUID: [UUID: WindowHandle] = [:]
    private var dirtyWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
    private var workspaceNodeIds: [WorkspaceDescriptor.ID: Set<NodeId>] = [:]
    private var nodeReferenceCounts: [NodeId: Int] = [:]

    private var layoutContexts: [WorkspaceDescriptor.ID: ZigNiriLayoutKernel.LayoutContext] = [:]

    // Runtime state does not encode these today, so we keep them in Swift side maps.
    private var windowSizingModesByNodeId: [NodeId: SizingMode] = [:]
    private var savedWindowHeightsByNodeId: [NodeId: WeightedSize] = [:]

    private var interactiveMoveState: ZigNiriInteractiveMoveState?
    private var interactiveResizeState: ActiveInteractiveResize?
    private var structuralAnimationsByWorkspace: [WorkspaceDescriptor.ID: StructuralAnimationState] = [:]

    init(
        maxWindowsPerColumn: Int = 3,
        maxVisibleColumns: Int = 3,
        infiniteLoop: Bool = false
    ) {
        self.maxWindowsPerColumn = max(1, min(10, maxWindowsPerColumn))
        self.maxVisibleColumns = max(1, min(5, maxVisibleColumns))
        self.infiniteLoop = infiniteLoop
    }

    func updateConfiguration(
        maxWindowsPerColumn: Int? = nil,
        maxVisibleColumns: Int? = nil,
        infiniteLoop: Bool? = nil
    ) {
        if let maxWindowsPerColumn {
            self.maxWindowsPerColumn = max(1, min(10, maxWindowsPerColumn))
        }
        if let maxVisibleColumns {
            self.maxVisibleColumns = max(1, min(5, maxVisibleColumns))
        }
        if let infiniteLoop {
            self.infiniteLoop = infiniteLoop
        }
    }

    func nodeId(for handle: WindowHandle) -> NodeId? {
        windowNodeIdsByHandle[handle]
    }

    func windowHandle(for nodeId: NodeId) -> WindowHandle? {
        windowHandlesByNodeId[nodeId]
    }

    func workspaceView(for workspaceId: WorkspaceDescriptor.ID) -> ZigNiriWorkspaceView? {
        workspaceViews[workspaceId]
    }

    func hasActiveStructuralAnimation(
        in workspaceId: WorkspaceDescriptor.ID,
        at time: TimeInterval = CACurrentMediaTime()
    ) -> Bool {
        guard let animation = structuralAnimationsByWorkspace[workspaceId] else {
            return false
        }
        let elapsed = max(0, time - animation.startedAt)
        if elapsed < animation.duration {
            return true
        }
        structuralAnimationsByWorkspace.removeValue(forKey: workspaceId)
        return false
    }

    func cancelStructuralAnimation(in workspaceId: WorkspaceDescriptor.ID) {
        structuralAnimationsByWorkspace.removeValue(forKey: workspaceId)
    }

    @discardableResult
    func startWorkspaceSwitchAnimation(
        in workspaceId: WorkspaceDescriptor.ID,
        duration: TimeInterval = 0.20
    ) -> Bool {
        guard ensureRuntimeContext(for: workspaceId) != nil else {
            return false
        }
        guard ensureSyncedViewIfNeeded(workspaceId: workspaceId) else {
            return false
        }
        structuralAnimationsByWorkspace[workspaceId] = StructuralAnimationState(
            kind: .workspaceSwitch,
            startedAt: CACurrentMediaTime(),
            duration: max(0.01, duration)
        )
        return true
    }

    @discardableResult
    func applyNavigation(
        _ request: ZigNiriNavigationRequest,
        in workspaceId: WorkspaceDescriptor.ID,
        orientation: Monitor.Orientation = .horizontal,
        selection: ZigNiriSelection? = nil
    ) -> ZigNiriNavigationResult {
        let latencyToken = ZigNiriLatencyProbe.begin(.navigationStep)
        defer { ZigNiriLatencyProbe.end(latencyToken) }

        guard let context = ensureRuntimeContext(for: workspaceId) else {
            return .noChange(
                workspaceId: workspaceId,
                targetNodeId: nil,
                selection: workspaceViews[workspaceId]?.selection
            )
        }

        guard ensureSyncedViewIfNeeded(workspaceId: workspaceId) else {
            return .noChange(
                workspaceId: workspaceId,
                targetNodeId: nil,
                selection: workspaceViews[workspaceId]?.selection
            )
        }
        var view = ensureWorkspaceView(for: workspaceId)
        if let selection {
            view.selection = selection
        }
        view = storeWorkspaceView(view, workspaceId: workspaceId)

        guard let runtimeRequest = runtimeNavigationRequest(
            for: request,
            orientation: orientation,
            in: view
        )
        else {
            return .noChange(
                workspaceId: workspaceId,
                targetNodeId: view.selection?.selectedNodeId,
                selection: view.selection
            )
        }

        let outcome = ZigNiriStateKernel.applyNavigation(
            context: context,
            request: .init(request: runtimeRequest)
        )
        guard outcome.rc == 0 else {
            return .noChange(
                workspaceId: workspaceId,
                targetNodeId: view.selection?.selectedNodeId,
                selection: view.selection
            )
        }

        if outcome.applied {
            markWorkspaceDirty(workspaceId)
        }
        guard ensureSyncedViewIfNeeded(workspaceId: workspaceId) else {
            return .noChange(
                workspaceId: workspaceId,
                targetNodeId: view.selection?.selectedNodeId,
                selection: view.selection
            )
        }
        var projected = ensureWorkspaceView(for: workspaceId)
        let targetNodeId = outcome.targetWindowId
            ?? navigationFallbackTarget(for: request, in: projected)
            ?? projected.selection?.selectedNodeId

        projected.selection = ZigNiriSelection(
            selectedNodeId: targetNodeId,
            focusedWindowId: outcome.targetWindowId ?? projected.selection?.focusedWindowId
        )
        projected = storeWorkspaceView(projected, workspaceId: workspaceId)

        return ZigNiriNavigationResult(
            applied: outcome.applied,
            workspaceId: workspaceId,
            targetNodeId: targetNodeId,
            selection: projected.selection,
            wrapped: false
        )
    }

    @discardableResult
    func applyMutation(
        _ request: ZigNiriMutationRequest,
        in workspaceId: WorkspaceDescriptor.ID,
        selection: ZigNiriSelection? = nil
    ) -> ZigNiriMutationResult {
        let latencyToken: (hotPath: ZigNiriLatencyHotPath, startedAt: UInt64)?
        switch request {
        case .moveWindow:
            latencyToken = ZigNiriLatencyProbe.begin(.windowMove)
        default:
            latencyToken = nil
        }
        defer { ZigNiriLatencyProbe.end(latencyToken) }

        guard ensureRuntimeContext(for: workspaceId) != nil else {
            return .noChange(
                workspaceId: workspaceId,
                selection: workspaceViews[workspaceId]?.selection
            )
        }
        guard ensureSyncedViewIfNeeded(workspaceId: workspaceId) else {
            return .noChange(
                workspaceId: workspaceId,
                selection: workspaceViews[workspaceId]?.selection
            )
        }

        switch request {
        case let .setColumnDisplay(columnId, display):
            return applyColumnDisplayMutation(
                columnId: columnId,
                display: display,
                workspaceId: workspaceId,
                selection: selection
            )

        case let .setColumnActiveWindow(columnId, windowIndex):
            return applyColumnActiveWindowMutation(
                columnId: columnId,
                windowIndex: windowIndex,
                workspaceId: workspaceId,
                selection: selection
            )

        case let .setColumnWidth(columnId, width):
            return applyColumnWidthMutation(
                columnId: columnId,
                width: width,
                workspaceId: workspaceId,
                selection: selection
            )

        case let .toggleColumnFullWidth(columnId):
            return applyColumnFullWidthToggleMutation(
                columnId: columnId,
                workspaceId: workspaceId,
                selection: selection
            )

        case let .setWindowSizing(windowId, mode):
            return applyWindowSizingMutation(
                windowId: windowId,
                mode: mode,
                workspaceId: workspaceId,
                selection: selection
            )

        case let .setWindowHeight(windowId, height):
            return applyWindowHeightMutation(
                windowId: windowId,
                height: height,
                workspaceId: workspaceId,
                selection: selection
            )

        case let .moveWindow(windowId, direction, orientation):
            guard let op = mutationOpForWindowMove(
                direction: direction,
                orientation: orientation,
                swap: false
            )
            else {
                return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
            }
            return applyRuntimeMutation(
                RuntimeMutationSpec(
                    op: op,
                    sourceWindowId: windowId,
                    direction: direction
                ),
                workspaceId: workspaceId,
                selection: selection
            )

        case let .swapWindow(windowId, direction, orientation):
            guard let op = mutationOpForWindowMove(
                direction: direction,
                orientation: orientation,
                swap: true
            )
            else {
                return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
            }
            return applyRuntimeMutation(
                RuntimeMutationSpec(
                    op: op,
                    sourceWindowId: windowId,
                    direction: direction
                ),
                workspaceId: workspaceId,
                selection: selection
            )

        case let .moveColumn(columnId, direction):
            guard direction == .left || direction == .right else {
                return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
            }
            return applyRuntimeMutation(
                RuntimeMutationSpec(
                    op: .moveColumn,
                    sourceColumnId: columnId,
                    direction: direction
                ),
                workspaceId: workspaceId,
                selection: selection
            )

        case let .consumeWindow(windowId, direction):
            guard direction == .left || direction == .right else {
                return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
            }
            return applyRuntimeMutation(
                RuntimeMutationSpec(
                    op: .consumeWindow,
                    sourceWindowId: windowId,
                    direction: direction,
                    placeholderColumnId: UUID()
                ),
                workspaceId: workspaceId,
                selection: selection
            )

        case let .expelWindow(windowId, direction):
            guard direction == .left || direction == .right else {
                return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
            }
            return applyRuntimeMutation(
                RuntimeMutationSpec(
                    op: .expelWindow,
                    sourceWindowId: windowId,
                    direction: direction,
                    createdColumnId: UUID(),
                    placeholderColumnId: UUID()
                ),
                workspaceId: workspaceId,
                selection: selection
            )

        case let .insertWindowByMove(sourceWindowId, targetWindowId, position):
            return applyRuntimeMutation(
                RuntimeMutationSpec(
                    op: .insertWindowByMove,
                    sourceWindowId: sourceWindowId,
                    targetWindowId: targetWindowId,
                    insertPosition: position
                ),
                workspaceId: workspaceId,
                selection: selection
            )

        case let .insertWindowInNewColumn(windowId, insertIndex):
            return applyRuntimeMutation(
                RuntimeMutationSpec(
                    op: .insertWindowInNewColumn,
                    sourceWindowId: windowId,
                    insertColumnIndex: insertIndex,
                    maxVisibleColumnsOverride: maxVisibleColumns,
                    createdColumnId: UUID(),
                    placeholderColumnId: UUID()
                ),
                workspaceId: workspaceId,
                selection: selection
            )

        case .balanceSizes:
            return applyRuntimeMutation(
                RuntimeMutationSpec(
                    op: .balanceSizes,
                    maxVisibleColumnsOverride: maxVisibleColumns
                ),
                workspaceId: workspaceId,
                selection: selection
            )

        case let .removeWindow(windowId):
            return applyRemoveWindowMutation(
                windowId: windowId,
                workspaceId: workspaceId,
                selection: selection
            )

        case .custom:
            var view = ensureWorkspaceView(for: workspaceId)
            if let selection {
                view.selection = selection
                view = storeWorkspaceView(view, workspaceId: workspaceId)
            }
            return .noChange(workspaceId: workspaceId, selection: view.selection)
        }
    }

    @discardableResult
    func applyWorkspace(
        _ request: ZigNiriWorkspaceRequest,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> ZigNiriMutationResult {
        let latencyToken: (hotPath: ZigNiriLatencyHotPath, startedAt: UInt64)?
        switch request {
        case .moveWindow:
            latencyToken = ZigNiriLatencyProbe.begin(.workspaceMove)
        default:
            latencyToken = nil
        }
        defer { ZigNiriLatencyProbe.end(latencyToken) }

        switch request {
        case .ensureWorkspace:
            let existed = layoutContexts[workspaceId] != nil
            guard ensureRuntimeContext(for: workspaceId) != nil else {
                return .noChange(
                    workspaceId: workspaceId,
                    selection: workspaceViews[workspaceId]?.selection
                )
            }
            guard ensureSyncedViewIfNeeded(workspaceId: workspaceId) else {
                return .noChange(
                    workspaceId: workspaceId,
                    selection: workspaceViews[workspaceId]?.selection
                )
            }
            let view = ensureWorkspaceView(for: workspaceId)
            return ZigNiriMutationResult(
                applied: !existed,
                workspaceId: workspaceId,
                selection: view.selection,
                affectedNodeIds: [],
                removedNodeIds: []
            )

        case .clearWorkspace:
            guard let context = ensureRuntimeContext(for: workspaceId) else {
                return .noChange(
                    workspaceId: workspaceId,
                    selection: workspaceViews[workspaceId]?.selection
                )
            }

            let removedIds: [NodeId] = {
                switch ZigNiriStateKernel.snapshotRuntimeStateResult(context: context) {
                case let .success(export):
                    return export.windows.map(\.windowId)
                case .failure:
                    return []
                }
            }()

            let resetColumnId = workspaceViews[workspaceId]?.columns.first?.nodeId ?? NodeId()
            let clearedExport = ZigNiriStateKernel.RuntimeStateExport(
                columns: [
                    .init(
                        columnId: resetColumnId,
                        windowStart: 0,
                        windowCount: 0,
                        activeTileIdx: 0,
                        isTabbed: false,
                        sizeValue: 1.0
                    ),
                ],
                windows: []
            )

            let rc = ZigNiriStateKernel.seedRuntimeState(
                context: context,
                export: clearedExport
            )
            guard rc == 0 else {
                return .noChange(
                    workspaceId: workspaceId,
                    selection: workspaceViews[workspaceId]?.selection
                )
            }

            markWorkspaceDirty(workspaceId)
            guard ensureSyncedViewIfNeeded(workspaceId: workspaceId) else {
                return .noChange(
                    workspaceId: workspaceId,
                    selection: workspaceViews[workspaceId]?.selection
                )
            }
            var view = ensureWorkspaceView(for: workspaceId)
            view.selection = nil
            view = storeWorkspaceView(view, workspaceId: workspaceId, allowNilWhenRequested: true)

            return ZigNiriMutationResult(
                applied: !removedIds.isEmpty,
                workspaceId: workspaceId,
                selection: nil,
                affectedNodeIds: [],
                removedNodeIds: removedIds
            )

        case let .setSelection(selection):
            guard ensureRuntimeContext(for: workspaceId) != nil else {
                return .noChange(
                    workspaceId: workspaceId,
                    selection: workspaceViews[workspaceId]?.selection
                )
            }
            guard ensureSyncedViewIfNeeded(workspaceId: workspaceId) else {
                return .noChange(
                    workspaceId: workspaceId,
                    selection: workspaceViews[workspaceId]?.selection
                )
            }

            var view = ensureWorkspaceView(for: workspaceId)
            view.selection = selection
            view = storeWorkspaceView(view, workspaceId: workspaceId, allowNilWhenRequested: true)

            return ZigNiriMutationResult(
                applied: true,
                workspaceId: workspaceId,
                selection: view.selection,
                affectedNodeIds: [],
                removedNodeIds: []
            )

        case let .moveWindow(windowId, targetWorkspaceId):
            guard let sourceContext = ensureRuntimeContext(for: workspaceId),
                  let targetContext = ensureRuntimeContext(for: targetWorkspaceId)
            else {
                return .noChange(
                    workspaceId: workspaceId,
                    selection: workspaceViews[workspaceId]?.selection
                )
            }
            let sourcePreFrames = captureNodeFrames(in: workspaceId)
            let targetPreFrames = captureNodeFrames(in: targetWorkspaceId)

            let outcome = ZigNiriStateKernel.applyWorkspace(
                sourceContext: sourceContext,
                targetContext: targetContext,
                request: .init(
                    request: ZigNiriStateKernel.WorkspaceRequest(
                        op: .moveWindowToWorkspace,
                        sourceWindowId: windowId,
                        maxVisibleColumns: maxVisibleColumns
                    ),
                    targetCreatedColumnId: UUID(),
                    sourcePlaceholderColumnId: UUID()
                )
            )
            guard outcome.rc == 0 else {
                return .noChange(
                    workspaceId: workspaceId,
                    selection: workspaceViews[workspaceId]?.selection
                )
            }

            if outcome.applied {
                markWorkspaceDirty(targetWorkspaceId)
                markWorkspaceDirty(workspaceId)
            }
            let structuralAnimationActive = outcome.applied && outcome.structuralAnimationActive
            if structuralAnimationActive {
                scheduleStructuralAnimation(
                    in: workspaceId,
                    from: sourcePreFrames
                )
                scheduleStructuralAnimation(
                    in: targetWorkspaceId,
                    from: targetPreFrames
                )
            }
            guard ensureSyncedViewIfNeeded(workspaceId: targetWorkspaceId) else {
                return .noChange(
                    workspaceId: workspaceId,
                    selection: workspaceViews[workspaceId]?.selection
                )
            }

            let targetView = ensureWorkspaceView(for: targetWorkspaceId)
            return ZigNiriMutationResult(
                applied: outcome.applied,
                workspaceId: targetWorkspaceId,
                selection: targetView.selection,
                affectedNodeIds: [windowId],
                removedNodeIds: [],
                structuralAnimationActive: structuralAnimationActive
            )

        case let .moveColumn(columnId, targetWorkspaceId):
            guard let sourceContext = ensureRuntimeContext(for: workspaceId),
                  let targetContext = ensureRuntimeContext(for: targetWorkspaceId)
            else {
                return .noChange(
                    workspaceId: workspaceId,
                    selection: workspaceViews[workspaceId]?.selection
                )
            }
            let sourcePreFrames = captureNodeFrames(in: workspaceId)
            let targetPreFrames = captureNodeFrames(in: targetWorkspaceId)

            let outcome = ZigNiriStateKernel.applyWorkspace(
                sourceContext: sourceContext,
                targetContext: targetContext,
                request: .init(
                    request: ZigNiriStateKernel.WorkspaceRequest(
                        op: .moveColumnToWorkspace,
                        sourceColumnId: columnId
                    ),
                    sourcePlaceholderColumnId: UUID()
                )
            )
            guard outcome.rc == 0 else {
                return .noChange(
                    workspaceId: workspaceId,
                    selection: workspaceViews[workspaceId]?.selection
                )
            }

            if outcome.applied {
                markWorkspaceDirty(targetWorkspaceId)
                markWorkspaceDirty(workspaceId)
            }
            let structuralAnimationActive = outcome.applied && outcome.structuralAnimationActive
            if structuralAnimationActive {
                scheduleStructuralAnimation(
                    in: workspaceId,
                    from: sourcePreFrames
                )
                scheduleStructuralAnimation(
                    in: targetWorkspaceId,
                    from: targetPreFrames
                )
            }
            guard ensureSyncedViewIfNeeded(workspaceId: targetWorkspaceId) else {
                return .noChange(
                    workspaceId: workspaceId,
                    selection: workspaceViews[workspaceId]?.selection
                )
            }

            let targetView = ensureWorkspaceView(for: targetWorkspaceId)
            return ZigNiriMutationResult(
                applied: outcome.applied,
                workspaceId: targetWorkspaceId,
                selection: targetView.selection,
                affectedNodeIds: [columnId],
                removedNodeIds: [],
                structuralAnimationActive: structuralAnimationActive
            )
        }
    }

    @discardableResult
    func syncWindows(
        _ handles: [WindowHandle],
        in workspaceId: WorkspaceDescriptor.ID,
        selectedNodeId: NodeId?,
        focusedHandle: WindowHandle? = nil
    ) -> Set<WindowHandle> {
        guard let context = ensureRuntimeContext(for: workspaceId) else {
            return []
        }
        let preFrames = captureNodeFrames(in: workspaceId)

        let incomingHandles = Set(handles)
        var incomingByUUID: [UUID: WindowHandle] = [:]
        incomingByUUID.reserveCapacity(handles.count)
        for handle in handles {
            incomingByUUID[handle.id] = handle
            windowHandlesByUUID[handle.id] = handle
        }

        var export: ZigNiriStateKernel.RuntimeStateExport
        switch ZigNiriStateKernel.snapshotRuntimeStateResult(context: context) {
        case let .success(snapshot):
            export = snapshot
        case .failure:
            export = runtimeBootstrapExport(for: workspaceId)
        }

        var removedNodeIds = Set<NodeId>()
        var keptWindows: [ZigNiriStateKernel.RuntimeWindowState] = []
        keptWindows.reserveCapacity(export.windows.count)

        for runtimeWindow in export.windows {
            let mappedHandle = windowHandlesByNodeId[runtimeWindow.windowId]
                ?? incomingByUUID[runtimeWindow.windowId.uuid]

            guard let handle = mappedHandle else {
                removedNodeIds.insert(runtimeWindow.windowId)
                continue
            }

            windowHandlesByNodeId[runtimeWindow.windowId] = handle
            windowNodeIdsByHandle[handle] = runtimeWindow.windowId
            if incomingHandles.contains(handle) {
                keptWindows.append(runtimeWindow)
            } else {
                removedNodeIds.insert(runtimeWindow.windowId)
            }
        }
        export.windows = keptWindows

        if export.columns.isEmpty {
            export.columns = [defaultRuntimeColumnState(columnId: NodeId())]
        }
        normalizeRuntimeExport(&export)
        let selectedAnchorId = selectedNodeId ?? workspaceViews[workspaceId]?.selection?.selectedNodeId

        let preferredColumnId: NodeId = {
            let view = workspaceViews[workspaceId]
            let anchor = runtimeSelectionAnchor(
                selectedNodeId: selectedAnchorId,
                in: view
            )
            return anchor?.columnId ?? export.columns.first!.columnId
        }()
        var existingWindowIds = Set(export.windows.map(\.windowId))
        var addedWindowIds: [NodeId] = []

        for handle in handles {
            let nodeId: NodeId
            if let existingNodeId = windowNodeIdsByHandle[handle] {
                nodeId = existingNodeId
            } else {
                nodeId = NodeId(uuid: handle.id)
                windowNodeIdsByHandle[handle] = nodeId
            }
            windowHandlesByNodeId[nodeId] = handle
            windowHandlesByUUID[handle.id] = handle
            if existingWindowIds.contains(nodeId) {
                continue
            }

            let targetColumnId: NodeId
            if export.windows.isEmpty,
               let emptyColumnIndex = export.columns.firstIndex(where: { $0.windowCount == 0 })
            {
                targetColumnId = export.columns[emptyColumnIndex].columnId
            } else {
                let preferredIndex = export.columns.firstIndex(where: { $0.columnId == preferredColumnId })
                    ?? max(0, export.columns.count - 1)
                let insertedColumnId = NodeId()
                export.columns.insert(
                    defaultRuntimeColumnState(columnId: insertedColumnId),
                    at: min(preferredIndex + 1, export.columns.count)
                )
                targetColumnId = insertedColumnId
            }

            export.windows.append(
                ZigNiriStateKernel.RuntimeWindowState(
                    windowId: nodeId,
                    columnId: targetColumnId,
                    columnIndex: 0,
                    sizeValue: 1.0,
                    heightKind: ZigNiriStateKernel.heightKindAuto,
                    heightValue: 1.0
                )
            )
            existingWindowIds.insert(nodeId)
            addedWindowIds.append(nodeId)
        }

        normalizeRuntimeExport(&export)
        let seedRC = ZigNiriStateKernel.seedRuntimeState(
            context: context,
            export: export
        )
        guard seedRC == 0 else {
            return []
        }

        let removedHandles = Set(
            removedNodeIds.compactMap { windowHandlesByNodeId[$0] }
        )
        markWorkspaceDirty(workspaceId)
        guard ensureSyncedViewIfNeeded(workspaceId: workspaceId) else {
            return removedHandles
        }
        var view = ensureWorkspaceView(for: workspaceId)

        let focusedNodeId = focusedHandle.flatMap { windowNodeIdsByHandle[$0] }
        let selectedForView = selectedNodeId ?? focusedNodeId ?? view.selection?.selectedNodeId
        view.selection = ZigNiriSelection(
            selectedNodeId: selectedForView,
            focusedWindowId: focusedNodeId ?? view.selection?.focusedWindowId
        )
        _ = storeWorkspaceView(view, workspaceId: workspaceId)

        if !addedWindowIds.isEmpty || !removedNodeIds.isEmpty {
            scheduleStructuralAnimation(in: workspaceId, from: preFrames)
        }

        return removedHandles
    }

    func calculateLayout(_ request: ZigNiriLayoutRequest) -> ZigNiriLayoutResult {
        let latencyToken = ZigNiriLatencyProbe.begin(.layoutPass)
        defer { ZigNiriLatencyProbe.end(latencyToken) }
        let persistFrames = !ZigNiriLatencyProbe.isEnabled

        guard var view = workspaceViews[request.workspaceId] else {
            return ZigNiriLayoutResult(frames: [:], hiddenHandles: [:])
        }
        guard !view.columns.isEmpty else {
            if persistFrames {
                for windowId in view.windowsById.keys {
                    var window = view.windowsById[windowId]
                    window?.frame = nil
                    if let window {
                        view.windowsById[windowId] = window
                    }
                }
                workspaceViews[request.workspaceId] = view
            }
            return ZigNiriLayoutResult(frames: [:], hiddenHandles: [:])
        }

        let workingFrame = request.workingArea?.workingFrame ?? request.monitorFrame
        let primaryGap = request.orientation == .horizontal ? request.gaps.horizontal : request.gaps.vertical
        let secondaryGap = request.orientation == .horizontal ? request.gaps.vertical : request.gaps.horizontal

        var frames: [WindowHandle: CGRect] = [:]
        var hiddenHandles: [WindowHandle: HideSide] = [:]
        let columnLayouts = columnLayoutsForLayout(
            view: view,
            workingFrame: workingFrame,
            orientation: request.orientation,
            primaryGap: primaryGap,
            viewOffset: request.viewportOffset
        )

        if let fullscreenWindowId = view.windowsById.values.first(where: { $0.sizingMode == .fullscreen })?.nodeId {
            let fullFrame = workingFrame.roundedToPhysicalPixels(scale: request.scale)
            for (windowId, existingWindow) in view.windowsById {
                if windowId == fullscreenWindowId {
                    if persistFrames {
                        var window = existingWindow
                        window.frame = fullFrame
                        view.windowsById[windowId] = window
                    }
                    frames[existingWindow.handle] = fullFrame
                } else {
                    if persistFrames {
                        var window = existingWindow
                        window.frame = nil
                        view.windowsById[windowId] = window
                    }
                    hiddenHandles[existingWindow.handle] = .right
                }
            }
            let layoutTime = request.animationTime ?? CACurrentMediaTime()
            frames = applyStructuralAnimationIfNeeded(
                frames: frames,
                workspaceId: request.workspaceId,
                orientation: request.orientation,
                at: layoutTime
            )
            if persistFrames {
                for (handle, frame) in frames {
                    guard let nodeId = windowNodeIdsByHandle[handle],
                          var window = view.windowsById[nodeId]
                    else {
                        continue
                    }
                    window.frame = frame
                    view.windowsById[nodeId] = window
                }
                workspaceViews[request.workspaceId] = view
            }
            return ZigNiriLayoutResult(frames: frames, hiddenHandles: hiddenHandles)
        }

        for (columnIndex, column) in view.columns.enumerated() {
            guard columnLayouts.indices.contains(columnIndex) else { continue }
            let columnLayout = columnLayouts[columnIndex]
            let columnRect = columnLayout.rect
            let windowIds = column.windowIds
            guard !windowIds.isEmpty else { continue }

            if let offscreenSide = columnLayout.hiddenSide {
                let frame = columnRect.roundedToPhysicalPixels(scale: request.scale)
                for windowId in windowIds {
                    guard let window = view.windowsById[windowId] else { continue }
                    if persistFrames {
                        var persistedWindow = window
                        persistedWindow.frame = frame
                        view.windowsById[windowId] = persistedWindow
                    }
                    frames[window.handle] = frame
                    hiddenHandles[window.handle] = offscreenSide
                }
                continue
            }

            if column.display == .tabbed {
                let activeIndex = min(max(column.activeWindowIndex ?? 0, 0), windowIds.count - 1)
                for (rowIndex, windowId) in windowIds.enumerated() {
                    guard let window = view.windowsById[windowId] else { continue }
                    if rowIndex == activeIndex {
                        let frame = columnRect.roundedToPhysicalPixels(scale: request.scale)
                        if persistFrames {
                            var persistedWindow = window
                            persistedWindow.frame = frame
                            view.windowsById[windowId] = persistedWindow
                        }
                        frames[window.handle] = frame
                    } else {
                        if persistFrames {
                            var persistedWindow = window
                            persistedWindow.frame = nil
                            view.windowsById[windowId] = persistedWindow
                        }
                        hiddenHandles[window.handle] = .right
                    }
                }
                continue
            }

            let rowRects = rowRectsForColumn(
                windowIds: windowIds,
                windowsById: view.windowsById,
                columnRect: columnRect,
                orientation: request.orientation,
                secondaryGap: secondaryGap
            )
            for (rowIndex, windowId) in windowIds.enumerated() {
                guard rowRects.indices.contains(rowIndex),
                      let window = view.windowsById[windowId]
                else { continue }
                let frame = rowRects[rowIndex].roundedToPhysicalPixels(scale: request.scale)
                if persistFrames {
                    var persistedWindow = window
                    persistedWindow.frame = frame
                    view.windowsById[windowId] = persistedWindow
                }
                frames[window.handle] = frame
            }
        }

        let layoutTime = request.animationTime ?? CACurrentMediaTime()
        frames = applyStructuralAnimationIfNeeded(
            frames: frames,
            workspaceId: request.workspaceId,
            orientation: request.orientation,
            at: layoutTime
        )

        if persistFrames {
            for (handle, frame) in frames {
                guard let nodeId = windowNodeIdsByHandle[handle],
                      var window = view.windowsById[nodeId]
                else {
                    continue
                }
                window.frame = frame
                view.windowsById[nodeId] = window
            }
        }

        if persistFrames {
            workspaceViews[request.workspaceId] = view
        }
        return ZigNiriLayoutResult(frames: frames, hiddenHandles: hiddenHandles)
    }

    func resolvedColumnSpans(
        for view: ZigNiriWorkspaceView,
        primarySpan: CGFloat,
        primaryGap: CGFloat
    ) -> [CGFloat] {
        resolveColumnSpans(
            view: view,
            primarySpan: primarySpan,
            primaryGap: primaryGap
        )
    }

    func hitTestResize(
        at point: CGPoint,
        _ request: ZigNiriHitTestRequest
    ) -> ZigNiriResizeHitResult? {
        guard let tiled = hitTestTiled(at: point, request) else {
            return nil
        }

        let threshold = max(2.0, 8.0 / max(request.scale, 0.5))
        var edges: ZigNiriResizeEdge = []
        if abs(point.x - tiled.windowFrame.minX) <= threshold {
            edges.insert(.left)
        }
        if abs(point.x - tiled.windowFrame.maxX) <= threshold {
            edges.insert(.right)
        }
        if abs(point.y - tiled.windowFrame.minY) <= threshold {
            edges.insert(.top)
        }
        if abs(point.y - tiled.windowFrame.maxY) <= threshold {
            edges.insert(.bottom)
        }
        guard !edges.isEmpty else {
            return nil
        }

        return ZigNiriResizeHitResult(
            windowHandle: tiled.windowHandle,
            windowId: tiled.windowId,
            columnIndex: tiled.columnIndex,
            edges: edges,
            windowFrame: tiled.windowFrame
        )
    }

    func hitTestTiled(
        at point: CGPoint,
        _ request: ZigNiriHitTestRequest
    ) -> ZigNiriTiledHitResult? {
        guard let view = workspaceViews[request.workspaceId] else {
            return nil
        }

        for (windowId, window) in view.windowsById {
            guard let frame = window.frame else {
                continue
            }
            guard frame.contains(point) else {
                continue
            }
            return ZigNiriTiledHitResult(
                windowHandle: window.handle,
                windowId: windowId,
                columnId: window.columnId,
                columnIndex: columnIndex(for: windowId, in: view),
                windowFrame: frame
            )
        }
        return nil
    }

    @discardableResult
    func beginInteractiveMove(_ state: ZigNiriInteractiveMoveState) -> Bool {
        guard interactiveMoveState == nil else { return false }
        interactiveMoveState = state
        return true
    }

    func updateInteractiveMove(mouseLocation: CGPoint) -> ZigNiriMoveHoverTarget? {
        guard var move = interactiveMoveState else { return nil }
        let hoverTarget: ZigNiriMoveHoverTarget?
        if mouseLocation.x <= move.monitorFrame.minX {
            hoverTarget = .workspaceEdge(side: .left)
        } else if mouseLocation.x >= move.monitorFrame.maxX {
            hoverTarget = .workspaceEdge(side: .right)
        } else {
            hoverTarget = nil
        }
        move.currentHoverTarget = hoverTarget
        interactiveMoveState = move
        return hoverTarget
    }

    func endInteractiveMove(commit: Bool = true) -> ZigNiriMutationResult {
        guard let move = interactiveMoveState else {
            return .noChange(workspaceId: nil, selection: nil)
        }
        defer { interactiveMoveState = nil }

        guard commit else {
            return .noChange(
                workspaceId: move.workspaceId,
                selection: workspaceViews[move.workspaceId]?.selection
            )
        }
        return ZigNiriMutationResult(
            applied: move.currentHoverTarget != nil,
            workspaceId: move.workspaceId,
            selection: workspaceViews[move.workspaceId]?.selection,
            affectedNodeIds: [move.windowId],
            removedNodeIds: []
        )
    }

    @discardableResult
    func beginInteractiveResize(_ state: ZigNiriInteractiveResizeState) -> Bool {
        guard interactiveResizeState == nil else { return false }
        guard ensureSyncedViewIfNeeded(workspaceId: state.workspaceId),
              let view = workspaceViews[state.workspaceId],
              let window = view.windowsById[state.windowId]
        else {
            return false
        }
        let fallbackWidth = max(1, state.orientation == .horizontal
            ? state.monitorFrame.width / 2
            : state.monitorFrame.width)
        let fallbackHeight = max(1, state.orientation == .horizontal
            ? state.monitorFrame.height
            : state.monitorFrame.height / 2)
        let windowFrame = window.frame ?? CGRect(
            x: state.monitorFrame.minX,
            y: state.monitorFrame.minY,
            width: fallbackWidth,
            height: fallbackHeight
        )

        let columnId = window.columnId
        let hasHorizontal = state.edges.hasHorizontal
        let hasVertical = state.edges.hasVertical

        let originalColumnWidth: CGFloat
        let minColumnWidth: CGFloat
        let maxColumnWidth: CGFloat
        if hasHorizontal {
            let measured = state.orientation == .horizontal ? windowFrame.width : windowFrame.height
            originalColumnWidth = max(1, measured)
            minColumnWidth = 80
            let monitorPrimary = state.orientation == .horizontal
                ? state.monitorFrame.width
                : state.monitorFrame.height
            maxColumnWidth = max(minColumnWidth, monitorPrimary - state.gap)
        } else {
            originalColumnWidth = 0
            minColumnWidth = 0
            maxColumnWidth = 0
        }

        let originalWindowWeight: CGFloat
        let pixelsPerWeight: CGFloat
        if hasVertical {
            switch window.height {
            case let .auto(weight):
                originalWindowWeight = max(0.1, weight)
            case let .fixed(value):
                originalWindowWeight = max(0.1, value / max(windowFrame.height, 1))
            }
            pixelsPerWeight = max(1, windowFrame.height / max(0.1, originalWindowWeight))
        } else {
            originalWindowWeight = 0
            pixelsPerWeight = 0
        }

        interactiveResizeState = ActiveInteractiveResize(
            windowId: state.windowId,
            workspaceId: state.workspaceId,
            edges: state.edges,
            startMouseLocation: state.startMouseLocation,
            columnId: columnId,
            originalColumnWidth: originalColumnWidth,
            minColumnWidth: minColumnWidth,
            maxColumnWidth: maxColumnWidth,
            originalWindowWeight: originalWindowWeight,
            minWindowWeight: ResizeConfiguration.default.minWindowWeight,
            maxWindowWeight: ResizeConfiguration.default.maxWindowWeight,
            pixelsPerWeight: pixelsPerWeight,
            originalViewOffset: state.edges.contains(.left) ? state.initialViewportOffset : nil,
            orientation: state.orientation
        )
        return true
    }

    func updateInteractiveResize(mouseLocation: CGPoint) -> ZigNiriMutationResult {
        let latencyToken = ZigNiriLatencyProbe.begin(.resizeDragUpdate)
        defer { ZigNiriLatencyProbe.end(latencyToken) }

        guard let resize = interactiveResizeState else {
            return .noChange(workspaceId: nil, selection: nil)
        }
        let hasMovement = mouseLocation != resize.startMouseLocation
        guard hasMovement else {
            return .noChange(
                workspaceId: resize.workspaceId,
                selection: workspaceViews[resize.workspaceId]?.selection
            )
        }

        var input = OmniNiriResizeInput(
            edges: UInt8(resize.edges.rawValue & 0xFF),
            start_x: Double(resize.startMouseLocation.x),
            start_y: Double(resize.startMouseLocation.y),
            current_x: Double(mouseLocation.x),
            current_y: Double(mouseLocation.y),
            original_column_width: Double(resize.originalColumnWidth),
            min_column_width: Double(resize.minColumnWidth),
            max_column_width: Double(resize.maxColumnWidth),
            original_window_weight: Double(resize.originalWindowWeight),
            min_window_weight: Double(resize.minWindowWeight),
            max_window_weight: Double(resize.maxWindowWeight),
            pixels_per_weight: Double(resize.pixelsPerWeight),
            has_original_view_offset: resize.originalViewOffset == nil ? 0 : 1,
            original_view_offset: Double(resize.originalViewOffset ?? 0)
        )
        var output = OmniNiriResizeResult(
            changed_width: 0,
            new_column_width: Double(resize.originalColumnWidth),
            changed_weight: 0,
            new_window_weight: Double(resize.originalWindowWeight),
            adjust_view_offset: 0,
            new_view_offset: Double(resize.originalViewOffset ?? 0)
        )
        let rc = withUnsafePointer(to: &input) { inputPtr in
            withUnsafeMutablePointer(to: &output) { outputPtr in
                omni_niri_resize_compute(inputPtr, outputPtr)
            }
        }
        guard rc == 0 else {
            return .noChange(
                workspaceId: resize.workspaceId,
                selection: workspaceViews[resize.workspaceId]?.selection
            )
        }

        let nextColumnWidth: CGFloat? = output.changed_width != 0 ? CGFloat(output.new_column_width) : nil
        let nextWindowWeight: CGFloat? = output.changed_weight != 0 ? CGFloat(output.new_window_weight) : nil
        let nextViewportOffset: CGFloat? = output.adjust_view_offset != 0 ? CGFloat(output.new_view_offset) : nil
        guard nextColumnWidth != nil || nextWindowWeight != nil || nextViewportOffset != nil else {
            return .noChange(
                workspaceId: resize.workspaceId,
                selection: workspaceViews[resize.workspaceId]?.selection
            )
        }

        let mutation: RuntimeStateMutationOutcome = if let context = ensureRuntimeContext(for: resize.workspaceId) {
            mutateRuntimeState(context: context, workspaceId: resize.workspaceId) { export in
                var changed = false

                if let columnId = resize.columnId,
                   let nextColumnWidth,
                   let columnIndex = export.columns.firstIndex(where: { $0.columnId == columnId })
                {
                    let column = export.columns[columnIndex]
                    if column.widthKind != ZigNiriStateKernel.sizeKindFixed
                        || abs(column.sizeValue - Double(nextColumnWidth)) > 0.0001
                        || column.isFullWidth
                        || column.hasSavedWidth
                    {
                        export.columns[columnIndex] = ZigNiriStateKernel.RuntimeColumnState(
                            columnId: column.columnId,
                            windowStart: column.windowStart,
                            windowCount: column.windowCount,
                            activeTileIdx: column.activeTileIdx,
                            isTabbed: column.isTabbed,
                            sizeValue: Double(nextColumnWidth),
                            widthKind: ZigNiriStateKernel.sizeKindFixed,
                            isFullWidth: false,
                            hasSavedWidth: false,
                            savedWidthKind: ZigNiriStateKernel.sizeKindFixed,
                            savedWidthValue: Double(nextColumnWidth)
                        )
                        changed = true
                    }
                }

                if let nextWindowWeight,
                   let windowIndex = export.windows.firstIndex(where: { $0.windowId == resize.windowId })
                {
                    let runtimeWindow = export.windows[windowIndex]
                    if runtimeWindow.heightKind != ZigNiriStateKernel.heightKindAuto
                        || abs(runtimeWindow.heightValue - Double(nextWindowWeight)) > 0.0001
                        || abs(runtimeWindow.sizeValue - Double(nextWindowWeight)) > 0.0001
                    {
                        export.windows[windowIndex] = ZigNiriStateKernel.RuntimeWindowState(
                            windowId: runtimeWindow.windowId,
                            columnId: runtimeWindow.columnId,
                            columnIndex: runtimeWindow.columnIndex,
                            sizeValue: Double(nextWindowWeight),
                            heightKind: ZigNiriStateKernel.heightKindAuto,
                            heightValue: Double(nextWindowWeight)
                        )
                        changed = true
                    }
                }

                return changed
            }
        } else {
            RuntimeStateMutationOutcome(rc: -1, applied: false)
        }

        guard mutation.rc == 0 else {
            return .noChange(
                workspaceId: resize.workspaceId,
                selection: workspaceViews[resize.workspaceId]?.selection
            )
        }

        if mutation.applied {
            _ = ensureSyncedViewIfNeeded(workspaceId: resize.workspaceId)
        }

        var affectedNodeIds: [NodeId] = []
        if mutation.applied {
            affectedNodeIds.append(resize.windowId)
            if let columnId = resize.columnId {
                affectedNodeIds.append(columnId)
            }
        }

        return ZigNiriMutationResult(
            applied: mutation.applied || nextViewportOffset != nil,
            workspaceId: resize.workspaceId,
            selection: workspaceViews[resize.workspaceId]?.selection,
            affectedNodeIds: affectedNodeIds,
            removedNodeIds: [],
            resizeOutput: ZigNiriResizeMutationOutput(
                columnWidth: nextColumnWidth,
                windowWeight: nextWindowWeight,
                viewportOffset: nextViewportOffset
            )
        )
    }

    func endInteractiveResize(commit: Bool = true) -> ZigNiriMutationResult {
        guard let resize = interactiveResizeState else {
            return .noChange(workspaceId: nil, selection: nil)
        }
        defer { interactiveResizeState = nil }

        guard commit else {
            return .noChange(
                workspaceId: resize.workspaceId,
                selection: workspaceViews[resize.workspaceId]?.selection
            )
        }
        return ZigNiriMutationResult(
            applied: true,
            workspaceId: resize.workspaceId,
            selection: workspaceViews[resize.workspaceId]?.selection,
            affectedNodeIds: [resize.windowId],
            removedNodeIds: []
        )
    }
}

private extension ZigNiriEngine {
    struct ColumnLayoutEntry {
        let rect: CGRect
        let hiddenSide: HideSide?
    }

    struct RuntimeMutationSpec {
        let op: ZigNiriStateKernel.MutationOp
        var sourceWindowId: NodeId?
        var sourceColumnId: NodeId?
        var targetWindowId: NodeId?
        var direction: Direction?
        var insertPosition: InsertPosition?
        var insertColumnIndex: Int
        var maxVisibleColumnsOverride: Int?
        var incomingWindowId: UUID?
        var incomingSpawnMode: ZigNiriStateKernel.IncomingSpawnMode
        var createdColumnId: UUID?
        var placeholderColumnId: UUID?

        init(
            op: ZigNiriStateKernel.MutationOp,
            sourceWindowId: NodeId? = nil,
            sourceColumnId: NodeId? = nil,
            targetWindowId: NodeId? = nil,
            direction: Direction? = nil,
            insertPosition: InsertPosition? = nil,
            insertColumnIndex: Int = -1,
            maxVisibleColumnsOverride: Int? = nil,
            incomingWindowId: UUID? = nil,
            incomingSpawnMode: ZigNiriStateKernel.IncomingSpawnMode = .newColumn,
            createdColumnId: UUID? = nil,
            placeholderColumnId: UUID? = nil
        ) {
            self.op = op
            self.sourceWindowId = sourceWindowId
            self.sourceColumnId = sourceColumnId
            self.targetWindowId = targetWindowId
            self.direction = direction
            self.insertPosition = insertPosition
            self.insertColumnIndex = insertColumnIndex
            self.maxVisibleColumnsOverride = maxVisibleColumnsOverride
            self.incomingWindowId = incomingWindowId
            self.incomingSpawnMode = incomingSpawnMode
            self.createdColumnId = createdColumnId
            self.placeholderColumnId = placeholderColumnId
        }
    }

    func mutationOpForWindowMove(
        direction: Direction,
        orientation: Monitor.Orientation,
        swap: Bool
    ) -> ZigNiriStateKernel.MutationOp? {
        if direction.primaryStep(for: orientation) != nil {
            return swap ? .swapWindowHorizontal : .moveWindowHorizontal
        }
        if direction.secondaryStep(for: orientation) != nil {
            return swap ? .swapWindowVertical : .moveWindowVertical
        }
        return nil
    }

    func applyRuntimeMutation(
        _ mutation: RuntimeMutationSpec,
        workspaceId: WorkspaceDescriptor.ID,
        selection: ZigNiriSelection? = nil
    ) -> ZigNiriMutationResult {
        guard let context = ensureRuntimeContext(for: workspaceId) else {
            return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
        }
        let preFrames = captureNodeFrames(in: workspaceId)

        let request = ZigNiriStateKernel.MutationRequest(
            op: mutation.op,
            sourceWindowId: mutation.sourceWindowId,
            targetWindowId: mutation.targetWindowId,
            direction: mutation.direction,
            infiniteLoop: infiniteLoop,
            insertPosition: mutation.insertPosition,
            maxWindowsPerColumn: maxWindowsPerColumn,
            sourceColumnId: mutation.sourceColumnId,
            targetColumnId: nil,
            insertColumnIndex: mutation.insertColumnIndex,
            maxVisibleColumns: mutation.maxVisibleColumnsOverride ?? maxVisibleColumns,
            selectedNodeId: selection?.selectedNodeId ?? workspaceViews[workspaceId]?.selection?.selectedNodeId,
            focusedWindowId: selection?.focusedWindowId ?? workspaceViews[workspaceId]?.selection?.focusedWindowId,
            incomingSpawnMode: mutation.incomingSpawnMode
        )
        let outcome = ZigNiriStateKernel.applyMutation(
            context: context,
            request: .init(
                request: request,
                incomingWindowId: mutation.incomingWindowId,
                createdColumnId: mutation.createdColumnId,
                placeholderColumnId: mutation.placeholderColumnId
            )
        )
        guard outcome.rc == 0 else {
            return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
        }

        let removedIds = outcome.delta?.removedWindowIds ?? []
        let structuralAnimationActive = outcome.applied && outcome.structuralAnimationActive
        if outcome.applied {
            markWorkspaceDirty(workspaceId)
            if structuralAnimationActive {
                scheduleStructuralAnimation(in: workspaceId, from: preFrames)
            }
        }
        let synced = ensureSyncedViewIfNeeded(workspaceId: workspaceId)
        guard synced else {
            return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
        }
        var view = ensureWorkspaceView(for: workspaceId)
        var nextSelection = selection ?? view.selection

        if let targetWindowId = outcome.targetWindowId {
            nextSelection = ZigNiriSelection(
                selectedNodeId: targetWindowId,
                focusedWindowId: targetWindowId
            )
        } else if let targetNode = outcome.targetNode {
            switch targetNode.kind {
            case .window:
                nextSelection = ZigNiriSelection(
                    selectedNodeId: targetNode.nodeId,
                    focusedWindowId: targetNode.nodeId
                )
            case .column:
                let focusedWindowId = nextSelection?.focusedWindowId ?? view.selection?.focusedWindowId
                if let resolvedWindowId = ZigNiriSelectionResolver.actionableWindowId(
                    for: targetNode.nodeId,
                    in: view
                ) {
                    nextSelection = ZigNiriSelection(
                        selectedNodeId: resolvedWindowId,
                        focusedWindowId: resolvedWindowId
                    )
                } else {
                    nextSelection = ZigNiriSelection(
                        selectedNodeId: targetNode.nodeId,
                        focusedWindowId: focusedWindowId
                    )
                }
            case .none:
                break
            }
        }

        view.selection = nextSelection
        view = storeWorkspaceView(view, workspaceId: workspaceId, allowNilWhenRequested: true)

        var affected: [NodeId] = []
        if let sourceWindowId = mutation.sourceWindowId {
            affected.append(sourceWindowId)
        }
        if let sourceColumnId = mutation.sourceColumnId {
            affected.append(sourceColumnId)
        }
        if let targetWindowId = mutation.targetWindowId {
            affected.append(targetWindowId)
        }
        if let targetWindowId = outcome.targetWindowId,
           !affected.contains(targetWindowId)
        {
            affected.append(targetWindowId)
        }
        if let targetNode = outcome.targetNode,
           !affected.contains(targetNode.nodeId)
        {
            affected.append(targetNode.nodeId)
        }

        return ZigNiriMutationResult(
            applied: outcome.applied,
            workspaceId: workspaceId,
            selection: view.selection,
            affectedNodeIds: affected,
            removedNodeIds: removedIds,
            structuralAnimationActive: structuralAnimationActive
        )
    }

    func resolveColumnSpans(
        view: ZigNiriWorkspaceView,
        primarySpan: CGFloat,
        primaryGap: CGFloat
    ) -> [CGFloat] {
        guard !view.columns.isEmpty else { return [] }
        let availablePrimary = max(0, primarySpan)
        let proportionalBase = max(0, availablePrimary - primaryGap)

        return view.columns.map { column in
            if column.isFullWidth {
                return availablePrimary
            }
            switch column.width {
            case let .proportion(value):
                return max(0, proportionalBase * max(0, value))
            case let .fixed(value):
                return max(0, value)
            }
        }
    }

    func columnLayoutsForLayout(
        view: ZigNiriWorkspaceView,
        workingFrame: CGRect,
        orientation: Monitor.Orientation,
        primaryGap: CGFloat,
        viewOffset: CGFloat
    ) -> [ColumnLayoutEntry] {
        let columns = view.columns
        guard !columns.isEmpty else { return [] }
        let primarySpan = orientation == .horizontal ? workingFrame.width : workingFrame.height
        let viewportSpan = max(0, primarySpan)
        let spans = resolveColumnSpans(
            view: view,
            primarySpan: primarySpan,
            primaryGap: primaryGap
        )
        guard !spans.isEmpty else { return [] }

        let selectedNodeId = view.selection?.selectedNodeId
        let focusedWindowId = view.selection?.focusedWindowId
        let activeColumnIndex = activeColumnIndex(
            in: view,
            selectedNodeId: selectedNodeId,
            focusedWindowId: focusedWindowId
        ) ?? 0
        let clampedActiveIndex = min(max(activeColumnIndex, 0), spans.count - 1)

        var activeColumnPosition: CGFloat = 0
        if clampedActiveIndex > 0 {
            for index in 0 ..< clampedActiveIndex {
                activeColumnPosition += spans[index] + primaryGap
            }
        }
        let viewStart = activeColumnPosition + viewOffset
        let viewEnd = viewStart + viewportSpan

        var entries: [ColumnLayoutEntry] = []
        entries.reserveCapacity(columns.count)

        var columnPosition: CGFloat = 0
        for span in spans {
            let clampedSpan = max(0, span)
            let columnStart = columnPosition
            let columnEnd = columnStart + clampedSpan
            let hiddenSide: HideSide?
            if columnEnd <= viewStart {
                hiddenSide = .left
            } else if columnStart >= viewEnd {
                hiddenSide = .right
            } else {
                hiddenSide = nil
            }

            let rect: CGRect
            if orientation == .horizontal {
                rect = CGRect(
                    x: workingFrame.minX + columnStart - viewStart,
                    y: workingFrame.minY,
                    width: clampedSpan,
                    height: workingFrame.height
                )
            } else {
                rect = CGRect(
                    x: workingFrame.minX,
                    y: workingFrame.minY + columnStart - viewStart,
                    width: workingFrame.width,
                    height: clampedSpan
                )
            }
            entries.append(ColumnLayoutEntry(rect: rect, hiddenSide: hiddenSide))
            columnPosition = columnEnd + primaryGap
        }

        return entries
    }

    func rowRectsForColumn(
        windowIds: [NodeId],
        windowsById: [NodeId: ZigNiriWindowView],
        columnRect: CGRect,
        orientation: Monitor.Orientation,
        secondaryGap: CGFloat
    ) -> [CGRect] {
        guard !windowIds.isEmpty else { return [] }

        let secondarySpan = orientation == .horizontal ? columnRect.height : columnRect.width
        let availableSecondary = max(0, secondarySpan - CGFloat(max(0, windowIds.count - 1)) * secondaryGap)

        var fixedTotal: CGFloat = 0
        var sizingValues = Array(repeating: CGFloat(1), count: windowIds.count)
        var isFixed = Array(repeating: false, count: windowIds.count)
        var autoTotalWeight: CGFloat = 0

        for index in windowIds.indices {
            guard let window = windowsById[windowIds[index]] else {
                autoTotalWeight += 1
                continue
            }
            switch window.height {
            case let .fixed(value):
                let clamped = max(16, value)
                sizingValues[index] = clamped
                isFixed[index] = true
                fixedTotal += clamped
            case let .auto(weight):
                let clamped = max(0.1, weight)
                sizingValues[index] = clamped
                autoTotalWeight += clamped
            }
        }

        let autoAvailable = max(0, availableSecondary - fixedTotal)
        let autoWeightDenominator = max(0.0001, autoTotalWeight)

        var rects: [CGRect] = []
        rects.reserveCapacity(windowIds.count)

        var cursor = orientation == .horizontal ? columnRect.minY : columnRect.minX
        for index in windowIds.indices {
            let remaining = windowIds.count - index - 1
            let remainingGap = CGFloat(max(0, remaining)) * secondaryGap
            let endEdge = orientation == .horizontal ? columnRect.maxY : columnRect.maxX
            let remainingSpan = max(0, endEdge - cursor - remainingGap)

            let proposedSize: CGFloat
            if isFixed[index] {
                proposedSize = sizingValues[index]
            } else {
                proposedSize = autoAvailable * (sizingValues[index] / autoWeightDenominator)
            }

            var size = min(proposedSize, remainingSpan)
            if index == windowIds.count - 1 {
                size = max(0, remainingSpan)
            }

            let rect: CGRect
            if orientation == .horizontal {
                rect = CGRect(
                    x: columnRect.minX,
                    y: cursor,
                    width: columnRect.width,
                    height: max(0, size)
                )
                cursor = rect.maxY + secondaryGap
            } else {
                rect = CGRect(
                    x: cursor,
                    y: columnRect.minY,
                    width: max(0, size),
                    height: columnRect.height
                )
                cursor = rect.maxX + secondaryGap
            }
            rects.append(rect)
        }

        return rects
    }

    func applyColumnDisplayMutation(
        columnId: NodeId,
        display: ColumnDisplay,
        workspaceId: WorkspaceDescriptor.ID,
        selection: ZigNiriSelection?
    ) -> ZigNiriMutationResult {
        guard let context = ensureRuntimeContext(for: workspaceId) else {
            return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
        }
        let preFrames = captureNodeFrames(in: workspaceId)

        let mutation = mutateRuntimeState(context: context, workspaceId: workspaceId) { export in
            guard let columnIndex = export.columns.firstIndex(where: { $0.columnId == columnId }) else {
                return false
            }
            let column = export.columns[columnIndex]
            let isTabbed = display == .tabbed
            guard column.isTabbed != isTabbed else {
                return false
            }

            let nextActiveTile: Int
            if column.windowCount == 0 {
                nextActiveTile = 0
            } else {
                nextActiveTile = min(max(column.activeTileIdx, 0), column.windowCount - 1)
            }

            export.columns[columnIndex] = ZigNiriStateKernel.RuntimeColumnState(
                columnId: column.columnId,
                windowStart: column.windowStart,
                windowCount: column.windowCount,
                activeTileIdx: nextActiveTile,
                isTabbed: isTabbed,
                sizeValue: column.sizeValue,
                widthKind: column.widthKind,
                isFullWidth: column.isFullWidth,
                hasSavedWidth: column.hasSavedWidth,
                savedWidthKind: column.savedWidthKind,
                savedWidthValue: column.savedWidthValue
            )
            return true
        }
        guard mutation.rc == 0 else {
            return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
        }

        guard ensureSyncedViewIfNeeded(workspaceId: workspaceId) else {
            return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
        }
        var view = ensureWorkspaceView(for: workspaceId)
        if let selection {
            view.selection = normalizedSelection(selection, in: view)
        }
        view = storeWorkspaceView(view, workspaceId: workspaceId)
        let structuralAnimationActive = mutation.applied
        if structuralAnimationActive {
            scheduleStructuralAnimation(in: workspaceId, from: preFrames)
        }

        return ZigNiriMutationResult(
            applied: mutation.applied,
            workspaceId: workspaceId,
            selection: view.selection,
            affectedNodeIds: mutation.applied ? [columnId] : [],
            removedNodeIds: [],
            structuralAnimationActive: structuralAnimationActive
        )
    }

    func applyColumnActiveWindowMutation(
        columnId: NodeId,
        windowIndex: Int,
        workspaceId: WorkspaceDescriptor.ID,
        selection: ZigNiriSelection?
    ) -> ZigNiriMutationResult {
        guard let context = ensureRuntimeContext(for: workspaceId) else {
            return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
        }

        let mutation = mutateRuntimeState(context: context, workspaceId: workspaceId) { export in
            guard let columnIndex = export.columns.firstIndex(where: { $0.columnId == columnId }) else {
                return false
            }
            let column = export.columns[columnIndex]
            guard column.windowCount > 0 else { return false }

            let clamped = min(max(windowIndex, 0), column.windowCount - 1)
            guard column.activeTileIdx != clamped else {
                return false
            }
            export.columns[columnIndex] = ZigNiriStateKernel.RuntimeColumnState(
                columnId: column.columnId,
                windowStart: column.windowStart,
                windowCount: column.windowCount,
                activeTileIdx: clamped,
                isTabbed: column.isTabbed,
                sizeValue: column.sizeValue,
                widthKind: column.widthKind,
                isFullWidth: column.isFullWidth,
                hasSavedWidth: column.hasSavedWidth,
                savedWidthKind: column.savedWidthKind,
                savedWidthValue: column.savedWidthValue
            )
            return true
        }
        guard mutation.rc == 0 else {
            return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
        }

        guard ensureSyncedViewIfNeeded(workspaceId: workspaceId) else {
            return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
        }
        var view = ensureWorkspaceView(for: workspaceId)
        if let selection {
            view.selection = selection
        } else if let column = view.columns.first(where: { $0.nodeId == columnId }),
                  column.windowIds.indices.contains(min(max(windowIndex, 0), max(0, column.windowIds.count - 1)))
        {
            let activeWindowId = column.windowIds[min(max(windowIndex, 0), column.windowIds.count - 1)]
            view.selection = ZigNiriSelection(selectedNodeId: activeWindowId, focusedWindowId: activeWindowId)
        }
        view = storeWorkspaceView(view, workspaceId: workspaceId)

        return ZigNiriMutationResult(
            applied: mutation.applied,
            workspaceId: workspaceId,
            selection: view.selection,
            affectedNodeIds: mutation.applied ? [columnId] : [],
            removedNodeIds: []
        )
    }

    func applyColumnWidthMutation(
        columnId: NodeId,
        width: ProportionalSize,
        workspaceId: WorkspaceDescriptor.ID,
        selection: ZigNiriSelection?
    ) -> ZigNiriMutationResult {
        guard let context = ensureRuntimeContext(for: workspaceId) else {
            return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
        }
        let preFrames = captureNodeFrames(in: workspaceId)

        let mutation = mutateRuntimeState(context: context, workspaceId: workspaceId) { export in
            guard let columnIndex = export.columns.firstIndex(where: { $0.columnId == columnId }) else {
                return false
            }

            let column = export.columns[columnIndex]
            let encodedWidth = ZigNiriStateKernel.encodeWidth(width)
            guard column.widthKind != encodedWidth.kind
                || column.sizeValue != encodedWidth.value
                || column.isFullWidth
                || column.hasSavedWidth
            else {
                return false
            }

            export.columns[columnIndex] = ZigNiriStateKernel.RuntimeColumnState(
                columnId: column.columnId,
                windowStart: column.windowStart,
                windowCount: column.windowCount,
                activeTileIdx: column.activeTileIdx,
                isTabbed: column.isTabbed,
                sizeValue: encodedWidth.value,
                widthKind: encodedWidth.kind,
                isFullWidth: false,
                hasSavedWidth: false,
                savedWidthKind: encodedWidth.kind,
                savedWidthValue: encodedWidth.value
            )
            return true
        }

        guard mutation.rc == 0 else {
            return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
        }

        guard ensureSyncedViewIfNeeded(workspaceId: workspaceId) else {
            return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
        }
        var view = ensureWorkspaceView(for: workspaceId)
        if let selection {
            view.selection = normalizedSelection(selection, in: view)
        }
        view = storeWorkspaceView(view, workspaceId: workspaceId)
        let structuralAnimationActive = mutation.applied
        if structuralAnimationActive {
            scheduleStructuralAnimation(in: workspaceId, from: preFrames)
        }

        return ZigNiriMutationResult(
            applied: mutation.applied,
            workspaceId: workspaceId,
            selection: view.selection,
            affectedNodeIds: mutation.applied ? [columnId] : [],
            removedNodeIds: [],
            structuralAnimationActive: structuralAnimationActive
        )
    }

    func applyColumnFullWidthToggleMutation(
        columnId: NodeId,
        workspaceId: WorkspaceDescriptor.ID,
        selection: ZigNiriSelection?
    ) -> ZigNiriMutationResult {
        guard let context = ensureRuntimeContext(for: workspaceId) else {
            return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
        }
        let preFrames = captureNodeFrames(in: workspaceId)

        let mutation = mutateRuntimeState(context: context, workspaceId: workspaceId) { export in
            guard let columnIndex = export.columns.firstIndex(where: { $0.columnId == columnId }) else {
                return false
            }

            let column = export.columns[columnIndex]
            let nextColumn: ZigNiriStateKernel.RuntimeColumnState
            if column.isFullWidth {
                let restoredWidthKind: UInt8
                let restoredWidthValue: Double
                if column.hasSavedWidth {
                    restoredWidthKind = column.savedWidthKind
                    restoredWidthValue = column.savedWidthValue
                } else {
                    restoredWidthKind = ZigNiriStateKernel.sizeKindProportion
                    restoredWidthValue = 1.0
                }

                nextColumn = ZigNiriStateKernel.RuntimeColumnState(
                    columnId: column.columnId,
                    windowStart: column.windowStart,
                    windowCount: column.windowCount,
                    activeTileIdx: column.activeTileIdx,
                    isTabbed: column.isTabbed,
                    sizeValue: restoredWidthValue,
                    widthKind: restoredWidthKind,
                    isFullWidth: false,
                    hasSavedWidth: false,
                    savedWidthKind: restoredWidthKind,
                    savedWidthValue: restoredWidthValue
                )
            } else {
                nextColumn = ZigNiriStateKernel.RuntimeColumnState(
                    columnId: column.columnId,
                    windowStart: column.windowStart,
                    windowCount: column.windowCount,
                    activeTileIdx: column.activeTileIdx,
                    isTabbed: column.isTabbed,
                    sizeValue: column.sizeValue,
                    widthKind: column.widthKind,
                    isFullWidth: true,
                    hasSavedWidth: true,
                    savedWidthKind: column.widthKind,
                    savedWidthValue: column.sizeValue
                )
            }

            guard nextColumn != column else {
                return false
            }
            export.columns[columnIndex] = nextColumn
            return true
        }

        guard mutation.rc == 0 else {
            return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
        }

        guard ensureSyncedViewIfNeeded(workspaceId: workspaceId) else {
            return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
        }
        var view = ensureWorkspaceView(for: workspaceId)
        if let selection {
            view.selection = selection
        }
        view = storeWorkspaceView(view, workspaceId: workspaceId)
        let structuralAnimationActive = mutation.applied
        if structuralAnimationActive {
            scheduleStructuralAnimation(in: workspaceId, from: preFrames)
        }

        return ZigNiriMutationResult(
            applied: mutation.applied,
            workspaceId: workspaceId,
            selection: view.selection,
            affectedNodeIds: mutation.applied ? [columnId] : [],
            removedNodeIds: [],
            structuralAnimationActive: structuralAnimationActive
        )
    }

    func applyWindowSizingMutation(
        windowId: NodeId,
        mode: SizingMode,
        workspaceId: WorkspaceDescriptor.ID,
        selection: ZigNiriSelection?
    ) -> ZigNiriMutationResult {
        guard ensureRuntimeContext(for: workspaceId) != nil else {
            return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
        }
        guard ensureSyncedViewIfNeeded(workspaceId: workspaceId) else {
            return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
        }
        let preFrames = captureNodeFrames(in: workspaceId)
        var view = ensureWorkspaceView(for: workspaceId)
        if let selection {
            view.selection = selection
        }
        guard var window = view.windowsById[windowId] else {
            return .noChange(workspaceId: workspaceId, selection: view.selection)
        }

        let previousMode = windowSizingModesByNodeId[windowId] ?? window.sizingMode
        guard previousMode != mode else {
            return .noChange(workspaceId: workspaceId, selection: view.selection)
        }

        var affectedNodeIds: [NodeId] = [windowId]
        var needsRuntimeRefresh = false

        if mode == .fullscreen {
            for candidateId in view.windowsById.keys where candidateId != windowId {
                guard var candidateWindow = view.windowsById[candidateId] else { continue }
                let candidateMode = windowSizingModesByNodeId[candidateId] ?? candidateWindow.sizingMode
                guard candidateMode == .fullscreen else { continue }

                affectedNodeIds.append(candidateId)
                windowSizingModesByNodeId[candidateId] = .normal
                candidateWindow.sizingMode = .normal

                if let restoredHeight = savedWindowHeightsByNodeId.removeValue(forKey: candidateId) {
                    let restoreOutcome = setWindowHeightInRuntime(
                        windowId: candidateId,
                        height: restoredHeight,
                        workspaceId: workspaceId
                    )
                    if restoreOutcome.applied {
                        needsRuntimeRefresh = true
                    } else if restoreOutcome.rc != 0 {
                        candidateWindow.height = restoredHeight
                    }
                }
                view.windowsById[candidateId] = candidateWindow
            }
        }

        if previousMode == .normal, mode == .fullscreen {
            savedWindowHeightsByNodeId[windowId] = window.height
        } else if previousMode == .fullscreen,
                  mode == .normal,
                  let savedHeight = savedWindowHeightsByNodeId.removeValue(forKey: windowId)
        {
            let restoreOutcome = setWindowHeightInRuntime(
                windowId: windowId,
                height: savedHeight,
                workspaceId: workspaceId
            )
            if restoreOutcome.applied {
                needsRuntimeRefresh = true
            } else if restoreOutcome.rc != 0 {
                window.height = savedHeight
            }
        }

        if needsRuntimeRefresh {
            guard ensureSyncedViewIfNeeded(workspaceId: workspaceId) else {
                return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
            }
            view = ensureWorkspaceView(for: workspaceId)
            guard let refreshedWindow = view.windowsById[windowId] else {
                return .noChange(workspaceId: workspaceId, selection: view.selection)
            }
            window = refreshedWindow
        }

        windowSizingModesByNodeId[windowId] = mode
        window.sizingMode = mode
        view.windowsById[windowId] = window
        view = storeWorkspaceView(view, workspaceId: workspaceId)
        scheduleStructuralAnimation(in: workspaceId, from: preFrames)

        return ZigNiriMutationResult(
            applied: true,
            workspaceId: workspaceId,
            selection: view.selection,
            affectedNodeIds: affectedNodeIds,
            removedNodeIds: [],
            structuralAnimationActive: true
        )
    }

    func applyWindowHeightMutation(
        windowId: NodeId,
        height: WeightedSize,
        workspaceId: WorkspaceDescriptor.ID,
        selection: ZigNiriSelection?
    ) -> ZigNiriMutationResult {
        let mutation = setWindowHeightInRuntime(
            windowId: windowId,
            height: height,
            workspaceId: workspaceId
        )
        guard mutation.rc == 0 else {
            return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
        }

        guard ensureSyncedViewIfNeeded(workspaceId: workspaceId) else {
            return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
        }
        var view = ensureWorkspaceView(for: workspaceId)
        if let selection {
            view.selection = selection
        }
        view = storeWorkspaceView(view, workspaceId: workspaceId)

        return ZigNiriMutationResult(
            applied: mutation.applied,
            workspaceId: workspaceId,
            selection: view.selection,
            affectedNodeIds: mutation.applied ? [windowId] : [],
            removedNodeIds: []
        )
    }

    func applyRemoveWindowMutation(
        windowId: NodeId,
        workspaceId: WorkspaceDescriptor.ID,
        selection: ZigNiriSelection?
    ) -> ZigNiriMutationResult {
        guard let context = ensureRuntimeContext(for: workspaceId) else {
            return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
        }

        let request = ZigNiriStateKernel.MutationRequest(
            op: .removeWindow,
            sourceWindowId: windowId
        )
        let outcome = ZigNiriStateKernel.applyMutation(
            context: context,
            request: .init(
                request: request,
                placeholderColumnId: UUID()
            )
        )
        guard outcome.rc == 0 else {
            return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
        }

        if outcome.applied {
            markWorkspaceDirty(workspaceId)
        }

        guard ensureSyncedViewIfNeeded(workspaceId: workspaceId) else {
            return .noChange(workspaceId: workspaceId, selection: workspaceViews[workspaceId]?.selection)
        }
        var view = ensureWorkspaceView(for: workspaceId)
        if let selection {
            view.selection = selection
        }
        view = storeWorkspaceView(view, workspaceId: workspaceId)

        return ZigNiriMutationResult(
            applied: outcome.applied,
            workspaceId: workspaceId,
            selection: view.selection,
            affectedNodeIds: [],
            removedNodeIds: outcome.applied ? [windowId] : []
        )
    }

    private func setWindowHeightInRuntime(
        windowId: NodeId,
        height: WeightedSize,
        workspaceId: WorkspaceDescriptor.ID
    ) -> RuntimeStateMutationOutcome {
        guard let context = ensureRuntimeContext(for: workspaceId) else {
            return RuntimeStateMutationOutcome(rc: -1, applied: false)
        }

        return mutateRuntimeState(context: context, workspaceId: workspaceId) { export in
            guard let windowIndex = export.windows.firstIndex(where: { $0.windowId == windowId }) else {
                return false
            }

            let runtimeWindow = export.windows[windowIndex]
            let encodedHeight = ZigNiriStateKernel.encodeHeight(height)
            let nextSizeValue: Double
            switch height {
            case let .auto(weight):
                nextSizeValue = Double(weight)
            case .fixed:
                nextSizeValue = 1.0
            }

            if runtimeWindow.heightKind == encodedHeight.kind,
               runtimeWindow.heightValue == encodedHeight.value,
               runtimeWindow.sizeValue == nextSizeValue
            {
                return false
            }

            export.windows[windowIndex] = ZigNiriStateKernel.RuntimeWindowState(
                windowId: runtimeWindow.windowId,
                columnId: runtimeWindow.columnId,
                columnIndex: runtimeWindow.columnIndex,
                sizeValue: nextSizeValue,
                heightKind: encodedHeight.kind,
                heightValue: encodedHeight.value
            )
            return true
        }
    }

    private func mutateRuntimeState(
        context: ZigNiriLayoutKernel.LayoutContext,
        workspaceId: WorkspaceDescriptor.ID,
        mutate: (inout ZigNiriStateKernel.RuntimeStateExport) -> Bool
    ) -> RuntimeStateMutationOutcome {
        var export: ZigNiriStateKernel.RuntimeStateExport
        switch ZigNiriStateKernel.snapshotRuntimeStateResult(context: context) {
        case let .success(snapshot):
            export = snapshot
        case let .failure(error):
            return RuntimeStateMutationOutcome(rc: error.rc, applied: false)
        }

        let applied = mutate(&export)
        guard applied else {
            return RuntimeStateMutationOutcome(rc: 0, applied: false)
        }

        normalizeRuntimeExport(&export)
        let rc = ZigNiriStateKernel.seedRuntimeState(
            context: context,
            export: export
        )
        if rc == 0 {
            markWorkspaceDirty(workspaceId)
        }
        return RuntimeStateMutationOutcome(rc: rc, applied: rc == 0)
    }

    func ensureWorkspaceView(for workspaceId: WorkspaceDescriptor.ID) -> ZigNiriWorkspaceView {
        if let existing = workspaceViews[workspaceId] {
            return existing
        }
        let view = ZigNiriWorkspaceView(
            workspaceId: workspaceId,
            columns: [],
            windowsById: [:],
            selection: nil
        )
        workspaceViews[workspaceId] = view
        return view
    }

    func markWorkspaceDirty(_ workspaceId: WorkspaceDescriptor.ID) {
        dirtyWorkspaceIds.insert(workspaceId)
    }

    @discardableResult
    func ensureSyncedViewIfNeeded(workspaceId: WorkspaceDescriptor.ID) -> Bool {
        if workspaceViews[workspaceId] == nil || dirtyWorkspaceIds.contains(workspaceId) {
            return syncWorkspaceViewFromRuntime(workspaceId: workspaceId)
        }
        return true
    }

    @discardableResult
    func storeWorkspaceView(
        _ view: ZigNiriWorkspaceView,
        workspaceId: WorkspaceDescriptor.ID,
        allowNilWhenRequested: Bool = false
    ) -> ZigNiriWorkspaceView {
        var normalizedView = view
        normalizedView.selection = normalizedSelection(
            normalizedView.selection,
            in: normalizedView,
            allowNilWhenRequested: allowNilWhenRequested
        )
        applyFocusState(to: &normalizedView)
        workspaceViews[workspaceId] = normalizedView
        return normalizedView
    }

    func ensureRuntimeContext(for workspaceId: WorkspaceDescriptor.ID) -> ZigNiriLayoutKernel.LayoutContext? {
        if let context = layoutContexts[workspaceId] {
            return context
        }
        guard let context = ZigNiriLayoutKernel.LayoutContext() else {
            return nil
        }
        let bootstrapExport = runtimeBootstrapExport(for: workspaceId)
        let seedRC = ZigNiriStateKernel.seedRuntimeState(
            context: context,
            export: bootstrapExport
        )
        guard seedRC == 0 else {
            return nil
        }
        layoutContexts[workspaceId] = context
        markWorkspaceDirty(workspaceId)
        return context
    }

    func runtimeBootstrapExport(for workspaceId: WorkspaceDescriptor.ID) -> ZigNiriStateKernel.RuntimeStateExport {
        guard let view = workspaceViews[workspaceId], !view.columns.isEmpty else {
            return ZigNiriStateKernel.RuntimeStateExport(
                columns: [
                    .init(
                        columnId: NodeId(),
                        windowStart: 0,
                        windowCount: 0,
                        activeTileIdx: 0,
                        isTabbed: false,
                        sizeValue: 1.0
                    ),
                ],
                windows: []
            )
        }

        var runtimeColumns: [ZigNiriStateKernel.RuntimeColumnState] = []
        runtimeColumns.reserveCapacity(max(1, view.columns.count))

        var runtimeWindows: [ZigNiriStateKernel.RuntimeWindowState] = []
        for (columnIndex, column) in view.columns.enumerated() {
            let encodedWidth = ZigNiriStateKernel.encodeWidth(column.width)
            let start = runtimeWindows.count
            for windowId in column.windowIds {
                guard let window = view.windowsById[windowId] else { continue }
                let encodedHeight = ZigNiriStateKernel.encodeHeight(window.height)
                let sizeValue: Double
                switch window.height {
                case let .auto(weight):
                    sizeValue = Double(weight)
                case .fixed:
                    sizeValue = 1.0
                }
                runtimeWindows.append(
                    ZigNiriStateKernel.RuntimeWindowState(
                        windowId: window.nodeId,
                        columnId: column.nodeId,
                        columnIndex: columnIndex,
                        sizeValue: sizeValue,
                        heightKind: encodedHeight.kind,
                        heightValue: encodedHeight.value
                    )
                )
            }

            runtimeColumns.append(
                ZigNiriStateKernel.RuntimeColumnState(
                    columnId: column.nodeId,
                    windowStart: start,
                    windowCount: runtimeWindows.count - start,
                    activeTileIdx: column.activeWindowIndex ?? 0,
                    isTabbed: column.display == .tabbed,
                    sizeValue: encodedWidth.value,
                    widthKind: encodedWidth.kind,
                    isFullWidth: column.isFullWidth,
                    hasSavedWidth: false,
                    savedWidthKind: encodedWidth.kind,
                    savedWidthValue: encodedWidth.value
                )
            )
        }

        if runtimeColumns.isEmpty {
            runtimeColumns.append(
                .init(
                    columnId: NodeId(),
                    windowStart: 0,
                    windowCount: 0,
                    activeTileIdx: 0,
                    isTabbed: false,
                    sizeValue: 1.0
                )
            )
        }

        return ZigNiriStateKernel.RuntimeStateExport(
            columns: runtimeColumns,
            windows: runtimeWindows
        )
    }

    @discardableResult
    func syncWorkspaceViewFromRuntime(workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let context = layoutContexts[workspaceId] else {
            return false
        }
        let export: ZigNiriStateKernel.RuntimeStateExport
        switch ZigNiriStateKernel.snapshotRuntimeStateResult(context: context) {
        case let .success(snapshot):
            export = snapshot
        case .failure:
            return false
        }

        let previousView = workspaceViews[workspaceId]
        var previousColumnsById: [NodeId: ZigNiriColumnView] = [:]
        if let previousView {
            previousColumnsById.reserveCapacity(previousView.columns.count)
            for column in previousView.columns {
                previousColumnsById[column.nodeId] = column
            }
        }
        var columns: [ZigNiriColumnView] = []
        columns.reserveCapacity(export.columns.count)

        var windowsById: [NodeId: ZigNiriWindowView] = [:]
        windowsById.reserveCapacity(export.windows.count)

        var currentNodeIds = Set<NodeId>()
        currentNodeIds.reserveCapacity(export.windows.count)

        for runtimeColumn in export.columns {
            let start = runtimeColumn.windowStart
            let count = runtimeColumn.windowCount
            let hasValidRange = start >= 0
                && count >= 0
                && start <= export.windows.count
                && count <= export.windows.count - start
            let end = hasValidRange ? start + count : start

            var columnWindowIds: [NodeId] = []
            columnWindowIds.reserveCapacity(max(0, count))

            if hasValidRange {
                for index in start ..< end {
                    let runtimeWindow = export.windows[index]
                    let handle = windowHandlesByNodeId[runtimeWindow.windowId]
                        ?? windowHandlesByUUID[runtimeWindow.windowId.uuid]
                    guard let handle else {
                        continue
                    }

                    windowHandlesByNodeId[runtimeWindow.windowId] = handle
                    windowNodeIdsByHandle[handle] = runtimeWindow.windowId
                    windowHandlesByUUID[handle.id] = handle
                    currentNodeIds.insert(runtimeWindow.windowId)

                    let priorWindow = previousView?.windowsById[runtimeWindow.windowId]
                    let height = ZigNiriStateKernel.decodeHeight(
                        kind: runtimeWindow.heightKind,
                        value: runtimeWindow.heightValue
                    ) ?? priorWindow?.height ?? .default
                    let sizingMode = windowSizingModesByNodeId[runtimeWindow.windowId]
                        ?? priorWindow?.sizingMode
                        ?? .normal

                    windowsById[runtimeWindow.windowId] = ZigNiriWindowView(
                        nodeId: runtimeWindow.windowId,
                        handle: handle,
                        columnId: runtimeColumn.columnId,
                        frame: priorWindow?.frame,
                        sizingMode: sizingMode,
                        height: height,
                        isFocused: false
                    )
                    columnWindowIds.append(runtimeWindow.windowId)
                }
            }

            let activeWindowIndex: Int?
            if columnWindowIds.isEmpty {
                activeWindowIndex = nil
            } else {
                activeWindowIndex = min(max(runtimeColumn.activeTileIdx, 0), columnWindowIds.count - 1)
            }
            let priorColumn = previousColumnsById[runtimeColumn.columnId]
            let width = ZigNiriStateKernel.decodeWidth(
                kind: runtimeColumn.widthKind,
                value: runtimeColumn.sizeValue
            ) ?? priorColumn?.width ?? .default

            columns.append(
                ZigNiriColumnView(
                    nodeId: runtimeColumn.columnId,
                    windowIds: columnWindowIds,
                    display: runtimeColumn.isTabbed ? .tabbed : .normal,
                    activeWindowIndex: activeWindowIndex,
                    width: width,
                    isFullWidth: runtimeColumn.isFullWidth
                )
            )
        }

        var nextView = ZigNiriWorkspaceView(
            workspaceId: workspaceId,
            columns: columns,
            windowsById: windowsById,
            selection: previousView?.selection
        )
        nextView = storeWorkspaceView(nextView, workspaceId: workspaceId)

        let removedNodeIds = updateNodeReferences(for: workspaceId, currentNodeIds: currentNodeIds)
        for removedNodeId in removedNodeIds {
            cleanupWindowMappings(for: removedNodeId)
        }

        dirtyWorkspaceIds.remove(workspaceId)
        return true
    }

    func updateNodeReferences(
        for workspaceId: WorkspaceDescriptor.ID,
        currentNodeIds: Set<NodeId>
    ) -> [NodeId] {
        let previousNodeIds = workspaceNodeIds[workspaceId] ?? []
        let addedNodeIds = currentNodeIds.subtracting(previousNodeIds)
        let removedNodeIds = previousNodeIds.subtracting(currentNodeIds)

        workspaceNodeIds[workspaceId] = currentNodeIds

        for nodeId in addedNodeIds {
            nodeReferenceCounts[nodeId, default: 0] += 1
        }

        var cleanupCandidates: [NodeId] = []
        cleanupCandidates.reserveCapacity(removedNodeIds.count)
        for nodeId in removedNodeIds {
            let nextCount = (nodeReferenceCounts[nodeId] ?? 1) - 1
            if nextCount <= 0 {
                nodeReferenceCounts.removeValue(forKey: nodeId)
                cleanupCandidates.append(nodeId)
            } else {
                nodeReferenceCounts[nodeId] = nextCount
            }
        }

        return cleanupCandidates
    }

    func normalizeRuntimeExport(_ export: inout ZigNiriStateKernel.RuntimeStateExport) {
        let maxPerColumn = max(1, maxWindowsPerColumn)
        guard runtimeExportNeedsNormalization(export, maxPerColumn: maxPerColumn) else {
            return
        }
        var windowsByColumn = groupedRuntimeWindowsByColumn(export)
        let normalized = rebuildNormalizedRuntimeExport(
            sourceColumns: export.columns,
            windowsByColumn: &windowsByColumn,
            sourceWindows: export.windows,
            maxPerColumn: maxPerColumn
        )
        export.columns = normalized.columns
        export.windows = normalized.windows
    }

    func runtimeExportNeedsNormalization(
        _ export: ZigNiriStateKernel.RuntimeStateExport,
        maxPerColumn: Int
    ) -> Bool {
        guard !export.columns.isEmpty else {
            return true
        }

        var seenWindowIds = Set<NodeId>()
        seenWindowIds.reserveCapacity(export.windows.count)

        for (columnIndex, column) in export.columns.enumerated() {
            let start = column.windowStart
            let count = column.windowCount
            guard start >= 0,
                  count >= 0,
                  start <= export.windows.count,
                  count <= export.windows.count - start
            else {
                return true
            }

            if count > maxPerColumn {
                return true
            }

            if count == 0 {
                if column.activeTileIdx != 0 {
                    return true
                }
                continue
            }

            if column.activeTileIdx < 0 || column.activeTileIdx >= count {
                return true
            }

            for index in start ..< start + count {
                let runtimeWindow = export.windows[index]
                if runtimeWindow.columnId != column.columnId || runtimeWindow.columnIndex != columnIndex {
                    return true
                }
                if !seenWindowIds.insert(runtimeWindow.windowId).inserted {
                    return true
                }
            }
        }

        return seenWindowIds.count != export.windows.count
    }

    func groupedRuntimeWindowsByColumn(
        _ export: ZigNiriStateKernel.RuntimeStateExport
    ) -> [NodeId: [ZigNiriStateKernel.RuntimeWindowState]] {
        var windowsByColumn: [NodeId: [ZigNiriStateKernel.RuntimeWindowState]] = [:]
        windowsByColumn.reserveCapacity(export.columns.count + 1)

        var orderedWindowIds = Set<NodeId>()
        orderedWindowIds.reserveCapacity(export.windows.count)

        for sourceColumn in export.columns {
            let start = sourceColumn.windowStart
            let count = sourceColumn.windowCount
            guard start >= 0,
                  count >= 0,
                  start <= export.windows.count,
                  count <= export.windows.count - start
            else {
                windowsByColumn[sourceColumn.columnId, default: []] = []
                continue
            }

            for runtimeWindow in export.windows[start ..< start + count] {
                windowsByColumn[sourceColumn.columnId, default: []].append(runtimeWindow)
                orderedWindowIds.insert(runtimeWindow.windowId)
            }
        }

        for runtimeWindow in export.windows where !orderedWindowIds.contains(runtimeWindow.windowId) {
            windowsByColumn[runtimeWindow.columnId, default: []].append(runtimeWindow)
        }

        return windowsByColumn
    }

    func rebuildNormalizedRuntimeExport(
        sourceColumns: [ZigNiriStateKernel.RuntimeColumnState],
        windowsByColumn: inout [NodeId: [ZigNiriStateKernel.RuntimeWindowState]],
        sourceWindows: [ZigNiriStateKernel.RuntimeWindowState],
        maxPerColumn: Int
    ) -> (columns: [ZigNiriStateKernel.RuntimeColumnState], windows: [ZigNiriStateKernel.RuntimeWindowState]) {
        var normalizedColumns: [ZigNiriStateKernel.RuntimeColumnState] = []
        normalizedColumns.reserveCapacity(max(1, sourceColumns.count))
        var normalizedWindows: [ZigNiriStateKernel.RuntimeWindowState] = []
        normalizedWindows.reserveCapacity(sourceWindows.count)

        var occupiedNodeIds = Set<NodeId>()
        occupiedNodeIds.reserveCapacity(sourceColumns.count + sourceWindows.count)
        occupiedNodeIds.formUnion(sourceColumns.map(\.columnId))
        occupiedNodeIds.formUnion(sourceWindows.map(\.windowId))

        for sourceColumn in sourceColumns {
            appendColumnWithSplits(
                sourceColumn: sourceColumn,
                windowsByColumn: &windowsByColumn,
                maxPerColumn: maxPerColumn,
                normalizedColumns: &normalizedColumns,
                normalizedWindows: &normalizedWindows,
                occupiedNodeIds: &occupiedNodeIds
            )
        }

        if !windowsByColumn.isEmpty {
            let orphanColumnIds = windowsByColumn.keys.sorted { lhs, rhs in
                lhs.uuid.uuidString < rhs.uuid.uuidString
            }
            for orphanColumnId in orphanColumnIds {
                appendColumnWithSplits(
                    sourceColumn: defaultRuntimeColumnState(columnId: orphanColumnId),
                    windowsByColumn: &windowsByColumn,
                    maxPerColumn: maxPerColumn,
                    normalizedColumns: &normalizedColumns,
                    normalizedWindows: &normalizedWindows,
                    occupiedNodeIds: &occupiedNodeIds
                )
            }
        }

        if normalizedColumns.isEmpty {
            normalizedColumns = [defaultRuntimeColumnState(columnId: NodeId())]
        }

        return (columns: normalizedColumns, windows: normalizedWindows)
    }

    func appendColumnWithSplits(
        sourceColumn: ZigNiriStateKernel.RuntimeColumnState,
        windowsByColumn: inout [NodeId: [ZigNiriStateKernel.RuntimeWindowState]],
        maxPerColumn: Int,
        normalizedColumns: inout [ZigNiriStateKernel.RuntimeColumnState],
        normalizedWindows: inout [ZigNiriStateKernel.RuntimeWindowState],
        occupiedNodeIds: inout Set<NodeId>
    ) {
        let columnWindows = windowsByColumn[sourceColumn.columnId] ?? []
        windowsByColumn.removeValue(forKey: sourceColumn.columnId)

        if columnWindows.isEmpty {
            let start = normalizedWindows.count
            normalizedColumns.append(
                ZigNiriStateKernel.RuntimeColumnState(
                    columnId: sourceColumn.columnId,
                    windowStart: start,
                    windowCount: 0,
                    activeTileIdx: 0,
                    isTabbed: sourceColumn.isTabbed,
                    sizeValue: sourceColumn.sizeValue,
                    widthKind: sourceColumn.widthKind,
                    isFullWidth: sourceColumn.isFullWidth,
                    hasSavedWidth: sourceColumn.hasSavedWidth,
                    savedWidthKind: sourceColumn.savedWidthKind,
                    savedWidthValue: sourceColumn.savedWidthValue
                )
            )
            return
        }

        let sourceActiveIndex = min(max(sourceColumn.activeTileIdx, 0), columnWindows.count - 1)
        var chunkStart = 0
        var chunkIndex = 0

        while chunkStart < columnWindows.count {
            let chunkEnd = min(columnWindows.count, chunkStart + maxPerColumn)
            let chunk = columnWindows[chunkStart ..< chunkEnd]
            let activeTileIdx: Int
            if sourceActiveIndex >= chunkStart, sourceActiveIndex < chunkEnd {
                activeTileIdx = sourceActiveIndex - chunkStart
            } else {
                activeTileIdx = 0
            }

            appendColumnChunk(
                sourceColumn: sourceColumn,
                chunk: chunk,
                chunkIndex: chunkIndex,
                activeTileIdx: activeTileIdx,
                normalizedColumns: &normalizedColumns,
                normalizedWindows: &normalizedWindows,
                occupiedNodeIds: &occupiedNodeIds
            )

            chunkStart = chunkEnd
            chunkIndex += 1
        }
    }

    func appendColumnChunk(
        sourceColumn: ZigNiriStateKernel.RuntimeColumnState,
        chunk: ArraySlice<ZigNiriStateKernel.RuntimeWindowState>,
        chunkIndex: Int,
        activeTileIdx: Int,
        normalizedColumns: inout [ZigNiriStateKernel.RuntimeColumnState],
        normalizedWindows: inout [ZigNiriStateKernel.RuntimeWindowState],
        occupiedNodeIds: inout Set<NodeId>
    ) {
        let isFirstChunk = chunkIndex == 0
        let columnId: NodeId
        if isFirstChunk {
            columnId = sourceColumn.columnId
        } else {
            columnId = splitColumnId(
                from: sourceColumn.columnId,
                splitIndex: chunkIndex,
                occupied: &occupiedNodeIds
            )
        }

        let start = normalizedWindows.count
        let columnIndex = normalizedColumns.count
        for runtimeWindow in chunk {
            normalizedWindows.append(
                ZigNiriStateKernel.RuntimeWindowState(
                    windowId: runtimeWindow.windowId,
                    columnId: columnId,
                    columnIndex: columnIndex,
                    sizeValue: runtimeWindow.sizeValue,
                    heightKind: runtimeWindow.heightKind,
                    heightValue: runtimeWindow.heightValue
                )
            )
        }

        if isFirstChunk {
            normalizedColumns.append(
                ZigNiriStateKernel.RuntimeColumnState(
                    columnId: columnId,
                    windowStart: start,
                    windowCount: chunk.count,
                    activeTileIdx: activeTileIdx,
                    isTabbed: sourceColumn.isTabbed,
                    sizeValue: sourceColumn.sizeValue,
                    widthKind: sourceColumn.widthKind,
                    isFullWidth: sourceColumn.isFullWidth,
                    hasSavedWidth: sourceColumn.hasSavedWidth,
                    savedWidthKind: sourceColumn.savedWidthKind,
                    savedWidthValue: sourceColumn.savedWidthValue
                )
            )
        } else {
            let spillColumn = defaultRuntimeColumnState(columnId: columnId)
            normalizedColumns.append(
                ZigNiriStateKernel.RuntimeColumnState(
                    columnId: columnId,
                    windowStart: start,
                    windowCount: chunk.count,
                    activeTileIdx: activeTileIdx,
                    isTabbed: sourceColumn.isTabbed,
                    sizeValue: spillColumn.sizeValue,
                    widthKind: spillColumn.widthKind,
                    isFullWidth: false,
                    hasSavedWidth: false,
                    savedWidthKind: spillColumn.savedWidthKind,
                    savedWidthValue: spillColumn.savedWidthValue
                )
            )
        }
    }

    func defaultRuntimeColumnState(columnId: NodeId) -> ZigNiriStateKernel.RuntimeColumnState {
        ZigNiriStateKernel.RuntimeColumnState(
            columnId: columnId,
            windowStart: 0,
            windowCount: 0,
            activeTileIdx: 0,
            isTabbed: false,
            sizeValue: 1.0,
            widthKind: ZigNiriStateKernel.sizeKindProportion,
            isFullWidth: false,
            hasSavedWidth: false,
            savedWidthKind: ZigNiriStateKernel.sizeKindProportion,
            savedWidthValue: 1.0
        )
    }

    func splitColumnId(
        from baseColumnId: NodeId,
        splitIndex: Int,
        occupied: inout Set<NodeId>
    ) -> NodeId {
        var salt = UInt32(max(1, splitIndex))
        while true {
            var raw = baseColumnId.uuid.uuid
            var encodedSalt = salt.littleEndian
            withUnsafeMutableBytes(of: &raw) { bytes in
                withUnsafeBytes(of: &encodedSalt) { saltBytes in
                    for idx in 0 ..< 4 {
                        bytes[12 + idx] ^= saltBytes[idx]
                    }
                    bytes[8] ^= saltBytes[0]
                    bytes[9] ^= saltBytes[1]
                }
            }
            let candidate = NodeId(uuid: UUID(uuid: raw))
            if candidate != baseColumnId, !occupied.contains(candidate) {
                occupied.insert(candidate)
                return candidate
            }
            salt &+= 1
        }
    }

    func nearestNonFullColumnIndex(
        columns: [ZigNiriStateKernel.RuntimeColumnState],
        windowsByColumn: [NodeId: [NodeId]],
        anchorIndex: Int,
        maxPerColumn: Int
    ) -> Int? {
        guard !columns.isEmpty else { return nil }
        let clampedAnchorIndex = min(max(anchorIndex, 0), columns.count - 1)

        var bestIndex: Int?
        var bestDistance = Int.max
        for (index, column) in columns.enumerated() {
            let count = windowsByColumn[column.columnId, default: []].count
            guard count < maxPerColumn else { continue }
            let distance = abs(index - clampedAnchorIndex)
            if distance < bestDistance || (distance == bestDistance && index < (bestIndex ?? Int.max)) {
                bestIndex = index
                bestDistance = distance
            }
        }
        return bestIndex
    }

    func preferredWindowId(
        in column: ZigNiriColumnView,
        focusedWindowId: NodeId?
    ) -> NodeId? {
        ZigNiriSelectionResolver.preferredWindowId(
            in: column,
            focusedWindowId: focusedWindowId
        )
    }

    func activeColumnIndex(
        in view: ZigNiriWorkspaceView,
        selectedNodeId: NodeId?,
        focusedWindowId: NodeId?
    ) -> Int? {
        if let selectedNodeId {
            if let selectedColumnIndex = view.columns.firstIndex(where: { $0.nodeId == selectedNodeId }) {
                return selectedColumnIndex
            }
            if let selectedWindowColumnIndex = view.columns.firstIndex(where: { $0.windowIds.contains(selectedNodeId) }) {
                return selectedWindowColumnIndex
            }
        }
        if let focusedWindowId,
           let focusedColumnIndex = view.columns.firstIndex(where: { $0.windowIds.contains(focusedWindowId) })
        {
            return focusedColumnIndex
        }
        if let firstPopulated = view.columns.firstIndex(where: { !$0.windowIds.isEmpty }) {
            return firstPopulated
        }
        return view.columns.isEmpty ? nil : 0
    }

    func cleanupWindowMappings(for nodeId: NodeId) {
        if let handle = windowHandlesByNodeId.removeValue(forKey: nodeId) {
            windowNodeIdsByHandle.removeValue(forKey: handle)
        }
        windowSizingModesByNodeId.removeValue(forKey: nodeId)
        savedWindowHeightsByNodeId.removeValue(forKey: nodeId)

        if !windowHandlesByNodeId.keys.contains(where: { $0.uuid == nodeId.uuid }) {
            windowHandlesByUUID.removeValue(forKey: nodeId.uuid)
        }
    }

    func normalizedSelection(
        _ selection: ZigNiriSelection?,
        in view: ZigNiriWorkspaceView,
        allowNilWhenRequested: Bool = false
    ) -> ZigNiriSelection? {
        if allowNilWhenRequested, selection == nil {
            return nil
        }
        guard !view.columns.isEmpty || !view.windowsById.isEmpty else {
            return nil
        }

        func containsNode(_ nodeId: NodeId) -> Bool {
            if view.windowsById[nodeId] != nil {
                return true
            }
            return view.columns.contains(where: { $0.nodeId == nodeId })
        }

        let firstWindowId = view.columns.lazy
            .compactMap { $0.windowIds.first }
            .first
            ?? view.windowsById.keys.first

        var selectedNodeId = selection?.selectedNodeId
        if let currentSelectedNodeId = selectedNodeId, !containsNode(currentSelectedNodeId) {
            selectedNodeId = nil
        }
        if selectedNodeId == nil {
            selectedNodeId = firstWindowId ?? view.columns.first?.nodeId
        }

        var focusedWindowId = selection?.focusedWindowId
        if let currentFocusedWindowId = focusedWindowId, view.windowsById[currentFocusedWindowId] == nil {
            focusedWindowId = nil
        }
        if focusedWindowId == nil,
           let selectedNodeId,
           view.windowsById[selectedNodeId] != nil
        {
            focusedWindowId = selectedNodeId
        }
        if focusedWindowId == nil {
            focusedWindowId = firstWindowId
        }

        return ZigNiriSelection(
            selectedNodeId: selectedNodeId,
            focusedWindowId: focusedWindowId
        )
    }

    func applyFocusState(to view: inout ZigNiriWorkspaceView) {
        let focusedWindowId = view.selection?.focusedWindowId
        let currentFocusedWindowId = view.windowsById.first(where: { $0.value.isFocused })?.key
        guard currentFocusedWindowId != focusedWindowId else {
            return
        }

        if let currentFocusedWindowId,
           var window = view.windowsById[currentFocusedWindowId]
        {
            window.isFocused = false
            view.windowsById[currentFocusedWindowId] = window
        }

        if let focusedWindowId,
           var window = view.windowsById[focusedWindowId]
        {
            window.isFocused = true
            view.windowsById[focusedWindowId] = window
        }
    }

    private func runtimeSelectionAnchor(
        selectedNodeId: NodeId?,
        in view: ZigNiriWorkspaceView?
    ) -> RuntimeSelectionAnchor? {
        guard let view else { return nil }
        guard let selectedNodeId = selectedNodeId ?? view.selection?.selectedNodeId else {
            if let firstColumn = view.columns.first {
                let firstWindow = preferredWindowId(
                    in: firstColumn,
                    focusedWindowId: view.selection?.focusedWindowId
                )
                return RuntimeSelectionAnchor(
                    windowId: firstWindow,
                    columnId: firstColumn.nodeId,
                    rowIndex: firstWindow.flatMap { rowIndex(for: $0, in: firstColumn.windowIds) }
                )
            }
            return nil
        }

        if let window = view.windowsById[selectedNodeId] {
            let row: Int?
            if let columnId = window.columnId,
               let column = view.columns.first(where: { $0.nodeId == columnId })
            {
                row = rowIndex(for: selectedNodeId, in: column.windowIds)
            } else {
                row = nil
            }
            return RuntimeSelectionAnchor(
                windowId: selectedNodeId,
                columnId: window.columnId,
                rowIndex: row
            )
        }

        guard let column = view.columns.first(where: { $0.nodeId == selectedNodeId }) else {
            return nil
        }
        let windowId = preferredWindowId(
            in: column,
            focusedWindowId: view.selection?.focusedWindowId
        )
        return RuntimeSelectionAnchor(
            windowId: windowId,
            columnId: column.nodeId,
            rowIndex: windowId.flatMap { rowIndex(for: $0, in: column.windowIds) }
        )
    }

    func runtimeNavigationRequest(
        for request: ZigNiriNavigationRequest,
        orientation: Monitor.Orientation,
        in view: ZigNiriWorkspaceView
    ) -> ZigNiriStateKernel.NavigationRequest? {
        let anchor = runtimeSelectionAnchor(
            selectedNodeId: view.selection?.selectedNodeId,
            in: view
        )

        switch request {
        case let .focus(direction):
            guard let anchor else { return nil }
            return ZigNiriStateKernel.NavigationRequest(
                op: .focusTarget,
                sourceWindowId: anchor.windowId,
                sourceColumnId: anchor.columnId,
                direction: direction,
                orientation: orientation,
                infiniteLoop: infiniteLoop
            )

        case let .move(direction):
            guard let anchor else { return nil }
            if let step = direction.primaryStep(for: orientation) {
                return ZigNiriStateKernel.NavigationRequest(
                    op: .moveByColumns,
                    sourceWindowId: anchor.windowId,
                    sourceColumnId: anchor.columnId,
                    direction: direction,
                    orientation: orientation,
                    infiniteLoop: infiniteLoop,
                    step: step,
                    targetRowIndex: anchor.rowIndex ?? -1
                )
            }
            if direction.secondaryStep(for: orientation) != nil {
                return ZigNiriStateKernel.NavigationRequest(
                    op: .moveVertical,
                    sourceWindowId: anchor.windowId,
                    sourceColumnId: anchor.columnId,
                    direction: direction,
                    orientation: orientation,
                    infiniteLoop: infiniteLoop
                )
            }
            return nil

        case .focusDownOrLeft:
            guard let anchor else { return nil }
            return ZigNiriStateKernel.NavigationRequest(
                op: .focusDownOrLeft,
                sourceWindowId: anchor.windowId,
                sourceColumnId: anchor.columnId
            )

        case .focusUpOrRight:
            guard let anchor else { return nil }
            return ZigNiriStateKernel.NavigationRequest(
                op: .focusUpOrRight,
                sourceWindowId: anchor.windowId,
                sourceColumnId: anchor.columnId
            )

        case .focusColumnFirst:
            return ZigNiriStateKernel.NavigationRequest(
                op: .focusColumnFirst,
                sourceWindowId: anchor?.windowId,
                sourceColumnId: anchor?.columnId
            )

        case .focusColumnLast:
            return ZigNiriStateKernel.NavigationRequest(
                op: .focusColumnLast,
                sourceWindowId: anchor?.windowId,
                sourceColumnId: anchor?.columnId
            )

        case let .focusColumn(index):
            return ZigNiriStateKernel.NavigationRequest(
                op: .focusColumnIndex,
                sourceWindowId: anchor?.windowId,
                sourceColumnId: anchor?.columnId,
                focusColumnIndex: index
            )

        case let .focusWindow(index):
            guard let anchor else { return nil }
            return ZigNiriStateKernel.NavigationRequest(
                op: .focusWindowIndex,
                sourceWindowId: anchor.windowId,
                sourceColumnId: anchor.columnId,
                focusWindowIndex: index
            )

        case .focusWindowTop:
            guard let anchor else { return nil }
            return ZigNiriStateKernel.NavigationRequest(
                op: .focusWindowTop,
                sourceWindowId: anchor.windowId,
                sourceColumnId: anchor.columnId
            )

        case .focusWindowBottom:
            guard let anchor else { return nil }
            return ZigNiriStateKernel.NavigationRequest(
                op: .focusWindowBottom,
                sourceWindowId: anchor.windowId,
                sourceColumnId: anchor.columnId
            )
        }
    }

    func navigationFallbackTarget(
        for request: ZigNiriNavigationRequest,
        in view: ZigNiriWorkspaceView
    ) -> NodeId? {
        switch request {
        case .focusColumnFirst:
            guard let column = view.columns.first else { return nil }
            return column.windowIds.first ?? column.nodeId
        case .focusColumnLast:
            guard let column = view.columns.last else { return nil }
            return column.windowIds.last ?? column.nodeId
        case let .focusColumn(index):
            guard view.columns.indices.contains(index) else { return nil }
            let column = view.columns[index]
            return column.windowIds.first ?? column.nodeId
        case let .focusWindow(index):
            let orderedWindowIds = view.columns.flatMap(\.windowIds)
            guard orderedWindowIds.indices.contains(index) else { return nil }
            return orderedWindowIds[index]
        case .focusDownOrLeft:
            return view.columns.first?.windowIds.first ?? view.selection?.selectedNodeId
        case .focusUpOrRight:
            return view.columns.last?.windowIds.last ?? view.selection?.selectedNodeId
        case .focusWindowTop:
            guard let selected = view.selection?.selectedNodeId else { return nil }
            guard let window = view.windowsById[selected],
                  let columnId = window.columnId,
                  let column = view.columns.first(where: { $0.nodeId == columnId })
            else {
                return view.columns.first?.windowIds.first
            }
            return column.windowIds.first
        case .focusWindowBottom:
            guard let selected = view.selection?.selectedNodeId else { return nil }
            guard let window = view.windowsById[selected],
                  let columnId = window.columnId,
                  let column = view.columns.first(where: { $0.nodeId == columnId })
            else {
                return view.columns.first?.windowIds.last
            }
            return column.windowIds.last
        case .focus, .move:
            return view.selection?.selectedNodeId
        }
    }

    func captureNodeFrames(in workspaceId: WorkspaceDescriptor.ID) -> [NodeId: CGRect] {
        guard let view = workspaceViews[workspaceId] else {
            return [:]
        }
        var framesByNodeId: [NodeId: CGRect] = [:]
        framesByNodeId.reserveCapacity(view.windowsById.count)
        for (windowId, window) in view.windowsById {
            if let frame = window.frame {
                framesByNodeId[windowId] = frame
            }
        }
        return framesByNodeId
    }

    func scheduleStructuralAnimation(
        in workspaceId: WorkspaceDescriptor.ID,
        from fromFramesByNodeId: [NodeId: CGRect],
        duration: TimeInterval = 0.18
    ) {
        structuralAnimationsByWorkspace[workspaceId] = StructuralAnimationState(
            kind: .mutation(fromFramesByNodeId: fromFramesByNodeId),
            startedAt: CACurrentMediaTime(),
            duration: max(0.01, duration)
        )
    }

    func applyStructuralAnimationIfNeeded(
        frames: [WindowHandle: CGRect],
        workspaceId: WorkspaceDescriptor.ID,
        orientation: Monitor.Orientation,
        at time: TimeInterval
    ) -> [WindowHandle: CGRect] {
        guard let animation = structuralAnimationsByWorkspace[workspaceId] else {
            return frames
        }
        let progress = max(0, min(1, (time - animation.startedAt) / animation.duration))
        if progress >= 1 {
            structuralAnimationsByWorkspace.removeValue(forKey: workspaceId)
            return frames
        }

        let appearOffset: CGFloat = 24
        var adjusted = frames
        switch animation.kind {
        case let .mutation(fromFramesByNodeId):
            for (handle, targetFrame) in frames {
                guard let nodeId = windowNodeIdsByHandle[handle] else { continue }
                let fromFrame = fromFramesByNodeId[nodeId] ?? shiftedFrame(
                    targetFrame,
                    orientation: orientation,
                    offset: appearOffset
                )
                adjusted[handle] = interpolatedFrame(from: fromFrame, to: targetFrame, progress: progress)
            }
        case .workspaceSwitch:
            let offset = CGFloat(1 - progress) * 32
            for (handle, frame) in frames {
                adjusted[handle] = shiftedFrame(frame, orientation: orientation, offset: offset)
            }
        }
        return adjusted
    }

    func shiftedFrame(
        _ frame: CGRect,
        orientation: Monitor.Orientation,
        offset: CGFloat
    ) -> CGRect {
        if orientation == .horizontal {
            return frame.offsetBy(dx: offset, dy: 0)
        }
        return frame.offsetBy(dx: 0, dy: offset)
    }

    func interpolatedFrame(from: CGRect, to: CGRect, progress: TimeInterval) -> CGRect {
        let t = CGFloat(max(0, min(1, progress)))
        return CGRect(
            x: from.origin.x + (to.origin.x - from.origin.x) * t,
            y: from.origin.y + (to.origin.y - from.origin.y) * t,
            width: from.width + (to.width - from.width) * t,
            height: from.height + (to.height - from.height) * t
        )
    }

    func rowIndex(for windowId: NodeId, in windowIds: [NodeId]) -> Int? {
        windowIds.firstIndex(of: windowId)
    }

    func columnIndex(for windowId: NodeId, in view: ZigNiriWorkspaceView) -> Int? {
        view.columns.firstIndex { $0.windowIds.contains(windowId) }
    }
}

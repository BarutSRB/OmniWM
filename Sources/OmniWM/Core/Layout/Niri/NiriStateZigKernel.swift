import CZigLayout
import Foundation

enum NiriStateZigKernel {
    struct Snapshot {
        struct ColumnEntry {
            let column: NiriContainer
            let columnIndex: Int
            let windowStart: Int
            let windowCount: Int
        }

        struct WindowEntry {
            let window: NiriWindow
            let column: NiriContainer
            let columnIndex: Int
            let rowIndex: Int
        }

        var columns: [OmniNiriStateColumnInput]
        var windows: [OmniNiriStateWindowInput]
        var columnEntries: [ColumnEntry]
        var windowEntries: [WindowEntry]
        var windowIndexByNodeId: [NodeId: Int]
        var columnIndexByNodeId: [NodeId: Int]
    }

    struct SelectionContext {
        let selectedWindowIndex: Int
        let selectedColumnIndex: Int
        let selectedRowIndex: Int
    }

    enum NavigationOp {
        case moveByColumns
        case moveVertical
        case focusTarget
        case focusDownOrLeft
        case focusUpOrRight
        case focusColumnFirst
        case focusColumnLast
        case focusColumnIndex
        case focusWindowIndex
        case focusWindowTop
        case focusWindowBottom
    }

    enum MutationOp: UInt8 {
        case moveWindowVertical = 0
        case swapWindowVertical = 1
        case moveWindowHorizontal = 2
        case swapWindowHorizontal = 3
        case swapWindowsByMove = 4
        case insertWindowByMove = 5
        case moveWindowToColumn = 6
        case createColumnAndMove = 7
        case insertWindowInNewColumn = 8
        case moveColumn = 9
        case consumeWindow = 10
        case expelWindow = 11
        case cleanupEmptyColumn = 12
        case normalizeColumnSizes = 13
        case normalizeWindowSizes = 14
        case balanceSizes = 15
        case addWindow = 16
        case removeWindow = 17
        case validateSelection = 18
        case fallbackSelectionOnRemoval = 19
    }

    enum MutationNodeKind: UInt8 {
        case none = 0
        case window = 1
        case column = 2
    }

    enum WorkspaceOp: UInt8 {
        case moveWindowToWorkspace = 0
        case moveColumnToWorkspace = 1
    }

    struct MutationNodeTarget {
        let kind: MutationNodeKind
        let index: Int
    }

    struct WorkspaceRequest {
        let op: WorkspaceOp
        let sourceWindowIndex: Int
        let sourceColumnIndex: Int
        let maxVisibleColumns: Int

        init(
            op: WorkspaceOp,
            sourceWindowIndex: Int = -1,
            sourceColumnIndex: Int = -1,
            maxVisibleColumns: Int = -1
        ) {
            self.op = op
            self.sourceWindowIndex = sourceWindowIndex
            self.sourceColumnIndex = sourceColumnIndex
            self.maxVisibleColumns = maxVisibleColumns
        }
    }

    struct NavigationRequest {
        let op: NavigationOp
        let direction: Direction?
        let orientation: Monitor.Orientation
        let infiniteLoop: Bool
        let selectedWindowIndex: Int
        let selectedColumnIndex: Int
        let selectedRowIndex: Int
        let step: Int
        let targetRowIndex: Int
        let targetColumnIndex: Int
        let targetWindowIndex: Int

        init(
            op: NavigationOp,
            selection: SelectionContext?,
            direction: Direction? = nil,
            orientation: Monitor.Orientation = .horizontal,
            infiniteLoop: Bool = false,
            step: Int = 0,
            targetRowIndex: Int = -1,
            targetColumnIndex: Int = -1,
            targetWindowIndex: Int = -1
        ) {
            self.op = op
            self.direction = direction
            self.orientation = orientation
            self.infiniteLoop = infiniteLoop
            selectedWindowIndex = selection?.selectedWindowIndex ?? -1
            selectedColumnIndex = selection?.selectedColumnIndex ?? -1
            selectedRowIndex = selection?.selectedRowIndex ?? -1
            self.step = step
            self.targetRowIndex = targetRowIndex
            self.targetColumnIndex = targetColumnIndex
            self.targetWindowIndex = targetWindowIndex
        }
    }

    struct MutationRequest {
        let op: MutationOp
        let sourceWindowIndex: Int
        let targetWindowIndex: Int
        let direction: Direction?
        let infiniteLoop: Bool
        let insertPosition: InsertPosition?
        let maxWindowsPerColumn: Int
        let sourceColumnIndex: Int
        let targetColumnIndex: Int
        let insertColumnIndex: Int
        let maxVisibleColumns: Int
        let selectedNodeKind: MutationNodeKind
        let selectedNodeIndex: Int
        let focusedWindowIndex: Int

        init(
            op: MutationOp,
            sourceWindowIndex: Int = -1,
            targetWindowIndex: Int = -1,
            direction: Direction? = nil,
            infiniteLoop: Bool = false,
            insertPosition: InsertPosition? = nil,
            maxWindowsPerColumn: Int = 1,
            sourceColumnIndex: Int = -1,
            targetColumnIndex: Int = -1,
            insertColumnIndex: Int = -1,
            maxVisibleColumns: Int = -1,
            selectedNodeKind: MutationNodeKind = .none,
            selectedNodeIndex: Int = -1,
            focusedWindowIndex: Int = -1
        ) {
            self.op = op
            self.sourceWindowIndex = sourceWindowIndex
            self.targetWindowIndex = targetWindowIndex
            self.direction = direction
            self.infiniteLoop = infiniteLoop
            self.insertPosition = insertPosition
            self.maxWindowsPerColumn = maxWindowsPerColumn
            self.sourceColumnIndex = sourceColumnIndex
            self.targetColumnIndex = targetColumnIndex
            self.insertColumnIndex = insertColumnIndex
            self.maxVisibleColumns = maxVisibleColumns
            self.selectedNodeKind = selectedNodeKind
            self.selectedNodeIndex = selectedNodeIndex
            self.focusedWindowIndex = focusedWindowIndex
        }
    }

    struct RuntimeColumnState: Equatable {
        let columnId: NodeId
        let windowStart: Int
        let windowCount: Int
        let activeTileIdx: Int
        let isTabbed: Bool
        let sizeValue: Double
        let widthKind: UInt8
        let isFullWidth: Bool
        let hasSavedWidth: Bool
        let savedWidthKind: UInt8
        let savedWidthValue: Double

        init(
            columnId: NodeId,
            windowStart: Int,
            windowCount: Int,
            activeTileIdx: Int,
            isTabbed: Bool,
            sizeValue: Double,
            widthKind: UInt8 = UInt8(truncatingIfNeeded: OMNI_NIRI_SIZE_KIND_PROPORTION.rawValue),
            isFullWidth: Bool = false,
            hasSavedWidth: Bool = false,
            savedWidthKind: UInt8 = UInt8(truncatingIfNeeded: OMNI_NIRI_SIZE_KIND_PROPORTION.rawValue),
            savedWidthValue: Double = 1.0
        ) {
            self.columnId = columnId
            self.windowStart = windowStart
            self.windowCount = windowCount
            self.activeTileIdx = activeTileIdx
            self.isTabbed = isTabbed
            self.sizeValue = sizeValue
            self.widthKind = widthKind
            self.isFullWidth = isFullWidth
            self.hasSavedWidth = hasSavedWidth
            self.savedWidthKind = savedWidthKind
            self.savedWidthValue = savedWidthValue
        }
    }

    struct RuntimeWindowState: Equatable {
        let windowId: NodeId
        let columnId: NodeId
        let columnIndex: Int
        let sizeValue: Double
        let heightKind: UInt8
        let heightValue: Double

        init(
            windowId: NodeId,
            columnId: NodeId,
            columnIndex: Int,
            sizeValue: Double,
            heightKind: UInt8 = UInt8(truncatingIfNeeded: OMNI_NIRI_HEIGHT_KIND_AUTO.rawValue),
            heightValue: Double = 1.0
        ) {
            self.windowId = windowId
            self.columnId = columnId
            self.columnIndex = columnIndex
            self.sizeValue = sizeValue
            self.heightKind = heightKind
            self.heightValue = heightValue
        }
    }

    struct RuntimeStateExport: Equatable {
        let columns: [RuntimeColumnState]
        let windows: [RuntimeWindowState]
    }

    struct DeltaColumnRecord: Equatable {
        let column: RuntimeColumnState
        let orderIndex: Int
    }

    struct DeltaWindowRecord: Equatable {
        let window: RuntimeWindowState
        let columnOrderIndex: Int
        let rowIndex: Int
    }

    struct DeltaExport {
        let columns: [DeltaColumnRecord]
        let windows: [DeltaWindowRecord]
        let removedColumnIds: [NodeId]
        let removedWindowIds: [NodeId]
        let refreshTabbedVisibilityColumnIds: [NodeId]
        let resetAllColumnCachedWidths: Bool
        let delegatedMoveColumn: (columnId: NodeId, direction: Direction)?
        let targetWindowId: NodeId?
        let targetNode: RuntimeNodeTarget?
        let sourceSelectionWindowId: NodeId?
        let targetSelectionWindowId: NodeId?
        let movedWindowId: NodeId?
        let generation: UInt64
    }

    enum TxnKind: UInt8 {
        case layout = 0
        case navigation = 1
        case mutation = 2
        case workspace = 3
    }

    enum TxnRequest {
        case navigation(context: NiriLayoutZigKernel.LayoutContext, request: NavigationApplyRequest)
        case mutation(context: NiriLayoutZigKernel.LayoutContext, request: MutationApplyRequest)
        case workspace(sourceContext: NiriLayoutZigKernel.LayoutContext, targetContext: NiriLayoutZigKernel.LayoutContext, request: WorkspaceApplyRequest)
    }

    struct TxnOutcome {
        let rc: Int32
        let kind: TxnKind
        let applied: Bool
        let targetWindowId: NodeId?
        let targetNode: RuntimeNodeTarget?
        let changedSourceContext: Bool
        let changedTargetContext: Bool
        let deltaColumnCount: Int
        let deltaWindowCount: Int
        let removedColumnCount: Int
        let removedWindowCount: Int
    }

    struct RuntimeNodeTarget: Equatable {
        let kind: MutationNodeKind
        let nodeId: NodeId
    }

    struct MutationApplyRequest {
        let request: MutationRequest
        let snapshot: Snapshot?
        let incomingWindowId: UUID?
        let createdColumnId: UUID?
        let placeholderColumnId: UUID?

        init(
            request: MutationRequest,
            snapshot: Snapshot? = nil,
            incomingWindowId: UUID? = nil,
            createdColumnId: UUID? = nil,
            placeholderColumnId: UUID? = nil
        ) {
            self.request = request
            self.snapshot = snapshot
            self.incomingWindowId = incomingWindowId
            self.createdColumnId = createdColumnId
            self.placeholderColumnId = placeholderColumnId
        }
    }

    struct MutationApplyOutcome {
        let rc: Int32
        let applied: Bool
        let targetWindowId: NodeId?
        let targetNode: RuntimeNodeTarget?
        let delta: DeltaExport?
    }

    struct WorkspaceApplyRequest {
        let request: WorkspaceRequest
        let sourceSnapshot: Snapshot?
        let targetCreatedColumnId: UUID?
        let sourcePlaceholderColumnId: UUID?

        init(
            request: WorkspaceRequest,
            sourceSnapshot: Snapshot? = nil,
            targetCreatedColumnId: UUID? = nil,
            sourcePlaceholderColumnId: UUID? = nil
        ) {
            self.request = request
            self.sourceSnapshot = sourceSnapshot
            self.targetCreatedColumnId = targetCreatedColumnId
            self.sourcePlaceholderColumnId = sourcePlaceholderColumnId
        }
    }

    struct WorkspaceApplyOutcome {
        let rc: Int32
        let applied: Bool
        let sourceSelectionWindowId: NodeId?
        let targetSelectionWindowId: NodeId?
        let movedWindowId: NodeId?
        let sourceDelta: DeltaExport?
        let targetDelta: DeltaExport?
    }

    struct RuntimeActiveTileUpdate {
        let columnId: NodeId
        let activeTileIdx: Int
    }

    struct NavigationApplyRequest {
        let request: NavigationRequest
        let snapshot: Snapshot?

        init(request: NavigationRequest, snapshot: Snapshot? = nil) {
            self.request = request
            self.snapshot = snapshot
        }
    }

    struct NavigationApplyOutcome {
        let rc: Int32
        let applied: Bool
        let targetWindowId: NodeId?
        let sourceActiveTileUpdate: RuntimeActiveTileUpdate?
        let targetActiveTileUpdate: RuntimeActiveTileUpdate?
        let refreshSourceColumnId: NodeId?
        let refreshTargetColumnId: NodeId?
        let delta: DeltaExport?
    }

    static func omniUUID(from nodeId: NodeId) -> OmniUuid128 {
        omniUUID(from: nodeId.uuid)
    }

    static func omniUUID(from uuid: UUID) -> OmniUuid128 {
        var rawUUID = uuid.uuid
        var encoded = OmniUuid128()
        withUnsafeBytes(of: &rawUUID) { src in
            withUnsafeMutableBytes(of: &encoded) { dst in
                dst.copyBytes(from: src)
            }
        }
        return encoded
    }

    static func uuid(from omniUuid: OmniUuid128) -> UUID {
        var decoded = UUID().uuid
        var value = omniUuid
        withUnsafeBytes(of: &value) { src in
            withUnsafeMutableBytes(of: &decoded) { dst in
                dst.copyBytes(from: src)
            }
        }
        return UUID(uuid: decoded)
    }

    static func nodeId(from omniUuid: OmniUuid128) -> NodeId {
        NodeId(uuid: uuid(from: omniUuid))
    }

    private static func zeroUUID() -> OmniUuid128 {
        OmniUuid128()
    }

    private static func navigationOpCode(_ op: NavigationOp) -> UInt8 {
        switch op {
        case .moveByColumns:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_NAV_OP_MOVE_BY_COLUMNS.rawValue)
        case .moveVertical:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_NAV_OP_MOVE_VERTICAL.rawValue)
        case .focusTarget:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_NAV_OP_FOCUS_TARGET.rawValue)
        case .focusDownOrLeft:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_NAV_OP_FOCUS_DOWN_OR_LEFT.rawValue)
        case .focusUpOrRight:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_NAV_OP_FOCUS_UP_OR_RIGHT.rawValue)
        case .focusColumnFirst:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_NAV_OP_FOCUS_COLUMN_FIRST.rawValue)
        case .focusColumnLast:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_NAV_OP_FOCUS_COLUMN_LAST.rawValue)
        case .focusColumnIndex:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_NAV_OP_FOCUS_COLUMN_INDEX.rawValue)
        case .focusWindowIndex:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_NAV_OP_FOCUS_WINDOW_INDEX.rawValue)
        case .focusWindowTop:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_NAV_OP_FOCUS_WINDOW_TOP.rawValue)
        case .focusWindowBottom:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_NAV_OP_FOCUS_WINDOW_BOTTOM.rawValue)
        }
    }

    private static func mutationOpCode(_ op: MutationOp) -> UInt8 {
        switch op {
        case .moveWindowVertical:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_VERTICAL.rawValue)
        case .swapWindowVertical:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_OP_SWAP_WINDOW_VERTICAL.rawValue)
        case .moveWindowHorizontal:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_HORIZONTAL.rawValue)
        case .swapWindowHorizontal:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_OP_SWAP_WINDOW_HORIZONTAL.rawValue)
        case .swapWindowsByMove:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_OP_SWAP_WINDOWS_BY_MOVE.rawValue)
        case .insertWindowByMove:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_OP_INSERT_WINDOW_BY_MOVE.rawValue)
        case .moveWindowToColumn:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_OP_MOVE_WINDOW_TO_COLUMN.rawValue)
        case .createColumnAndMove:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_OP_CREATE_COLUMN_AND_MOVE.rawValue)
        case .insertWindowInNewColumn:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_OP_INSERT_WINDOW_IN_NEW_COLUMN.rawValue)
        case .moveColumn:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_OP_MOVE_COLUMN.rawValue)
        case .consumeWindow:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_OP_CONSUME_WINDOW.rawValue)
        case .expelWindow:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_OP_EXPEL_WINDOW.rawValue)
        case .cleanupEmptyColumn:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_OP_CLEANUP_EMPTY_COLUMN.rawValue)
        case .normalizeColumnSizes:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_OP_NORMALIZE_COLUMN_SIZES.rawValue)
        case .normalizeWindowSizes:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_OP_NORMALIZE_WINDOW_SIZES.rawValue)
        case .balanceSizes:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_OP_BALANCE_SIZES.rawValue)
        case .addWindow:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_OP_ADD_WINDOW.rawValue)
        case .removeWindow:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_OP_REMOVE_WINDOW.rawValue)
        case .validateSelection:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_OP_VALIDATE_SELECTION.rawValue)
        case .fallbackSelectionOnRemoval:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_OP_FALLBACK_SELECTION_ON_REMOVAL.rawValue)
        }
    }

    private static func workspaceOpCode(_ op: WorkspaceOp) -> UInt8 {
        switch op {
        case .moveWindowToWorkspace:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_WORKSPACE_OP_MOVE_WINDOW_TO_WORKSPACE.rawValue)
        case .moveColumnToWorkspace:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_WORKSPACE_OP_MOVE_COLUMN_TO_WORKSPACE.rawValue)
        }
    }

    private static func mutationNodeKindCode(_ kind: MutationNodeKind) -> UInt8 {
        switch kind {
        case .none:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_NODE_NONE.rawValue)
        case .window:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_NODE_WINDOW.rawValue)
        case .column:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_NODE_COLUMN.rawValue)
        }
    }

    private static func navigationDirectionCode(_ direction: Direction?) -> UInt8 {
        switch direction {
        case .left:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_DIRECTION_LEFT.rawValue)
        case .right:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_DIRECTION_RIGHT.rawValue)
        case .up:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_DIRECTION_UP.rawValue)
        case .down:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_DIRECTION_DOWN.rawValue)
        case nil:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_DIRECTION_LEFT.rawValue)
        }
    }

    private static func mutationDirectionCode(_ direction: Direction?) -> UInt8 {
        switch direction {
        case .left:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_DIRECTION_LEFT.rawValue)
        case .right:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_DIRECTION_RIGHT.rawValue)
        case .up:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_DIRECTION_UP.rawValue)
        case .down:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_DIRECTION_DOWN.rawValue)
        case nil:
            // Direction-required mutation ops must reject unspecified direction.
            return 0xFF
        }
    }

    private static func insertPositionCode(_ position: InsertPosition?) -> UInt8 {
        switch position {
        case .before:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_INSERT_BEFORE.rawValue)
        case .after:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_INSERT_AFTER.rawValue)
        case .swap:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_INSERT_SWAP.rawValue)
        case nil:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_INSERT_BEFORE.rawValue)
        }
    }

    private static func orientationCode(_ orientation: Monitor.Orientation) -> UInt8 {
        switch orientation {
        case .horizontal:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_ORIENTATION_HORIZONTAL.rawValue)
        case .vertical:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_ORIENTATION_VERTICAL.rawValue)
        }
    }

    static let sizeKindProportion: UInt8 = UInt8(truncatingIfNeeded: OMNI_NIRI_SIZE_KIND_PROPORTION.rawValue)
    static let sizeKindFixed: UInt8 = UInt8(truncatingIfNeeded: OMNI_NIRI_SIZE_KIND_FIXED.rawValue)
    static let heightKindAuto: UInt8 = UInt8(truncatingIfNeeded: OMNI_NIRI_HEIGHT_KIND_AUTO.rawValue)
    static let heightKindFixed: UInt8 = UInt8(truncatingIfNeeded: OMNI_NIRI_HEIGHT_KIND_FIXED.rawValue)

    static func encodeWidth(_ width: ProportionalSize) -> (kind: UInt8, value: Double) {
        switch width {
        case let .proportion(value):
            return (kind: sizeKindProportion, value: Double(value))
        case let .fixed(value):
            return (kind: sizeKindFixed, value: Double(value))
        }
    }

    static func decodeWidth(kind: UInt8, value: Double) -> ProportionalSize? {
        if kind == sizeKindProportion {
            return .proportion(CGFloat(value))
        }
        if kind == sizeKindFixed {
            return .fixed(CGFloat(value))
        }
        return nil
    }

    static func encodeHeight(_ height: WeightedSize) -> (kind: UInt8, value: Double) {
        switch height {
        case let .auto(weight):
            return (kind: heightKindAuto, value: Double(weight))
        case let .fixed(value):
            return (kind: heightKindFixed, value: Double(value))
        }
    }

    static func decodeHeight(kind: UInt8, value: Double) -> WeightedSize? {
        if kind == heightKindAuto {
            return .auto(weight: CGFloat(value))
        }
        if kind == heightKindFixed {
            return .fixed(CGFloat(value))
        }
        return nil
    }

    static func makeSnapshot(columns: [NiriContainer]) -> Snapshot {
        let estimatedWindowCount = columns.reduce(0) { partial, column in
            partial + column.windowNodes.count
        }

        var columnInputs: [OmniNiriStateColumnInput] = []
        columnInputs.reserveCapacity(columns.count)

        var windowInputs: [OmniNiriStateWindowInput] = []
        windowInputs.reserveCapacity(estimatedWindowCount)

        var columnEntries: [Snapshot.ColumnEntry] = []
        columnEntries.reserveCapacity(columns.count)

        var windowEntries: [Snapshot.WindowEntry] = []
        windowEntries.reserveCapacity(estimatedWindowCount)

        var windowIndexByNodeId: [NodeId: Int] = [:]
        windowIndexByNodeId.reserveCapacity(estimatedWindowCount)

        var columnIndexByNodeId: [NodeId: Int] = [:]
        columnIndexByNodeId.reserveCapacity(columns.count + estimatedWindowCount)

        for (columnIndex, column) in columns.enumerated() {
            let start = windowInputs.count
            let windows = column.windowNodes
            let columnId = omniUUID(from: column.id)
            let encodedWidth = encodeWidth(column.width)
            let encodedSavedWidth = column.savedWidth.map(encodeWidth)

            columnEntries.append(
                Snapshot.ColumnEntry(
                    column: column,
                    columnIndex: columnIndex,
                    windowStart: start,
                    windowCount: windows.count
                )
            )
            columnIndexByNodeId[column.id] = columnIndex

            for (rowIndex, window) in windows.enumerated() {
                let windowIndex = windowInputs.count
                windowEntries.append(
                    Snapshot.WindowEntry(
                        window: window,
                        column: column,
                        columnIndex: columnIndex,
                        rowIndex: rowIndex
                    )
                )
                windowIndexByNodeId[window.id] = windowIndex
                columnIndexByNodeId[window.id] = columnIndex

                let encodedHeight = encodeHeight(window.height)
                windowInputs.append(
                    OmniNiriStateWindowInput(
                        window_id: omniUUID(from: window.id),
                        column_id: columnId,
                        column_index: columnIndex,
                        size_value: Double(window.size),
                        height_kind: encodedHeight.kind,
                        height_value: encodedHeight.value
                    )
                )
            }

            columnInputs.append(
                OmniNiriStateColumnInput(
                    column_id: columnId,
                    window_start: start,
                    window_count: windows.count,
                    active_tile_idx: max(0, column.activeTileIdx),
                    is_tabbed: column.isTabbed ? 1 : 0,
                    size_value: encodedWidth.value,
                    width_kind: encodedWidth.kind,
                    is_full_width: column.isFullWidth ? 1 : 0,
                    has_saved_width: encodedSavedWidth == nil ? 0 : 1,
                    saved_width_kind: encodedSavedWidth?.kind ?? sizeKindProportion,
                    saved_width_value: encodedSavedWidth?.value ?? 1.0
                )
            )
        }

        return Snapshot(
            columns: columnInputs,
            windows: windowInputs,
            columnEntries: columnEntries,
            windowEntries: windowEntries,
            windowIndexByNodeId: windowIndexByNodeId,
            columnIndexByNodeId: columnIndexByNodeId
        )
    }

    static func makeSelectionContext(node: NiriNode, snapshot: Snapshot) -> SelectionContext? {
        if let windowIndex = snapshot.windowIndexByNodeId[node.id],
           snapshot.windowEntries.indices.contains(windowIndex)
        {
            let entry = snapshot.windowEntries[windowIndex]
            return SelectionContext(
                selectedWindowIndex: windowIndex,
                selectedColumnIndex: entry.columnIndex,
                selectedRowIndex: entry.rowIndex
            )
        }

        guard let columnIndex = snapshot.columnIndexByNodeId[node.id],
              snapshot.columnEntries.indices.contains(columnIndex)
        else {
            return nil
        }

        let columnEntry = snapshot.columnEntries[columnIndex]
        guard columnEntry.windowCount > 0 else { return nil }

        // Match Swift fallback in updateActiveTileIdx(for:in:) when node is not a window.
        return SelectionContext(
            selectedWindowIndex: columnEntry.windowStart,
            selectedColumnIndex: columnIndex,
            selectedRowIndex: 0
        )
    }

    static func mutationNodeTarget(
        for nodeId: NodeId?,
        snapshot: Snapshot
    ) -> MutationNodeTarget {
        guard let nodeId else {
            return MutationNodeTarget(kind: .none, index: -1)
        }

        if let windowIndex = snapshot.windowIndexByNodeId[nodeId],
           snapshot.windowEntries.indices.contains(windowIndex)
        {
            return MutationNodeTarget(kind: .window, index: windowIndex)
        }

        if let columnIndex = snapshot.columnIndexByNodeId[nodeId],
           snapshot.columnEntries.indices.contains(columnIndex)
        {
            return MutationNodeTarget(kind: .column, index: columnIndex)
        }

        return MutationNodeTarget(kind: .none, index: -1)
    }

    static func nodeId(
        from target: MutationNodeTarget?,
        snapshot: Snapshot
    ) -> NodeId? {
        guard let target else { return nil }
        switch target.kind {
        case .window:
            guard snapshot.windowEntries.indices.contains(target.index) else { return nil }
            return snapshot.windowEntries[target.index].window.id
        case .column:
            guard snapshot.columnEntries.indices.contains(target.index) else { return nil }
            return snapshot.columnEntries[target.index].column.id
        case .none:
            return nil
        }
    }

    private static func direction(from rawCode: UInt8) -> Direction? {
        switch rawCode {
        case 0:
            return .left
        case 1:
            return .right
        case 2:
            return .up
        case 3:
            return .down
        default:
            return nil
        }
    }

    private static func rawMutationRequest(from request: MutationRequest) -> OmniNiriMutationRequest {
        OmniNiriMutationRequest(
            op: mutationOpCode(request.op),
            direction: mutationDirectionCode(request.direction),
            infinite_loop: request.infiniteLoop ? 1 : 0,
            insert_position: insertPositionCode(request.insertPosition),
            source_window_index: Int64(request.sourceWindowIndex),
            target_window_index: Int64(request.targetWindowIndex),
            max_windows_per_column: Int64(request.maxWindowsPerColumn),
            source_column_index: Int64(request.sourceColumnIndex),
            target_column_index: Int64(request.targetColumnIndex),
            insert_column_index: Int64(request.insertColumnIndex),
            max_visible_columns: Int64(request.maxVisibleColumns),
            selected_node_kind: mutationNodeKindCode(request.selectedNodeKind),
            selected_node_index: Int64(request.selectedNodeIndex),
            focused_window_index: Int64(request.focusedWindowIndex)
        )
    }

    private static func rawWorkspaceRequest(from request: WorkspaceRequest) -> OmniNiriWorkspaceRequest {
        OmniNiriWorkspaceRequest(
            op: workspaceOpCode(request.op),
            source_window_index: Int64(request.sourceWindowIndex),
            source_column_index: Int64(request.sourceColumnIndex),
            max_visible_columns: Int64(request.maxVisibleColumns)
        )
    }

    private static func rawNavigationRequest(from request: NavigationRequest) -> OmniNiriNavigationRequest {
        OmniNiriNavigationRequest(
            op: navigationOpCode(request.op),
            direction: navigationDirectionCode(request.direction),
            orientation: orientationCode(request.orientation),
            infinite_loop: request.infiniteLoop ? 1 : 0,
            selected_window_index: Int64(request.selectedWindowIndex),
            selected_column_index: Int64(request.selectedColumnIndex),
            selected_row_index: Int64(request.selectedRowIndex),
            step: Int64(request.step),
            target_row_index: Int64(request.targetRowIndex),
            target_column_index: Int64(request.targetColumnIndex),
            target_window_index: Int64(request.targetWindowIndex)
        )
    }

    static func runtimeStateExport(snapshot: Snapshot) -> RuntimeStateExport {
        let columns = snapshot.columns.map { column in
            RuntimeColumnState(
                columnId: nodeId(from: column.column_id),
                windowStart: column.window_start,
                windowCount: column.window_count,
                activeTileIdx: column.active_tile_idx,
                isTabbed: column.is_tabbed != 0,
                sizeValue: column.size_value,
                widthKind: column.width_kind,
                isFullWidth: column.is_full_width != 0,
                hasSavedWidth: column.has_saved_width != 0,
                savedWidthKind: column.saved_width_kind,
                savedWidthValue: column.saved_width_value
            )
        }
        let windows = snapshot.windows.map { window in
            RuntimeWindowState(
                windowId: nodeId(from: window.window_id),
                columnId: nodeId(from: window.column_id),
                columnIndex: window.column_index,
                sizeValue: window.size_value,
                heightKind: window.height_kind,
                heightValue: window.height_value
            )
        }
        return RuntimeStateExport(columns: columns, windows: windows)
    }

    static func seedRuntimeState(
        context: NiriLayoutZigKernel.LayoutContext,
        snapshot: Snapshot
    ) -> Int32 {
        seedRuntimeState(
            context: context,
            export: runtimeStateExport(snapshot: snapshot)
        )
    }

    static func seedRuntimeState(
        context: NiriLayoutZigKernel.LayoutContext,
        export: RuntimeStateExport
    ) -> Int32 {
        let rawColumns = export.columns.map { column in
            OmniNiriRuntimeColumnState(
                column_id: omniUUID(from: column.columnId),
                window_start: column.windowStart,
                window_count: column.windowCount,
                active_tile_idx: column.activeTileIdx,
                is_tabbed: column.isTabbed ? 1 : 0,
                size_value: column.sizeValue,
                width_kind: column.widthKind,
                is_full_width: column.isFullWidth ? 1 : 0,
                has_saved_width: column.hasSavedWidth ? 1 : 0,
                saved_width_kind: column.savedWidthKind,
                saved_width_value: column.savedWidthValue
            )
        }
        let rawWindows = export.windows.map { window in
            OmniNiriRuntimeWindowState(
                window_id: omniUUID(from: window.windowId),
                column_id: omniUUID(from: window.columnId),
                column_index: window.columnIndex,
                size_value: window.sizeValue,
                height_kind: window.heightKind,
                height_value: window.heightValue
            )
        }

        return rawColumns.withUnsafeBufferPointer { columnBuf in
            rawWindows.withUnsafeBufferPointer { windowBuf in
                let columnPtr = columnBuf.count > 0 ? columnBuf.baseAddress : nil
                let windowPtr = windowBuf.count > 0 ? windowBuf.baseAddress : nil

                guard !(columnBuf.count > 0 && columnPtr == nil),
                      !(windowBuf.count > 0 && windowPtr == nil)
                else {
                    return Int32(OMNI_ERR_INVALID_ARGS)
                }
                return context.withRawContext { raw in
                    omni_niri_ctx_seed_runtime_state(
                        raw,
                        columnPtr,
                        columnBuf.count,
                        windowPtr,
                        windowBuf.count
                    )
                }
            }
        }
    }

    private static func emptyNavigationTxnPayload() -> OmniNiriTxnNavigationPayload {
        OmniNiriTxnNavigationPayload(
            op: 0,
            direction: 0,
            orientation: 0,
            infinite_loop: 0,
            has_selected_window_id: 0,
            selected_window_id: zeroUUID(),
            has_selected_column_id: 0,
            selected_column_id: zeroUUID(),
            selected_row_index: -1,
            step: 0,
            target_row_index: -1,
            has_target_column_id: 0,
            target_column_id: zeroUUID(),
            has_target_window_id: 0,
            target_window_id: zeroUUID()
        )
    }

    private static func emptyMutationTxnPayload() -> OmniNiriTxnMutationPayload {
        OmniNiriTxnMutationPayload(
            op: 0,
            direction: 0,
            infinite_loop: 0,
            insert_position: 0,
            has_source_window_id: 0,
            source_window_id: zeroUUID(),
            has_target_window_id: 0,
            target_window_id: zeroUUID(),
            max_windows_per_column: 0,
            has_source_column_id: 0,
            source_column_id: zeroUUID(),
            has_target_column_id: 0,
            target_column_id: zeroUUID(),
            insert_column_index: -1,
            max_visible_columns: -1,
            selected_node_kind: UInt8(truncatingIfNeeded: OMNI_NIRI_MUTATION_NODE_NONE.rawValue),
            has_selected_node_id: 0,
            selected_node_id: zeroUUID(),
            has_focused_window_id: 0,
            focused_window_id: zeroUUID(),
            has_incoming_window_id: 0,
            incoming_window_id: zeroUUID(),
            has_created_column_id: 0,
            created_column_id: zeroUUID(),
            has_placeholder_column_id: 0,
            placeholder_column_id: zeroUUID()
        )
    }

    private static func emptyWorkspaceTxnPayload() -> OmniNiriTxnWorkspacePayload {
        OmniNiriTxnWorkspacePayload(
            op: 0,
            has_source_window_id: 0,
            source_window_id: zeroUUID(),
            has_source_column_id: 0,
            source_column_id: zeroUUID(),
            max_visible_columns: -1,
            has_target_created_column_id: 0,
            target_created_column_id: zeroUUID(),
            has_source_placeholder_column_id: 0,
            source_placeholder_column_id: zeroUUID()
        )
    }

    private static func nodeId(atWindowIndex index: Int, snapshot: Snapshot?) -> NodeId? {
        guard let snapshot, index >= 0, index < snapshot.windowEntries.count else { return nil }
        return snapshot.windowEntries[index].window.id
    }

    private static func nodeId(atColumnIndex index: Int, snapshot: Snapshot?) -> NodeId? {
        guard let snapshot, index >= 0, index < snapshot.columnEntries.count else { return nil }
        return snapshot.columnEntries[index].column.id
    }

    static func exportDelta(
        context: NiriLayoutZigKernel.LayoutContext
    ) -> (rc: Int32, export: DeltaExport) {
        var rawExport = OmniNiriTxnDeltaExport()

        let rc = context.withRawContext { raw in
            withUnsafeMutablePointer(to: &rawExport) { exportPtr in
                omni_niri_ctx_export_delta(raw, exportPtr)
            }
        }

        guard rc == OMNI_OK else {
            return (
                rc: rc,
                export: DeltaExport(
                    columns: [],
                    windows: [],
                    removedColumnIds: [],
                    removedWindowIds: [],
                    refreshTabbedVisibilityColumnIds: [],
                    resetAllColumnCachedWidths: false,
                    delegatedMoveColumn: nil,
                    targetWindowId: nil,
                    targetNode: nil,
                    sourceSelectionWindowId: nil,
                    targetSelectionWindowId: nil,
                    movedWindowId: nil,
                    generation: 0
                )
            )
        }

        var columns: [DeltaColumnRecord] = []
        if let base = rawExport.columns, rawExport.column_count > 0 {
            let rawColumns = Array(UnsafeBufferPointer(start: base, count: rawExport.column_count))
            columns = rawColumns.map { column in
                DeltaColumnRecord(
                    column: RuntimeColumnState(
                        columnId: nodeId(from: column.column_id),
                        windowStart: column.window_start,
                        windowCount: column.window_count,
                        activeTileIdx: column.active_tile_idx,
                        isTabbed: column.is_tabbed != 0,
                        sizeValue: column.size_value,
                        widthKind: column.width_kind,
                        isFullWidth: column.is_full_width != 0,
                        hasSavedWidth: column.has_saved_width != 0,
                        savedWidthKind: column.saved_width_kind,
                        savedWidthValue: column.saved_width_value
                    ),
                    orderIndex: column.order_index
                )
            }
        }

        var windows: [DeltaWindowRecord] = []
        if let base = rawExport.windows, rawExport.window_count > 0 {
            let rawWindows = Array(UnsafeBufferPointer(start: base, count: rawExport.window_count))
            windows = rawWindows.map { window in
                DeltaWindowRecord(
                    window: RuntimeWindowState(
                        windowId: nodeId(from: window.window_id),
                        columnId: nodeId(from: window.column_id),
                        columnIndex: window.column_order_index,
                        sizeValue: window.size_value,
                        heightKind: window.height_kind,
                        heightValue: window.height_value
                    ),
                    columnOrderIndex: window.column_order_index,
                    rowIndex: window.row_index
                )
            }
        }

        var removedColumnIds: [NodeId] = []
        if let base = rawExport.removed_column_ids, rawExport.removed_column_count > 0 {
            removedColumnIds = Array(UnsafeBufferPointer(start: base, count: rawExport.removed_column_count)).map(nodeId(from:))
        }

        var removedWindowIds: [NodeId] = []
        if let base = rawExport.removed_window_ids, rawExport.removed_window_count > 0 {
            removedWindowIds = Array(UnsafeBufferPointer(start: base, count: rawExport.removed_window_count)).map(nodeId(from:))
        }

        let refreshCount = max(0, min(Int(OMNI_NIRI_RUNTIME_HINT_MAX_COLUMNS), Int(rawExport.refresh_tabbed_visibility_count)))
        var refreshIds: [NodeId] = []
        refreshIds.reserveCapacity(refreshCount)
        withUnsafePointer(to: &rawExport.refresh_tabbed_visibility_column_ids) { tuplePtr in
            let base = UnsafeRawPointer(tuplePtr).assumingMemoryBound(to: OmniUuid128.self)
            for idx in 0 ..< refreshCount {
                refreshIds.append(nodeId(from: base[idx]))
            }
        }

        let delegatedMoveColumn: (columnId: NodeId, direction: Direction)?
        if rawExport.has_delegate_move_column != 0,
           let direction = direction(from: rawExport.delegate_move_direction) {
            delegatedMoveColumn = (nodeId(from: rawExport.delegate_move_column_id), direction)
        } else {
            delegatedMoveColumn = nil
        }

        let targetNode: RuntimeNodeTarget?
        if rawExport.has_target_node_id != 0,
           let kind = MutationNodeKind(rawValue: rawExport.target_node_kind),
           kind != .none {
            targetNode = RuntimeNodeTarget(
                kind: kind,
                nodeId: nodeId(from: rawExport.target_node_id)
            )
        } else {
            targetNode = nil
        }

        return (
            rc: rc,
            export: DeltaExport(
                columns: columns,
                windows: windows,
                removedColumnIds: removedColumnIds,
                removedWindowIds: removedWindowIds,
                refreshTabbedVisibilityColumnIds: refreshIds,
                resetAllColumnCachedWidths: rawExport.reset_all_column_cached_widths != 0,
                delegatedMoveColumn: delegatedMoveColumn,
                targetWindowId: rawExport.has_target_window_id != 0
                    ? nodeId(from: rawExport.target_window_id)
                    : nil,
                targetNode: targetNode,
                sourceSelectionWindowId: rawExport.has_source_selection_window_id != 0
                    ? nodeId(from: rawExport.source_selection_window_id)
                    : nil,
                targetSelectionWindowId: rawExport.has_target_selection_window_id != 0
                    ? nodeId(from: rawExport.target_selection_window_id)
                    : nil,
                movedWindowId: rawExport.has_moved_window_id != 0
                    ? nodeId(from: rawExport.moved_window_id)
                    : nil,
                generation: rawExport.generation
            )
        )
    }

    static func applyTxn(_ request: TxnRequest) -> TxnOutcome {
        let sourceContext: NiriLayoutZigKernel.LayoutContext
        let targetContext: NiriLayoutZigKernel.LayoutContext?
        let kind: TxnKind
        var rawNavigation = emptyNavigationTxnPayload()
        var rawMutation = emptyMutationTxnPayload()
        var rawWorkspace = emptyWorkspaceTxnPayload()

        switch request {
        case let .navigation(context, navRequest):
            sourceContext = context
            targetContext = nil
            kind = .navigation
            let selectedWindowId: NodeId?
            let selectedColumnId: NodeId?
            let targetWindowId: NodeId?
            let targetColumnId: NodeId?
            guard let snapshot = navRequest.snapshot else {
                return TxnOutcome(
                    rc: Int32(OMNI_ERR_INVALID_ARGS),
                    kind: .navigation,
                    applied: false,
                    targetWindowId: nil,
                    targetNode: nil,
                    changedSourceContext: false,
                    changedTargetContext: false,
                    deltaColumnCount: 0,
                    deltaWindowCount: 0,
                    removedColumnCount: 0,
                    removedWindowCount: 0
                )
            }
            selectedWindowId = nodeId(atWindowIndex: navRequest.request.selectedWindowIndex, snapshot: snapshot)
            selectedColumnId = nodeId(atColumnIndex: navRequest.request.selectedColumnIndex, snapshot: snapshot)
            targetWindowId = nodeId(atWindowIndex: navRequest.request.targetWindowIndex, snapshot: snapshot)
            targetColumnId = nodeId(atColumnIndex: navRequest.request.targetColumnIndex, snapshot: snapshot)

            rawNavigation = OmniNiriTxnNavigationPayload(
                op: navigationOpCode(navRequest.request.op),
                direction: navigationDirectionCode(navRequest.request.direction),
                orientation: orientationCode(navRequest.request.orientation),
                infinite_loop: navRequest.request.infiniteLoop ? 1 : 0,
                has_selected_window_id: selectedWindowId == nil ? 0 : 1,
                selected_window_id: selectedWindowId.map(omniUUID(from:)) ?? zeroUUID(),
                has_selected_column_id: selectedColumnId == nil ? 0 : 1,
                selected_column_id: selectedColumnId.map(omniUUID(from:)) ?? zeroUUID(),
                selected_row_index: Int64(navRequest.request.selectedRowIndex),
                step: Int64(navRequest.request.step),
                target_row_index: Int64(navRequest.request.targetRowIndex),
                has_target_column_id: targetColumnId == nil ? 0 : 1,
                target_column_id: targetColumnId.map(omniUUID(from:)) ?? zeroUUID(),
                has_target_window_id: targetWindowId == nil ? 0 : 1,
                target_window_id: targetWindowId.map(omniUUID(from:)) ?? zeroUUID()
            )
        case let .mutation(context, mutationRequest):
            sourceContext = context
            targetContext = nil
            kind = .mutation
            let sourceWindowId: NodeId?
            let targetWindowId: NodeId?
            let sourceColumnId: NodeId?
            let targetColumnId: NodeId?
            let focusedWindowId: NodeId?
            let selectedNodeId: NodeId?

            guard let snapshot = mutationRequest.snapshot else {
                return TxnOutcome(
                    rc: Int32(OMNI_ERR_INVALID_ARGS),
                    kind: .mutation,
                    applied: false,
                    targetWindowId: nil,
                    targetNode: nil,
                    changedSourceContext: false,
                    changedTargetContext: false,
                    deltaColumnCount: 0,
                    deltaWindowCount: 0,
                    removedColumnCount: 0,
                    removedWindowCount: 0
                )
            }
            sourceWindowId = nodeId(atWindowIndex: mutationRequest.request.sourceWindowIndex, snapshot: snapshot)
            targetWindowId = nodeId(atWindowIndex: mutationRequest.request.targetWindowIndex, snapshot: snapshot)
            sourceColumnId = nodeId(atColumnIndex: mutationRequest.request.sourceColumnIndex, snapshot: snapshot)
            targetColumnId = nodeId(atColumnIndex: mutationRequest.request.targetColumnIndex, snapshot: snapshot)
            focusedWindowId = nodeId(atWindowIndex: mutationRequest.request.focusedWindowIndex, snapshot: snapshot)
            selectedNodeId = switch mutationRequest.request.selectedNodeKind {
            case .window:
                nodeId(atWindowIndex: mutationRequest.request.selectedNodeIndex, snapshot: snapshot)
            case .column:
                nodeId(atColumnIndex: mutationRequest.request.selectedNodeIndex, snapshot: snapshot)
            case .none:
                nil
            }

            rawMutation = OmniNiriTxnMutationPayload(
                op: mutationOpCode(mutationRequest.request.op),
                direction: mutationDirectionCode(mutationRequest.request.direction),
                infinite_loop: mutationRequest.request.infiniteLoop ? 1 : 0,
                insert_position: insertPositionCode(mutationRequest.request.insertPosition),
                has_source_window_id: sourceWindowId == nil ? 0 : 1,
                source_window_id: sourceWindowId.map(omniUUID(from:)) ?? zeroUUID(),
                has_target_window_id: targetWindowId == nil ? 0 : 1,
                target_window_id: targetWindowId.map(omniUUID(from:)) ?? zeroUUID(),
                max_windows_per_column: Int64(mutationRequest.request.maxWindowsPerColumn),
                has_source_column_id: sourceColumnId == nil ? 0 : 1,
                source_column_id: sourceColumnId.map(omniUUID(from:)) ?? zeroUUID(),
                has_target_column_id: targetColumnId == nil ? 0 : 1,
                target_column_id: targetColumnId.map(omniUUID(from:)) ?? zeroUUID(),
                insert_column_index: Int64(mutationRequest.request.insertColumnIndex),
                max_visible_columns: Int64(mutationRequest.request.maxVisibleColumns),
                selected_node_kind: mutationNodeKindCode(mutationRequest.request.selectedNodeKind),
                has_selected_node_id: selectedNodeId == nil ? 0 : 1,
                selected_node_id: selectedNodeId.map(omniUUID(from:)) ?? zeroUUID(),
                has_focused_window_id: focusedWindowId == nil ? 0 : 1,
                focused_window_id: focusedWindowId.map(omniUUID(from:)) ?? zeroUUID(),
                has_incoming_window_id: mutationRequest.incomingWindowId == nil ? 0 : 1,
                incoming_window_id: mutationRequest.incomingWindowId.map(omniUUID(from:)) ?? zeroUUID(),
                has_created_column_id: mutationRequest.createdColumnId == nil ? 0 : 1,
                created_column_id: mutationRequest.createdColumnId.map(omniUUID(from:)) ?? zeroUUID(),
                has_placeholder_column_id: mutationRequest.placeholderColumnId == nil ? 0 : 1,
                placeholder_column_id: mutationRequest.placeholderColumnId.map(omniUUID(from:)) ?? zeroUUID()
            )
        case let .workspace(source, target, workspaceRequest):
            sourceContext = source
            targetContext = target
            kind = .workspace
            let sourceWindowId: NodeId?
            let sourceColumnId: NodeId?
            guard let snapshot = workspaceRequest.sourceSnapshot else {
                return TxnOutcome(
                    rc: Int32(OMNI_ERR_INVALID_ARGS),
                    kind: .workspace,
                    applied: false,
                    targetWindowId: nil,
                    targetNode: nil,
                    changedSourceContext: false,
                    changedTargetContext: false,
                    deltaColumnCount: 0,
                    deltaWindowCount: 0,
                    removedColumnCount: 0,
                    removedWindowCount: 0
                )
            }
            sourceWindowId = nodeId(atWindowIndex: workspaceRequest.request.sourceWindowIndex, snapshot: snapshot)
            sourceColumnId = nodeId(atColumnIndex: workspaceRequest.request.sourceColumnIndex, snapshot: snapshot)
            rawWorkspace = OmniNiriTxnWorkspacePayload(
                op: workspaceOpCode(workspaceRequest.request.op),
                has_source_window_id: sourceWindowId == nil ? 0 : 1,
                source_window_id: sourceWindowId.map(omniUUID(from:)) ?? zeroUUID(),
                has_source_column_id: sourceColumnId == nil ? 0 : 1,
                source_column_id: sourceColumnId.map(omniUUID(from:)) ?? zeroUUID(),
                max_visible_columns: Int64(workspaceRequest.request.maxVisibleColumns),
                has_target_created_column_id: workspaceRequest.targetCreatedColumnId == nil ? 0 : 1,
                target_created_column_id: workspaceRequest.targetCreatedColumnId.map(omniUUID(from:)) ?? zeroUUID(),
                has_source_placeholder_column_id: workspaceRequest.sourcePlaceholderColumnId == nil ? 0 : 1,
                source_placeholder_column_id: workspaceRequest.sourcePlaceholderColumnId.map(omniUUID(from:)) ?? zeroUUID()
            )
        }

        var rawRequest = OmniNiriTxnRequest(
            kind: kind.rawValue,
            navigation: rawNavigation,
            mutation: rawMutation,
            workspace: rawWorkspace,
            max_delta_columns: 0,
            max_delta_windows: 0,
            max_removed_ids: 0
        )

        var rawResult = OmniNiriTxnResult()
        let rc = sourceContext.withRawContext { sourceRaw in
            withUnsafePointer(to: &rawRequest) { requestPtr in
                withUnsafeMutablePointer(to: &rawResult) { resultPtr in
                    if let targetContext {
                        return targetContext.withRawContext { targetRaw in
                            omni_niri_ctx_apply_txn(sourceRaw, targetRaw, requestPtr, resultPtr)
                        }
                    }
                    return omni_niri_ctx_apply_txn(sourceRaw, nil, requestPtr, resultPtr)
                }
            }
        }

        let targetNode: RuntimeNodeTarget?
        if rc == OMNI_OK,
           rawResult.has_target_node_id != 0,
           let nodeKind = MutationNodeKind(rawValue: rawResult.target_node_kind),
           nodeKind != .none {
            targetNode = RuntimeNodeTarget(
                kind: nodeKind,
                nodeId: nodeId(from: rawResult.target_node_id)
            )
        } else {
            targetNode = nil
        }

        let resolvedKind = TxnKind(rawValue: rawResult.kind) ?? kind
        return TxnOutcome(
            rc: rc,
            kind: resolvedKind,
            applied: rc == OMNI_OK && rawResult.applied != 0,
            targetWindowId: rc == OMNI_OK && rawResult.has_target_window_id != 0
                ? nodeId(from: rawResult.target_window_id)
                : nil,
            targetNode: targetNode,
            changedSourceContext: rc == OMNI_OK && rawResult.changed_source_context != 0,
            changedTargetContext: rc == OMNI_OK && rawResult.changed_target_context != 0,
            deltaColumnCount: rawResult.delta_column_count,
            deltaWindowCount: rawResult.delta_window_count,
            removedColumnCount: rawResult.removed_column_count,
            removedWindowCount: rawResult.removed_window_count
        )
    }

    static func applyMutation(
        context: NiriLayoutZigKernel.LayoutContext,
        request: MutationApplyRequest
    ) -> MutationApplyOutcome {
        let outcome = applyTxn(.mutation(context: context, request: request))
        let delta = exportDelta(context: context)
        guard outcome.rc == OMNI_OK, delta.rc == OMNI_OK else {
            return MutationApplyOutcome(
                rc: outcome.rc != OMNI_OK ? outcome.rc : delta.rc,
                applied: false,
                targetWindowId: nil,
                targetNode: nil,
                delta: nil
            )
        }
        return MutationApplyOutcome(
            rc: outcome.rc,
            applied: outcome.applied,
            targetWindowId: outcome.targetWindowId,
            targetNode: outcome.targetNode,
            delta: delta.export
        )
    }

    static func applyWorkspace(
        sourceContext: NiriLayoutZigKernel.LayoutContext,
        targetContext: NiriLayoutZigKernel.LayoutContext,
        request: WorkspaceApplyRequest
    ) -> WorkspaceApplyOutcome {
        let outcome = applyTxn(.workspace(sourceContext: sourceContext, targetContext: targetContext, request: request))
        let sourceDelta = exportDelta(context: sourceContext)
        let targetDelta = exportDelta(context: targetContext)
        return WorkspaceApplyOutcome(
            rc: outcome.rc,
            applied: outcome.applied,
            sourceSelectionWindowId: sourceDelta.rc == OMNI_OK ? sourceDelta.export.sourceSelectionWindowId : nil,
            targetSelectionWindowId: targetDelta.rc == OMNI_OK ? targetDelta.export.targetSelectionWindowId : nil,
            movedWindowId: targetDelta.rc == OMNI_OK ? targetDelta.export.movedWindowId : nil,
            sourceDelta: sourceDelta.rc == OMNI_OK ? sourceDelta.export : nil,
            targetDelta: targetDelta.rc == OMNI_OK ? targetDelta.export : nil
        )
    }

    static func applyNavigation(
        context: NiriLayoutZigKernel.LayoutContext,
        request: NavigationApplyRequest
    ) -> NavigationApplyOutcome {
        let outcome = applyTxn(.navigation(context: context, request: request))
        let delta = exportDelta(context: context)
        let refreshColumnIds: [NodeId]
        if delta.rc == OMNI_OK {
            refreshColumnIds = delta.export.refreshTabbedVisibilityColumnIds
        } else {
            refreshColumnIds = []
        }
        return NavigationApplyOutcome(
            rc: outcome.rc,
            applied: outcome.applied,
            targetWindowId: outcome.targetWindowId,
            sourceActiveTileUpdate: nil,
            targetActiveTileUpdate: nil,
            refreshSourceColumnId: refreshColumnIds.first,
            refreshTargetColumnId: refreshColumnIds.count > 1 ? refreshColumnIds[1] : nil,
            delta: delta.rc == OMNI_OK ? delta.export : nil
        )
    }
}

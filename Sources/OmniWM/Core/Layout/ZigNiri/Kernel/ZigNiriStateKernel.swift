import CZigLayout
import Foundation

enum ZigNiriStateKernel {
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

    struct WorkspaceRequest {
        let op: WorkspaceOp
        let sourceWindowId: NodeId?
        let sourceColumnId: NodeId?
        let maxVisibleColumns: Int

        init(
            op: WorkspaceOp,
            sourceWindowId: NodeId? = nil,
            sourceColumnId: NodeId? = nil,
            maxVisibleColumns: Int = -1
        ) {
            self.op = op
            self.sourceWindowId = sourceWindowId
            self.sourceColumnId = sourceColumnId
            self.maxVisibleColumns = maxVisibleColumns
        }
    }

    struct NavigationRequest {
        let op: NavigationOp
        let direction: Direction?
        let orientation: Monitor.Orientation
        let infiniteLoop: Bool
        let sourceWindowId: NodeId?
        let sourceColumnId: NodeId?
        let targetWindowId: NodeId?
        let targetColumnId: NodeId?
        let step: Int
        let targetRowIndex: Int
        let focusColumnIndex: Int
        let focusWindowIndex: Int

        init(
            op: NavigationOp,
            sourceWindowId: NodeId? = nil,
            sourceColumnId: NodeId? = nil,
            direction: Direction? = nil,
            orientation: Monitor.Orientation = .horizontal,
            infiniteLoop: Bool = false,
            step: Int = 0,
            targetRowIndex: Int = -1,
            focusColumnIndex: Int = -1,
            focusWindowIndex: Int = -1,
            targetWindowId: NodeId? = nil,
            targetColumnId: NodeId? = nil
        ) {
            self.op = op
            self.direction = direction
            self.orientation = orientation
            self.infiniteLoop = infiniteLoop
            self.sourceWindowId = sourceWindowId
            self.sourceColumnId = sourceColumnId
            self.targetWindowId = targetWindowId
            self.targetColumnId = targetColumnId
            self.step = step
            self.targetRowIndex = targetRowIndex
            self.focusColumnIndex = focusColumnIndex
            self.focusWindowIndex = focusWindowIndex
        }
    }

    struct MutationRequest {
        let op: MutationOp
        let sourceWindowId: NodeId?
        let targetWindowId: NodeId?
        let direction: Direction?
        let infiniteLoop: Bool
        let insertPosition: InsertPosition?
        let maxWindowsPerColumn: Int
        let sourceColumnId: NodeId?
        let targetColumnId: NodeId?
        let insertColumnIndex: Int
        let maxVisibleColumns: Int
        let selectedNodeId: NodeId?
        let focusedWindowId: NodeId?

        init(
            op: MutationOp,
            sourceWindowId: NodeId? = nil,
            targetWindowId: NodeId? = nil,
            direction: Direction? = nil,
            infiniteLoop: Bool = false,
            insertPosition: InsertPosition? = nil,
            maxWindowsPerColumn: Int = 1,
            sourceColumnId: NodeId? = nil,
            targetColumnId: NodeId? = nil,
            insertColumnIndex: Int = -1,
            maxVisibleColumns: Int = -1,
            selectedNodeId: NodeId? = nil,
            focusedWindowId: NodeId? = nil
        ) {
            self.op = op
            self.sourceWindowId = sourceWindowId
            self.targetWindowId = targetWindowId
            self.direction = direction
            self.infiniteLoop = infiniteLoop
            self.insertPosition = insertPosition
            self.maxWindowsPerColumn = maxWindowsPerColumn
            self.sourceColumnId = sourceColumnId
            self.targetColumnId = targetColumnId
            self.insertColumnIndex = insertColumnIndex
            self.maxVisibleColumns = maxVisibleColumns
            self.selectedNodeId = selectedNodeId
            self.focusedWindowId = focusedWindowId
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
        var columns: [RuntimeColumnState]
        var windows: [RuntimeWindowState]
    }

    enum RuntimeExportDecodeError: Error, Equatable, CustomStringConvertible {
        case runtimeCallFailed(operation: String, rc: Int32)
        case countOutOfRange(field: String, count: Int, max: Int)
        case missingBuffer(field: String, count: Int)

        var rc: Int32 {
            switch self {
            case let .runtimeCallFailed(_, rc):
                return rc
            case .countOutOfRange:
                return Int32(OMNI_ERR_OUT_OF_RANGE)
            case .missingBuffer:
                return Int32(OMNI_ERR_INVALID_ARGS)
            }
        }

        var description: String {
            switch self {
            case let .runtimeCallFailed(operation, rc):
                return "\(operation) failed rc=\(rc)"
            case let .countOutOfRange(field, count, max):
                return "runtime export \(field) out of range count=\(count) max=\(max)"
            case let .missingBuffer(field, count):
                return "runtime export \(field) missing buffer for count=\(count)"
            }
        }
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
        case navigation(context: ZigNiriLayoutKernel.LayoutContext, request: NavigationApplyRequest)
        case mutation(context: ZigNiriLayoutKernel.LayoutContext, request: MutationApplyRequest)
        case workspace(sourceContext: ZigNiriLayoutKernel.LayoutContext, targetContext: ZigNiriLayoutKernel.LayoutContext, request: WorkspaceApplyRequest)
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
        let incomingWindowId: UUID?
        let createdColumnId: UUID?
        let placeholderColumnId: UUID?

        init(
            request: MutationRequest,
            incomingWindowId: UUID? = nil,
            createdColumnId: UUID? = nil,
            placeholderColumnId: UUID? = nil
        ) {
            self.request = request
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
        let targetCreatedColumnId: UUID?
        let sourcePlaceholderColumnId: UUID?

        init(
            request: WorkspaceRequest,
            targetCreatedColumnId: UUID? = nil,
            sourcePlaceholderColumnId: UUID? = nil
        ) {
            self.request = request
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

        init(request: NavigationRequest) {
            self.request = request
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

    private static let runtimeExportMaxEntries = 512

    private static func validatedRuntimeExportCount<T: BinaryInteger>(
        _ rawCount: T,
        field: String
    ) throws -> Int {
        if rawCount < 0 {
            throw RuntimeExportDecodeError.countOutOfRange(
                field: field,
                count: Int(clamping: rawCount),
                max: runtimeExportMaxEntries
            )
        }
        let count = Int(clamping: rawCount)
        guard count <= runtimeExportMaxEntries else {
            throw RuntimeExportDecodeError.countOutOfRange(
                field: field,
                count: count,
                max: runtimeExportMaxEntries
            )
        }
        return count
    }

    private static func validatedRefreshHintCount(_ rawCount: UInt8) throws -> Int {
        let count = Int(rawCount)
        let maxCount = Int(OMNI_NIRI_RUNTIME_HINT_MAX_COLUMNS)
        guard count <= maxCount else {
            throw RuntimeExportDecodeError.countOutOfRange(
                field: "refresh_tabbed_visibility_count",
                count: count,
                max: maxCount
            )
        }
        return count
    }

    private static func validateRuntimePointer<T>(
        _ pointer: UnsafePointer<T>?,
        count: Int,
        field: String
    ) throws -> UnsafePointer<T>? {
        if count > 0, pointer == nil {
            throw RuntimeExportDecodeError.missingBuffer(field: field, count: count)
        }
        return pointer
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

    private static func decodeRuntimeStateExport(
        _ rawExport: OmniNiriRuntimeStateExport
    ) throws -> RuntimeStateExport {
        let columnCount = try validatedRuntimeExportCount(rawExport.column_count, field: "column_count")
        let windowCount = try validatedRuntimeExportCount(rawExport.window_count, field: "window_count")
        let columnBase = try validateRuntimePointer(
            rawExport.columns,
            count: columnCount,
            field: "columns"
        )
        let windowBase = try validateRuntimePointer(
            rawExport.windows,
            count: windowCount,
            field: "windows"
        )

        let columns: [RuntimeColumnState]
        if let columnBase, columnCount > 0 {
            let rawColumns = Array(UnsafeBufferPointer(start: columnBase, count: columnCount))
            columns = rawColumns.map { column in
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
        } else {
            columns = []
        }

        let windows: [RuntimeWindowState]
        if let windowBase, windowCount > 0 {
            let rawWindows = Array(UnsafeBufferPointer(start: windowBase, count: windowCount))
            windows = rawWindows.map { window in
                RuntimeWindowState(
                    windowId: nodeId(from: window.window_id),
                    columnId: nodeId(from: window.column_id),
                    columnIndex: window.column_index,
                    sizeValue: window.size_value,
                    heightKind: window.height_kind,
                    heightValue: window.height_value
                )
            }
        } else {
            windows = []
        }

        return RuntimeStateExport(columns: columns, windows: windows)
    }

    static func validateAndDecodeRuntimeStateExport(
        _ rawExport: OmniNiriRuntimeStateExport
    ) -> Result<RuntimeStateExport, RuntimeExportDecodeError> {
        do {
            return .success(try decodeRuntimeStateExport(rawExport))
        } catch let error as RuntimeExportDecodeError {
            return .failure(error)
        } catch {
            return .failure(
                .runtimeCallFailed(operation: "omni_niri_runtime_snapshot.decode", rc: Int32(OMNI_ERR_INVALID_ARGS))
            )
        }
    }

    static func snapshotRuntimeStateResult(
        context: ZigNiriLayoutKernel.LayoutContext
    ) -> Result<RuntimeStateExport, RuntimeExportDecodeError> {
        var rawExport = OmniNiriRuntimeStateExport(
            columns: nil,
            column_count: 0,
            windows: nil,
            window_count: 0
        )

        let rc = context.withRawContext { raw in
            withUnsafeMutablePointer(to: &rawExport) { exportPtr in
                omni_niri_runtime_snapshot(raw, exportPtr)
            }
        }
        guard rc == OMNI_OK else {
            return .failure(
                .runtimeCallFailed(operation: "omni_niri_runtime_snapshot", rc: rc)
            )
        }

        return validateAndDecodeRuntimeStateExport(rawExport)
    }

    static func seedRuntimeState(
        context: ZigNiriLayoutKernel.LayoutContext,
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
                var request = OmniNiriRuntimeSeedRequest(
                    columns: columnPtr,
                    column_count: columnBuf.count,
                    windows: windowPtr,
                    window_count: windowBuf.count
                )

                guard !(columnBuf.count > 0 && columnPtr == nil),
                      !(windowBuf.count > 0 && windowPtr == nil)
                else {
                    return Int32(OMNI_ERR_INVALID_ARGS)
                }
                return context.withRawContext { raw in
                    withUnsafePointer(to: &request) { requestPtr in
                        omni_niri_runtime_seed(raw, requestPtr)
                    }
                }
            }
        }
    }

    static func snapshotRuntimeState(
        context: ZigNiriLayoutKernel.LayoutContext
    ) -> (rc: Int32, export: RuntimeStateExport) {
        switch snapshotRuntimeStateResult(context: context) {
        case let .success(export):
            return (rc: Int32(OMNI_OK), export: export)
        case let .failure(error):
            return (
                rc: error.rc,
                export: RuntimeStateExport(columns: [], windows: [])
            )
        }
    }

    private static func emptyNavigationTxnPayload() -> OmniNiriTxnNavigationPayload {
        OmniNiriTxnNavigationPayload(
            op: 0,
            direction: 0,
            orientation: 0,
            infinite_loop: 0,
            has_source_window_id: 0,
            source_window_id: zeroUUID(),
            has_source_column_id: 0,
            source_column_id: zeroUUID(),
            has_target_window_id: 0,
            target_window_id: zeroUUID(),
            has_target_column_id: 0,
            target_column_id: zeroUUID(),
            step: 0,
            target_row_index: -1,
            focus_column_index: -1,
            focus_window_index: -1
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

    private static func emptyDeltaExport() -> DeltaExport {
        DeltaExport(
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
    }

    private static func decodeDeltaExport(
        _ rawExport: OmniNiriTxnDeltaExport
    ) throws -> DeltaExport {
        let columnCount = try validatedRuntimeExportCount(rawExport.column_count, field: "delta_column_count")
        let windowCount = try validatedRuntimeExportCount(rawExport.window_count, field: "delta_window_count")
        let removedColumnCount = try validatedRuntimeExportCount(
            rawExport.removed_column_count,
            field: "removed_column_count"
        )
        let removedWindowCount = try validatedRuntimeExportCount(
            rawExport.removed_window_count,
            field: "removed_window_count"
        )
        let refreshCount = try validatedRefreshHintCount(rawExport.refresh_tabbed_visibility_count)

        let columnBase = try validateRuntimePointer(
            rawExport.columns,
            count: columnCount,
            field: "delta_columns"
        )
        let windowBase = try validateRuntimePointer(
            rawExport.windows,
            count: windowCount,
            field: "delta_windows"
        )
        let removedColumnBase = try validateRuntimePointer(
            rawExport.removed_column_ids,
            count: removedColumnCount,
            field: "removed_column_ids"
        )
        let removedWindowBase = try validateRuntimePointer(
            rawExport.removed_window_ids,
            count: removedWindowCount,
            field: "removed_window_ids"
        )

        var columns: [DeltaColumnRecord] = []
        if let columnBase, columnCount > 0 {
            let rawColumns = Array(UnsafeBufferPointer(start: columnBase, count: columnCount))
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
        if let windowBase, windowCount > 0 {
            let rawWindows = Array(UnsafeBufferPointer(start: windowBase, count: windowCount))
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

        let removedColumnIds: [NodeId]
        if let removedColumnBase, removedColumnCount > 0 {
            removedColumnIds = Array(
                UnsafeBufferPointer(start: removedColumnBase, count: removedColumnCount)
            ).map(nodeId(from:))
        } else {
            removedColumnIds = []
        }

        let removedWindowIds: [NodeId]
        if let removedWindowBase, removedWindowCount > 0 {
            removedWindowIds = Array(
                UnsafeBufferPointer(start: removedWindowBase, count: removedWindowCount)
            ).map(nodeId(from:))
        } else {
            removedWindowIds = []
        }

        var refreshIds: [NodeId] = []
        refreshIds.reserveCapacity(refreshCount)
        withUnsafePointer(to: rawExport.refresh_tabbed_visibility_column_ids) { tuplePtr in
            let base = UnsafeRawPointer(tuplePtr).assumingMemoryBound(to: OmniUuid128.self)
            for idx in 0 ..< refreshCount {
                refreshIds.append(nodeId(from: base[idx]))
            }
        }

        let delegatedMoveColumn: (columnId: NodeId, direction: Direction)?
        if rawExport.has_delegate_move_column != 0 {
            guard let resolvedDirection = direction(from: rawExport.delegate_move_direction) else {
                throw RuntimeExportDecodeError.runtimeCallFailed(
                    operation: "omni_niri_ctx_export_delta.decode_delegate_move_direction",
                    rc: Int32(OMNI_ERR_INVALID_ARGS)
                )
            }
            delegatedMoveColumn = (
                nodeId(from: rawExport.delegate_move_column_id),
                resolvedDirection
            )
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

        return DeltaExport(
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
    }

    static func validateAndDecodeDeltaExport(
        _ rawExport: OmniNiriTxnDeltaExport
    ) -> Result<DeltaExport, RuntimeExportDecodeError> {
        do {
            return .success(try decodeDeltaExport(rawExport))
        } catch let error as RuntimeExportDecodeError {
            return .failure(error)
        } catch {
            return .failure(
                .runtimeCallFailed(operation: "omni_niri_ctx_export_delta.decode", rc: Int32(OMNI_ERR_INVALID_ARGS))
            )
        }
    }

    static func exportDeltaResult(
        context: ZigNiriLayoutKernel.LayoutContext
    ) -> Result<DeltaExport, RuntimeExportDecodeError> {
        var rawExport = OmniNiriTxnDeltaExport()
        let rc = context.withRawContext { raw in
            withUnsafeMutablePointer(to: &rawExport) { exportPtr in
                omni_niri_ctx_export_delta(raw, exportPtr)
            }
        }
        guard rc == OMNI_OK else {
            return .failure(
                .runtimeCallFailed(operation: "omni_niri_ctx_export_delta", rc: rc)
            )
        }

        return validateAndDecodeDeltaExport(rawExport)
    }

    static func exportDelta(
        context: ZigNiriLayoutKernel.LayoutContext
    ) -> (rc: Int32, export: DeltaExport) {
        switch exportDeltaResult(context: context) {
        case let .success(export):
            return (rc: Int32(OMNI_OK), export: export)
        case let .failure(error):
            return (rc: error.rc, export: emptyDeltaExport())
        }
    }

    static func applyTxn(_ request: TxnRequest) -> TxnOutcome {
        let sourceContext: ZigNiriLayoutKernel.LayoutContext
        let targetContext: ZigNiriLayoutKernel.LayoutContext?
        let kind: TxnKind
        var rawNavigation = emptyNavigationTxnPayload()
        var rawMutation = emptyMutationTxnPayload()
        var rawWorkspace = emptyWorkspaceTxnPayload()

        switch request {
        case let .navigation(context, navRequest):
            sourceContext = context
            targetContext = nil
            kind = .navigation

            rawNavigation = OmniNiriTxnNavigationPayload(
                op: navigationOpCode(navRequest.request.op),
                direction: navigationDirectionCode(navRequest.request.direction),
                orientation: orientationCode(navRequest.request.orientation),
                infinite_loop: navRequest.request.infiniteLoop ? 1 : 0,
                has_source_window_id: navRequest.request.sourceWindowId == nil ? 0 : 1,
                source_window_id: navRequest.request.sourceWindowId.map(omniUUID(from:)) ?? zeroUUID(),
                has_source_column_id: navRequest.request.sourceColumnId == nil ? 0 : 1,
                source_column_id: navRequest.request.sourceColumnId.map(omniUUID(from:)) ?? zeroUUID(),
                has_target_window_id: navRequest.request.targetWindowId == nil ? 0 : 1,
                target_window_id: navRequest.request.targetWindowId.map(omniUUID(from:)) ?? zeroUUID(),
                has_target_column_id: navRequest.request.targetColumnId == nil ? 0 : 1,
                target_column_id: navRequest.request.targetColumnId.map(omniUUID(from:)) ?? zeroUUID(),
                step: Int64(navRequest.request.step),
                target_row_index: Int64(navRequest.request.targetRowIndex),
                focus_column_index: Int64(navRequest.request.focusColumnIndex),
                focus_window_index: Int64(navRequest.request.focusWindowIndex)
            )
        case let .mutation(context, mutationRequest):
            sourceContext = context
            targetContext = nil
            kind = .mutation

            rawMutation = OmniNiriTxnMutationPayload(
                op: mutationOpCode(mutationRequest.request.op),
                direction: mutationDirectionCode(mutationRequest.request.direction),
                infinite_loop: mutationRequest.request.infiniteLoop ? 1 : 0,
                insert_position: insertPositionCode(mutationRequest.request.insertPosition),
                has_source_window_id: mutationRequest.request.sourceWindowId == nil ? 0 : 1,
                source_window_id: mutationRequest.request.sourceWindowId.map(omniUUID(from:)) ?? zeroUUID(),
                has_target_window_id: mutationRequest.request.targetWindowId == nil ? 0 : 1,
                target_window_id: mutationRequest.request.targetWindowId.map(omniUUID(from:)) ?? zeroUUID(),
                max_windows_per_column: Int64(mutationRequest.request.maxWindowsPerColumn),
                has_source_column_id: mutationRequest.request.sourceColumnId == nil ? 0 : 1,
                source_column_id: mutationRequest.request.sourceColumnId.map(omniUUID(from:)) ?? zeroUUID(),
                has_target_column_id: mutationRequest.request.targetColumnId == nil ? 0 : 1,
                target_column_id: mutationRequest.request.targetColumnId.map(omniUUID(from:)) ?? zeroUUID(),
                insert_column_index: Int64(mutationRequest.request.insertColumnIndex),
                max_visible_columns: Int64(mutationRequest.request.maxVisibleColumns),
                has_selected_node_id: mutationRequest.request.selectedNodeId == nil ? 0 : 1,
                selected_node_id: mutationRequest.request.selectedNodeId.map(omniUUID(from:)) ?? zeroUUID(),
                has_focused_window_id: mutationRequest.request.focusedWindowId == nil ? 0 : 1,
                focused_window_id: mutationRequest.request.focusedWindowId.map(omniUUID(from:)) ?? zeroUUID(),
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
            rawWorkspace = OmniNiriTxnWorkspacePayload(
                op: workspaceOpCode(workspaceRequest.request.op),
                has_source_window_id: workspaceRequest.request.sourceWindowId == nil ? 0 : 1,
                source_window_id: workspaceRequest.request.sourceWindowId.map(omniUUID(from:)) ?? zeroUUID(),
                has_source_column_id: workspaceRequest.request.sourceColumnId == nil ? 0 : 1,
                source_column_id: workspaceRequest.request.sourceColumnId.map(omniUUID(from:)) ?? zeroUUID(),
                max_visible_columns: Int64(workspaceRequest.request.maxVisibleColumns),
                has_target_created_column_id: workspaceRequest.targetCreatedColumnId == nil ? 0 : 1,
                target_created_column_id: workspaceRequest.targetCreatedColumnId.map(omniUUID(from:)) ?? zeroUUID(),
                has_source_placeholder_column_id: workspaceRequest.sourcePlaceholderColumnId == nil ? 0 : 1,
                source_placeholder_column_id: workspaceRequest.sourcePlaceholderColumnId.map(omniUUID(from:)) ?? zeroUUID()
            )
        }

        let rawRequest = OmniNiriTxnRequest(
            kind: kind.rawValue,
            navigation: rawNavigation,
            mutation: rawMutation,
            workspace: rawWorkspace,
            max_delta_columns: 0,
            max_delta_windows: 0,
            max_removed_ids: 0
        )
        var rawRuntimeRequest = OmniNiriRuntimeCommandRequest(txn: rawRequest)

        var rawRuntimeResult = OmniNiriRuntimeCommandResult()
        let rc = sourceContext.withRawContext { sourceRaw in
            withUnsafePointer(to: &rawRuntimeRequest) { requestPtr in
                withUnsafeMutablePointer(to: &rawRuntimeResult) { resultPtr in
                    if let targetContext {
                        return targetContext.withRawContext { targetRaw in
                            omni_niri_runtime_apply_command(sourceRaw, targetRaw, requestPtr, resultPtr)
                        }
                    }
                    return omni_niri_runtime_apply_command(sourceRaw, nil, requestPtr, resultPtr)
                }
            }
        }
        let rawResult = rawRuntimeResult.txn

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
        context: ZigNiriLayoutKernel.LayoutContext,
        request: MutationApplyRequest
    ) -> MutationApplyOutcome {
        let exported = applyTxnAndExportSingleContext(
            .mutation(context: context, request: request),
            context: context
        )
        guard exported.outcome.rc == OMNI_OK, exported.deltaRC == OMNI_OK else {
            return MutationApplyOutcome(
                rc: exported.outcome.rc != OMNI_OK ? exported.outcome.rc : exported.deltaRC,
                applied: false,
                targetWindowId: nil,
                targetNode: nil,
                delta: nil
            )
        }
        return MutationApplyOutcome(
            rc: exported.outcome.rc,
            applied: exported.outcome.applied,
            targetWindowId: exported.outcome.targetWindowId,
            targetNode: exported.outcome.targetNode,
            delta: exported.delta
        )
    }

    static func applyWorkspace(
        sourceContext: ZigNiriLayoutKernel.LayoutContext,
        targetContext: ZigNiriLayoutKernel.LayoutContext,
        request: WorkspaceApplyRequest
    ) -> WorkspaceApplyOutcome {
        let exported = applyTxnAndExportWorkspace(
            sourceContext: sourceContext,
            targetContext: targetContext,
            request: request
        )
        return WorkspaceApplyOutcome(
            rc: exported.outcome.rc,
            applied: exported.outcome.applied,
            sourceSelectionWindowId: exported.sourceDelta?.sourceSelectionWindowId,
            targetSelectionWindowId: exported.targetDelta?.targetSelectionWindowId,
            movedWindowId: exported.targetDelta?.movedWindowId,
            sourceDelta: exported.sourceDelta,
            targetDelta: exported.targetDelta
        )
    }

    static func applyNavigation(
        context: ZigNiriLayoutKernel.LayoutContext,
        request: NavigationApplyRequest
    ) -> NavigationApplyOutcome {
        let exported = applyTxnAndExportSingleContext(
            .navigation(context: context, request: request),
            context: context
        )
        let refreshColumnIds: [NodeId]
        if exported.deltaRC == OMNI_OK, let delta = exported.delta {
            refreshColumnIds = delta.refreshTabbedVisibilityColumnIds
        } else {
            refreshColumnIds = []
        }
        return NavigationApplyOutcome(
            rc: exported.outcome.rc,
            applied: exported.outcome.applied,
            targetWindowId: exported.outcome.targetWindowId,
            sourceActiveTileUpdate: nil,
            targetActiveTileUpdate: nil,
            refreshSourceColumnId: refreshColumnIds.first,
            refreshTargetColumnId: refreshColumnIds.count > 1 ? refreshColumnIds[1] : nil,
            delta: exported.deltaRC == OMNI_OK ? exported.delta : nil
        )
    }

    private static func applyTxnAndExportSingleContext(
        _ request: TxnRequest,
        context: ZigNiriLayoutKernel.LayoutContext
    ) -> (
        outcome: TxnOutcome,
        deltaRC: Int32,
        delta: DeltaExport?
    ) {
        let outcome = applyTxn(request)
        let delta = exportDelta(context: context)
        return (
            outcome: outcome,
            deltaRC: delta.rc,
            delta: delta.rc == OMNI_OK ? delta.export : nil
        )
    }

    private static func applyTxnAndExportWorkspace(
        sourceContext: ZigNiriLayoutKernel.LayoutContext,
        targetContext: ZigNiriLayoutKernel.LayoutContext,
        request: WorkspaceApplyRequest
    ) -> (
        outcome: TxnOutcome,
        sourceDelta: DeltaExport?,
        targetDelta: DeltaExport?
    ) {
        let outcome = applyTxn(
            .workspace(
                sourceContext: sourceContext,
                targetContext: targetContext,
                request: request
            )
        )
        let sourceDelta = exportDelta(context: sourceContext)
        let targetDelta = exportDelta(context: targetContext)
        return (
            outcome: outcome,
            sourceDelta: sourceDelta.rc == OMNI_OK ? sourceDelta.export : nil,
            targetDelta: targetDelta.rc == OMNI_OK ? targetDelta.export : nil
        )
    }
}

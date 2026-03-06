import CoreGraphics
import Foundation

struct ZigNiriWorkspaceView {
    let workspaceId: WorkspaceDescriptor.ID
    var columns: [ZigNiriColumnView]
    var windowsById: [NodeId: ZigNiriWindowView]
    var selection: ZigNiriSelection?
}

struct ZigNiriColumnView {
    let nodeId: NodeId
    var windowIds: [NodeId]
    var display: ColumnDisplay
    var activeWindowIndex: Int?
    var width: ProportionalSize = .default
    var isFullWidth: Bool = false
}

struct ZigNiriWindowView {
    let nodeId: NodeId
    let handle: WindowHandle
    var columnId: NodeId?
    var frame: CGRect?
    var sizingMode: SizingMode
    var height: WeightedSize
    var isFocused: Bool
}

struct ZigNiriSelection: Equatable {
    var selectedNodeId: NodeId?
    var focusedWindowId: NodeId?

    static let none = ZigNiriSelection(selectedNodeId: nil, focusedWindowId: nil)
}

struct ZigNiriMutationResult {
    let applied: Bool
    let workspaceId: WorkspaceDescriptor.ID?
    let selection: ZigNiriSelection?
    let affectedNodeIds: [NodeId]
    let removedNodeIds: [NodeId]
    let structuralAnimationActive: Bool
    let resizeOutput: ZigNiriResizeMutationOutput?

    init(
        applied: Bool,
        workspaceId: WorkspaceDescriptor.ID?,
        selection: ZigNiriSelection?,
        affectedNodeIds: [NodeId],
        removedNodeIds: [NodeId],
        structuralAnimationActive: Bool = false,
        resizeOutput: ZigNiriResizeMutationOutput? = nil
    ) {
        self.applied = applied
        self.workspaceId = workspaceId
        self.selection = selection
        self.affectedNodeIds = affectedNodeIds
        self.removedNodeIds = removedNodeIds
        self.structuralAnimationActive = structuralAnimationActive
        self.resizeOutput = resizeOutput
    }

    static func noChange(
        workspaceId: WorkspaceDescriptor.ID?,
        selection: ZigNiriSelection?
    ) -> ZigNiriMutationResult {
        ZigNiriMutationResult(
            applied: false,
            workspaceId: workspaceId,
            selection: selection,
            affectedNodeIds: [],
            removedNodeIds: [],
            structuralAnimationActive: false,
            resizeOutput: nil
        )
    }
}

struct ZigNiriResizeMutationOutput {
    let columnWidth: CGFloat?
    let windowWeight: CGFloat?
    let viewportOffset: CGFloat?
}

struct ZigNiriNavigationResult {
    let applied: Bool
    let workspaceId: WorkspaceDescriptor.ID
    let targetNodeId: NodeId?
    let selection: ZigNiriSelection?
    let wrapped: Bool

    static func noChange(
        workspaceId: WorkspaceDescriptor.ID,
        targetNodeId: NodeId?,
        selection: ZigNiriSelection?
    ) -> ZigNiriNavigationResult {
        ZigNiriNavigationResult(
            applied: false,
            workspaceId: workspaceId,
            targetNodeId: targetNodeId,
            selection: selection,
            wrapped: false
        )
    }
}

enum ZigNiriNavigationRequest {
    case focus(direction: Direction)
    case move(direction: Direction)
    case focusDownOrLeft
    case focusUpOrRight
    case focusColumnFirst
    case focusColumnLast
    case focusColumn(index: Int)
    case focusWindow(index: Int)
    case focusWindowTop
    case focusWindowBottom
}

enum ZigNiriMutationRequest {
    case setColumnDisplay(columnId: NodeId, display: ColumnDisplay)
    case setColumnActiveWindow(columnId: NodeId, windowIndex: Int)
    case setColumnWidth(columnId: NodeId, width: ProportionalSize)
    case toggleColumnFullWidth(columnId: NodeId)
    case setWindowSizing(windowId: NodeId, mode: SizingMode)
    case setWindowHeight(windowId: NodeId, height: WeightedSize)
    case moveWindow(windowId: NodeId, direction: Direction, orientation: Monitor.Orientation)
    case swapWindow(windowId: NodeId, direction: Direction, orientation: Monitor.Orientation)
    case moveColumn(columnId: NodeId, direction: Direction)
    case consumeWindow(windowId: NodeId, direction: Direction)
    case expelWindow(windowId: NodeId, direction: Direction)
    case insertWindowByMove(sourceWindowId: NodeId, targetWindowId: NodeId, position: InsertPosition)
    case insertWindowInNewColumn(windowId: NodeId, insertIndex: Int)
    case balanceSizes
    case removeWindow(windowId: NodeId)
    case custom(name: String)
}

enum ZigNiriWorkspaceRequest {
    case ensureWorkspace
    case clearWorkspace
    case setSelection(ZigNiriSelection?)
    case moveWindow(windowId: NodeId, targetWorkspaceId: WorkspaceDescriptor.ID)
    case moveColumn(columnId: NodeId, targetWorkspaceId: WorkspaceDescriptor.ID)
}

struct ZigNiriWorkingAreaContext {
    var workingFrame: CGRect
    var viewFrame: CGRect
    var scale: CGFloat
}

struct ZigNiriGaps {
    var horizontal: CGFloat
    var vertical: CGFloat

    static let `default` = ZigNiriGaps(horizontal: 8, vertical: 8)
}

struct ZigNiriLayoutRequest {
    let workspaceId: WorkspaceDescriptor.ID
    let monitorFrame: CGRect
    let screenFrame: CGRect?
    let gaps: ZigNiriGaps
    let scale: CGFloat
    let workingArea: ZigNiriWorkingAreaContext?
    let orientation: Monitor.Orientation
    let viewportOffset: CGFloat
    let animationTime: TimeInterval?

    init(
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        screenFrame: CGRect?,
        gaps: ZigNiriGaps,
        scale: CGFloat,
        workingArea: ZigNiriWorkingAreaContext?,
        orientation: Monitor.Orientation,
        viewportOffset: CGFloat,
        animationTime: TimeInterval? = nil
    ) {
        self.workspaceId = workspaceId
        self.monitorFrame = monitorFrame
        self.screenFrame = screenFrame
        self.gaps = gaps
        self.scale = scale
        self.workingArea = workingArea
        self.orientation = orientation
        self.viewportOffset = viewportOffset
        self.animationTime = animationTime
    }
}

struct ZigNiriLayoutResult {
    let frames: [WindowHandle: CGRect]
    let hiddenHandles: [WindowHandle: HideSide]
}

struct ZigNiriHitTestRequest {
    let workspaceId: WorkspaceDescriptor.ID
    let monitorFrame: CGRect
    let gaps: ZigNiriGaps
    let scale: CGFloat
    let orientation: Monitor.Orientation
}

struct ZigNiriTiledHitResult {
    let windowHandle: WindowHandle
    let windowId: NodeId
    let columnId: NodeId?
    let columnIndex: Int?
    let windowFrame: CGRect
}

struct ZigNiriResizeEdge: OptionSet, Hashable {
    let rawValue: UInt32

    static let top = ZigNiriResizeEdge(rawValue: 0b0001)
    static let bottom = ZigNiriResizeEdge(rawValue: 0b0010)
    static let left = ZigNiriResizeEdge(rawValue: 0b0100)
    static let right = ZigNiriResizeEdge(rawValue: 0b1000)

    var hasHorizontal: Bool {
        !intersection([.left, .right]).isEmpty
    }

    var hasVertical: Bool {
        !intersection([.top, .bottom]).isEmpty
    }
}

struct ZigNiriResizeHitResult {
    let windowHandle: WindowHandle
    let windowId: NodeId
    let columnIndex: Int?
    let edges: ZigNiriResizeEdge
    let windowFrame: CGRect
}

enum ZigNiriInsertPosition: Equatable {
    case before
    case after
    case swap
}

enum ZigNiriHorizontalSide: Equatable {
    case left
    case right
}

enum ZigNiriMoveHoverTarget: Equatable {
    case window(nodeId: NodeId, handle: WindowHandle, insertPosition: ZigNiriInsertPosition)
    case columnGap(columnIndex: Int, insertPosition: ZigNiriInsertPosition)
    case workspaceEdge(side: ZigNiriHorizontalSide)
}

struct ZigNiriInteractiveMoveState {
    let windowId: NodeId
    let workspaceId: WorkspaceDescriptor.ID
    let startMouseLocation: CGPoint
    let monitorFrame: CGRect
    var currentHoverTarget: ZigNiriMoveHoverTarget?
}

struct ZigNiriInteractiveResizeState {
    let windowId: NodeId
    let workspaceId: WorkspaceDescriptor.ID
    let edges: ZigNiriResizeEdge
    let startMouseLocation: CGPoint
    let monitorFrame: CGRect
    let orientation: Monitor.Orientation
    let gap: CGFloat
    let initialViewportOffset: CGFloat?
}

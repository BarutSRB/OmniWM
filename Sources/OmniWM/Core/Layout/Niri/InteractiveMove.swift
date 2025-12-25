import AppKit
import Foundation

struct InteractiveMove {
    let windowId: NodeId
    let windowHandle: WindowHandle
    let workspaceId: WorkspaceDescriptor.ID
    let startMouseLocation: CGPoint
    let originalColumnIndex: Int
    let originalWindowIndexInColumn: Int
    let originalFrame: CGRect

    var currentHoverTarget: MoveHoverTarget?
}

enum MoveHoverTarget: Equatable {
    case window(nodeId: NodeId, handle: WindowHandle, insertPosition: InsertPosition)
    case columnGap(columnIndex: Int, insertPosition: InsertPosition)
    case workspaceEdge(side: HorizontalSide)
}

enum InsertPosition: Equatable {
    case before
    case after
    case swap
}

enum HorizontalSide: Equatable {
    case left
    case right
}

struct MoveHitTestResult {
    let target: MoveHoverTarget
    let targetFrame: CGRect
}

struct MoveConfiguration {
    var edgeDropZone: CGFloat = 50.0
    var showPreview: Bool = true
    var dragThreshold: CGFloat = 10.0

    static let `default` = MoveConfiguration()
}

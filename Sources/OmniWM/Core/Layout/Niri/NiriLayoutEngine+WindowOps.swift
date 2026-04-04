import AppKit
import Foundation

extension NiriLayoutEngine {
    func moveWindow(
        _ node: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        switch direction {
        case .down, .up:
            moveWindowVertical(node, direction: direction)
        case .left, .right:
            consumeOrExpelWindow(
                node,
                direction: direction,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }
    }

    private func moveWindowVertical(_ node: NiriWindow, direction: Direction) -> Bool {
        guard let column = node.parent as? NiriContainer else {
            return false
        }

        let sibling: NiriNode?
        switch direction {
        case .up:
            sibling = node.nextSibling()
        case .down:
            sibling = node.prevSibling()
        default:
            return false
        }

        guard let targetSibling = sibling else {
            return false
        }

        let nodeIdx = column.windowNodes.firstIndex { $0 === node }
        let siblingIdx = column.windowNodes.firstIndex { $0 === targetSibling }

        node.swapWith(targetSibling)

        if column.displayMode == .tabbed, let nIdx = nodeIdx, let sIdx = siblingIdx {
            if nIdx == column.activeTileIdx {
                column.setActiveTileIdx(sIdx)
            } else if sIdx == column.activeTileIdx {
                column.setActiveTileIdx(nIdx)
            }
        }

        return true
    }
}

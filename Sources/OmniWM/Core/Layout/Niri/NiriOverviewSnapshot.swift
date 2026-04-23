// SPDX-License-Identifier: GPL-2.0-only
import CoreGraphics
import Foundation

struct NiriOverviewTileSnapshot: Equatable {
    let token: WindowToken
    let preferredHeight: CGFloat
}

struct NiriOverviewColumnSnapshot: Equatable {
    let index: Int
    let widthWeight: CGFloat
    let preferredWidth: CGFloat?
    let tiles: [NiriOverviewTileSnapshot]
}

struct NiriOverviewWorkspaceSnapshot: Equatable {
    let workspaceId: WorkspaceDescriptor.ID
    let columns: [NiriOverviewColumnSnapshot]
}

extension NiriLayoutEngine {
    func overviewSnapshot(for workspaceId: WorkspaceDescriptor.ID) -> NiriOverviewWorkspaceSnapshot? {
        let workspaceColumns = columns(in: workspaceId)
        guard !workspaceColumns.isEmpty else { return nil }

        let snapshotColumns = workspaceColumns.enumerated().map { index, column in
            NiriOverviewColumnSnapshot(
                index: index,
                widthWeight: overviewWidthWeight(for: column),
                preferredWidth: overviewPreferredWidth(for: column),
                tiles: column.windowNodes.reversed().map {
                    NiriOverviewTileSnapshot(
                        token: $0.token,
                        preferredHeight: overviewPreferredHeight(for: $0)
                    )
                }
            )
        }

        return NiriOverviewWorkspaceSnapshot(
            workspaceId: workspaceId,
            columns: snapshotColumns
        )
    }

    private func overviewPreferredWidth(for column: NiriContainer) -> CGFloat? {
        if column.cachedWidth > 0 {
            return column.cachedWidth
        }

        switch column.width {
        case let .fixed(width):
            return max(width, 1)
        case .proportion:
            return nil
        }
    }

    private func overviewWidthWeight(for column: NiriContainer) -> CGFloat {
        switch column.width {
        case let .proportion(weight):
            return max(weight, 0.001)
        case let .fixed(width):
            return max(width, 1)
        }
    }

    private func overviewPreferredHeight(for window: NiriWindow) -> CGFloat {
        if let resolvedHeight = window.resolvedHeight, resolvedHeight > 0 {
            return resolvedHeight
        }
        if let frameHeight = window.frame?.height, frameHeight > 0 {
            return frameHeight
        }
        switch window.height {
        case let .auto(weight):
            return max(weight, 1)
        case let .fixed(height):
            return max(height, 1)
        }
    }
}

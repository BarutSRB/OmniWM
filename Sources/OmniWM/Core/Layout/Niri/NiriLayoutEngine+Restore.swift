// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

extension NiriLayoutEngine {
    func persistedPlacements(in workspaceId: WorkspaceDescriptor.ID) -> [WindowToken: PersistedNiriPlacement] {
        let columns = columns(in: workspaceId)
        guard !columns.isEmpty else { return [:] }

        var placements: [WindowToken: PersistedNiriPlacement] = [:]
        placements.reserveCapacity(columns.reduce(0) { $0 + $1.windowNodes.count })

        for (columnIndex, column) in columns.enumerated() {
            let columnState = PersistedNiriColumnState(
                displayMode: column.displayMode,
                activeTileIndex: column.activeTileIdx,
                width: column.width,
                presetWidthIndex: column.presetWidthIdx,
                isFullWidth: column.isFullWidth,
                savedWidth: column.savedWidth,
                hasManualSingleWindowWidthOverride: column.hasManualSingleWindowWidthOverride
            )

            for (tileIndex, window) in column.windowNodes.enumerated() {
                placements[window.token] = PersistedNiriPlacement(
                    columnIndex: columnIndex,
                    tileIndex: tileIndex,
                    column: columnState,
                    window: PersistedNiriWindowState(
                        sizingMode: window.sizingMode,
                        height: window.height,
                        savedHeight: window.savedHeight,
                        windowWidth: window.windowWidth
                    )
                )
            }
        }

        return placements
    }

    @discardableResult
    func restoreInitialPlacements(
        _ placements: [WindowToken: PersistedNiriPlacement],
        matching tokens: [WindowToken],
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        assertSanctionedMutation()
        guard !placements.isEmpty, !tokens.isEmpty else { return false }

        let root = ensureRoot(for: workspaceId)
        let currentTokens = root.windowIdSet
        let placedTokens = Set(tokens.compactMap { token -> WindowToken? in
            guard let placement = placements[token],
                  placement.columnIndex >= 0,
                  placement.tileIndex >= 0
            else {
                return nil
            }
            return token
        })
        let missingPlacedTokens = placedTokens.subtracting(currentTokens)
        guard !placedTokens.isEmpty, !missingPlacedTokens.isEmpty else { return false }
        guard currentTokens.isEmpty || currentTokens.isSubset(of: placedTokens) else { return false }

        removeEmptyColumnsIfWorkspaceEmpty(in: root)

        var tokenOrder: [WindowToken: Int] = [:]
        tokenOrder.reserveCapacity(tokens.count)
        for (index, token) in tokens.enumerated() where tokenOrder[token] == nil {
            tokenOrder[token] = index
        }

        var placementsByColumn: [Int: [(token: WindowToken, placement: PersistedNiriPlacement)]] = [:]
        placementsByColumn.reserveCapacity(placedTokens.count)

        for token in tokens {
            guard placedTokens.contains(token), let placement = placements[token] else { continue }

            placementsByColumn[placement.columnIndex, default: []].append((token, placement))
        }

        guard !placementsByColumn.isEmpty else { return false }

        var reusableNodes: [WindowToken: NiriWindow] = [:]
        reusableNodes.reserveCapacity(currentTokens.count)
        for window in root.allWindows {
            reusableNodes[window.token] = window
        }

        for window in reusableNodes.values {
            window.detach()
        }
        removeEmptyColumnsIfWorkspaceEmpty(in: root)

        for columnIndex in placementsByColumn.keys.sorted() {
            let groupedPlacements = placementsByColumn[columnIndex, default: []].sorted { lhs, rhs in
                if lhs.placement.tileIndex != rhs.placement.tileIndex {
                    return lhs.placement.tileIndex < rhs.placement.tileIndex
                }
                return (tokenOrder[lhs.token] ?? Int.max) < (tokenOrder[rhs.token] ?? Int.max)
            }
            guard let seed = groupedPlacements.first else { continue }

            let column = NiriContainer()
            applyPersistedColumnState(seed.placement.column, to: column)
            root.appendChild(column)

            for groupedPlacement in groupedPlacements {
                let window = reusableNodes[groupedPlacement.token] ?? NiriWindow(token: groupedPlacement.token)
                applyPersistedWindowState(groupedPlacement.placement.window, to: window)
                column.appendChild(window)
                tokenToNode[groupedPlacement.token] = window
            }

            column.setActiveTileIdx(seed.placement.column.activeTileIndex)
            updateTabbedColumnVisibility(column: column)
        }

        return true
    }

    private func applyPersistedColumnState(_ state: PersistedNiriColumnState, to column: NiriContainer) {
        column.displayMode = state.displayMode
        column.width = state.width
        column.presetWidthIdx = state.presetWidthIndex
        column.isFullWidth = state.isFullWidth
        column.savedWidth = state.savedWidth
        column.hasManualSingleWindowWidthOverride = state.hasManualSingleWindowWidthOverride
        column.cachedWidth = 0
        column.widthAnimation = nil
        column.targetWidth = nil
    }

    private func applyPersistedWindowState(_ state: PersistedNiriWindowState, to window: NiriWindow) {
        window.sizingMode = state.sizingMode
        window.height = state.height
        window.savedHeight = state.savedHeight
        window.windowWidth = state.windowWidth
        window.resolvedHeight = nil
        window.resolvedWidth = nil
        window.heightFixedByConstraint = false
        window.widthFixedByConstraint = false
        window.isHiddenInTabbedMode = false
    }
}

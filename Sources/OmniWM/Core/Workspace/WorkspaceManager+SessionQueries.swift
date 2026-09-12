// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    var interactionMonitorId: Monitor.ID? {
        focusSessionSnapshot.interactionMonitorId
    }

    var previousInteractionMonitorId: Monitor.ID? {
        focusSessionSnapshot.previousInteractionMonitorId
    }

    var selectedManagedToken: WindowToken? {
        focusSessionSnapshot.selectedManagedToken
    }

    var nativeFocusOwner: NativeFocusOwner {
        focusSessionSnapshot.nativeFocusOwner
    }

    var nativeManagedFocusToken: WindowToken? {
        focusSessionSnapshot.nativeFocusOwner.managedToken
    }

    var lastTiledFocusedToken: WindowToken? {
        focusSessionSnapshot.lastTiledFocusedToken
    }

    func mostRecentlyFocusedTiledToken(excluding token: WindowToken) -> WindowToken? {
        focusSessionSnapshot.tiledFocusHistory.first { candidate in
            candidate != token && (windowMode(for: candidate) ?? .tiling) == .tiling && entry(for: candidate) != nil
        }
    }

    var selectedManagedHandle: WindowHandle? {
        selectedManagedToken.flatMap { windowQueries.handle(for: $0) }
    }

    var pendingFocusedToken: WindowToken? {
        focusSessionSnapshot.pendingManagedFocus.token
    }

    var pendingFocusedHandle: WindowHandle? {
        pendingFocusedToken.flatMap { windowQueries.handle(for: $0) }
    }

    var pendingFocusedWorkspaceId: WorkspaceDescriptor.ID? {
        focusSessionSnapshot.pendingManagedFocus.workspaceId
    }

    var pendingFocusedMonitorId: Monitor.ID? {
        focusSessionSnapshot.pendingManagedFocus.monitorId
    }

    func scratchpadMembers(in index: ScratchpadIndex) -> [WindowToken] {
        scratchpadState.membersBySlot[index] ?? []
    }

    func occupiedScratchpadIndices() -> [ScratchpadIndex] {
        scratchpadState.membersBySlot.keys.sorted()
    }

    func isScratchpadToken(_ token: WindowToken) -> Bool {
        scratchpadIndex(for: token) != nil
    }

    func revealedScratchpadIndex() -> ScratchpadIndex? {
        scratchpadState.revealedIndex
    }

    @discardableResult
    func setScratchpadMembership(_ token: WindowToken, to index: ScratchpadIndex?) -> Bool {
        updateScratchpadMembership(token, to: index, notify: true)
    }

    @discardableResult
    func clearScratchpadIfMatches(_ token: WindowToken) -> Bool {
        updateScratchpadMembership(token, to: nil, notify: true)
    }

    @discardableResult
    func setRevealedScratchpad(_ index: ScratchpadIndex?) -> Bool {
        guard scratchpadState.revealedIndex != index else { return false }
        if let index, scratchpadState.membersBySlot[index] == nil { return false }
        recordReconcileEvent(.scratchpadRevealChanged(index: index, source: .workspaceManager))
        notifySessionStateChanged()
        drainPendingRuntimeMonitorOverrideClears()
        return true
    }
}

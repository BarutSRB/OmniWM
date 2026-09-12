// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

@MainActor
final class ScratchpadRevealGroups {
    private weak var controller: WMController?
    private var nextScratchpadRevealGroupId: UInt64 = 1
    private var scratchpadRevealGroups: [UInt64: ScratchpadRevealGroup] = [:]

    init(controller: WMController?) {
        self.controller = controller
    }

    func indices() -> Set<ScratchpadIndex> {
        Set(scratchpadRevealGroups.values.map(\.index))
    }

    func contains(_ groupId: UInt64) -> Bool {
        scratchpadRevealGroups[groupId] != nil
    }

    func resetIdentitySequence() {
        nextScratchpadRevealGroupId = 1
    }

    private struct ScratchpadRevealGroup {
        let index: ScratchpadIndex
        var pendingTransactionIds: Set<UInt64> = []
        var revealedHandles: [WindowHandle] = []
        var sealed = false
        let onComplete: (LayoutRefreshController.ScratchpadRevealOutcome) -> Void
    }

    func begin(
        index: ScratchpadIndex,
        onComplete: @escaping (LayoutRefreshController.ScratchpadRevealOutcome) -> Void
    ) -> UInt64 {
        let groupId = nextScratchpadRevealGroupId
        nextScratchpadRevealGroupId &+= 1
        scratchpadRevealGroups[groupId] = ScratchpadRevealGroup(index: index, onComplete: onComplete)
        return groupId
    }

    func seal(_ groupId: UInt64) {
        guard var group = scratchpadRevealGroups[groupId] else { return }
        group.sealed = true
        guard group.pendingTransactionIds.isEmpty else {
            scratchpadRevealGroups[groupId] = group
            return
        }
        scratchpadRevealGroups.removeValue(forKey: groupId)
        group.onComplete(LayoutRefreshController.ScratchpadRevealOutcome(revealedHandles: group.revealedHandles))
    }

    @discardableResult
    func discard(_ groupId: UInt64) -> ScratchpadIndex? {
        scratchpadRevealGroups.removeValue(forKey: groupId)?.index
    }

    func discardAll() {
        scratchpadRevealGroups.removeAll()
    }

    func recordSuccess(_ token: WindowToken, groupId: UInt64) {
        guard var group = scratchpadRevealGroups[groupId],
              let controller,
              let handle = controller.workspaceManager.handle(for: token)
        else {
            return
        }
        if !group.revealedHandles.contains(where: { $0 === handle }) {
            group.revealedHandles.append(handle)
        }
        scratchpadRevealGroups[groupId] = group
    }

    func register(_ transactionId: UInt64, groupId: UInt64) {
        guard var group = scratchpadRevealGroups[groupId] else { return }
        group.pendingTransactionIds.insert(transactionId)
        scratchpadRevealGroups[groupId] = group
    }

    func detach(_ transactionId: UInt64, groupId: UInt64) {
        guard var group = scratchpadRevealGroups[groupId] else { return }
        group.pendingTransactionIds.remove(transactionId)
        guard group.sealed, group.pendingTransactionIds.isEmpty else {
            scratchpadRevealGroups[groupId] = group
            return
        }
        scratchpadRevealGroups.removeValue(forKey: groupId)
        group.onComplete(LayoutRefreshController.ScratchpadRevealOutcome(revealedHandles: group.revealedHandles))
    }

    func settle(
        _ transaction: LayoutRefreshController.PendingRevealTransaction,
        succeeded: Bool
    ) {
        guard let groupId = transaction.revealGroupId,
              var group = scratchpadRevealGroups[groupId]
        else {
            return
        }
        group.pendingTransactionIds.remove(transaction.id)
        if succeeded,
           let controller,
           let handle = controller.workspaceManager.handle(for: transaction.token),
           !group.revealedHandles.contains(where: { $0 === handle })
        {
            group.revealedHandles.append(handle)
        }
        guard group.sealed, group.pendingTransactionIds.isEmpty else {
            scratchpadRevealGroups[groupId] = group
            return
        }
        scratchpadRevealGroups.removeValue(forKey: groupId)
        group.onComplete(LayoutRefreshController.ScratchpadRevealOutcome(revealedHandles: group.revealedHandles))
    }
}

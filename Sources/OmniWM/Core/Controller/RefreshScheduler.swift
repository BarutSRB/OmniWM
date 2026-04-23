// SPDX-License-Identifier: GPL-2.0-only
import Foundation

@MainActor
final class RefreshScheduler {
    typealias PostLayoutAction = @MainActor () -> Void

    private var nextRefreshCycleId: RefreshCycleId = 1
    private var nextPostLayoutAttachmentId: RefreshAttachmentId = 1
    private var postLayoutActionsByAttachmentId: [RefreshAttachmentId: PostLayoutAction] = [:]

    func makeScheduledRefresh(
        kind: ScheduledRefreshKind,
        reason: RefreshReason,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = [],
        postLayoutAttachmentIds: [RefreshAttachmentId] = [],
        windowRemovalPayload: WindowRemovalPayload? = nil
    ) -> ScheduledRefresh {
        ScheduledRefresh(
            cycleId: allocateRefreshCycleId(),
            kind: kind,
            reason: reason,
            affectedWorkspaceIds: affectedWorkspaceIds,
            postLayoutAttachmentIds: postLayoutAttachmentIds,
            windowRemovalPayload: windowRemovalPayload
        )
    }

    func synchronizeCycleCounter(
        activeRefresh: ScheduledRefresh?,
        pendingRefresh: ScheduledRefresh?
    ) {
        let highestObservedCycleId = [activeRefresh?.cycleId, pendingRefresh?.cycleId]
            .compactMap(\.self)
            .max()

        guard let highestObservedCycleId else { return }
        nextRefreshCycleId = max(nextRefreshCycleId, highestObservedCycleId &+ 1)
    }

    func registerPostLayoutAttachments(
        _ postLayout: PostLayoutAction?
    ) -> [RefreshAttachmentId] {
        guard let postLayout else {
            return []
        }
        let id = nextPostLayoutAttachmentId
        nextPostLayoutAttachmentId &+= 1
        postLayoutActionsByAttachmentId[id] = postLayout
        return [id]
    }

    func resolvePostLayoutActions(
        attachmentIds: [RefreshAttachmentId]
    ) -> [PostLayoutAction] {
        attachmentIds.compactMap { postLayoutActionsByAttachmentId[$0] }
    }

    func runPostLayoutActions(
        attachmentIds: [RefreshAttachmentId]
    ) {
        for attachmentId in attachmentIds {
            guard let action = postLayoutActionsByAttachmentId.removeValue(forKey: attachmentId) else {
                continue
            }
            action()
        }
    }

    func discardPostLayoutActions(
        attachmentIds: [RefreshAttachmentId]
    ) {
        for attachmentId in attachmentIds {
            postLayoutActionsByAttachmentId.removeValue(forKey: attachmentId)
        }
    }

    func clearPostLayoutActions() {
        postLayoutActionsByAttachmentId.removeAll()
    }

    private func allocateRefreshCycleId() -> RefreshCycleId {
        let cycleId = nextRefreshCycleId
        nextRefreshCycleId &+= 1
        return cycleId
    }
}

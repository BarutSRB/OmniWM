// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension WMController {
    func deferManagedFocusRetry(_ request: ManagedFocusRequest) -> Bool {
        guard intentLedger.defersRetryRaise(for: request) else { return false }
        dispatchRetryRaise(for: request, refronting: true)
        return true
    }

    func dispatchRetryRaise(for request: ManagedFocusRequest, refronting: Bool) {
        guard let entry = workspaceManager.entry(for: request.token),
              entry.workspaceId == request.workspaceId,
              let handle = workspaceManager.handle(for: request.token),
              !isManagedWindowSuppressedByMacOSHide(request.token),
              let job = intentLedger.beginDeferredRetryRaise(for: request)
        else { return }
        let handleIdentity = ObjectIdentifier(handle)
        let expectedWindow = entry.axRef
        let applied = !refronting || applyManagedFocusRequest(
            request, entry: entry, validatesPointer: true, isRetry: true, raisesWindow: false
        )
        let completion: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self,
                  let liveRequest = intentLedger.completeDeferredRetryRaise(job: job),
                  let currentEntry = workspaceManager.entry(for: liveRequest.token),
                  currentEntry.workspaceId == liveRequest.workspaceId,
                  sameAXWindowIdentity(currentEntry.axRef, expectedWindow),
                  workspaceManager.handle(for: liveRequest.token).map(ObjectIdentifier.init) == handleIdentity,
                  !isManagedWindowSuppressedByMacOSHide(liveRequest.token),
                  workspaceManager.pendingManagedFocusMatches(
                      token: liveRequest.token,
                      workspaceId: liveRequest.workspaceId,
                      requestId: liveRequest.requestId
                  )
            else { return }
            axEventHandler.handleAppActivation(
                pid: liveRequest.token.pid,
                source: liveRequest.lastActivationSource ?? .focusedWindowChanged,
                origin: .retry
            )
        }
        if !applied || job.isCancelled
            || !windowFocusOperations.enqueueRetryRaise(entry.pid, expectedWindow, job, completion)
        {
            completion()
        }
    }

    func retryManagedFocusFronting(_ request: ManagedFocusRequest) {
        guard let liveRequest = intentLedger.activeManagedRequest(requestId: request.requestId),
              liveRequest.token == request.token,
              let entry = workspaceManager.entry(for: liveRequest.token),
              entry.workspaceId == request.workspaceId,
              !isManagedWindowSuppressedByMacOSHide(liveRequest.token)
        else {
            return
        }
        _ = applyManagedFocusRequest(
            liveRequest,
            entry: entry,
            validatesPointer: true,
            isRetry: true
        )
    }
}

// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

extension AXEventHandler {
    func protectDeferredReplacement(
        windowId: UInt32,
        token: WindowToken,
        scope: RescanScope
    ) {
        let protectedScope = scope.merged(with: .targeted(
            appPIDs: [token.pid],
            nativeSpaceIds: []
        ))
        if var protection = deferredReplacementProtectionsByWindowId[windowId] {
            protection.protectedTokens.insert(token)
            protection.fallbackProtectedTokens.removeAll()
            protection.permitsPIDFallback = false
            protection.scope = protection.scope.merged(with: protectedScope)
            deferredReplacementProtectionsByWindowId[windowId] = protection
        } else {
            deferredReplacementProtectionsByWindowId[windowId] = DeferredReplacementProtection(
                protectedTokens: [token],
                scope: protectedScope,
                permitsPIDFallback: false
            )
        }
    }

    func recordDeferredReplacementAssessment(
        windowId: UInt32,
        scope: RescanScope
    ) {
        if var protection = deferredReplacementProtectionsByWindowId[windowId] {
            protection.fallbackProtectedTokens.removeAll()
            protection.permitsPIDFallback = false
            protection.scope = protection.scope.merged(with: scope)
            deferredReplacementProtectionsByWindowId[windowId] = protection
        } else {
            deferredReplacementProtectionsByWindowId[windowId] = DeferredReplacementProtection(
                protectedTokens: [],
                scope: scope,
                permitsPIDFallback: false
            )
        }
    }

    func protectMissingEntriesDuringUnsettledAdmission(
        candidates: Set<WindowToken>,
        scope: RescanScope
    ) -> Set<WindowToken> {
        guard !candidates.isEmpty else { return [] }
        let retryWindowIds = Set(
            admissionRetryStateByWindowId.compactMap { windowId, state in
                state.exhausted || !state.trigger.protectsMissingEntriesDuringAdmission
                    ? nil
                    : windowId
            }
        )
        let unsettledWindowIds = deferredCreatedWindowIds.union(retryWindowIds)
        var protectedTokens: Set<WindowToken> = []
        for windowId in unsettledWindowIds {
            let retryState = admissionRetryStateByWindowId[windowId]
            let existingProtection = deferredReplacementProtectionsByWindowId[windowId]
            let exactTokens = candidates.intersection(existingProtection?.protectedTokens ?? [])
            protectedTokens.formUnion(exactTokens)
            guard existingProtection?.permitsPIDFallback != false else { continue }
            let retainedFallbackTokens = candidates.intersection(
                existingProtection?.fallbackProtectedTokens ?? []
            )
            protectedTokens.formUnion(retainedFallbackTokens)
            let pids = fallbackProtectionPIDs(
                windowId: windowId,
                retryState: retryState,
                retainedFallbackTokens: retainedFallbackTokens
            )
            let matchingTokens = Set(candidates.filter { pids.contains($0.pid) })
            if !matchingTokens.isEmpty {
                let protectedScope = scope.merged(with: .targeted(
                    appPIDs: Set(matchingTokens.map(\.pid)),
                    nativeSpaceIds: []
                ))
                if var protection = deferredReplacementProtectionsByWindowId[windowId] {
                    protection.fallbackProtectedTokens.formUnion(matchingTokens)
                    protection.scope = protection.scope.merged(with: protectedScope)
                    deferredReplacementProtectionsByWindowId[windowId] = protection
                } else {
                    deferredReplacementProtectionsByWindowId[windowId] =
                        DeferredReplacementProtection(
                            protectedTokens: [],
                            scope: protectedScope,
                            fallbackProtectedTokens: matchingTokens
                        )
                }
            }
            protectedTokens.formUnion(matchingTokens)
        }
        return protectedTokens
    }

    func rejectDeferredReplacement(windowId: UInt32) {
        guard let protection = deferredReplacementProtectionsByWindowId.removeValue(forKey: windowId)
        else {
            return
        }
        guard !protection.protectedTokens.isEmpty
            || !protection.fallbackProtectedTokens.isEmpty
        else {
            return
        }
        controller?.layoutRefreshController.scheduleMissingConfirmation(scope: protection.scope)
    }

    func discardDeferredReplacementProtection(windowId: UInt32) {
        deferredReplacementProtectionsByWindowId.removeValue(forKey: windowId)
    }

    func finishDeferredReplacementAfterTracking(windowId: UInt32) {
        guard let protection = deferredReplacementProtectionsByWindowId.removeValue(forKey: windowId),
              let controller
        else {
            return
        }
        if protection.protectedTokens.union(protection.fallbackProtectedTokens).contains(where: {
            controller.workspaceManager.entry(for: $0) != nil
        }) {
            controller.layoutRefreshController.scheduleMissingConfirmation(scope: protection.scope)
        }
    }

    func finishDeferredReplacementAfterTracking(windowId: Int) {
        guard let windowId = UInt32(exactly: windowId) else { return }
        finishDeferredReplacementAfterTracking(windowId: windowId)
    }

    func pruneDeferredReplacementProtections(forTerminatedPID pid: pid_t) {
        for windowId in Array(deferredReplacementProtectionsByWindowId.keys) {
            guard var protection = deferredReplacementProtectionsByWindowId[windowId] else {
                continue
            }
            let containedTerminatedPID = protection.protectedTokens.contains { $0.pid == pid }
                || protection.fallbackProtectedTokens.contains { $0.pid == pid }
            guard containedTerminatedPID else { continue }
            protection.protectedTokens = protection.protectedTokens.filter { $0.pid != pid }
            protection.fallbackProtectedTokens = protection.fallbackProtectedTokens.filter {
                $0.pid != pid
            }
            if protection.protectedTokens.isEmpty,
               protection.fallbackProtectedTokens.isEmpty
            {
                deferredReplacementProtectionsByWindowId.removeValue(forKey: windowId)
            } else {
                deferredReplacementProtectionsByWindowId[windowId] = protection
            }
        }
    }

    private func fallbackProtectionPIDs(
        windowId: UInt32,
        retryState: AdmissionRetryState?,
        retainedFallbackTokens: Set<WindowToken>
    ) -> Set<pid_t> {
        var pids = Set(retainedFallbackTokens.map(\.pid))
        pids.formUnion(retryState?.trigger.protectionPIDs ?? [])
        if let expectedPID = retryState?.expectedToken?.pid {
            pids.insert(expectedPID)
        }
        if let axPID = retryState?.axRef.flatMap(AXWindowService.processIdentifier),
           axPID > 0
        {
            pids.insert(axPID)
        }
        pids.formUnion(identityAliasesByWindowId[Int(windowId)]?.pids ?? [])
        if pids.isEmpty, let windowInfo = resolveWindowInfo(windowId) {
            pids.insert(pid_t(windowInfo.pid))
        }
        return pids
    }
}

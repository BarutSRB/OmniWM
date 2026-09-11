// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation

struct AppAXFrameBatchWriter {
    private let generations: LockedWindowGenerationMap
    private let suppression: LockedWindowIdSet?
    private let hardSuppression: LockedWindowIdSet?
    private let trace: AppAXFrameWriteTrace

    init(
        generations: LockedWindowGenerationMap,
        suppression: LockedWindowIdSet?,
        hardSuppression: LockedWindowIdSet?,
        trace: AppAXFrameWriteTrace
    ) {
        self.generations = generations
        self.suppression = suppression
        self.hardSuppression = hardSuppression
        self.trace = trace
    }

    func execute(
        _ requests: [AppAXFrameWriteRequest],
        axApp: AXUIElement,
        traceItems: [AppAXFrameMailbox.Item]? = nil,
        isCancelled: () -> Bool
    ) -> [AXFrameApplyResult] {
        let hasEligibleRequest = hasEligibleRequest(in: requests, isCancelled: isCancelled)
        let latencyActive = trace.lane.supportsFrameEffectTracing && AXWriteLatencyTrace.shared.isActive
        guard hasEligibleRequest else {
            return skippedResults(
                for: requests,
                trace: latencyActive ? trace : nil,
                traceItems: traceItems,
                isCancelled: isCancelled
            )
        }
        let batchStartNs = latencyActive ? DispatchTime.now().uptimeNanoseconds : 0
        let enhancedUI = AppAXEnhancedUIWriteScope(axApp: axApp, pid: trace.context.pid, tracing: latencyActive)
        var activeTrace = latencyActive ? trace : nil
        activeTrace?.enhancedUI = enhancedUI.wasEnabled
        let results = applyRequests(
            requests,
            trace: activeTrace,
            traceItems: traceItems,
            isCancelled: isCancelled
        )
        let timing = enhancedUI.restore()
        activeTrace?.recordBatch(count: requests.count, startedNs: batchStartNs, timing: timing)
        return results
    }

    private func hasEligibleRequest(
        in requests: [AppAXFrameWriteRequest],
        isCancelled: () -> Bool
    ) -> Bool {
        var hasEligibleRequest = false
        var staleBeforeIPC = 0
        for request in requests {
            let reason = skipReason(for: request, isCancelled: isCancelled)
            hasEligibleRequest = hasEligibleRequest || reason == nil
            if reason == .cancelled,
               !generations.isCurrent(request.generation, for: request.windowId)
            {
                staleBeforeIPC += 1
            }
        }
        if AppAXContextRuntimeMetrics.shared.isActive {
            AppAXContextRuntimeMetrics.shared.noteStaleBeforeIPC(staleBeforeIPC)
        }
        return hasEligibleRequest
    }

    private func skippedResults(
        for requests: [AppAXFrameWriteRequest],
        trace: AppAXFrameWriteTrace?,
        traceItems: [AppAXFrameMailbox.Item]?,
        isCancelled: () -> Bool
    ) -> [AXFrameApplyResult] {
        requests.enumerated().map { index, request in
            let result = skippedFrameApplyResult(
                for: request,
                reason: skipReason(for: request, isCancelled: isCancelled) ?? .cancelled
            )
            if let trace {
                let item = traceItems.flatMap { items in
                    items.indices.contains(index) ? items[index] : nil
                }
                trace.recordSkipped(request, item: item, result: result)
            }
            return result
        }
    }

    private func applyRequests(
        _ requests: [AppAXFrameWriteRequest],
        trace activeTrace: AppAXFrameWriteTrace?,
        traceItems: [AppAXFrameMailbox.Item]?,
        isCancelled: () -> Bool
    ) -> [AXFrameApplyResult] {
        var results: [AXFrameApplyResult] = []
        results.reserveCapacity(requests.count)
        for (index, request) in requests.enumerated() {
            if let reason = skipReason(for: request, isCancelled: isCancelled) {
                let result = skippedFrameApplyResult(for: request, reason: reason)
                results.append(result)
                if let activeTrace {
                    let item = traceItems.flatMap { items in
                        items.indices.contains(index) ? items[index] : nil
                    }
                    activeTrace.recordSkipped(request, item: item, result: result)
                }
                continue
            }
            if let activeTrace {
                let item = traceItems.flatMap { items in
                    items.indices.contains(index) ? items[index] : nil
                }
                results.append(applyFrameWriteRequest(
                    request,
                    pid: trace.context.pid,
                    callbackGeneration: trace.context.callbackGeneration,
                    generations: generations,
                    traceLane: trace.lane
                ) { attempt in
                    activeTrace.recordAttempt(request, item: item, attempt: attempt)
                })
            } else {
                results.append(applyFrameWriteRequest(
                    request,
                    pid: trace.context.pid,
                    callbackGeneration: trace.context.callbackGeneration,
                    generations: generations,
                    traceLane: trace.lane
                ))
            }
        }
        return results
    }

    private func skipReason(
        for request: AppAXFrameWriteRequest,
        isCancelled: () -> Bool
    ) -> AXFrameWriteFailureReason? {
        if isCancelled() || !generations.isCurrent(request.generation, for: request.windowId) {
            return .cancelled
        }
        if hardSuppression?.isHardSuppressed() == true
            || suppression?.contains(request.windowId) == true
        {
            return .suppressed
        }
        return nil
    }
}

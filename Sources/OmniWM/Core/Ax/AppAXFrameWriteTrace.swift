// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct AppAXFrameWriteAttempt {
    let number: UInt8
    let startedNs: UInt64
    let timing: AXFrameSetterTiming
    let result: AXFrameWriteResult
}

struct AppAXFrameWriteTrace {
    let context: AXWriteMetrics.ContextToken
    let bundleId: String?
    let lane: AppAXFrameLane
    let drainId: UInt64
    var enhancedUI = false

    func recordSkipped(
        _ request: AppAXFrameWriteRequest,
        item: AppAXFrameMailbox.Item?,
        result: AXFrameApplyResult
    ) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        AXWriteLatencyTrace.shared.record(
            AXWriteLatencyTrace.Record(
                kind: .attempt,
                uptimeNs: nowNs,
                requestTraceId: FrameEffectTraceContext.currentCaptureIdentifier(request.traceRequestId),
                requestId: request.requestId,
                pid: context.pid,
                bundleId: bundleId,
                callbackGeneration: context.callbackGeneration,
                lane: lane,
                submissionId: item?.submissionId ?? 0,
                drainId: drainId,
                windowId: request.windowId,
                attempt: 0,
                count: 1,
                queueNs: Self.queueDelay(startedNs: nowNs, enqueuedAt: item?.enqueuedAt),
                sizeNs: 0,
                positionNs: 0,
                verificationNs: 0,
                enhancedUIProbeNs: 0,
                enhancedUIDisableNs: 0,
                enhancedUIRestoreNs: 0,
                totalNs: 0,
                enhancedUI: enhancedUI,
                failureReason: result.writeResult.failureReason
            )
        )
    }

    func recordAttempt(
        _ request: AppAXFrameWriteRequest,
        item: AppAXFrameMailbox.Item?,
        attempt: AppAXFrameWriteAttempt
    ) {
        let endNs = DispatchTime.now().uptimeNanoseconds
        AXWriteLatencyTrace.shared.record(
            AXWriteLatencyTrace.Record(
                kind: .attempt,
                uptimeNs: endNs,
                requestTraceId: FrameEffectTraceContext.currentCaptureIdentifier(request.traceRequestId),
                requestId: request.requestId,
                pid: context.pid,
                bundleId: bundleId,
                callbackGeneration: context.callbackGeneration,
                lane: lane,
                submissionId: item?.submissionId ?? 0,
                drainId: drainId,
                windowId: request.windowId,
                attempt: attempt.number,
                count: 1,
                queueNs: Self.mailboxQueueDelay(
                    attempt: attempt.number,
                    startedNs: attempt.startedNs,
                    enqueuedAt: item?.enqueuedAt
                ),
                sizeNs: attempt.timing.sizeNs,
                positionNs: attempt.timing.positionNs,
                verificationNs: attempt.timing.verificationNs,
                enhancedUIProbeNs: 0,
                enhancedUIDisableNs: 0,
                enhancedUIRestoreNs: 0,
                totalNs: Self.elapsedNanoseconds(from: attempt.startedNs, to: endNs),
                enhancedUI: enhancedUI,
                failureReason: attempt.result.failureReason
            )
        )
    }

    func recordBatch(count: Int, startedNs: UInt64, timing: AppAXEnhancedUITiming) {
        let endNs = DispatchTime.now().uptimeNanoseconds
        AXWriteLatencyTrace.shared.record(
            AXWriteLatencyTrace.Record(
                kind: .batch,
                uptimeNs: endNs,
                requestTraceId: 0,
                requestId: 0,
                pid: context.pid,
                bundleId: bundleId,
                callbackGeneration: context.callbackGeneration,
                lane: lane,
                submissionId: 0,
                drainId: drainId,
                windowId: 0,
                attempt: 0,
                count: count,
                queueNs: 0,
                sizeNs: 0,
                positionNs: 0,
                verificationNs: 0,
                enhancedUIProbeNs: timing.probeNs,
                enhancedUIDisableNs: timing.disableNs,
                enhancedUIRestoreNs: timing.restoreNs,
                totalNs: Self.elapsedNanoseconds(from: startedNs, to: endNs),
                enhancedUI: enhancedUI,
                failureReason: nil
            )
        )
    }

    private static func queueDelay(startedNs: UInt64, enqueuedAt: UInt64?) -> UInt64 {
        guard let enqueuedAt, startedNs >= enqueuedAt else { return 0 }
        return startedNs - enqueuedAt
    }

    static func mailboxQueueDelay(attempt: UInt8, startedNs: UInt64, enqueuedAt: UInt64?) -> UInt64 {
        attempt == 1 ? queueDelay(startedNs: startedNs, enqueuedAt: enqueuedAt) : 0
    }

    static func elapsedNanoseconds(from start: UInt64, to end: UInt64) -> UInt64 {
        end >= start ? end - start : 0
    }
}

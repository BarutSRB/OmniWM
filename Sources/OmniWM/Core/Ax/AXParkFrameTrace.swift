// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension AXFrameApplicationTarget {
    func recordParkVerifiedNoop(traceRequestId: UInt64, traceOrigin: FrameEffectTraceOrigin) {
        if traceRequestId != 0 {
            FrameApplyTrace.recordEvent(
                pid: pid,
                windowId: windowId,
                outcome: "park-ledger-noop/verified/terminal",
                target: frame,
                traceRequestId: traceRequestId,
                effectOrigin: traceOrigin,
                lane: .park
            )
        }
    }

    func recordParkCoalescing(traceRequestId: UInt64, traceOrigin: FrameEffectTraceOrigin, relatedTraceId: UInt64) {
        if traceRequestId != 0 {
            FrameApplyTrace.recordEvent(
                pid: pid,
                windowId: windowId,
                outcome: "park-ledger-coalesced/pending",
                target: frame,
                traceRequestId: traceRequestId,
                effectOrigin: traceOrigin,
                relatedTraceId: relatedTraceId,
                lane: .park
            )
        }
    }

    func recordParkPreparation(request: AXFrameApplicationRequest, traceOrigin: FrameEffectTraceOrigin) {
        if request.traceRequestId != 0 {
            FrameApplyTrace.recordEvent(
                pid: pid,
                windowId: windowId,
                outcome: "park-ledger-prepared",
                target: frame,
                requestId: request.requestId,
                traceRequestId: request.traceRequestId,
                effectOrigin: traceOrigin,
                lane: .park
            )
        }
    }
}

extension AXFrameApplicationRequest {
    func recordParkSuperseded(relatedTraceId: UInt64) {
        FrameApplyTrace.recordEvent(
            pid: pid,
            windowId: windowId,
            outcome: "outcome=ax-park-cancelled/superseded",
            target: frame,
            requestId: requestId,
            traceRequestId: traceRequestId,
            relatedTraceId: relatedTraceId,
            lane: .park
        )
    }

    func recordParkRetry(parentTraceId: UInt64) {
        if traceRequestId != 0 {
            FrameApplyTrace.recordEvent(
                pid: pid,
                windowId: windowId,
                outcome: "park-ledger-prepared/retry",
                target: frame,
                requestId: requestId,
                traceRequestId: traceRequestId,
                parentTraceId: parentTraceId,
                lane: .park
            )
        }
    }
}

extension AXFrameApplyResult {
    func recordParkConfirmation() {
        FrameApplyTrace.recordEvent(
            pid: pid,
            windowId: windowId,
            outcome: "outcome=ax-park-confirmed",
            target: targetFrame,
            hint: currentFrameHint,
            observed: writeResult.observedFrame,
            confirmed: writeResult.observedFrame,
            requestId: requestId,
            traceRequestId: traceRequestId,
            lane: .park
        )
    }

    func recordParkCancellation() {
        FrameApplyTrace.recordEvent(
            pid: pid,
            windowId: windowId,
            outcome: "outcome=ax-park-cancelled/cancelled",
            target: targetFrame,
            requestId: requestId,
            traceRequestId: traceRequestId,
            lane: .park
        )
    }

    func recordParkFailure(_ failureReason: AXFrameWriteFailureReason) {
        FrameApplyTrace.recordEvent(
            pid: pid,
            windowId: windowId,
            outcome: "outcome=ax-park-failed/\(failureReason.traceDescription)",
            target: targetFrame,
            hint: currentFrameHint,
            observed: writeResult.observedFrame,
            requestId: requestId,
            traceRequestId: traceRequestId,
            lane: .park
        )
    }
}

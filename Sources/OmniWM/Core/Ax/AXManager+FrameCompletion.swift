// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension AXManager {
    func handleFrameApplyResults(_ results: [AXFrameApplyResult]) {
        for result in results {
            FrameApplyTrace.recordResult(result)
        }
        let outcome = frameLedger.handleFrameApplyResults(results) { [weak self] result in
            self?.handleAcceptedFrameApplySuccess(result)
        }
        for retry in outcome.retries {
            FrameApplyTrace.recordEvent(
                pid: retry.pid,
                windowId: retry.windowId,
                outcome: "outcome=retry-scheduled",
                target: retry.frame,
                requestId: retry.requestId,
                traceRequestId: retry.traceRequestId
            )
            scheduleFrameRetry(retry)
        }
        for delivery in outcome.deliveries {
            delivery.deliver()
        }
        for refusal in outcome.terminalRefusals {
            FrameApplyTrace.recordEvent(
                pid: refusal.pid,
                windowId: refusal.windowId,
                outcome: "outcome=terminal-refusal/\(refusal.failureReason.traceDescription)",
                target: refusal.targetFrame,
                observed: refusal.observedFrame,
                requestId: refusal.requestId,
                traceRequestId: refusal.traceRequestId
            )
            onTerminalFrameRefusal?(refusal)
        }
        for terminalFailure in outcome.terminalFailures {
            handleTerminalFrameApplyFailure(terminalFailure)
        }
        for result in outcome.stableSizeClamps {
            onStableSizeClamp?(result)
        }
    }

    func handleAcceptedFrameApplySuccess(_ result: AXFrameApplyResult) {
        clearSkyLightLivePosition(for: result.windowId)
        if isWindowParked?(result.windowId) == true {
            parkLedger.markParkPending(
                for: result.windowId,
                pid: result.pid,
                target: nil,
                cancellationReason: "ordinary-write"
            )
        }
        onFrameApplySucceeded?(result)
    }

    func handleTerminalFrameApplyFailure(_ result: AXFrameApplyResult) {
        let reason = result.writeResult.failureReason?.traceDescription ?? "unconfirmed"
        FrameApplyTrace.recordEvent(
            pid: result.pid,
            windowId: result.windowId,
            outcome: "outcome=terminal-failure/\(reason)",
            target: result.targetFrame,
            requestId: result.requestId,
            traceRequestId: result.traceRequestId
        )
        onFrameApplyTerminated?(result)
    }
}

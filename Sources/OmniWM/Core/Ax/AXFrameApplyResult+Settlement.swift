// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

extension AXFrameApplyResult {
    static func successfulNoOpFrameApplyResult(
        requestId: AXFrameRequestId,
        target: AXFrameApplicationTarget,
        observedFrame: CGRect,
        components: AXFrameComponents,
        traceRequestId: UInt64
    ) -> AXFrameApplyResult {
        AXFrameApplyResult(
            requestId: requestId,
            pid: target.pid,
            windowId: target.windowId,
            expectedWindow: target.expectedWindow,
            targetFrame: target.frame,
            currentFrameHint: observedFrame,
            writeResult: AXFrameWriteResult(
                observedFrame: observedFrame,
                writeOrder: AXWindowService.frameWriteOrder(
                    currentFrame: observedFrame,
                    targetFrame: target.frame
                ),
                sizeError: .success,
                positionError: .success,
                failureReason: nil,
                components: components
            ),
            traceRequestId: traceRequestId
        )
    }

    static func refusedFrameApplyResult(
        requestId: AXFrameRequestId,
        target: AXFrameApplicationTarget,
        currentFrameHint: CGRect?,
        refusal: AXRecentFrameWriteFailure,
        traceRequestId: UInt64
    ) -> AXFrameApplyResult {
        AXFrameApplyResult(
            requestId: requestId,
            pid: target.pid,
            windowId: target.windowId,
            expectedWindow: target.expectedWindow,
            targetFrame: target.frame,
            currentFrameHint: currentFrameHint,
            writeResult: .skipped(
                targetFrame: target.frame,
                currentFrameHint: currentFrameHint,
                failureReason: refusal.reason,
                observedFrame: refusal.observedFrame,
                components: refusal.components
            ),
            traceRequestId: traceRequestId
        )
    }

    static func acceptedSizeConvergenceResult(
        _ result: AXFrameApplyResult,
        observedFrame: CGRect
    ) -> AXFrameApplyResult {
        AXFrameApplyResult(
            requestId: result.requestId,
            pid: result.pid,
            windowId: result.windowId,
            expectedWindow: result.expectedWindow,
            targetFrame: result.targetFrame,
            currentFrameHint: result.currentFrameHint,
            writeResult: AXFrameWriteResult(
                observedFrame: observedFrame,
                writeOrder: result.writeResult.writeOrder,
                sizeError: result.writeResult.sizeError,
                positionError: result.writeResult.positionError,
                failureReason: nil,
                components: result.writeResult.components
            ),
            traceRequestId: result.traceRequestId
        )
    }

    func shouldRetryFrameWrite(
        resultResolvedThroughRekey: Bool
    ) -> Bool {
        guard let failureReason = writeResult.failureReason else { return false }
        switch failureReason {
        case .cancelled:
            return resultResolvedThroughRekey
        case .suppressed:
            return false
        default:
            return true
        }
    }
}

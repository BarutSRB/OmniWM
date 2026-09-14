// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct AXFrameFailureAssessment {
    var stableSizeClamp = false
    var convergedFrame: CGRect?
    var terminalRefusal: AXFrameTerminalRefusal?

    init(result: AXFrameApplyResult, priorFailure: AXRecentFrameWriteFailure?) {
        if let failureReason = result.writeResult.failureReason,
           priorFailure?.reason == failureReason,
           let observedFrame = result.writeResult.observedFrame
        {
            let stableSizeClamp = priorFailure?.isStableSizeClamp(
                result: result,
                observedFrame: observedFrame
            ) == true
            if stableSizeClamp,
               observedFrame.width >= result.targetFrame.width - FrameTolerance.frameWrite,
               observedFrame.height >= result.targetFrame.height - FrameTolerance.frameWrite,
               observedFrame.width > result.targetFrame.width + FrameTolerance.frameWrite
               || observedFrame.height > result.targetFrame.height + FrameTolerance.frameWrite
            {
                self.stableSizeClamp = true
            }
            if stableSizeClamp,
               priorFailure?.isWithinSizeConvergence(
                   target: result.targetFrame,
                   observedFrame: observedFrame
               ) == true
            {
                convergedFrame = observedFrame
                return
            }
            terminalRefusal = AXFrameTerminalRefusal(
                pid: result.pid,
                windowId: result.windowId,
                targetFrame: result.targetFrame,
                observedFrame: observedFrame,
                failureReason: failureReason,
                requestId: result.requestId,
                traceRequestId: result.traceRequestId
            )
        }
    }
}

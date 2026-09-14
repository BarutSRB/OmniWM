// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct AXPendingFrameWrite {
    var frame: CGRect
    var components: AXFrameComponents
    var verify: Bool
    var expectedWindow: AXWindowRef
    var requestId: AXFrameRequestId
    var traceRequestId: UInt64

    func matches(
        target: AXFrameApplicationTarget,
        components: AXFrameComponents,
        verify: Bool
    ) -> Bool {
        sameAXWindowIdentity(expectedWindow, target.expectedWindow)
            && self.components == components
            && self.verify == verify
            && frame.approximatelyEqual(to: target.frame, tolerance: FrameTolerance.frameWrite)
    }

    func cancelledResult(pid: pid_t, windowId: Int, currentFrameHint: CGRect?) -> AXFrameApplyResult {
        AXFrameApplyResult(
            requestId: requestId, pid: pid, windowId: windowId, expectedWindow: expectedWindow,
            targetFrame: frame, currentFrameHint: currentFrameHint,
            writeResult: .skipped(
                targetFrame: frame,
                currentFrameHint: currentFrameHint,
                failureReason: .cancelled,
                observedFrame: currentFrameHint,
                components: components
            ),
            traceRequestId: traceRequestId
        )
    }

    func appendStateDescription(to parts: inout [String]) {
        parts.append("pending=\(TraceFormat.rect(frame))")
    }

    func matchesResult(_ result: AXFrameApplyResult) -> Bool {
        requestId == result.requestId
            && sameAXWindowIdentity(expectedWindow, result.expectedWindow)
            && components == result.writeResult.components
            && frame.approximatelyEqual(to: result.targetFrame, tolerance: FrameTolerance.frameWrite)
    }
}

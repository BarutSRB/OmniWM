// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct AXPendingParkFrameRequest {
    let request: AXFrameApplicationRequest
    let retriesRemaining: Int

    @MainActor
    func retry(requestId: AXFrameRequestId) -> AXFrameApplicationRequest {
        return AXFrameApplicationRequest(
            requestId: requestId,
            pid: request.pid,
            windowId: request.windowId,
            expectedWindow: request.expectedWindow,
            frame: request.frame,
            currentFrameHint: request.currentFrameHint,
            components: request.components,
            verify: true,
            traceRequestId: FrameEffectTraceContext.isCurrentCapture(
                identifier: request.traceRequestId
            ) ? FrameEffectTraceContext.makeRequestTraceId(
                parentTraceId: request.traceRequestId
            ) : 0
        )
    }
}

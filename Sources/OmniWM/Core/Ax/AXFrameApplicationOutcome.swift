// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

typealias AXFrameApplicationTerminalObserver = @MainActor (AXFrameApplyResult) -> Void

struct AXFrameTerminalDelivery {
    let result: AXFrameApplyResult
    let observers: [AXFrameApplicationTerminalObserver]

    @MainActor
    func deliver() {
        for observer in observers {
            observer(result)
        }
    }
}

struct AXFrameRetryRequest: Equatable, Sendable {
    let requestId: AXFrameRequestId
    let pid: pid_t
    let windowId: Int
    let expectedWindow: AXWindowRef
    let frame: CGRect
    let currentFrameHint: CGRect?
    let components: AXFrameComponents
    let traceRequestId: UInt64

    init(
        requestId: AXFrameRequestId,
        pid: pid_t,
        windowId: Int,
        expectedWindow: AXWindowRef,
        frame: CGRect,
        currentFrameHint: CGRect?,
        components: AXFrameComponents = .all,
        traceRequestId: UInt64 = 0
    ) {
        self.requestId = requestId
        self.pid = pid
        self.windowId = windowId
        self.expectedWindow = expectedWindow
        self.frame = frame
        self.currentFrameHint = currentFrameHint
        self.components = components
        self.traceRequestId = traceRequestId
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.requestId == rhs.requestId
            && lhs.pid == rhs.pid
            && lhs.windowId == rhs.windowId
            && sameAXWindowIdentity(lhs.expectedWindow, rhs.expectedWindow)
            && lhs.frame == rhs.frame
            && lhs.currentFrameHint == rhs.currentFrameHint
            && lhs.components == rhs.components
    }
}

struct AXFrameTerminalRefusal: Equatable {
    let pid: pid_t
    let windowId: Int
    let targetFrame: CGRect
    let observedFrame: CGRect
    let failureReason: AXFrameWriteFailureReason
    let requestId: AXFrameRequestId
    let traceRequestId: UInt64

    init(
        pid: pid_t,
        windowId: Int,
        targetFrame: CGRect,
        observedFrame: CGRect,
        failureReason: AXFrameWriteFailureReason,
        requestId: AXFrameRequestId = 0,
        traceRequestId: UInt64 = 0
    ) {
        self.pid = pid
        self.windowId = windowId
        self.targetFrame = targetFrame
        self.observedFrame = observedFrame
        self.failureReason = failureReason
        self.requestId = requestId
        self.traceRequestId = traceRequestId
    }
}

struct AXFrameEnqueueDecision {
    var request: AXFrameApplicationRequest?
    var deliveries: [AXFrameTerminalDelivery] = []
    var shouldCancelPendingRetry = false
}

struct AXFrameApplyOutcome {
    var deliveries: [AXFrameTerminalDelivery] = []
    var retries: [AXFrameRetryRequest] = []
    var terminalRefusals: [AXFrameTerminalRefusal] = []
    var terminalFailures: [AXFrameApplyResult] = []
    var stableSizeClamps: [AXFrameApplyResult] = []
}

struct AXFrameJobCancellationOutcome {
    var deliveries: [AXFrameTerminalDelivery] = []
    var terminalFailure: AXFrameApplyResult?
}

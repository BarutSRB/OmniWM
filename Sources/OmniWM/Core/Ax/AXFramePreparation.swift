// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

@MainActor
struct AXFramePreparation {
    struct Options {
        let isRetry: Bool
        let verify: Bool
        let terminalObserver: AXFrameApplicationTerminalObserver?
        let traceOrigin: FrameEffectTraceOrigin
        let parentTraceRequestId: UInt64
    }

    let target: AXFrameApplicationTarget
    let options: Options
    let cachedState: AXAppliedFrameState?
    let pendingWrite: AXPendingFrameWrite?
    let components: AXFrameComponents
    let verify: Bool
    let traceRequestId: UInt64

    init(
        target: AXFrameApplicationTarget,
        options: Options,
        cachedState: AXAppliedFrameState?,
        pendingWrite: AXPendingFrameWrite?
    ) {
        self.target = target
        self.options = options
        self.cachedState = cachedState
        self.pendingWrite = pendingWrite
        traceRequestId = options.traceOrigin.effectId != 0 || options.parentTraceRequestId != 0
            ? FrameEffectTraceContext.makeRequestTraceId(parentTraceId: options.parentTraceRequestId)
            : 0
        var components = target.components
        if let pendingWrite, sameAXWindowIdentity(pendingWrite.expectedWindow, target.expectedWindow) {
            components.formUnion(pendingWrite.components)
        }
        self.components = components
        verify = options.verify
            ||
            (pendingWrite
                .map { sameAXWindowIdentity($0.expectedWindow, target.expectedWindow) && $0.verify } == true)
    }

    var matchesPendingWrite: Bool {
        pendingWrite?.matches(target: target, components: components, verify: verify) == true
    }

    var matchesVerifiedFrame: Bool {
        guard let cachedState else { return false }
        return cachedState.matches(target: target.frame, components: components)
            && (!verify || cachedState.verifiedComponents.contains(components))
    }

    func matchesTerminalRefusal(_ failure: AXRecentFrameWriteFailure) -> Bool {
        failure.matchesTerminalRefusal(
            expectedWindow: target.expectedWindow,
            frame: target.frame,
            components: components
        )
    }

    func coalescedDecision(observers: AXFrameObserverRegistry) -> AXFrameEnqueueDecision? {
        if let terminalObserver = options.terminalObserver, !options.isRetry,
           !observers.append(
               terminalObserver,
               for: target.windowId,
               expectedWindow: target.expectedWindow,
               targetFrame: target.frame,
               components: components
           )
        {
            return nil
        }
        if traceRequestId != 0 {
            record(
                requestId: 0,
                outcome: "ledger-coalesced/pending",
                relatedTraceRequestId: pendingWrite?.traceRequestId ?? 0
            )
        }
        return AXFrameEnqueueDecision()
    }

    func refusedDecision(_ failure: AXRecentFrameWriteFailure, requestId: AXFrameRequestId) -> AXFrameEnqueueDecision {
        record(requestId: requestId, outcome: "ledger-refused/\(failure.reason.traceDescription)")
        guard let terminalObserver = options.terminalObserver else { return AXFrameEnqueueDecision() }
        return AXFrameEnqueueDecision(deliveries: [AXFrameTerminalDelivery(
            result: AXFrameApplyResult.refusedFrameApplyResult(
                requestId: requestId, target: target, currentFrameHint: cachedState?.frame,
                refusal: failure, traceRequestId: traceRequestId
            ),
            observers: [terminalObserver]
        )])
    }

    func noOpDecision(requestId: AXFrameRequestId) -> AXFrameEnqueueDecision {
        if traceRequestId != 0 {
            record(requestId: requestId, outcome: "ledger-noop/applied/terminal")
        }
        guard let terminalObserver = options.terminalObserver, let cachedState else { return AXFrameEnqueueDecision() }
        return AXFrameEnqueueDecision(deliveries: [AXFrameTerminalDelivery(
            result: AXFrameApplyResult.successfulNoOpFrameApplyResult(
                requestId: requestId, target: target, observedFrame: cachedState.frame,
                components: components, traceRequestId: traceRequestId
            ),
            observers: [terminalObserver]
        )])
    }

    func request(id: AXFrameRequestId) -> AXFrameApplicationRequest {
        AXFrameApplicationRequest(
            requestId: id,
            pid: target.pid,
            windowId: target.windowId,
            expectedWindow: target.expectedWindow,
            frame: target.frame,
            currentFrameHint: cachedState?.frame,
            components: components,
            verify: verify,
            traceRequestId: traceRequestId
        )
    }

    func recordPrepared(requestId: AXFrameRequestId) {
        if traceRequestId != 0 {
            record(requestId: requestId, outcome: options.isRetry ? "ledger-prepared/retry" : "ledger-prepared")
        }
    }

    private func record(requestId: AXFrameRequestId, outcome: String, relatedTraceRequestId: UInt64 = 0) {
        options.traceOrigin.recordFrameDecision(
            traceRequestId: traceRequestId, parentTraceRequestId: options.parentTraceRequestId,
            requestId: requestId, target: target, outcome: outcome, relatedTraceRequestId: relatedTraceRequestId
        )
    }
}

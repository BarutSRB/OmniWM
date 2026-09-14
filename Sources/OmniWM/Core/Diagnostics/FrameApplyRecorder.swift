// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Dispatch
import Foundation
import os

enum FrameApplyTrace {
    struct Record: Sendable {
        let uptimeNs: UInt64
        let requestTraceId: UInt64
        let effectId: UInt64
        let effectKind: FrameEffectTraceKind
        let displayId: CGDirectDisplayID
        let parentTraceId: UInt64
        let relatedTraceId: UInt64
        let requestId: AXFrameRequestId
        let pid: pid_t
        let callbackGeneration: UInt64
        let lane: AppAXFrameLane
        let submissionId: UInt64
        let drainId: UInt64
        let windowId: Int
        let attempt: UInt8
        let outcome: String
        let target: CGRect?
        let hint: CGRect?
        let observed: CGRect?
        let confirmed: CGRect?
        let eventUptimeNs: UInt64
    }

    static let shared = SessionTraceRecorder<Record>(
        sectionTitle: "Frame Apply Trace",
        capacity: 65_536
    ) { record in
        "scope=ax-ordinary+ax-park closing=excluded skylight-position=excluded"
            + " t_ns=\(record.uptimeNs) trace=\(record.requestTraceId) effect=\(record.effectId)"
            + " origin=\(record.effectKind.traceDescription) display=\(record.displayId)"
            + " parent=\(record.parentTraceId) related=\(record.relatedTraceId)"
            + " request=\(record.requestId) win=\(record.windowId) pid=\(record.pid)"
            + " context=\(record.callbackGeneration) lane=\(record.lane.traceDescription)"
            + " submission=\(record.submissionId) drain=\(record.drainId)"
            + " attempt=\(record.attempt) event=\(record.outcome)"
            + " target=\(TraceFormat.rect(record.target))"
            + " hint=\(TraceFormat.rect(record.hint))"
            + " observed=\(TraceFormat.rect(record.observed))"
            + " confirmed=\(TraceFormat.rect(record.confirmed))"
            + " cgs_t_ns=\(record.eventUptimeNs)"
    }

    static func recordResult(_ result: AXFrameApplyResult, lane: AppAXFrameLane = .ordinary) {
        guard shared.isActive else { return }
        FrameEffectObservationTracker.shared.noteWriteResult(result)
        let outcome: String = if let reason = result.writeResult.failureReason {
            "outcome=skip/\(reason.traceDescription)"
        } else {
            result.confirmedFrame != nil ? "outcome=confirmed" : "outcome=applied"
        }
        recordEvent(
            pid: result.pid,
            windowId: result.windowId,
            outcome: outcome,
            target: result.targetFrame,
            hint: result.currentFrameHint,
            observed: result.writeResult.observedFrame,
            confirmed: result.confirmedFrame,
            requestId: result.requestId,
            traceRequestId: result.traceRequestId,
            lane: lane
        )
    }

    static func recordAcceptedSizeConvergence(_ result: AXFrameApplyResult) {
        guard shared.isActive else { return }
        if let confirmedFrame = result.confirmedFrame {
            FrameEffectObservationTracker.shared.updateAcceptedTarget(
                traceRequestId: result.traceRequestId,
                target: confirmedFrame
            )
        }
        recordEvent(
            pid: result.pid,
            windowId: result.windowId,
            outcome: "outcome=accepted-size-convergence",
            target: result.targetFrame,
            hint: result.currentFrameHint,
            observed: result.writeResult.observedFrame,
            confirmed: result.confirmedFrame,
            requestId: result.requestId,
            traceRequestId: result.traceRequestId
        )
    }

    static func recordEvent(
        pid: pid_t,
        windowId: Int,
        outcome: String,
        target: CGRect? = nil,
        hint: CGRect? = nil,
        observed: CGRect? = nil,
        confirmed: CGRect? = nil,
        requestId: AXFrameRequestId = 0,
        traceRequestId: UInt64 = 0,
        effectOrigin: FrameEffectTraceOrigin = .none,
        parentTraceId: UInt64 = 0,
        relatedTraceId: UInt64 = 0,
        callbackGeneration: UInt64 = 0,
        lane: AppAXFrameLane = .ordinary,
        submissionId: UInt64 = 0,
        drainId: UInt64 = 0,
        attempt: UInt8 = 0,
        eventUptimeNs: UInt64 = 0,
        uptimeNs: UInt64 = 0
    ) {
        guard shared.isActive else { return }
        let currentTraceRequestId = FrameEffectTraceContext.currentCaptureIdentifier(traceRequestId)
        let currentEffectId = FrameEffectTraceContext.currentCaptureIdentifier(effectOrigin.effectId)
        let currentEffectOrigin = currentEffectId == 0
            ? FrameEffectTraceOrigin.none
            : FrameEffectTraceOrigin(
                effectId: currentEffectId,
                displayId: effectOrigin.displayId,
                kind: effectOrigin.kind
            )
        shared.record(
            Record(
                uptimeNs: uptimeNs == 0 ? DispatchTime.now().uptimeNanoseconds : uptimeNs,
                requestTraceId: currentTraceRequestId,
                effectId: currentEffectOrigin.effectId,
                effectKind: currentEffectOrigin.kind,
                displayId: currentEffectOrigin.displayId,
                parentTraceId: FrameEffectTraceContext.currentCaptureIdentifier(parentTraceId),
                relatedTraceId: FrameEffectTraceContext.currentCaptureIdentifier(relatedTraceId),
                requestId: requestId,
                pid: pid,
                callbackGeneration: callbackGeneration,
                lane: lane,
                submissionId: submissionId,
                drainId: drainId,
                windowId: windowId,
                attempt: attempt,
                outcome: outcome,
                target: target,
                hint: hint,
                observed: observed,
                confirmed: confirmed,
                eventUptimeNs: eventUptimeNs
            )
        )
    }
}

extension FrameEffectTraceOrigin {
    func recordFrameDecision(
        traceRequestId: UInt64,
        parentTraceRequestId: UInt64,
        requestId: AXFrameRequestId,
        target: AXFrameApplicationTarget,
        outcome: String,
        relatedTraceRequestId: UInt64 = 0
    ) {
        guard traceRequestId != 0 else { return }
        FrameApplyTrace.recordEvent(
            pid: target.pid,
            windowId: target.windowId,
            outcome: outcome,
            target: target.frame,
            requestId: requestId,
            traceRequestId: traceRequestId,
            effectOrigin: self,
            parentTraceId: parentTraceRequestId,
            relatedTraceId: relatedTraceRequestId
        )
    }
}

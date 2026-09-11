// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct AXRecentFrameWriteFailure {
    let pid: pid_t
    var expectedWindow: AXWindowRef
    let reason: AXFrameWriteFailureReason
    let targetFrame: CGRect
    let observedFrame: CGRect?
    let settersSucceeded: Bool
    let components: AXFrameComponents
    var isTerminalRefusal = false
    private static let maxAcceptedSizeSnap: CGFloat = 16

    private static func isAXTopLeftAnchoredSizeClamp(target: CGRect, observed: CGRect) -> Bool {
        guard !target.isNull,
              !observed.isNull,
              target.origin.x.isFinite,
              target.origin.y.isFinite,
              target.width.isFinite,
              target.height.isFinite,
              observed.origin.x.isFinite,
              observed.origin.y.isFinite,
              observed.width.isFinite,
              observed.height.isFinite,
              target.width > 1,
              target.height > 1,
              observed.width > 1,
              observed.height > 1,
              abs(observed.minX - target.minX) < FrameTolerance.frameWrite,
              abs(observed.maxY - target.maxY) < FrameTolerance.frameWrite
        else {
            return false
        }
        return abs(observed.width - target.width) >= FrameTolerance.frameWrite
            || abs(observed.height - target.height) >= FrameTolerance.frameWrite
    }

    private static func isBoundedAXTopLeftSizeConvergence(target: CGRect, observed: CGRect) -> Bool {
        isAXTopLeftAnchoredSizeClamp(target: target, observed: observed)
            && abs(observed.width - target.width) <= Self.maxAcceptedSizeSnap
            && abs(observed.height - target.height) <= Self.maxAcceptedSizeSnap
    }

    func isStableSizeClamp(
        result: AXFrameApplyResult,
        observedFrame: CGRect
    ) -> Bool {
        guard pid == result.pid,
              sameAXWindowIdentity(self.expectedWindow, result.expectedWindow),
              self.components == .all,
              result.writeResult.components == .all,
              self.reason == .verificationMismatch,
              result.writeResult.failureReason == .verificationMismatch,
              self.settersSucceeded,
              result.writeResult.sizeError == .success,
              result.writeResult.positionError == .success,
              self.targetFrame.approximatelyEqual(
                  to: result.targetFrame,
                  tolerance: FrameTolerance.frameWrite
              ),
              let priorObservedFrame = self.observedFrame,
              priorObservedFrame.approximatelyEqual(
                  to: observedFrame,
                  tolerance: FrameTolerance.frameWrite
              ),
              Self.isAXTopLeftAnchoredSizeClamp(
                  target: self.targetFrame,
                  observed: priorObservedFrame
              )
        else {
            return false
        }
        return Self.isAXTopLeftAnchoredSizeClamp(
            target: result.targetFrame,
            observed: observedFrame
        )
    }

    func isWithinSizeConvergence(target: CGRect, observedFrame: CGRect) -> Bool {
        guard let priorObservedFrame = self.observedFrame else { return false }
        return Self.isBoundedAXTopLeftSizeConvergence(target: targetFrame, observed: priorObservedFrame)
            && Self.isBoundedAXTopLeftSizeConvergence(target: target, observed: observedFrame)
    }

    func enforcedSizeClamp(for targetFrame: CGRect) -> CGRect? {
        guard isTerminalRefusal,
              self.components.contains(.size),
              let observedFrame = self.observedFrame,
              Self.isAXTopLeftAnchoredSizeClamp(target: self.targetFrame, observed: observedFrame),
              axFrameMatches(targetFrame, target: self.targetFrame, components: .size)
        else {
            return nil
        }
        return observedFrame
    }

    func retainsTerminalSizeRefusal(
        components: AXFrameComponents,
        enforcedSizeTarget: CGRect? = nil
    ) -> Bool {
        guard isTerminalRefusal else {
            return false
        }
        guard components.contains(.size) else { return true }
        guard let enforcedSizeTarget else { return false }
        return enforcedSizeClamp(for: enforcedSizeTarget) != nil
    }

    func observedFrameShowsRefusedSize(_ result: AXFrameApplyResult) -> Bool {
        guard isTerminalRefusal,
              let observedFrame = result.writeResult.observedFrame,
              sameAXWindowIdentity(self.expectedWindow, result.expectedWindow)
        else {
            return false
        }
        return axFrameMatches(observedFrame, target: self.targetFrame, components: .size)
    }

    func repeatsRefusedOutcome(_ result: AXFrameApplyResult) -> Bool {
        guard self.reason == result.writeResult.failureReason,
              self.components == result.writeResult.components,
              sameAXWindowIdentity(self.expectedWindow, result.expectedWindow),
              axFrameMatches(result.targetFrame, target: self.targetFrame, components: .size),
              let priorObservedFrame = self.observedFrame,
              let observedFrame = result.writeResult.observedFrame
        else {
            return false
        }
        return axFrameMatches(observedFrame, target: priorObservedFrame, components: .size)
            && Self.isAXTopLeftAnchoredSizeClamp(target: result.targetFrame, observed: observedFrame)
    }

    func matchesTerminalRefusal(
        expectedWindow: AXWindowRef,
        frame: CGRect,
        components: AXFrameComponents
    ) -> Bool {
        guard isTerminalRefusal,
              self.components == components,
              sameAXWindowIdentity(self.expectedWindow, expectedWindow),
              self.targetFrame.approximatelyEqual(to: frame, tolerance: FrameTolerance.frameWrite)
        else {
            return false
        }
        return true
    }

    static func recording(_ result: AXFrameApplyResult, priorFailure: Self?) -> Self? {
        if let failureReason = result.writeResult.failureReason {
            return AXRecentFrameWriteFailure(
                pid: result.pid,
                expectedWindow: result.expectedWindow,
                reason: failureReason,
                targetFrame: result.targetFrame,
                observedFrame: result.writeResult.observedFrame,
                settersSucceeded: result.writeResult.sizeError == .success
                    && result.writeResult.positionError == .success,
                components: result.writeResult.components,
                isTerminalRefusal: priorFailure.map {
                    $0.isTerminalRefusal && $0.repeatsRefusedOutcome(result)
                } ?? false
            )
        }
        return nil
    }

    func appendStateDescription(to parts: inout [String]) {
        parts.append("failure=\(reason.traceDescription)")
        if isTerminalRefusal {
            parts.append("refusedTarget=\(TraceFormat.rect(targetFrame))")
        }
    }
}

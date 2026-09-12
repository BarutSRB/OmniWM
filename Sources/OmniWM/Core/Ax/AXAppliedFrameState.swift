// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct AXAppliedFrameState {
    let frame: CGRect
    let verifiedComponents: AXFrameComponents
    let convergedTargetFrame: CGRect?

    static func accepting(
        _ confirmedFrame: CGRect,
        writeResult: AXFrameWriteResult,
        priorState: Self?
    ) -> Self {
        let verifiedComponents: AXFrameComponents
        let appliedFrame: CGRect
        if writeResult.observedFrame != nil {
            verifiedComponents = .all
            appliedFrame = confirmedFrame
        } else {
            var retained = priorState?.verifiedComponents ?? []
            retained.subtract(writeResult.components)
            verifiedComponents = retained
            var composedFrame = confirmedFrame
            if !writeResult.components.contains(.position), let priorState {
                composedFrame.origin = priorState.frame.origin
            }
            if !writeResult.components.contains(.size), let priorState {
                composedFrame.size = priorState.frame.size
            }
            appliedFrame = composedFrame
        }
        return Self(
            frame: appliedFrame,
            verifiedComponents: verifiedComponents,
            convergedTargetFrame: nil
        )
    }

    var verifiedSize: CGSize? {
        verifiedComponents.contains(.size) ? frame.size : nil
    }

    func matches(target: CGRect, components: AXFrameComponents) -> Bool {
        axFrameMatches(frame, target: target, components: components)
            || (components == .all
                && convergedTargetFrame?.approximatelyEqual(
                    to: target,
                    tolerance: FrameTolerance.frameWrite
                ) == true)
    }

    func appendStateDescription(to parts: inout [String]) {
        parts.append("lastApplied=\(TraceFormat.rect(frame))")
        parts.append("verifiedComponents=\(verifiedComponents.rawValue)")
        if let target = convergedTargetFrame {
            parts.append("convergedTarget=\(TraceFormat.rect(target))")
        }
    }
}

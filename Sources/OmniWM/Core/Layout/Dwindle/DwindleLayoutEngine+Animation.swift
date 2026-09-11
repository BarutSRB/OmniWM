// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension DwindleLayoutEngine {
    func tickAnimations(at time: TimeInterval, in workspaceId: WorkspaceDescriptor.ID) {
        guard let root = existingState(for: workspaceId)?.root else { return }
        tickAnimationsRecursive(root, at: time)
    }

    private func tickAnimationsRecursive(_ node: DwindleNode, at time: TimeInterval) {
        node.tickAnimations(at: time)
        for child in node.children {
            tickAnimationsRecursive(child, at: time)
        }
    }

    func hasActiveAnimations(in workspaceId: WorkspaceDescriptor.ID, at time: TimeInterval) -> Bool {
        guard let root = existingState(for: workspaceId)?.root else { return false }
        return hasActiveAnimationsRecursive(root, at: time)
    }

    private func hasActiveAnimationsRecursive(_ node: DwindleNode, at time: TimeInterval) -> Bool {
        if node.hasActiveAnimations(at: time) { return true }
        for child in node.children where hasActiveAnimationsRecursive(child, at: time) {
            return true
        }
        return false
    }

    func animateWindowMovements(
        _ transition: DwindleFrameTransition,
        in workspaceId: WorkspaceDescriptor.ID,
        startTime: TimeInterval,
        motion: MotionSnapshot
    ) {
        guard let state = existingState(for: workspaceId) else { return }
        for (handle, newFrame) in transition.newFrames {
            guard let oldFrame = transition.oldFrames[handle],
                  let node = state.leafByToken[handle] else { continue }

            let targetChanged = transition.previousTargetFrames[handle].map {
                frameChanged($0, newFrame)
            } ?? true

            if targetChanged {
                node.animateFrom(
                    oldFrame: oldFrame,
                    newFrame: newFrame,
                    startTime: startTime,
                    config: windowMovementAnimationConfig,
                    animated: motion.animationsEnabled
                )
            }
        }
    }

    private func frameChanged(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) > 0.5 ||
            abs(lhs.origin.y - rhs.origin.y) > 0.5 ||
            abs(lhs.width - rhs.width) > 0.5 ||
            abs(lhs.height - rhs.height) > 0.5
    }

    func calculateAnimatedFrames(
        baseFrames: consuming [WindowToken: CGRect],
        in workspaceId: WorkspaceDescriptor.ID,
        at time: TimeInterval
    ) -> [WindowToken: CGRect] {
        guard let state = existingState(for: workspaceId) else { return consume baseFrames }
        var result = consume baseFrames

        for (handle, node) in state.leafByToken {
            guard let frame = result[handle] else { continue }
            guard let presentedFrame = node.presentedFrame(at: time) else { continue }

            let hasAnimation = abs(presentedFrame.origin.x - frame.origin.x) > 0.1 ||
                abs(presentedFrame.origin.y - frame.origin.y) > 0.1 ||
                abs(presentedFrame.width - frame.width) > 0.1 ||
                abs(presentedFrame.height - frame.height) > 0.1

            if hasAnimation {
                result[handle] = presentedFrame
            }
        }

        return result
    }
}

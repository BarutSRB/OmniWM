// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension DwindleLayoutHandler {
    func startRelayoutAnimations(
        _ transition: DwindleFrameTransition,
        snapshot: DwindleWorkspaceSnapshot,
        engine: DwindleLayoutEngine,
        now: TimeInterval
    ) -> Bool {
        engine.animateWindowMovements(
            transition,
            in: snapshot.workspaceId,
            startTime: now,
            motion: controller?.motionPolicy.snapshot() ?? .enabled
        )

        let animationsActive = snapshot.isActiveWorkspace
            && engine.hasActiveAnimations(in: snapshot.workspaceId, at: now)
        if !snapshot.isActiveWorkspace {
            engine.cancelAnimations(in: snapshot.workspaceId)
        }
        return animationsActive
    }

    func animationTargetDisposition(
        snapshot: DwindleWorkspaceSnapshot,
        engine: DwindleLayoutEngine,
        frames: [WindowToken: CGRect],
        active: Bool
    ) -> DwindleAnimationTargetDisposition {
        if active {
            return .replace(
                DwindleAnimationTargetCandidate(
                    workspaceId: snapshot.workspaceId,
                    engineIdentifier: ObjectIdentifier(engine),
                    geometry: geometryContext(monitor: snapshot.monitor, settings: snapshot.settings),
                    targetFrames: frames
                )
            )
        } else {
            return .clear(
                engineIdentifier: ObjectIdentifier(engine),
                geometry: geometryContext(monitor: snapshot.monitor, settings: snapshot.settings)
            )
        }
    }
}

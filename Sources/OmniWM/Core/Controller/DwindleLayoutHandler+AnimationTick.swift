// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension DwindleLayoutHandler {
    private func currentAnimationTarget(
        workspaceId wsId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        displayId: CGDirectDisplayID,
        engine: DwindleLayoutEngine,
        controller: WMController
    ) -> (snapshot: DwindleWorkspaceSnapshot, session: AnimationSession)? {
        guard let snapshot = makeWorkspaceSnapshot(
            workspaceId: wsId,
            monitor: monitor,
            resolveConstraints: false,
            isActiveWorkspace: true
        ) else {
            controller.layoutRefreshController.suspendStaleDwindleAnimation(
                workspaceId: wsId,
                displayId: displayId
            )
            return nil
        }
        guard let session = animationSessionByDisplay[displayId],
              isAnimationSessionCurrent(
                  session,
                  displayId: displayId,
                  engine: engine,
                  snapshot: snapshot
              )
        else {
            controller.layoutRefreshController.suspendStaleDwindleAnimation(
                workspaceId: wsId,
                displayId: displayId
            )
            return nil
        }

        return (snapshot, session)
    }

    func tickDwindleAnimation(targetTime: CFTimeInterval, displayId: CGDirectDisplayID) {
        guard let (wsId, animationMonitor) = dwindleAnimationByDisplay[displayId] else { return }
        guard let controller else {
            _ = removeAnimationState(for: displayId)
            return
        }
        guard let engine = controller.dwindleEngine else {
            controller.layoutRefreshController.stopDwindleAnimation(for: displayId)
            return
        }

        guard let monitor = controller.workspaceManager.monitor(byId: animationMonitor.id) else {
            controller.layoutRefreshController.stopDwindleAnimation(for: displayId)
            return
        }

        guard controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == wsId else {
            controller.layoutRefreshController.stopDwindleAnimation(for: displayId)
            return
        }

        guard let (snapshot, session) = currentAnimationTarget(
            workspaceId: wsId,
            monitor: monitor,
            displayId: displayId,
            engine: engine,
            controller: controller
        ) else { return }

        engine.tickAnimations(at: targetTime, in: wsId)
        let animationsOngoing = engine.hasActiveAnimations(in: wsId, at: targetTime)
        let plan = buildAnimationPlan(
            snapshot: snapshot,
            engine: engine,
            session: session,
            targetTime: targetTime,
            isAnimationTick: animationsOngoing
        )
        let didExecute = controller.layoutRefreshController.executeLayoutPlan(plan)
        guard didExecute else {
            controller.layoutRefreshController.suspendStaleDwindleAnimation(
                workspaceId: wsId,
                displayId: displayId
            )
            return
        }

        if !animationsOngoing {
            controller.layoutRefreshController.stopDwindleAnimation(for: displayId)
            controller.surfaceReconciler.noteRestackOccurred()
        }
    }
}

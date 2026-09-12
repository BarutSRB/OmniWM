// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension DwindleLayoutHandler {
    func isAnimationSessionCurrent(
        _ session: AnimationSession,
        displayId: CGDirectDisplayID,
        engine: DwindleLayoutEngine,
        snapshot: DwindleWorkspaceSnapshot
    ) -> Bool {
        guard let controller,
              session.workspaceId == snapshot.workspaceId,
              session.geometry.displayId == displayId,
              session.engineIdentifier == ObjectIdentifier(engine),
              session.geometry == geometryContext(
                  monitor: snapshot.monitor,
                  settings: snapshot.settings
              )
        else {
            return false
        }
        return session.plannedSeq == 0
            || controller.workspaceManager.isSeqCurrent(
                session.plannedSeq,
                for: snapshot.workspaceId,
                domains: .layoutCommit
            )
    }
}

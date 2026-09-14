// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension DwindleLayoutHandler {
    func moveToRootInDwindle() {
        guard let controller else { return }
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            let stable = controller.settings.dwindle.moveToRootStable
            if engine.moveSelectionToRoot(stable: stable, in: wsId) {
                controller.dwindleLayoutHandler.recordLayoutOperation(.windowMovedToRoot, in: wsId)
            }
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
    }

    func toggleSplitInDwindle() {
        guard let controller else { return }
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            if engine.toggleOrientation(in: wsId) {
                controller.dwindleLayoutHandler.recordLayoutOperation(.splitOrientationToggled, in: wsId)
            }
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
    }

    func swapSplitInDwindle() {
        guard let controller else { return }
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            if engine.swapSplit(in: wsId) {
                controller.dwindleLayoutHandler.recordLayoutOperation(.splitSwapped, in: wsId)
            }
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
    }

    func resizeAlongAxisInDwindle(orientation: DwindleOrientation, grow: Bool) {
        guard let controller else { return }
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            let delta = grow ? engine.settings.resizeStep : -engine.settings.resizeStep
            if engine.resizeSelected(by: delta, orientation: orientation, in: wsId) {
                controller.dwindleLayoutHandler.recordLayoutOperation(.splitRatioChanged, in: wsId)
            }
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
    }

    func resizeFocusedWindowInDwindle(grow: Bool) {
        guard let controller else { return }
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            let delta = grow ? engine.settings.resizeStep : -engine.settings.resizeStep
            if engine.resizeFocusedWindow(by: delta, in: wsId) {
                controller.dwindleLayoutHandler.recordLayoutOperation(.splitRatioChanged, in: wsId)
            }
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
    }

    func preselectInDwindle(direction: Direction) {
        guard let controller else { return }
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            if engine.setPreselection(direction, in: wsId) {
                controller.dwindleLayoutHandler.recordLayoutOperation(.preselectionChanged, in: wsId)
            }
        }
    }

    func clearPreselectInDwindle() {
        guard let controller else { return }
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            if engine.setPreselection(nil, in: wsId) {
                controller.dwindleLayoutHandler.recordLayoutOperation(.preselectionChanged, in: wsId)
            }
        }
    }
}

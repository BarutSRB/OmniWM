// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension NiriLayoutHandler {
    func toggleFullscreen() {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard let currentId = state.selectedNodeId,
                  let currentNode = engine.findNode(by: currentId, in: wsId),
                  let windowNode = currentNode as? NiriWindow
            else { return }

            engine.toggleFullscreen(windowNode, motion: motion, state: &state)
            if windowNode.sizingMode == .normal {
                engine.recoverSettledCoverage(
                    context: .init(
                        workspaceId: wsId,
                        motion: motion,
                        workingFrame: workingFrame,
                        gaps: gaps,
                        orientation: orientation
                    ),
                    state: &state
                )
            }

            recordLayoutOperation(.fullscreenToggled(token: windowNode.token), in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func cycleSize(forward: Bool) {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId, in: wsId) as? NiriWindow,
                  let column = engine.findColumn(containing: windowNode, in: wsId)
            else { return }

            engine.toggleContainerPrimarySpan(
                column,
                forwards: forward,
                context: .init(
                    workspaceId: wsId,
                    motion: motion,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: orientation
                ),
                state: &state
            )
            recordLayoutOperation(.containerPrimarySpanChanged, in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func cycleWindowPrimarySpan(forward: Bool) {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId, in: wsId) as? NiriWindow
            else { return }

            engine.toggleWindowPrimarySpan(
                windowNode,
                forwards: forward,
                context: .init(
                    workspaceId: wsId,
                    motion: motion,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: orientation
                ),
                state: &state
            )
            recordLayoutOperation(.windowSizeChanged(token: windowNode.token), in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func cycleWindowSecondarySpan(forward: Bool) {
        withNiriWorkspaceContext { engine, wsId, _, state, _, workingFrame, gaps, orientation in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId, in: wsId) as? NiriWindow
            else { return }

            engine.toggleWindowSecondarySpan(
                windowNode,
                forwards: forward,
                in: wsId,
                geometry: NiriSizingGeometry(
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: orientation
                )
            )
            recordLayoutOperation(.windowSizeChanged(token: windowNode.token), in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func toggleContainerFullPrimarySpan() {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId, in: wsId) as? NiriWindow,
                  let column = engine.findColumn(containing: windowNode, in: wsId)
            else { return }

            engine.toggleContainerFullPrimarySpan(
                column,
                context: .init(
                    workspaceId: wsId,
                    motion: motion,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: orientation
                ),
                state: &state
            )
            recordLayoutOperation(.containerPrimarySpanChanged, in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func expandContainerToAvailablePrimarySpan() {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId, in: wsId) as? NiriWindow,
                  let column = engine.findColumn(containing: windowNode, in: wsId)
            else { return }

            engine.expandContainerToAvailablePrimarySpan(
                column,
                context: .init(
                    workspaceId: wsId,
                    motion: motion,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: orientation
                ),
                state: &state
            )
            recordLayoutOperation(.containerPrimarySpanChanged, in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func resetWindowSecondarySpan() {
        withNiriWorkspaceContext { engine, wsId, _, state, _, _, _, orientation in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId, in: wsId) as? NiriWindow
            else { return }

            engine.resetWindowSecondarySpan(windowNode, in: wsId, orientation: orientation)
            recordLayoutOperation(.windowSizeChanged(token: windowNode.token), in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func centerColumn() {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard engine.centerColumn(
                context: .init(
                    workspaceId: wsId,
                    motion: motion,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: orientation
                ),
                state: &state
            ) else { return }

            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func centerVisibleColumns() {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard engine.centerVisibleColumns(
                context: .init(
                    workspaceId: wsId,
                    motion: motion,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: orientation
                ),
                state: &state
            ) else { return }

            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func setContainerPrimarySpan(_ change: NiriSizeChange) {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId, in: wsId) as? NiriWindow,
                  let column = engine.findColumn(containing: windowNode, in: wsId)
            else { return }

            engine.setContainerPrimarySpan(
                column,
                change: change,
                context: .init(
                    workspaceId: wsId,
                    motion: motion,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: orientation
                ),
                state: &state
            )
            recordLayoutOperation(.containerPrimarySpanChanged, in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func setWindowPrimarySpan(_ change: NiriSizeChange) {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId, in: wsId) as? NiriWindow
            else { return }

            engine.setWindowPrimarySpan(
                windowNode,
                change: change,
                context: .init(
                    workspaceId: wsId,
                    motion: motion,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: orientation
                ),
                state: &state
            )
            recordLayoutOperation(.windowSizeChanged(token: windowNode.token), in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func setWindowSecondarySpan(_ change: NiriSizeChange) {
        withNiriWorkspaceContext { engine, wsId, _, state, _, workingFrame, gaps, orientation in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId, in: wsId) as? NiriWindow
            else { return }

            engine.setWindowSecondarySpan(
                windowNode,
                change: change,
                in: wsId,
                geometry: NiriSizingGeometry(
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: orientation
                )
            )
            recordLayoutOperation(.windowSizeChanged(token: windowNode.token), in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func balanceSizes() {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard engine.balanceSizes(
                in: wsId,
                motion: motion,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            ) else { return }
            engine.recoverSettledCoverage(
                context: .init(
                    workspaceId: wsId,
                    motion: motion,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: orientation
                ),
                state: &state
            )
            recordLayoutOperation(.sizesBalanced, in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func balanceSizesAllWorkspaces() {
        guard let controller else { return }
        var changed: Set<WorkspaceDescriptor.ID> = []
        for descriptor in controller.workspaceManager.workspaces {
            guard controller.settings.workspaces.layoutType(for: descriptor.name) != .dwindle else { continue }
            withNiriWorkspaceContext(for: descriptor.id) {
                engine, wsId, motion, state, _, workingFrame, gaps, orientation in
                guard engine.balanceSizes(
                    in: wsId,
                    motion: motion,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: orientation
                ) else { return }
                engine.recoverSettledCoverage(
                    context: .init(
                        workspaceId: wsId,
                        motion: motion,
                        workingFrame: workingFrame,
                        gaps: gaps,
                        orientation: orientation
                    ),
                    state: &state
                )
                changed.insert(wsId)
                recordLayoutOperation(.sizesBalanced, in: wsId)
                startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
            }
        }
        if !changed.isEmpty {
            controller.layoutRefreshController.requestLayoutCommandRelayout(affectedWorkspaceIds: changed)
        }
    }

    // MARK: - Layout Engine Configuration
}

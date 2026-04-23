// SPDX-License-Identifier: GPL-2.0-only
import Foundation
@testable import OmniWM
import Testing

private func makeWorkspaceNavigationKernelMonitor(
    id: UInt32,
    minX: CGFloat,
    maxY: CGFloat = 1080,
    centerX: CGFloat,
    centerY: CGFloat = 540,
    activeWorkspaceId: WorkspaceDescriptor.ID? = nil,
    previousWorkspaceId: WorkspaceDescriptor.ID? = nil
) -> WorkspaceNavigationKernel.Input.MonitorSnapshot {
    .init(
        monitorId: .init(displayId: id),
        frameMinX: minX,
        frameMaxY: maxY,
        centerX: centerX,
        centerY: centerY,
        activeWorkspaceId: activeWorkspaceId,
        previousWorkspaceId: previousWorkspaceId
    )
}

private func makeWorkspaceNavigationKernelWorkspace(
    id: WorkspaceDescriptor.ID,
    monitorId: UInt32?,
    layoutKind: WorkspaceNavigationKernel.Input.WorkspaceSnapshot.LayoutKind = .niri,
    rememberedTiledFocusToken: WindowToken? = nil,
    firstTiledFocusToken: WindowToken? = nil,
    rememberedFloatingFocusToken: WindowToken? = nil,
    firstFloatingFocusToken: WindowToken? = nil
) -> WorkspaceNavigationKernel.Input.WorkspaceSnapshot {
    .init(
        workspaceId: id,
        monitorId: monitorId.map(Monitor.ID.init(displayId:)),
        layoutKind: layoutKind,
        rememberedTiledFocusToken: rememberedTiledFocusToken,
        firstTiledFocusToken: firstTiledFocusToken,
        rememberedFloatingFocusToken: rememberedFloatingFocusToken,
        firstFloatingFocusToken: firstFloatingFocusToken
    )
}

private func makeWorkspaceNavigationKernelInput(
    intent: WorkspaceNavigationKernel.Intent,
    monitors: [WorkspaceNavigationKernel.Input.MonitorSnapshot],
    workspaces: [WorkspaceNavigationKernel.Input.WorkspaceSnapshot],
    adjacentFallbackWorkspaceNumber: UInt32? = nil,
    activeColumnSubjectToken: WindowToken? = nil,
    selectedColumnSubjectToken: WindowToken? = nil,
    focus: WorkspaceNavigationKernel.Input.FocusSessionSnapshot = .init()
) -> WorkspaceNavigationKernel.Input {
    .init(
        intent: intent,
        adjacentFallbackWorkspaceNumber: adjacentFallbackWorkspaceNumber,
        activeColumnSubjectToken: activeColumnSubjectToken,
        selectedColumnSubjectToken: selectedColumnSubjectToken,
        focus: focus,
        monitors: monitors,
        workspaces: workspaces
    )
}

@Suite @MainActor struct WorkspaceNavigationKernelTests {
    @Test func explicitSwitchHandsOffRememberedFocusAndSavesCurrentWorkspace() {
        let workspaceOne = WorkspaceDescriptor.ID()
        let workspaceTwo = WorkspaceDescriptor.ID()
        let targetToken = WindowToken(pid: 42, windowId: 4201)

        let input = makeWorkspaceNavigationKernelInput(
            intent: .init(
                operation: .switchWorkspaceExplicit,
                currentWorkspaceId: workspaceOne,
                targetWorkspaceId: workspaceTwo
            ),
            monitors: [
                makeWorkspaceNavigationKernelMonitor(
                    id: 1,
                    minX: 0,
                    centerX: 960,
                    activeWorkspaceId: workspaceOne
                )
            ],
            workspaces: [
                makeWorkspaceNavigationKernelWorkspace(id: workspaceOne, monitorId: 1),
                makeWorkspaceNavigationKernelWorkspace(
                    id: workspaceTwo,
                    monitorId: 1,
                    rememberedTiledFocusToken: targetToken
                )
            ]
        )

        let plan = WorkspaceNavigationKernel.plan(input)

        #expect(plan.outcome == .execute)
        #expect(plan.targetWorkspaceId == workspaceTwo)
        #expect(plan.targetMonitorId == Monitor.ID(displayId: 1))
        #expect(plan.focusAction == .workspaceHandoff)
        #expect(plan.resolvedFocusToken == targetToken)
        #expect(plan.saveWorkspaceIds == [workspaceOne])
        #expect(plan.shouldActivateTargetWorkspace)
        #expect(plan.shouldCommitWorkspaceTransition)
    }

    @Test func explicitSwitchClearsManagedFocusWhenTargetHasNoCandidate() {
        let workspaceOne = WorkspaceDescriptor.ID()
        let workspaceTwo = WorkspaceDescriptor.ID()

        let input = makeWorkspaceNavigationKernelInput(
            intent: .init(
                operation: .switchWorkspaceExplicit,
                currentWorkspaceId: workspaceOne,
                targetWorkspaceId: workspaceTwo
            ),
            monitors: [
                makeWorkspaceNavigationKernelMonitor(
                    id: 1,
                    minX: 0,
                    centerX: 960,
                    activeWorkspaceId: workspaceOne
                )
            ],
            workspaces: [
                makeWorkspaceNavigationKernelWorkspace(id: workspaceOne, monitorId: 1),
                makeWorkspaceNavigationKernelWorkspace(id: workspaceTwo, monitorId: 1)
            ]
        )

        let plan = WorkspaceNavigationKernel.plan(input)

        #expect(plan.outcome == .execute)
        #expect(plan.focusAction == .clearManagedFocus)
        #expect(plan.resolvedFocusToken == nil)
    }

    @Test func focusWorkspaceAnywhereSavesCurrentAndVisibleTargetWorkspace() {
        let workspaceOne = WorkspaceDescriptor.ID()
        let workspaceTwo = WorkspaceDescriptor.ID()
        let workspaceThree = WorkspaceDescriptor.ID()

        let input = makeWorkspaceNavigationKernelInput(
            intent: .init(
                operation: .focusWorkspaceAnywhere,
                currentWorkspaceId: workspaceOne,
                targetWorkspaceId: workspaceThree,
                currentMonitorId: .init(displayId: 1)
            ),
            monitors: [
                makeWorkspaceNavigationKernelMonitor(
                    id: 1,
                    minX: 0,
                    centerX: 960,
                    activeWorkspaceId: workspaceOne
                ),
                makeWorkspaceNavigationKernelMonitor(
                    id: 2,
                    minX: 1920,
                    centerX: 2880,
                    activeWorkspaceId: workspaceTwo
                )
            ],
            workspaces: [
                makeWorkspaceNavigationKernelWorkspace(id: workspaceOne, monitorId: 1),
                makeWorkspaceNavigationKernelWorkspace(id: workspaceTwo, monitorId: 2),
                makeWorkspaceNavigationKernelWorkspace(id: workspaceThree, monitorId: 2)
            ]
        )

        let plan = WorkspaceNavigationKernel.plan(input)

        #expect(plan.outcome == .execute)
        #expect(plan.targetWorkspaceId == workspaceThree)
        #expect(plan.saveWorkspaceIds == [workspaceOne, workspaceTwo])
        #expect(plan.shouldSyncMonitorsToNiri)
    }

    @Test func moveWindowAdjacentMaterializesConfiguredWorkspaceWhenNeighborIsMissing() {
        let workspaceTwo = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 77, windowId: 7701)

        let input = makeWorkspaceNavigationKernelInput(
            intent: .init(
                operation: .moveWindowAdjacent,
                direction: .down,
                sourceWorkspaceId: workspaceTwo,
                currentMonitorId: .init(displayId: 1),
                focusedToken: token
            ),
            monitors: [
                makeWorkspaceNavigationKernelMonitor(
                    id: 1,
                    minX: 0,
                    centerX: 960,
                    activeWorkspaceId: workspaceTwo
                )
            ],
            workspaces: [
                makeWorkspaceNavigationKernelWorkspace(id: workspaceTwo, monitorId: 1)
            ],
            adjacentFallbackWorkspaceNumber: 3
        )

        let plan = WorkspaceNavigationKernel.plan(input)

        #expect(plan.outcome == .execute)
        #expect(plan.subject == .window(token))
        #expect(plan.focusAction == .recoverSource)
        #expect(plan.sourceWorkspaceId == workspaceTwo)
        #expect(plan.targetWorkspaceId == nil)
        #expect(plan.targetMonitorId == Monitor.ID(displayId: 1))
        #expect(plan.materializeTargetWorkspaceRawID == "3")
        #expect(plan.saveWorkspaceIds == [workspaceTwo])
    }

    @Test func moveColumnAdjacentBlocksWithoutNiriColumnSubject() {
        let workspaceOne = WorkspaceDescriptor.ID()

        let input = makeWorkspaceNavigationKernelInput(
            intent: .init(
                operation: .moveColumnAdjacent,
                direction: .right,
                sourceWorkspaceId: workspaceOne,
                currentMonitorId: .init(displayId: 1)
            ),
            monitors: [
                makeWorkspaceNavigationKernelMonitor(
                    id: 1,
                    minX: 0,
                    centerX: 960,
                    activeWorkspaceId: workspaceOne
                )
            ],
            workspaces: [
                makeWorkspaceNavigationKernelWorkspace(
                    id: workspaceOne,
                    monitorId: 1,
                    layoutKind: .defaultLayout
                )
            ]
        )

        let plan = WorkspaceNavigationKernel.plan(input)

        #expect(plan.outcome == .blocked)
    }

    @Test func moveWindowExplicitFollowFocusUsesSubjectFocusPath() {
        let workspaceOne = WorkspaceDescriptor.ID()
        let workspaceTwo = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 91, windowId: 9101)

        let input = makeWorkspaceNavigationKernelInput(
            intent: .init(
                operation: .moveWindowExplicit,
                sourceWorkspaceId: workspaceOne,
                targetWorkspaceId: workspaceTwo,
                focusedToken: token,
                followFocus: true
            ),
            monitors: [
                makeWorkspaceNavigationKernelMonitor(id: 1, minX: 0, centerX: 960, activeWorkspaceId: workspaceOne),
                makeWorkspaceNavigationKernelMonitor(id: 2, minX: 1920, centerX: 2880, activeWorkspaceId: workspaceTwo)
            ],
            workspaces: [
                makeWorkspaceNavigationKernelWorkspace(id: workspaceOne, monitorId: 1),
                makeWorkspaceNavigationKernelWorkspace(id: workspaceTwo, monitorId: 2)
            ]
        )

        let plan = WorkspaceNavigationKernel.plan(input)

        #expect(plan.outcome == .execute)
        #expect(plan.subject == .window(token))
        #expect(plan.focusAction == .subject)
        #expect(plan.shouldActivateTargetWorkspace)
        #expect(plan.shouldSetInteractionMonitor)
        #expect(plan.shouldCommitWorkspaceTransition)
    }

    @Test func swapWorkspaceWithMonitorPlansMonitorSyncAndAffectedSets() {
        let workspaceOne = WorkspaceDescriptor.ID()
        let workspaceTwo = WorkspaceDescriptor.ID()

        let input = makeWorkspaceNavigationKernelInput(
            intent: .init(
                operation: .swapWorkspaceWithMonitor,
                direction: .right,
                currentWorkspaceId: workspaceOne,
                currentMonitorId: .init(displayId: 1)
            ),
            monitors: [
                makeWorkspaceNavigationKernelMonitor(id: 1, minX: 0, centerX: 960, activeWorkspaceId: workspaceOne),
                makeWorkspaceNavigationKernelMonitor(id: 2, minX: 1920, centerX: 2880, activeWorkspaceId: workspaceTwo)
            ],
            workspaces: [
                makeWorkspaceNavigationKernelWorkspace(id: workspaceOne, monitorId: 1),
                makeWorkspaceNavigationKernelWorkspace(id: workspaceTwo, monitorId: 2)
            ]
        )

        let plan = WorkspaceNavigationKernel.plan(input)

        #expect(plan.outcome == .execute)
        #expect(plan.sourceWorkspaceId == workspaceOne)
        #expect(plan.targetWorkspaceId == workspaceTwo)
        #expect(plan.saveWorkspaceIds == [workspaceOne])
        #expect(plan.affectedWorkspaceIds == Set([workspaceOne, workspaceTwo]))
        #expect(plan.affectedMonitorIds == [Monitor.ID(displayId: 1), Monitor.ID(displayId: 2)])
        #expect(plan.shouldSyncMonitorsToNiri)
    }

    @Test func focusMonitorCyclicUsesSortedMonitorOrderInsteadOfInputOrder() {
        let workspaceOne = WorkspaceDescriptor.ID()
        let workspaceTwo = WorkspaceDescriptor.ID()
        let workspaceThree = WorkspaceDescriptor.ID()
        let targetToken = WindowToken(pid: 12, windowId: 1201)

        let input = makeWorkspaceNavigationKernelInput(
            intent: .init(
                operation: .focusMonitorCyclic,
                direction: .right,
                currentMonitorId: .init(displayId: 2)
            ),
            monitors: [
                makeWorkspaceNavigationKernelMonitor(id: 3, minX: 1920, centerX: 2880, activeWorkspaceId: workspaceThree),
                makeWorkspaceNavigationKernelMonitor(id: 2, minX: 960, centerX: 1440, activeWorkspaceId: workspaceTwo),
                makeWorkspaceNavigationKernelMonitor(id: 1, minX: 0, centerX: 480, activeWorkspaceId: workspaceOne)
            ],
            workspaces: [
                makeWorkspaceNavigationKernelWorkspace(id: workspaceOne, monitorId: 1),
                makeWorkspaceNavigationKernelWorkspace(id: workspaceTwo, monitorId: 2),
                makeWorkspaceNavigationKernelWorkspace(
                    id: workspaceThree,
                    monitorId: 3,
                    rememberedTiledFocusToken: targetToken
                )
            ]
        )

        let plan = WorkspaceNavigationKernel.plan(input)

        #expect(plan.outcome == .execute)
        #expect(plan.targetWorkspaceId == workspaceThree)
        #expect(plan.targetMonitorId == Monitor.ID(displayId: 3))
        #expect(plan.focusAction == .resolveTargetIfPresent)
        #expect(plan.resolvedFocusToken == targetToken)
    }

    @Test func focusMonitorCyclicUsesDisplayIdTieBreakerForIdenticalSortKeys() {
        let workspaceOne = WorkspaceDescriptor.ID()
        let workspaceTwo = WorkspaceDescriptor.ID()
        let workspaceThree = WorkspaceDescriptor.ID()

        let input = makeWorkspaceNavigationKernelInput(
            intent: .init(
                operation: .focusMonitorCyclic,
                direction: .right,
                currentMonitorId: .init(displayId: 2)
            ),
            monitors: [
                makeWorkspaceNavigationKernelMonitor(id: 2, minX: 0, centerX: 500, activeWorkspaceId: workspaceTwo),
                makeWorkspaceNavigationKernelMonitor(id: 1, minX: 0, centerX: 500, activeWorkspaceId: workspaceOne),
                makeWorkspaceNavigationKernelMonitor(id: 3, minX: 1920, centerX: 2880, activeWorkspaceId: workspaceThree)
            ],
            workspaces: [
                makeWorkspaceNavigationKernelWorkspace(id: workspaceOne, monitorId: 1),
                makeWorkspaceNavigationKernelWorkspace(id: workspaceTwo, monitorId: 2),
                makeWorkspaceNavigationKernelWorkspace(id: workspaceThree, monitorId: 3)
            ]
        )

        let plan = WorkspaceNavigationKernel.plan(input)

        #expect(plan.outcome == .execute)
        #expect(plan.targetWorkspaceId == workspaceThree)
        #expect(plan.targetMonitorId == Monitor.ID(displayId: 3))
    }
}

import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

private func hasDwindleAnimationDirective(
    _ directives: [AnimationDirective],
    workspaceId: WorkspaceDescriptor.ID,
    monitorId: Monitor.ID
) -> Bool {
    directives.contains { directive in
        if case let .startDwindleAnimation(candidateWorkspaceId, candidateMonitorId) = directive {
            return candidateWorkspaceId == workspaceId && candidateMonitorId == monitorId
        }
        return false
    }
}

private func layoutTokenSet(_ changes: [LayoutFrameChange]) -> Set<WindowToken> {
    Set(changes.map(\.token))
}

@MainActor
private func configureWorkspaceAsDwindle(
    on controller: WMController,
    workspaceId: WorkspaceDescriptor.ID
) {
    configureWorkspacesAsDwindle(on: controller, workspaceIds: [workspaceId])
}

@MainActor
private func configureWorkspacesAsDwindle(
    on controller: WMController,
    workspaceIds: [WorkspaceDescriptor.ID]
) {
    let configurations = workspaceIds.compactMap { workspaceId -> WorkspaceConfiguration? in
        guard let workspace = controller.workspaceManager.descriptor(for: workspaceId) else { return nil }
        return WorkspaceConfiguration(name: workspace.name, layoutType: .dwindle)
    }
    guard !configurations.isEmpty else { return }
    controller.settings.workspaceConfigurations = configurations
}

@Suite struct DwindleLayoutEngineTests {
    @Test func syncWindowsKeepsStableNodeForReobservedToken() {
        let engine = DwindleLayoutEngine()
        let wsId = UUID()

        let original = makeTestHandle(pid: 31)
        let refreshed = WindowHandle(
            id: original.id,
            pid: original.pid,
            axElement: AXUIElementCreateSystemWide()
        )

        _ = engine.syncWindows([original], in: wsId, focusedHandle: original)
        let originalNodeId = engine.findNode(for: original.id)?.id

        _ = engine.syncWindows([refreshed], in: wsId, focusedHandle: refreshed)

        #expect(engine.windowCount(in: wsId) == 1)
        #expect(engine.findNode(for: refreshed.id)?.id == originalNodeId)
    }

    @Test func layoutAndFrameCachesUseStableTokens() {
        let engine = DwindleLayoutEngine()
        let wsId = UUID()
        let handle1 = makeTestHandle(pid: 41)
        let handle2 = makeTestHandle(pid: 42)

        _ = engine.syncWindows([handle1, handle2], in: wsId, focusedHandle: handle1)

        let baseFrames = engine.calculateLayout(
            for: wsId,
            screen: CGRect(x: 0, y: 0, width: 1600, height: 1000)
        )
        #expect(Set(baseFrames.keys) == Set([handle1.id, handle2.id]))

        let currentFrames = engine.currentFrames(in: wsId)
        #expect(Set(currentFrames.keys) == Set([handle1.id, handle2.id]))

        engine.removeWindow(token: handle2.id, from: wsId)

        let updatedFrames = engine.calculateLayout(
            for: wsId,
            screen: CGRect(x: 0, y: 0, width: 1600, height: 1000)
        )
        #expect(Set(updatedFrames.keys) == Set([handle1.id]))
        #expect(engine.findNode(for: handle2.id) == nil)
    }

    @Test @MainActor func steadyRelayoutPlanUsesTokensWithoutVisibilityDiffs() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for Dwindle plan test")
            return
        }

        configureWorkspaceAsDwindle(on: controller, workspaceId: workspaceId)
        controller.enableDwindleLayout()
        await waitForLayoutPlanRefreshWork(on: controller)

        let firstToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 601)
        let secondToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 602)
        _ = controller.workspaceManager.setManagedFocus(firstToken, in: workspaceId, onMonitor: monitor.id)

        let plans = try await controller.dwindleLayoutHandler.layoutWithDwindleEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let plan = plans.first else {
            Issue.record("Expected a Dwindle layout plan for the active workspace")
            return
        }

        #expect(layoutTokenSet(plan.diff.frameChanges) == Set([firstToken, secondToken]))
        #expect(plan.diff.visibilityChanges.isEmpty)
    }

    @Test @MainActor func relayoutPlanStartsAnimationWhenFramesChange() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for Dwindle animation test")
            return
        }

        configureWorkspaceAsDwindle(on: controller, workspaceId: workspaceId)
        controller.enableDwindleLayout()
        await waitForLayoutPlanRefreshWork(on: controller)

        _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 701)
        let initialPlans = try await controller.dwindleLayoutHandler.layoutWithDwindleEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 702)
        let plans = try await controller.dwindleLayoutHandler.layoutWithDwindleEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let plan = plans.first else {
            Issue.record("Expected a Dwindle layout plan after adding a window")
            return
        }

        #expect(
            hasDwindleAnimationDirective(
                plan.animationDirectives,
                workspaceId: workspaceId,
                monitorId: monitor.id
            )
        )
        #expect(plan.diff.visibilityChanges.isEmpty)
    }

    @Test @MainActor func relayoutPlanUsesResolvedMonitorSettingsFromSnapshot() async throws {
        let monitor = makeLayoutPlanTestMonitor(name: "SquareTest")
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing active workspace for Dwindle settings test")
            return
        }

        configureWorkspaceAsDwindle(on: controller, workspaceId: workspaceId)
        controller.enableDwindleLayout()
        await waitForLayoutPlanRefreshWork(on: controller)

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 801)

        let baselinePlans = try await controller.dwindleLayoutHandler.layoutWithDwindleEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let baselinePlan = baselinePlans.first,
              let baselineFrame = baselinePlan.diff.frameChanges.first(where: { $0.token == token })?.frame
        else {
            Issue.record("Expected a baseline Dwindle frame for the single window")
            return
        }

        controller.settings.updateDwindleSettings(
            MonitorDwindleSettings(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                singleWindowAspectRatio: .square
            )
        )

        let overridePlans = try await controller.dwindleLayoutHandler.layoutWithDwindleEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let overridePlan = overridePlans.first,
              let overrideFrame = overridePlan.diff.frameChanges.first(where: { $0.token == token })?.frame
        else {
            Issue.record("Expected a Dwindle frame after applying monitor override settings")
            return
        }

        #expect(baselineFrame.width > overrideFrame.width)
        #expect(abs(overrideFrame.width - overrideFrame.height) < 0.5)
    }

    @Test @MainActor func nonFocusedWorkspacePlanDoesNotClearFocusedBorder() async throws {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller
        controller.setBordersEnabled(true)
        configureWorkspacesAsDwindle(
            on: controller,
            workspaceIds: [fixture.primaryWorkspaceId, fixture.secondaryWorkspaceId]
        )
        controller.enableDwindleLayout()
        await waitForLayoutPlanRefreshWork(on: controller)

        let primaryToken = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: fixture.primaryWorkspaceId,
            windowId: 901
        )
        _ = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: fixture.secondaryWorkspaceId,
            windowId: 902
        )
        _ = controller.workspaceManager.setManagedFocus(
            primaryToken,
            in: fixture.primaryWorkspaceId,
            onMonitor: fixture.primaryMonitor.id
        )

        let plans = try await controller.dwindleLayoutHandler.layoutWithDwindleEngine(
            activeWorkspaces: [fixture.primaryWorkspaceId, fixture.secondaryWorkspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(plans)

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 901)
    }

    @Test @MainActor func visibleSecondaryWorkspacePlanRestoresInactiveHiddenWindows() async throws {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller
        configureWorkspacesAsDwindle(
            on: controller,
            workspaceIds: [fixture.primaryWorkspaceId, fixture.secondaryWorkspaceId]
        )
        controller.enableDwindleLayout()
        await waitForLayoutPlanRefreshWork(on: controller)

        let token = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: fixture.secondaryWorkspaceId,
            windowId: 905
        )
        setWorkspaceInactiveHiddenStateForLayoutPlanTests(
            on: controller,
            token: token,
            monitor: fixture.secondaryMonitor
        )

        let plans = try await controller.dwindleLayoutHandler.layoutWithDwindleEngine(
            activeWorkspaces: [fixture.primaryWorkspaceId, fixture.secondaryWorkspaceId]
        )
        guard let secondaryPlan = plans.first(where: { $0.workspaceId == fixture.secondaryWorkspaceId }) else {
            Issue.record("Expected a plan for the visible secondary workspace")
            return
        }

        #expect(secondaryPlan.diff.restoreChanges.contains { $0.token == token })
    }

    @Test @MainActor func staleDwindleAnimationStopsBeforeRestoringInactiveWorkspaceWindows() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let originalWorkspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let replacementWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Missing monitor or workspaces for stale Dwindle animation test")
            return
        }

        configureWorkspacesAsDwindle(
            on: controller,
            workspaceIds: [originalWorkspaceId, replacementWorkspaceId]
        )
        controller.enableDwindleLayout()
        await waitForLayoutPlanRefreshWork(on: controller)

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: originalWorkspaceId, windowId: 903)
        _ = controller.workspaceManager.setManagedFocus(token, in: originalWorkspaceId, onMonitor: monitor.id)

        let plans = try await controller.dwindleLayoutHandler.layoutWithDwindleEngine(
            activeWorkspaces: [originalWorkspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(plans)

        setWorkspaceInactiveHiddenStateForLayoutPlanTests(on: controller, token: token, monitor: monitor)
        #expect(
            controller.dwindleLayoutHandler.registerDwindleAnimation(
                originalWorkspaceId,
                monitor: monitor,
                on: monitor.displayId
            )
        )
        _ = controller.workspaceManager.setActiveWorkspace(replacementWorkspaceId, on: monitor.id)

        controller.dwindleLayoutHandler.tickDwindleAnimation(targetTime: 1, displayId: monitor.displayId)

        #expect(controller.dwindleLayoutHandler.dwindleAnimationByDisplay[monitor.displayId] == nil)
        #expect(controller.workspaceManager.hiddenState(for: token)?.workspaceInactive == true)
    }
}

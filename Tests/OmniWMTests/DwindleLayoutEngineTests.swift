import ApplicationServices
import CoreGraphics
import Foundation
import QuartzCore
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
    let targetNames = Set(
        workspaceIds.compactMap { workspaceId in
            controller.workspaceManager.descriptor(for: workspaceId)?.name
        }
    )
    guard !targetNames.isEmpty else { return }

    var configurations = controller.settings.workspaceConfigurations.map { configuration in
        targetNames.contains(configuration.name)
            ? configuration.with(layoutType: .dwindle)
            : configuration
    }
    let configuredNames = Set(configurations.map(\.name))
    let missingConfigurations = workspaceIds.compactMap { workspaceId -> WorkspaceConfiguration? in
        guard let workspace = controller.workspaceManager.descriptor(for: workspaceId),
              !configuredNames.contains(workspace.name)
        else {
            return nil
        }
        return WorkspaceConfiguration(name: workspace.name, layoutType: .dwindle)
    }

    configurations.append(contentsOf: missingConfigurations)
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

    @Test func rekeyWindowKeepsLeafStableAcrossSync() {
        let engine = DwindleLayoutEngine()
        let wsId = UUID()

        let handle1 = makeTestHandle(pid: 73)
        let handle2 = makeTestHandle(pid: 74)

        _ = engine.syncWindows([handle1, handle2], in: wsId, focusedHandle: handle1)
        let originalNodeId = engine.findNode(for: handle2.id)?.id
        let replacementToken = WindowToken(pid: handle2.pid, windowId: handle2.windowId + 1000)

        #expect(engine.rekeyWindow(from: handle2.id, to: replacementToken, in: wsId))

        let removed = engine.syncWindows([handle1.id, replacementToken], in: wsId, focusedToken: handle1.id)

        #expect(removed.isEmpty)
        #expect(engine.windowCount(in: wsId) == 2)
        #expect(engine.findNode(for: handle2.id) == nil)
        #expect(engine.findNode(for: replacementToken)?.id == originalNodeId)
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

    @Test func syncWindowsPreservesCallerOrderForFreshLayouts() {
        let forwardEngine = DwindleLayoutEngine()
        let reverseEngine = DwindleLayoutEngine()
        let wsId = UUID()
        let handleA = makeTestHandle(pid: 141)
        let handleB = makeTestHandle(pid: 142)
        let handleC = makeTestHandle(pid: 143)
        let forwardOrder = [handleA, handleB, handleC]
        let reverseOrder = [handleC, handleB, handleA]

        _ = forwardEngine.syncWindows(forwardOrder, in: wsId, focusedHandle: nil)
        _ = reverseEngine.syncWindows(reverseOrder, in: wsId, focusedHandle: nil)

        guard let forwardRoot = forwardEngine.root(for: wsId),
              let reverseRoot = reverseEngine.root(for: wsId)
        else {
            Issue.record("Expected Dwindle roots for fresh sync order test")
            return
        }

        #expect(forwardRoot.collectAllWindows() == forwardOrder.map(\.id))
        #expect(reverseRoot.collectAllWindows() == reverseOrder.map(\.id))
        #expect(forwardEngine.selectedNode(in: wsId)?.windowToken == handleC.id)
        #expect(reverseEngine.selectedNode(in: wsId)?.windowToken == handleA.id)

        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let forwardFrames = forwardEngine.calculateLayout(for: wsId, screen: screen)
        let reverseFrames = reverseEngine.calculateLayout(for: wsId, screen: screen)
        #expect(forwardFrames != reverseFrames)
    }

    @Test func selectionSurvivesSiblingCollapseAfterRemoval() {
        let engine = DwindleLayoutEngine()
        let wsId = UUID()
        let left = makeTestHandle(pid: 81)
        let right = makeTestHandle(pid: 82)

        _ = engine.syncWindows([left, right], in: wsId, focusedHandle: left)
        guard let rightNode = engine.findNode(for: right.id) else {
            Issue.record("Expected surviving sibling node for Dwindle removal regression test")
            return
        }

        engine.setSelectedNode(rightNode, in: wsId)
        engine.removeWindow(token: left.id, from: wsId)

        #expect(engine.selectedNode(in: wsId)?.windowToken == right.id)
        #expect(engine.toggleFullscreen(in: wsId) == right.id)
    }

    @Test func focusHitTestMissesEmptyWorkspace() {
        let engine = DwindleLayoutEngine()
        let wsId = UUID()

        #expect(engine.hitTestFocusableWindow(point: .zero, in: wsId, at: CACurrentMediaTime()) == nil)
    }

    @Test func focusHitTestReturnsMatchingLeaf() {
        let engine = DwindleLayoutEngine()
        let wsId = UUID()
        let firstHandle = makeTestHandle(pid: 51)
        let secondHandle = makeTestHandle(pid: 52)

        _ = engine.syncWindows([firstHandle, secondHandle], in: wsId, focusedHandle: firstHandle)
        let frames = engine.calculateLayout(
            for: wsId,
            screen: CGRect(x: 0, y: 0, width: 1600, height: 1000)
        )

        guard let secondFrame = frames[secondHandle.id] else {
            Issue.record("Expected a Dwindle frame for matching-leaf focus hit-test")
            return
        }

        #expect(
            engine.hitTestFocusableWindow(
                point: CGPoint(x: secondFrame.midX, y: secondFrame.midY),
                in: wsId,
                at: CACurrentMediaTime()
            ) == secondHandle.id
        )
    }

    @Test func focusHitTestPrefersFullscreenWindowOverCoveredTile() {
        let engine = DwindleLayoutEngine()
        let wsId = UUID()
        let coveredHandle = makeTestHandle(pid: 61)
        let fullscreenHandle = makeTestHandle(pid: 62)

        _ = engine.syncWindows([coveredHandle, fullscreenHandle], in: wsId, focusedHandle: fullscreenHandle)
        _ = engine.calculateLayout(
            for: wsId,
            screen: CGRect(x: 0, y: 0, width: 1600, height: 1000)
        )

        guard let fullscreenNode = engine.findNode(for: fullscreenHandle.id) else {
            Issue.record("Expected a fullscreen node for Dwindle focus hit-test")
            return
        }

        engine.setSelectedNode(fullscreenNode, in: wsId)
        #expect(engine.toggleFullscreen(in: wsId) == fullscreenHandle.id)

        let frames = engine.calculateLayout(
            for: wsId,
            screen: CGRect(x: 0, y: 0, width: 1600, height: 1000)
        )

        guard let coveredFrame = frames[coveredHandle.id],
              let fullscreenFrame = frames[fullscreenHandle.id]
        else {
            Issue.record("Expected covered and fullscreen frames for Dwindle focus hit-test")
            return
        }

        let overlapPoint = CGPoint(x: coveredFrame.midX, y: coveredFrame.midY)
        #expect(coveredFrame.contains(overlapPoint))
        #expect(fullscreenFrame.contains(overlapPoint))
        #expect(
            engine.hitTestFocusableWindow(
                point: overlapPoint,
                in: wsId,
                at: CACurrentMediaTime()
            ) == fullscreenHandle.id
        )
    }

    @Test func focusHitTestUsesPresentedFrameDuringAnimation() {
        let engine = DwindleLayoutEngine()
        let wsId = UUID()
        let handle = makeTestHandle(pid: 71)

        _ = engine.syncWindows([handle], in: wsId, focusedHandle: handle)
        let frames = engine.calculateLayout(
            for: wsId,
            screen: CGRect(x: 0, y: 0, width: 1600, height: 1000)
        )

        guard let baseFrame = frames[handle.id],
              let node = engine.findNode(for: handle.id)
        else {
            Issue.record("Expected Dwindle node state for animation-aware focus hit-test")
            return
        }

        let animatedStartFrame = baseFrame.offsetBy(dx: baseFrame.width + 120, dy: 0)
        node.animateFrom(
            oldFrame: animatedStartFrame,
            newFrame: baseFrame,
            clock: nil,
            config: CubicConfig(duration: 10.0)
        )

        let animatedPoint = CGPoint(x: animatedStartFrame.midX, y: animatedStartFrame.midY)
        #expect(baseFrame.contains(animatedPoint) == false)
        #expect(
            engine.hitTestFocusableWindow(
                point: animatedPoint,
                in: wsId,
                at: CACurrentMediaTime()
            ) == handle.id
        )
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

    @Test @MainActor func activeAnimationTickReappliesFocusedBorder() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for Dwindle border animation test")
            return
        }

        configureWorkspaceAsDwindle(on: controller, workspaceId: workspaceId)
        controller.enableDwindleLayout()
        controller.setBordersEnabled(true)
        await waitForLayoutPlanRefreshWork(on: controller)

        let firstToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 703)
        _ = controller.workspaceManager.setManagedFocus(firstToken, in: workspaceId, onMonitor: monitor.id)

        let initialPlans = try await controller.dwindleLayoutHandler.layoutWithDwindleEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 703)

        _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 704)
        let animationPlans = try await controller.dwindleLayoutHandler.layoutWithDwindleEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(animationPlans)
        #expect(controller.dwindleLayoutHandler.dwindleAnimationByDisplay[monitor.displayId]?.0 == workspaceId)

        controller.borderManager.hideBorder()
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == nil)

        controller.dwindleLayoutHandler.tickDwindleAnimation(
            targetTime: controller.animationClock.now(),
            displayId: monitor.displayId
        )

        #expect(controller.dwindleLayoutHandler.dwindleAnimationByDisplay[monitor.displayId]?.0 == workspaceId)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 703)
    }

    @Test @MainActor func fullscreenRelayoutSuppressesFocusedBorder() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or workspace for fullscreen border regression test")
            return
        }

        configureWorkspaceAsDwindle(on: controller, workspaceId: workspaceId)
        controller.enableDwindleLayout()
        controller.setBordersEnabled(true)
        await waitForLayoutPlanRefreshWork(on: controller)
        guard let engine = controller.dwindleEngine else {
            Issue.record("Missing Dwindle engine for fullscreen border regression test")
            return
        }

        let firstToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 707)
        _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 708)
        _ = controller.workspaceManager.setManagedFocus(firstToken, in: workspaceId, onMonitor: monitor.id)

        let initialPlans = try await controller.dwindleLayoutHandler.layoutWithDwindleEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 707)

        guard let fullscreenNode = engine.findNode(for: firstToken) else {
            Issue.record("Missing Dwindle node for fullscreen border regression test")
            return
        }

        engine.setSelectedNode(fullscreenNode, in: workspaceId)
        #expect(engine.toggleFullscreen(in: workspaceId) == firstToken)

        let fullscreenPlans = try await controller.dwindleLayoutHandler.layoutWithDwindleEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(fullscreenPlans)

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == nil)
        #expect(lastAppliedBorderFrameForLayoutPlanTests(on: controller) == nil)
    }

    @Test @MainActor func activeAnimationTickKeepsBorderHiddenDuringPreservedNonManagedFocus() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for Dwindle preserved-focus border test")
            return
        }

        configureWorkspaceAsDwindle(on: controller, workspaceId: workspaceId)
        controller.enableDwindleLayout()
        controller.setBordersEnabled(true)
        await waitForLayoutPlanRefreshWork(on: controller)

        let firstToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 705)
        _ = controller.workspaceManager.setManagedFocus(firstToken, in: workspaceId, onMonitor: monitor.id)

        let initialPlans = try await controller.dwindleLayoutHandler.layoutWithDwindleEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 705)

        _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 706)
        let animationPlans = try await controller.dwindleLayoutHandler.layoutWithDwindleEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(animationPlans)
        #expect(controller.dwindleLayoutHandler.dwindleAnimationByDisplay[monitor.displayId]?.0 == workspaceId)

        _ = controller.workspaceManager.enterNonManagedFocus(
            appFullscreen: false,
            preserveFocusedToken: true
        )
        controller.borderManager.hideBorder()
        #expect(controller.workspaceManager.focusedToken == firstToken)
        #expect(controller.workspaceManager.isNonManagedFocusActive)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == nil)

        controller.dwindleLayoutHandler.tickDwindleAnimation(
            targetTime: controller.animationClock.now(),
            displayId: monitor.displayId
        )

        #expect(controller.dwindleLayoutHandler.dwindleAnimationByDisplay[monitor.displayId]?.0 == workspaceId)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == nil)
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
        guard controller.workspaceManager.monitor(for: fixture.secondaryWorkspaceId)?.id == fixture.secondaryMonitor.id else {
            Issue.record("Expected the secondary workspace to remain assigned to the visible secondary monitor")
            return
        }
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

    @Test func summonWindowRightReinsertsWindowAsRightSibling() {
        let engine = DwindleLayoutEngine()
        let wsId = UUID()
        let anchor = makeTestHandle(pid: 81)
        let summoned = makeTestHandle(pid: 82)

        _ = engine.syncWindows([anchor, summoned], in: wsId, focusedHandle: anchor)
        _ = engine.calculateLayout(
            for: wsId,
            screen: CGRect(x: 0, y: 0, width: 1600, height: 1000)
        )

        let moved = engine.summonWindowRight(summoned.id, beside: anchor.id, in: wsId)
        let frames = engine.calculateLayout(
            for: wsId,
            screen: CGRect(x: 0, y: 0, width: 1600, height: 1000)
        )

        guard let anchorFrame = frames[anchor.id],
              let summonedFrame = frames[summoned.id]
        else {
            Issue.record("Expected both frames after Dwindle summon-right")
            return
        }

        #expect(moved)
        #expect(summonedFrame.minX >= anchorFrame.maxX - 1.0)
        #expect(engine.selectedNode(in: wsId)?.windowToken == summoned.id)
    }

    @Test func preselectionAddsCrossWorkspaceWindowAsRightSibling() {
        let engine = DwindleLayoutEngine()
        let targetWorkspaceId = UUID()
        let sourceWorkspaceId = UUID()
        let anchor = makeTestHandle(pid: 91)
        let summoned = makeTestHandle(pid: 92)
        let fallback = makeTestHandle(pid: 93)

        _ = engine.syncWindows([anchor], in: targetWorkspaceId, focusedHandle: anchor)
        _ = engine.syncWindows([summoned, fallback], in: sourceWorkspaceId, focusedHandle: summoned)
        _ = engine.calculateLayout(
            for: targetWorkspaceId,
            screen: CGRect(x: 0, y: 0, width: 1600, height: 1000)
        )
        _ = engine.calculateLayout(
            for: sourceWorkspaceId,
            screen: CGRect(x: 0, y: 0, width: 1600, height: 1000)
        )

        guard let anchorNode = engine.findNode(for: anchor.id) else {
            Issue.record("Expected anchor node for Dwindle cross-workspace summon")
            return
        }

        engine.setSelectedNode(anchorNode, in: targetWorkspaceId)
        engine.setPreselection(.right, in: targetWorkspaceId)
        engine.removeWindow(token: summoned.id, from: sourceWorkspaceId)
        _ = engine.syncWindows(
            [anchor.id, summoned.id],
            in: targetWorkspaceId,
            focusedToken: anchor.id
        )

        let targetFrames = engine.calculateLayout(
            for: targetWorkspaceId,
            screen: CGRect(x: 0, y: 0, width: 1600, height: 1000)
        )

        guard let anchorFrame = targetFrames[anchor.id],
              let summonedFrame = targetFrames[summoned.id]
        else {
            Issue.record("Expected target workspace frames after cross-workspace Dwindle summon")
            return
        }

        #expect(engine.windowCount(in: sourceWorkspaceId) == 1)
        #expect(summonedFrame.minX >= anchorFrame.maxX - 1.0)
    }
}

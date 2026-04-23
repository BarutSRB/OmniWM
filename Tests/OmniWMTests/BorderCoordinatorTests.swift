// SPDX-License-Identifier: GPL-2.0-only
import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

private func makeBorderCoordinatorFallbackTarget(
    pid: pid_t = getpid(),
    windowId: Int
) -> KeyboardFocusTarget {
    let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId)
    return KeyboardFocusTarget(
        token: WindowToken(pid: pid, windowId: windowId),
        axRef: axRef,
        workspaceId: nil,
        isManaged: false
    )
}

private func makeBorderCoordinatorWindowInfo(
    id: UInt32,
    pid: pid_t = getpid(),
    level: Int32 = 0,
    frame: CGRect = .zero,
    title: String? = nil,
    parentId: UInt32 = 0,
    attributes: UInt32 = 0x2
) -> WindowServerInfo {
    var info = WindowServerInfo(id: id, pid: pid, level: level, frame: frame)
    info.attributes = attributes
    info.parentId = parentId
    info.title = title
    return info
}

private func makeBorderCoordinatorWindowFacts(
    bundleId: String = "com.example.app",
    title: String? = nil,
    windowServer: WindowServerInfo? = nil
) -> WindowRuleFacts {
    WindowRuleFacts(
        appName: nil,
        ax: AXWindowFacts(
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            title: title,
            hasCloseButton: true,
            hasFullscreenButton: true,
            fullscreenButtonEnabled: true,
            hasZoomButton: true,
            hasMinimizeButton: true,
            appPolicy: .regular,
            bundleId: bundleId,
            attributeFetchSucceeded: true
        ),
        sizeConstraints: nil,
        windowServer: windowServer
    )
}

@MainActor
private func waitForBorderCoordinatorCondition(
    timeout: Duration = .seconds(1),
    step: Duration = .milliseconds(10),
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: step)
    }
    return condition()
}

@Suite(.serialized)
struct BorderCoordinatorTests {
    @Test @MainActor func fallbackLeaseExpiryRevalidatesCurrentFocusedTarget() async {
        let controller = makeLayoutPlanTestController()
        let target = makeBorderCoordinatorFallbackTarget(windowId: 901)
        let frame = CGRect(x: 32, y: 48, width: 640, height: 420)

        controller.setBordersEnabled(true)
        controller.focusBridge.setFocusedTarget(target)
        controller.borderCoordinator.fallbackLeaseDurationForTests = .milliseconds(20)
        controller.borderCoordinator.observedFrameProviderForTests = { _ in frame }
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 901 else { return nil }
            return makeBorderCoordinatorWindowInfo(id: windowId, frame: frame)
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            makeBorderCoordinatorWindowFacts(
                title: "fallback-window",
                windowServer: makeBorderCoordinatorWindowInfo(
                    id: UInt32(axRef.windowId),
                    frame: frame,
                    title: "fallback-window"
                )
            )
        }

        #expect(
            controller.borderCoordinator.reconcile(
                event: .renderRequested(
                    source: .manualRender,
                    target: target,
                    preferredFrame: nil,
                    policy: .direct
                )
            )
        )

        let observedRevalidation = await waitForBorderCoordinatorCondition(timeout: .seconds(5)) {
            return lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 901
        }
        #expect(observedRevalidation)
    }

    @Test @MainActor func fallbackLeaseExpiryExtendsDuringLiveMotion() async {
        let controller = makeLayoutPlanTestController()
        let target = makeBorderCoordinatorFallbackTarget(windowId: 902)
        let frame = CGRect(x: 44, y: 60, width: 520, height: 360)

        controller.setBordersEnabled(true)
        controller.focusBridge.setFocusedTarget(target)
        controller.borderCoordinator.fallbackLeaseDurationForTests = .milliseconds(20)
        controller.borderCoordinator.liveMotionIdleDurationForTests = .milliseconds(120)
        controller.borderCoordinator.observedFrameProviderForTests = { _ in frame }
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 902 else { return nil }
            return makeBorderCoordinatorWindowInfo(id: windowId, frame: frame)
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            makeBorderCoordinatorWindowFacts(
                title: "dragging-window",
                windowServer: makeBorderCoordinatorWindowInfo(
                    id: UInt32(axRef.windowId),
                    frame: frame,
                    title: "dragging-window"
                )
            )
        }

        #expect(
            controller.borderCoordinator.reconcile(
                event: .renderRequested(
                    source: .manualRender,
                    target: target,
                    preferredFrame: nil,
                    policy: .direct
                )
            )
        )
        #expect(controller.borderCoordinator.reconcile(event: .cgsFrameChanged(windowId: 902)))

        let observedLeaseExtension = await waitForBorderCoordinatorCondition(timeout: .seconds(5)) {
            return lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 902
        }
        #expect(observedLeaseExtension)
    }

    @Test @MainActor func staleFrameEventFromPreviousOwnerGenerationIsIgnored() {
        let controller = makeLayoutPlanTestController()
        let firstTarget = makeBorderCoordinatorFallbackTarget(windowId: 903)
        let secondTarget = makeBorderCoordinatorFallbackTarget(windowId: 904)
        let firstFrame = CGRect(x: 10, y: 20, width: 400, height: 300)
        let secondFrame = CGRect(x: 80, y: 70, width: 420, height: 320)

        controller.setBordersEnabled(true)
        controller.borderCoordinator.observedFrameProviderForTests = { axRef in
            switch axRef.windowId {
            case 903: firstFrame
            case 904: secondFrame
            default: nil
            }
        }
        controller.axEventHandler.windowInfoProvider = { windowId in
            switch windowId {
            case 903:
                return makeBorderCoordinatorWindowInfo(id: windowId, frame: firstFrame)
            case 904:
                return makeBorderCoordinatorWindowInfo(id: windowId, frame: secondFrame)
            default:
                return nil
            }
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            switch axRef.windowId {
            case 903:
                return makeBorderCoordinatorWindowFacts(
                    title: "first",
                    windowServer: makeBorderCoordinatorWindowInfo(
                        id: UInt32(axRef.windowId),
                        frame: firstFrame,
                        title: "first"
                    )
                )
            case 904:
                return makeBorderCoordinatorWindowFacts(
                    title: "second",
                    windowServer: makeBorderCoordinatorWindowInfo(
                        id: UInt32(axRef.windowId),
                        frame: secondFrame,
                        title: "second"
                    )
                )
            default:
                return makeBorderCoordinatorWindowFacts()
            }
        }

        controller.focusBridge.setFocusedTarget(firstTarget)
        #expect(
            controller.borderCoordinator.reconcile(
                event: .renderRequested(
                    source: .manualRender,
                    target: firstTarget,
                    preferredFrame: nil,
                    policy: .direct
                )
            )
        )

        controller.focusBridge.setFocusedTarget(secondTarget)
        #expect(
            controller.borderCoordinator.reconcile(
                event: .renderRequested(
                    source: .manualRender,
                    target: secondTarget,
                    preferredFrame: nil,
                    policy: .direct
                )
            )
        )

        #expect(!controller.borderCoordinator.reconcile(event: .cgsFrameChanged(windowId: 903)))

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 904)
    }

    @Test @MainActor func managedRenderUsesSafeFallbackOrderingWhenWindowServerPidMismatches() {
        let controller = makeLayoutPlanTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 905)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: getpid(),
            windowId: 905,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        let target = controller.keyboardFocusTarget(for: token, axRef: axRef)
        let frame = CGRect(x: 120, y: 96, width: 700, height: 520)
        controller.setBordersEnabled(true)
        controller.borderCoordinator.observedFrameProviderForTests = { _ in frame }
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 905 else { return nil }
            return makeBorderCoordinatorWindowInfo(
                id: windowId,
                pid: getpid() + 1,
                level: 8,
                frame: frame
            )
        }

        #expect(
            controller.borderCoordinator.reconcile(
                event: .renderRequested(
                    source: .manualRender,
                    target: target,
                    preferredFrame: nil,
                    policy: .direct
                )
            )
        )

        let ownerState = controller.borderCoordinator.ownerStateSnapshotForTests()
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 905)
        #expect(ownerState.resolvedWindowInfo == nil)
        #expect(ownerState.orderingDecision == "fallback:missing-window-server-info")
        #expect(
            ownerState.orderingMetadata
                == BorderOrderingMetadata.fallback(relativeTo: 905)
        )
    }

    @Test @MainActor func managedRenderUsesOverlayLevelForNormalWindowServerLevelZero() {
        let controller = makeLayoutPlanTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 907)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: getpid(),
            windowId: 907,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        let target = controller.keyboardFocusTarget(for: token, axRef: axRef)
        let frame = CGRect(x: 140, y: 100, width: 760, height: 540)
        controller.setBordersEnabled(true)
        controller.borderCoordinator.observedFrameProviderForTests = { _ in frame }
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 907 else { return nil }
            return makeBorderCoordinatorWindowInfo(
                id: windowId,
                level: 0,
                frame: frame
            )
        }

        #expect(
            controller.borderCoordinator.reconcile(
                event: .renderRequested(
                    source: .manualRender,
                    target: target,
                    preferredFrame: nil,
                    policy: .direct
                )
            )
        )

        let ownerState = controller.borderCoordinator.ownerStateSnapshotForTests()
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 907)
        #expect(ownerState.orderingMetadata?.level == 3)
        #expect(ownerState.orderingMetadata?.relativeTo == 907)
        #expect(ownerState.orderingMetadata?.order == .below)
        #expect(ownerState.orderingDecision.contains("overlay-level=3"))
    }

    @Test @MainActor func managedRenderPreservesCornerRadiusWhileUsingOverlayLevel() {
        let controller = makeLayoutPlanTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 908)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: getpid(),
            windowId: 908,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        let target = controller.keyboardFocusTarget(for: token, axRef: axRef)
        let frame = CGRect(x: 160, y: 120, width: 680, height: 480)
        controller.setBordersEnabled(true)
        controller.borderCoordinator.observedFrameProviderForTests = { _ in frame }
        controller.borderCoordinator.cornerRadiusProviderForTests = { windowId in
            windowId == 908 ? 18 : nil
        }
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 908 else { return nil }
            return makeBorderCoordinatorWindowInfo(
                id: windowId,
                level: 0,
                frame: frame
            )
        }

        #expect(
            controller.borderCoordinator.reconcile(
                event: .renderRequested(
                    source: .manualRender,
                    target: target,
                    preferredFrame: nil,
                    policy: .direct
                )
            )
        )

        let ownerState = controller.borderCoordinator.ownerStateSnapshotForTests()
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 908)
        #expect(ownerState.orderingMetadata?.level == 3)
        #expect(ownerState.orderingMetadata?.cornerRadius == 18)
        #expect(ownerState.orderingDecision.contains("overlay-level=3"))
        #expect(ownerState.orderingDecision.contains("corner-radius"))
    }

    @Test @MainActor func managedRenderReusesCachedEligibilityWhenPreferredFrameIsStable() {
        let controller = makeLayoutPlanTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 909)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: getpid(),
            windowId: 909,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        let frame = CGRect(x: 180, y: 140, width: 720, height: 520)
        var windowFactsLookups = 0


        controller.setBordersEnabled(true)
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 909 else { return nil }
            return makeBorderCoordinatorWindowInfo(
                id: windowId,
                level: 0,
                frame: frame
            )
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            windowFactsLookups += 1
            return makeBorderCoordinatorWindowFacts(
                title: "stable-managed-window",
                windowServer: makeBorderCoordinatorWindowInfo(
                    id: UInt32(axRef.windowId),
                    frame: frame,
                    title: "stable-managed-window"
                )
            )
        }

        let target = controller.keyboardFocusTarget(for: token, axRef: axRef)

        #expect(
            controller.borderCoordinator.reconcile(
                event: .renderRequested(
                    source: .manualRender,
                    target: target,
                    preferredFrame: frame,
                    policy: .coordinated
                )
            )
        )
        #expect(
            controller.borderCoordinator.reconcile(
                event: .renderRequested(
                    source: .manualRender,
                    target: target,
                    preferredFrame: frame,
                    policy: .coordinated
                )
            )
        )

        #expect(windowFactsLookups == 1)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 909)
    }

    @Test @MainActor func managedRenderReusesEligibilityWhenPreferredFrameChangesOutsideFastPathTolerance() {
        let controller = makeLayoutPlanTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 914)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: getpid(),
            windowId: 914,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        let firstFrame = CGRect(x: 200, y: 152, width: 720, height: 520)
        let secondFrame = CGRect(x: 208, y: 160, width: 720, height: 520)
        var windowFactsLookups = 0


        controller.setBordersEnabled(true)
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 914 else { return nil }
            return makeBorderCoordinatorWindowInfo(
                id: windowId,
                level: 0,
                frame: secondFrame
            )
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            windowFactsLookups += 1
            return makeBorderCoordinatorWindowFacts(
                title: "moving-managed-window",
                windowServer: makeBorderCoordinatorWindowInfo(
                    id: UInt32(axRef.windowId),
                    frame: secondFrame,
                    title: "moving-managed-window"
                )
            )
        }

        let target = controller.keyboardFocusTarget(for: token, axRef: axRef)

        #expect(
            controller.borderCoordinator.reconcile(
                event: .renderRequested(
                    source: .manualRender,
                    target: target,
                    preferredFrame: firstFrame,
                    policy: .coordinated
                )
            )
        )
        #expect(
            controller.borderCoordinator.reconcile(
                event: .renderRequested(
                    source: .manualRender,
                    target: target,
                    preferredFrame: secondFrame,
                    policy: .coordinated
                )
            )
        )

        #expect(windowFactsLookups == 1)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 914)
        #expect(lastAppliedBorderFrameForLayoutPlanTests(on: controller) == secondFrame)
    }

    @Test @MainActor func managedEligibilityCacheReusesFullscreenAndMinimizedState() {
        let controller = makeLayoutPlanTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 915)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: getpid(),
            windowId: 915,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        let firstFrame = CGRect(x: 220, y: 172, width: 720, height: 520)
        let secondFrame = CGRect(x: 230, y: 184, width: 720, height: 520)
        var windowFactsLookups = 0
        var fullscreenLookups = 0
        var minimizedLookups = 0


        controller.setBordersEnabled(true)
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 915 else { return nil }
            return makeBorderCoordinatorWindowInfo(
                id: windowId,
                level: 0,
                frame: secondFrame
            )
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            windowFactsLookups += 1
            return makeBorderCoordinatorWindowFacts(
                title: "probe-cached-window",
                windowServer: makeBorderCoordinatorWindowInfo(
                    id: UInt32(axRef.windowId),
                    frame: secondFrame,
                    title: "probe-cached-window"
                )
            )
        }
        controller.axEventHandler.isFullscreenProvider = { _ in
            fullscreenLookups += 1
            return false
        }
        controller.borderCoordinator.minimizedProviderForTests = { _ in
            minimizedLookups += 1
            return false
        }

        let target = controller.keyboardFocusTarget(for: token, axRef: axRef)

        #expect(
            controller.borderCoordinator.reconcile(
                event: .renderRequested(
                    source: .manualRender,
                    target: target,
                    preferredFrame: firstFrame,
                    policy: .coordinated
                )
            )
        )
        #expect(
            controller.borderCoordinator.reconcile(
                event: .renderRequested(
                    source: .manualRender,
                    target: target,
                    preferredFrame: secondFrame,
                    policy: .coordinated
                )
            )
        )

        #expect(windowFactsLookups == 1)
        #expect(fullscreenLookups == 1)
        #expect(minimizedLookups == 1)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 915)
        #expect(lastAppliedBorderFrameForLayoutPlanTests(on: controller) == secondFrame)
    }

    @Test @MainActor func orderingCacheRefreshesWhenCornerRadiusChanges() {
        let controller = makeLayoutPlanTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 916)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: getpid(),
            windowId: 916,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        let firstFrame = CGRect(x: 240, y: 188, width: 720, height: 520)
        let secondFrame = CGRect(x: 252, y: 198, width: 720, height: 520)
        var cornerRadiusLookups = 0
        var currentCornerRadius: CGFloat? = 18


        controller.setBordersEnabled(true)
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 916 else { return nil }
            return makeBorderCoordinatorWindowInfo(
                id: windowId,
                level: 0,
                frame: secondFrame
            )
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            makeBorderCoordinatorWindowFacts(
                title: "ordering-cache-window",
                windowServer: makeBorderCoordinatorWindowInfo(
                    id: UInt32(axRef.windowId),
                    frame: secondFrame,
                    title: "ordering-cache-window"
                )
            )
        }
        controller.borderCoordinator.cornerRadiusProviderForTests = { windowId in
            guard windowId == 916 else { return nil }
            cornerRadiusLookups += 1
            return currentCornerRadius
        }

        let target = controller.keyboardFocusTarget(for: token, axRef: axRef)

        #expect(
            controller.borderCoordinator.reconcile(
                event: .renderRequested(
                    source: .manualRender,
                    target: target,
                    preferredFrame: firstFrame,
                    policy: .coordinated
                )
            )
        )
        currentCornerRadius = 24
        #expect(
            controller.borderCoordinator.reconcile(
                event: .renderRequested(
                    source: .manualRender,
                    target: target,
                    preferredFrame: secondFrame,
                    policy: .coordinated
                )
            )
        )

        let ownerState = controller.borderCoordinator.ownerStateSnapshotForTests()
        #expect(cornerRadiusLookups == 2)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 916)
        #expect(lastAppliedBorderFrameForLayoutPlanTests(on: controller) == secondFrame)
        #expect(ownerState.orderingMetadata?.cornerRadius == 24)
    }

    @Test @MainActor func representativeInvalidationSourcesForceManagedCacheReevaluation() {
        @MainActor
        func assertInvalidation(source: BorderReconcileSource, windowId: Int) {
            let controller = makeLayoutPlanTestController()
            guard let workspaceId = controller.activeWorkspace()?.id else {
                Issue.record("Missing active workspace")
                return
            }

            let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId)
            let token = controller.workspaceManager.addWindow(
                axRef,
                pid: getpid(),
                windowId: windowId,
                to: workspaceId
            )
            _ = controller.workspaceManager.setManagedFocus(
                token,
                in: workspaceId,
                onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
            )

            let firstFrame = CGRect(x: 276, y: 212, width: 720, height: 520)
            let secondFrame = CGRect(x: 288, y: 224, width: 720, height: 520)
            var windowFactsLookups = 0
            var fullscreenLookups = 0
            var minimizedLookups = 0
            var cornerRadiusLookups = 0
            var currentCornerRadius: CGFloat? = 18


            controller.setBordersEnabled(true)
            controller.axEventHandler.windowInfoProvider = { requestedWindowId in
                guard requestedWindowId == windowId else { return nil }
                return makeBorderCoordinatorWindowInfo(
                    id: requestedWindowId,
                    level: 0,
                    frame: secondFrame
                )
            }
            controller.axEventHandler.windowFactsProvider = { axRef, _ in
                windowFactsLookups += 1
                return makeBorderCoordinatorWindowFacts(
                    title: "invalidate-\(windowId)",
                    windowServer: makeBorderCoordinatorWindowInfo(
                        id: UInt32(axRef.windowId),
                        frame: secondFrame,
                        title: "invalidate-\(windowId)"
                    )
                )
            }
            controller.axEventHandler.isFullscreenProvider = { _ in
                fullscreenLookups += 1
                return false
            }
            controller.borderCoordinator.minimizedProviderForTests = { _ in
                minimizedLookups += 1
                return false
            }
            controller.borderCoordinator.cornerRadiusProviderForTests = { requestedWindowId in
                guard requestedWindowId == windowId else { return nil }
                cornerRadiusLookups += 1
                return currentCornerRadius
            }

            let target = controller.keyboardFocusTarget(for: token, axRef: axRef)
            #expect(
                controller.borderCoordinator.reconcile(
                    event: .renderRequested(
                        source: .manualRender,
                        target: target,
                        preferredFrame: firstFrame,
                        policy: .coordinated
                    )
                )
            )

            currentCornerRadius = 26

            #expect(
                controller.borderCoordinator.reconcile(
                    event: .renderRequested(
                        source: source,
                        target: target,
                        preferredFrame: secondFrame,
                        policy: .coordinated
                    )
                )
            )

            let ownerState = controller.borderCoordinator.ownerStateSnapshotForTests()
            #expect(windowFactsLookups == 2)
            #expect(fullscreenLookups == 2)
            #expect(minimizedLookups == 2)
            #expect(cornerRadiusLookups == 2)
            #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == windowId)
            #expect(lastAppliedBorderFrameForLayoutPlanTests(on: controller) == secondFrame)
            #expect(ownerState.orderingMetadata?.cornerRadius == 26)
        }

        assertInvalidation(source: .workspaceActivation, windowId: 918)
        assertInvalidation(source: .activeSpaceChanged, windowId: 919)
        assertInvalidation(source: .nativeFullscreenExit, windowId: 920)
    }

    @Test @MainActor func managedRekeyForcesManagedCacheReevaluation() {
        let controller = makeLayoutPlanTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let oldAxRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 921)
        let oldToken = controller.workspaceManager.addWindow(
            oldAxRef,
            pid: getpid(),
            windowId: 921,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            oldToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        let newAxRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 922)
        let newToken = WindowToken(pid: getpid(), windowId: 922)
        let firstFrame = CGRect(x: 300, y: 236, width: 720, height: 520)
        let secondFrame = CGRect(x: 312, y: 248, width: 720, height: 520)
        var windowFactsLookups = 0
        var fullscreenLookups = 0
        var minimizedLookups = 0
        var cornerRadiusLookups = 0


        controller.setBordersEnabled(true)
        controller.axEventHandler.windowInfoProvider = { windowId in
            switch windowId {
            case 921:
                return makeBorderCoordinatorWindowInfo(
                    id: windowId,
                    level: 0,
                    frame: firstFrame
                )
            case 922:
                return makeBorderCoordinatorWindowInfo(
                    id: windowId,
                    level: 0,
                    frame: secondFrame
                )
            default:
                return nil
            }
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            windowFactsLookups += 1
            let frame = axRef.windowId == 921 ? firstFrame : secondFrame
            return makeBorderCoordinatorWindowFacts(
                title: "rekey-\(axRef.windowId)",
                windowServer: makeBorderCoordinatorWindowInfo(
                    id: UInt32(axRef.windowId),
                    frame: frame,
                    title: "rekey-\(axRef.windowId)"
                )
            )
        }
        controller.axEventHandler.isFullscreenProvider = { _ in
            fullscreenLookups += 1
            return false
        }
        controller.borderCoordinator.minimizedProviderForTests = { _ in
            minimizedLookups += 1
            return false
        }
        controller.borderCoordinator.cornerRadiusProviderForTests = { windowId in
            switch windowId {
            case 921:
                cornerRadiusLookups += 1
                return 14
            case 922:
                cornerRadiusLookups += 1
                return 24
            default:
                return nil
            }
        }

        let target = controller.keyboardFocusTarget(for: oldToken, axRef: oldAxRef)
        #expect(
            controller.borderCoordinator.reconcile(
                event: .renderRequested(
                    source: .manualRender,
                    target: target,
                    preferredFrame: firstFrame,
                    policy: .coordinated
                )
            )
        )

        guard controller.workspaceManager.rekeyWindow(
            from: oldToken,
            to: newToken,
            newAXRef: newAxRef
        ) != nil else {
            Issue.record("Failed to rekey managed window")
            return
        }

        #expect(
            controller.borderCoordinator.reconcile(
                event: .managedRekey(
                    from: oldToken,
                    to: newToken,
                    workspaceId: workspaceId,
                    axRef: newAxRef,
                    preferredFrame: secondFrame,
                    policy: .coordinated
                )
            )
        )

        let ownerState = controller.borderCoordinator.ownerStateSnapshotForTests()
        #expect(windowFactsLookups == 2)
        #expect(fullscreenLookups == 2)
        #expect(minimizedLookups == 2)
        #expect(cornerRadiusLookups == 2)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 922)
        #expect(lastAppliedBorderFrameForLayoutPlanTests(on: controller) == secondFrame)
        #expect(ownerState.owner == .managed(token: newToken, wid: 922, workspaceId: workspaceId))
        #expect(ownerState.orderingMetadata?.cornerRadius == 24)
    }

    @Test @MainActor func cgsFrameChangeDoesNotPolluteRenderRequestedMetrics() {
        let controller = makeLayoutPlanTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 917)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: getpid(),
            windowId: 917,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        let frame = CGRect(x: 264, y: 204, width: 720, height: 520)


        controller.setBordersEnabled(true)
        controller.focusBridge.setFocusedTarget(controller.keyboardFocusTarget(for: token, axRef: axRef))
        controller.borderCoordinator.observedFrameProviderForTests = { _ in frame }
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 917 else { return nil }
            return makeBorderCoordinatorWindowInfo(
                id: windowId,
                level: 0,
                frame: frame
            )
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            makeBorderCoordinatorWindowFacts(
                title: "frame-change-window",
                windowServer: makeBorderCoordinatorWindowInfo(
                    id: UInt32(axRef.windowId),
                    frame: frame,
                    title: "frame-change-window"
                )
            )
        }

        let target = controller.keyboardFocusTarget(for: token, axRef: axRef)
        #expect(
            controller.borderCoordinator.reconcile(
                event: .renderRequested(
                    source: .manualRender,
                    target: target,
                    preferredFrame: nil,
                    policy: .direct
                )
            )
        )

        #expect(controller.borderCoordinator.reconcile(event: .cgsFrameChanged(windowId: 917)))

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 917)
    }

    @Test @MainActor func managedRenderInvalidatesCachedEligibilityWhenWindowServerMetadataChanges() {
        let controller = makeLayoutPlanTestController()
        guard let workspaceId = controller.activeWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 910)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: getpid(),
            windowId: 910,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(
            token,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        let frame = CGRect(x: 188, y: 144, width: 700, height: 500)
        var parentId: UInt32 = 0
        var windowFactsLookups = 0

        controller.setBordersEnabled(true)
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 910 else { return nil }
            return makeBorderCoordinatorWindowInfo(
                id: windowId,
                level: 0,
                frame: frame,
                parentId: parentId
            )
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            windowFactsLookups += 1
            return makeBorderCoordinatorWindowFacts(
                title: "managed-window",
                windowServer: makeBorderCoordinatorWindowInfo(
                    id: UInt32(axRef.windowId),
                    level: 0,
                    frame: frame,
                    title: "managed-window",
                    parentId: parentId
                )
            )
        }

        let target = controller.keyboardFocusTarget(for: token, axRef: axRef)

        #expect(
            controller.borderCoordinator.reconcile(
                event: .renderRequested(
                    source: .manualRender,
                    target: target,
                    preferredFrame: frame,
                    policy: .coordinated
                )
            )
        )
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 910)

        parentId = 1

        #expect(
            controller.borderCoordinator.reconcile(
                event: .renderRequested(
                    source: .manualRender,
                    target: target,
                    preferredFrame: frame,
                    policy: .coordinated
                )
            )
        )

        let ownerState = controller.borderCoordinator.ownerStateSnapshotForTests()
        #expect(windowFactsLookups == 2)
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 910)
        #expect(ownerState.owner == .managed(token: token, wid: 910, workspaceId: workspaceId))
        #expect(ownerState.resolvedWindowInfo?.parentId == 1)
        #expect(ownerState.orderingDecision == "fallback:missing-window-server-info")
    }

    @Test @MainActor func fallbackSubscriptionIsRequestedOnlyOncePerWindow() {
        let controller = makeLayoutPlanTestController()
        let target = makeBorderCoordinatorFallbackTarget(windowId: 911)
        let frame = CGRect(x: 28, y: 36, width: 500, height: 340)
        var subscriptions: [[UInt32]] = []

        controller.setBordersEnabled(true)
        controller.borderCoordinator.observedFrameProviderForTests = { _ in frame }
        controller.axEventHandler.windowSubscriptionHandler = { windowIds in
            subscriptions.append(windowIds)
        }
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 911 else { return nil }
            return makeBorderCoordinatorWindowInfo(id: windowId, frame: frame)
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            makeBorderCoordinatorWindowFacts(
                title: "fallback-window",
                windowServer: makeBorderCoordinatorWindowInfo(
                    id: UInt32(axRef.windowId),
                    frame: frame,
                    title: "fallback-window"
                )
            )
        }

        #expect(
            controller.borderCoordinator.reconcile(
                event: .renderRequested(
                    source: .manualRender,
                    target: target,
                    preferredFrame: nil,
                    policy: .direct
                )
            )
        )
        #expect(
            controller.borderCoordinator.hideBorder(
                source: .manualRender,
                reason: "clear test state"
            ) == false
        )
        #expect(
            controller.borderCoordinator.reconcile(
                event: .renderRequested(
                    source: .manualRender,
                    target: target,
                    preferredFrame: nil,
                    policy: .direct
                )
            )
        )

        #expect(subscriptions == [[911]])
    }

    @Test @MainActor func fallbackSubscriptionStateClearsWhenOwnershipIsReleasedWithoutUnderlyingUnsubscribe() {
        let controller = makeLayoutPlanTestController()
        let target = makeBorderCoordinatorFallbackTarget(windowId: 912)
        let frame = CGRect(x: 34, y: 42, width: 520, height: 360)
        let observer = CGSEventObserver.shared
        var subscriptions: [[UInt32]] = []
        var unsubscriptions: [[UInt32]] = []

        controller.setBordersEnabled(true)
        controller.borderCoordinator.observedFrameProviderForTests = { _ in frame }
        observer.resetDebugStateForTests()
        observer.windowNotificationRequestHandlerForTests = { windowIds in
            subscriptions.append(windowIds)
            return true
        }
        observer.windowNotificationUnrequestHandlerForTests = { windowIds in
            unsubscriptions.append(windowIds)
            return nil
        }
        defer { observer.resetDebugStateForTests() }
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 912 else { return nil }
            return makeBorderCoordinatorWindowInfo(id: windowId, frame: frame)
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            makeBorderCoordinatorWindowFacts(
                title: "sticky-fallback-window",
                windowServer: makeBorderCoordinatorWindowInfo(
                    id: UInt32(axRef.windowId),
                    frame: frame,
                    title: "sticky-fallback-window"
                )
            )
        }

        #expect(
            controller.borderCoordinator.reconcile(
                event: .renderRequested(
                    source: .manualRender,
                    target: target,
                    preferredFrame: nil,
                    policy: .direct
                )
            )
        )
        #expect(
            controller.borderCoordinator.hideBorder(
                source: .manualRender,
                reason: "clear test state"
            ) == false
        )

        let ownerStateAfterHide = controller.borderCoordinator.ownerStateSnapshotForTests()
        #expect(ownerStateAfterHide.fallbackSubscribedWindowIds.isEmpty)

        #expect(
            controller.borderCoordinator.reconcile(
                event: .renderRequested(
                    source: .manualRender,
                    target: target,
                    preferredFrame: nil,
                    policy: .direct
                )
            )
        )

        #expect(subscriptions == [[912]])
        #expect(unsubscriptions == [[912]])
    }

    @Test @MainActor func fallbackSubscriptionStateClearsWhenUnderlyingUnsubscribeRemovesWindow() {
        let controller = makeLayoutPlanTestController()
        let target = makeBorderCoordinatorFallbackTarget(windowId: 913)
        let frame = CGRect(x: 40, y: 48, width: 540, height: 380)
        let observer = CGSEventObserver.shared
        var subscriptions: [[UInt32]] = []
        var unsubscriptions: [[UInt32]] = []

        controller.setBordersEnabled(true)
        controller.borderCoordinator.observedFrameProviderForTests = { _ in frame }
        observer.resetDebugStateForTests()
        observer.windowNotificationRequestHandlerForTests = { windowIds in
            subscriptions.append(windowIds)
            return true
        }
        observer.windowNotificationUnrequestHandlerForTests = { windowIds in
            unsubscriptions.append(windowIds)
            return true
        }
        defer { observer.resetDebugStateForTests() }
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 913 else { return nil }
            return makeBorderCoordinatorWindowInfo(id: windowId, frame: frame)
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            makeBorderCoordinatorWindowFacts(
                title: "releasable-fallback-window",
                windowServer: makeBorderCoordinatorWindowInfo(
                    id: UInt32(axRef.windowId),
                    frame: frame,
                    title: "releasable-fallback-window"
                )
            )
        }

        #expect(
            controller.borderCoordinator.reconcile(
                event: .renderRequested(
                    source: .manualRender,
                    target: target,
                    preferredFrame: nil,
                    policy: .direct
                )
            )
        )
        #expect(
            controller.borderCoordinator.hideBorder(
                source: .manualRender,
                reason: "clear test state"
            ) == false
        )

        let ownerStateAfterHide = controller.borderCoordinator.ownerStateSnapshotForTests()
        #expect(ownerStateAfterHide.fallbackSubscribedWindowIds.isEmpty)

        #expect(
            controller.borderCoordinator.reconcile(
                event: .renderRequested(
                    source: .manualRender,
                    target: target,
                    preferredFrame: nil,
                    policy: .direct
                )
            )
        )

        #expect(subscriptions == [[913], [913]])
        #expect(unsubscriptions == [[913]])
    }

}

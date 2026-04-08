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

        let observedRevalidation = await waitForBorderCoordinatorCondition {
            let trace = controller.borderCoordinator.traceSnapshotForTests()
            return lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 901
                && trace.contains {
                    $0.source == .fallbackLeaseExpired
                        && $0.action == .update
                        && $0.reason == "fallback lease revalidated"
                }
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

        let observedLeaseExtension = await waitForBorderCoordinatorCondition {
            let trace = controller.borderCoordinator.traceSnapshotForTests()
            return lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 902
                && trace.contains {
                    $0.source == .fallbackLeaseExpired
                        && $0.action == .ignore
                        && $0.reason == "lease extended during live motion"
                }
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

        let trace = controller.borderCoordinator.traceSnapshotForTests()
        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 904)
        #expect(trace.last?.source == .cgsFrameChanged)
        #expect(trace.last?.action == .ignore)
        #expect(trace.last?.reason == "stale frame event")
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

    @Test @MainActor func traceBufferStaysBoundedAndTitleFree() {
        let controller = makeLayoutPlanTestController()
        let target = makeBorderCoordinatorFallbackTarget(windowId: 906)
        let frame = CGRect(x: 12, y: 14, width: 340, height: 220)
        let secretTitle = "Secret Border Title"

        controller.setBordersEnabled(true)
        controller.borderCoordinator.observedFrameProviderForTests = { _ in frame }
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == 906 else { return nil }
            return makeBorderCoordinatorWindowInfo(
                id: windowId,
                frame: frame,
                title: secretTitle
            )
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            makeBorderCoordinatorWindowFacts(
                title: secretTitle,
                windowServer: makeBorderCoordinatorWindowInfo(
                    id: UInt32(axRef.windowId),
                    frame: frame,
                    title: secretTitle
                )
            )
        }

        for _ in 0..<140 {
            controller.focusBridge.setFocusedTarget(target)
            _ = controller.borderCoordinator.reconcile(
                event: .renderRequested(
                    source: .manualRender,
                    target: target,
                    preferredFrame: nil,
                    policy: .direct
                )
            )
        }

        let trace = controller.borderCoordinator.traceSnapshotForTests()
        #expect(trace.count == 128)
        #expect(trace.allSatisfy { ($0.rawFocus ?? "").contains(secretTitle) == false })
        #expect(trace.last?.rawFocus == "pid=\(getpid()) wid=906")
    }
}

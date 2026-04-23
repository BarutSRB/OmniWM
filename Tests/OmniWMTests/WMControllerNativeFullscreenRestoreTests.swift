// SPDX-License-Identifier: GPL-2.0-only
import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

@Suite(.serialized) struct WMControllerNativeFullscreenRestoreTests {
    // When a window is first observed already in macOS native fullscreen
    // (e.g. app launches fullscreen, Space handoff races our attach), the
    // managed restore snapshot ends up holding the display rect as the
    // "pre-fullscreen" frame. If we trusted it, the toggle-out-of-fullscreen
    // restore would be a visual no-op. The seed resolver is supposed to
    // notice this (via the cached niri state reporting a non-full-width
    // column) and fall through to the pre-fullscreen tile frame we still
    // have in AX. Regression test that guard.
    @Test @MainActor func `suspend seed skips managed snapshot frame when it matches display bounds and niri indicates tiled column`() {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller
        let monitor = fixture.primaryMonitor
        let workspaceId = fixture.primaryWorkspaceId
        let windowId = 8_401
        let token = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: workspaceId,
            windowId: windowId
        )

        // Simulate the tile frame that was already applied to the window
        // before macOS put it into fullscreen — this is the frame the
        // fallback (`preservedManagedGeometryFrame` → `axManager.lastAppliedFrame`)
        // should surface once the display-bounds guard trips.
        let tileFrame = CGRect(x: 160, y: 120, width: 800, height: 600)
        controller.axManager.applyFramesParallel([(token.pid, token.windowId, tileFrame)])

        // Plant the poisoned managed snapshot: frame == display.visibleFrame
        // but the paired niri state reports a normal tile (isFullWidth=false
        // at a 50% column width). This is the exact shape seen in the bug
        // logs for pid=69017 wid=32111.
        let poisonedNiriState = ManagedWindowRestoreSnapshot.NiriState(
            nodeId: nil,
            columnIndex: 0,
            tileIndex: 0,
            columnWindowTokens: [token],
            columnSizing: .init(
                width: .proportion(0.5),
                cachedWidth: tileFrame.width,
                presetWidthIdx: nil,
                isFullWidth: false,
                savedWidth: nil,
                hasManualSingleWindowWidthOverride: false,
                height: .proportion(1.0),
                cachedHeight: tileFrame.height,
                isFullHeight: false,
                savedHeight: nil
            ),
            windowSizing: .init(
                height: .auto(weight: 1.0),
                savedHeight: nil,
                windowWidth: .auto(weight: 1.0),
                sizingMode: .normal
            )
        )
        let poisonedSnapshot = ManagedWindowRestoreSnapshot(
            token: token,
            workspaceId: workspaceId,
            frame: monitor.visibleFrame,
            topologyProfile: controller.workspaceManager.topologyProfile,
            niriState: poisonedNiriState,
            replacementMetadata: nil
        )
        #expect(
            controller.workspaceManager.setManagedRestoreSnapshot(
                poisonedSnapshot,
                for: token
            )
        )

        _ = controller.suspendManagedWindowForNativeFullscreen(
            token,
            path: .directActivationEnter
        )

        let restoreFrame = controller.workspaceManager
            .nativeFullscreenRecord(for: token)?
            .restoreSnapshot?
            .frame
        #expect(restoreFrame != nil, "suspend should have produced a restore snapshot")
        if let restoreFrame {
            #expect(
                !restoreFrame.approximatelyEqual(
                    to: monitor.visibleFrame,
                    tolerance: 1.0
                ),
                "restore frame must not stay at the display bounds; got \(restoreFrame)"
            )
            #expect(
                restoreFrame.approximatelyEqual(to: tileFrame, tolerance: 1.0),
                "restore frame should fall back to the AX-observed tile frame; got \(restoreFrame)"
            )
        }
    }

    // Same guard must NOT fire when the managed snapshot frame equals the
    // display bounds but niri actually reports a full-width column (e.g. the
    // user genuinely asked niri for a fullscreen-width column that happens
    // to coincide with the display rect). In that case the managed-snapshot
    // branch is correct and should be preserved.
    @Test @MainActor func `suspend seed keeps managed snapshot frame when niri indicates full width column`() {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller
        let monitor = fixture.primaryMonitor
        let workspaceId = fixture.primaryWorkspaceId
        let windowId = 8_402
        let token = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: workspaceId,
            windowId: windowId
        )

        controller.axManager.applyFramesParallel([
            (token.pid, token.windowId, monitor.visibleFrame)
        ])

        let fullWidthNiriState = ManagedWindowRestoreSnapshot.NiriState(
            nodeId: nil,
            columnIndex: 0,
            tileIndex: 0,
            columnWindowTokens: [token],
            columnSizing: .init(
                width: .proportion(1.0),
                cachedWidth: monitor.visibleFrame.width,
                presetWidthIdx: nil,
                isFullWidth: true,
                savedWidth: nil,
                hasManualSingleWindowWidthOverride: false,
                height: .proportion(1.0),
                cachedHeight: monitor.visibleFrame.height,
                isFullHeight: false,
                savedHeight: nil
            ),
            windowSizing: .init(
                height: .auto(weight: 1.0),
                savedHeight: nil,
                windowWidth: .auto(weight: 1.0),
                sizingMode: .normal
            )
        )
        let legitimateSnapshot = ManagedWindowRestoreSnapshot(
            token: token,
            workspaceId: workspaceId,
            frame: monitor.visibleFrame,
            topologyProfile: controller.workspaceManager.topologyProfile,
            niriState: fullWidthNiriState,
            replacementMetadata: nil
        )
        #expect(
            controller.workspaceManager.setManagedRestoreSnapshot(
                legitimateSnapshot,
                for: token
            )
        )

        _ = controller.suspendManagedWindowForNativeFullscreen(
            token,
            path: .directActivationEnter
        )

        let restoreFrame = controller.workspaceManager
            .nativeFullscreenRecord(for: token)?
            .restoreSnapshot?
            .frame
        #expect(restoreFrame != nil)
        if let restoreFrame {
            #expect(
                restoreFrame.approximatelyEqual(
                    to: monitor.visibleFrame,
                    tolerance: 1.0
                ),
                "legitimate full-width column should keep the display-sized seed frame; got \(restoreFrame)"
            )
        }
    }

    // Once the record is already suspended with a seeded snapshot, follow-up
    // suspend calls (from the periodic rescan and from repeated AX
    // fullscreen-change notifications) must short-circuit so they do not
    // re-run seed resolution or re-log `suspend`.
    @Test @MainActor func `repeated suspend calls short circuit once the record is suspended`() {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller
        let monitor = fixture.primaryMonitor
        let workspaceId = fixture.primaryWorkspaceId
        let windowId = 8_403
        let token = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: workspaceId,
            windowId: windowId
        )

        let tileFrame = CGRect(x: 200, y: 100, width: 900, height: 600)
        controller.axManager.applyFramesParallel([(token.pid, token.windowId, tileFrame)])

        let initialNiriState = ManagedWindowRestoreSnapshot.NiriState(
            nodeId: nil,
            columnIndex: 0,
            tileIndex: 0,
            columnWindowTokens: [token],
            columnSizing: .init(
                width: .proportion(0.5),
                cachedWidth: tileFrame.width,
                presetWidthIdx: nil,
                isFullWidth: false,
                savedWidth: nil,
                hasManualSingleWindowWidthOverride: false,
                height: .proportion(1.0),
                cachedHeight: tileFrame.height,
                isFullHeight: false,
                savedHeight: nil
            ),
            windowSizing: .init(
                height: .auto(weight: 1.0),
                savedHeight: nil,
                windowWidth: .auto(weight: 1.0),
                sizingMode: .normal
            )
        )
        #expect(
            controller.workspaceManager.setManagedRestoreSnapshot(
                ManagedWindowRestoreSnapshot(
                    token: token,
                    workspaceId: workspaceId,
                    frame: tileFrame,
                    topologyProfile: controller.workspaceManager.topologyProfile,
                    niriState: initialNiriState,
                    replacementMetadata: nil
                ),
                for: token
            )
        )

        let first = controller.suspendManagedWindowForNativeFullscreen(
            token,
            path: .directActivationEnter
        )
        #expect(first, "first suspend should record the native fullscreen state")

        let second = controller.suspendManagedWindowForNativeFullscreen(
            token,
            path: .fullRescanExistingEntryFullscreen
        )
        #expect(second == false, "second suspend while already suspended must short-circuit")

        let third = controller.suspendManagedWindowForNativeFullscreen(
            token,
            path: .directActivationEnter
        )
        #expect(third == false, "third suspend (repeated AX notification) must short-circuit")

        _ = monitor  // silence unused warning if dropped
    }

    @Test @MainActor func `rekey migrates cached niri column members to replacement token`() {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller
        let workspaceId = fixture.primaryWorkspaceId
        let originalToken = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: workspaceId,
            windowId: 8_404
        )
        let siblingToken = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: workspaceId,
            windowId: 8_405
        )

        controller.setLastKnownNiriStateForTests(
            ManagedWindowRestoreSnapshot.NiriState(
                nodeId: nil,
                columnIndex: 0,
                tileIndex: 0,
                columnWindowTokens: [originalToken, siblingToken],
                columnSizing: .init(
                    width: .proportion(0.5),
                    cachedWidth: 820,
                    presetWidthIdx: nil,
                    isFullWidth: false,
                    savedWidth: nil,
                    hasManualSingleWindowWidthOverride: false,
                    height: .proportion(1.0),
                    cachedHeight: 580,
                    isFullHeight: false,
                    savedHeight: nil
                ),
                windowSizing: .init(
                    height: .auto(weight: 1.0),
                    savedHeight: nil,
                    windowWidth: .auto(weight: 1.0),
                    sizingMode: .normal
                )
            ),
            for: originalToken
        )
        #expect(
            controller.lastKnownNiriStateForTests(token: originalToken)?.columnWindowTokens
                == [originalToken, siblingToken]
        )

        let replacementToken = WindowToken(pid: originalToken.pid, windowId: 8_406)
        #expect(
            controller.workspaceManager.rekeyWindow(
                from: originalToken,
                to: replacementToken,
                newAXRef: makeLayoutPlanTestWindow(windowId: replacementToken.windowId)
            ) != nil
        )

        #expect(controller.lastKnownNiriStateForTests(token: originalToken) == nil)
        #expect(
            controller.lastKnownNiriStateForTests(token: replacementToken)?.columnWindowTokens
                == [replacementToken, siblingToken]
        )
    }

    @Test @MainActor func `native fullscreen seed ignores cached niri state from another workspace`() {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller
        let primaryToken = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: fixture.primaryWorkspaceId,
            windowId: 8_407
        )
        let secondaryToken = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: fixture.secondaryWorkspaceId,
            windowId: 8_408
        )

        let staleNiriState = ManagedWindowRestoreSnapshot.NiriState(
            nodeId: nil,
            columnIndex: 0,
            tileIndex: 0,
            columnWindowTokens: [primaryToken, secondaryToken],
            columnSizing: .init(
                width: .proportion(0.5),
                cachedWidth: 820,
                presetWidthIdx: nil,
                isFullWidth: false,
                savedWidth: nil,
                hasManualSingleWindowWidthOverride: false,
                height: .proportion(1.0),
                cachedHeight: 580,
                isFullHeight: false,
                savedHeight: nil
            ),
            windowSizing: .init(
                height: .auto(weight: 1.0),
                savedHeight: nil,
                windowWidth: .auto(weight: 1.0),
                sizingMode: .normal
            )
        )
        controller.setLastKnownNiriStateForTests(
            staleNiriState,
            for: primaryToken,
            workspaceId: fixture.secondaryWorkspaceId
        )

        let fallbackFrame = CGRect(x: 140, y: 100, width: 780, height: 540)
        controller.axManager.applyFramesParallel([
            (primaryToken.pid, primaryToken.windowId, fallbackFrame)
        ])

        let restoreSnapshot = controller.captureNativeFullscreenRestoreSnapshot(for: primaryToken)
        #expect(restoreSnapshot?.frame.approximatelyEqual(to: fallbackFrame, tolerance: 1.0) == true)
        #expect(restoreSnapshot?.niriState == nil)
    }
}

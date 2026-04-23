// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation
import Testing

@testable import OmniWM

private func makeQuakeTerminalTestDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.quake-terminal-focus.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

@MainActor
private func makeQuakeTerminalTestController(
    autoHide: Bool = false,
    captureRestoreTarget: @escaping @MainActor () -> QuakeTerminalRestoreTarget?,
    restoreFocusTarget: @escaping @MainActor (QuakeTerminalRestoreTarget) -> Void,
    isWindowFocused: @escaping @MainActor (NSWindow) -> Bool
) -> QuakeTerminalController {
    let settings = SettingsStore(defaults: makeQuakeTerminalTestDefaults())
    settings.animationsEnabled = false
    settings.quakeTerminalUseCustomFrame = true
    settings.quakeTerminalAutoHide = autoHide

    return QuakeTerminalController(
        settings: settings,
        motionPolicy: MotionPolicy(animationsEnabled: false),
        captureRestoreTarget: captureRestoreTarget,
        restoreFocusTarget: restoreFocusTarget,
        isWindowFocused: isWindowFocused
    )
}

private func makeManagedRestoreTarget(
    pid: pid_t,
    windowId: Int
) -> QuakeTerminalRestoreTarget {
    .managed(WindowToken(pid: pid, windowId: windowId))
}

private final class QuakeTerminalFocusBox<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

@MainActor
private func settleQuakeTerminalFocusUpdates() async {
    for _ in 0..<5 {
        await Task.yield()
    }
}

@Suite(.serialized) struct QuakeTerminalControllerTests {
    @Test @MainActor func manualCloseRestoresCapturedTargetWhenFocusNeverChanged() {
        let target = makeManagedRestoreTarget(pid: 41, windowId: 410)
        var restoredTargets: [QuakeTerminalRestoreTarget] = []
        let controller = makeQuakeTerminalTestController(
            captureRestoreTarget: { target },
            restoreFocusTarget: { restoredTargets.append($0) },
            isWindowFocused: { _ in true }
        )

        controller.configureTransitionStateForTests(visible: true, isTransitioning: false)
        controller.captureRestoreTargetForTests()
        controller.animateOut()

        #expect(restoredTargets == [target])
        #expect(controller.restoreTargetForTests == nil)
    }

    @Test @MainActor func focusLossRefreshesRestoreTargetToLatestWindowInSameApp() async {
        let appPid: pid_t = 52
        let initialTarget = makeManagedRestoreTarget(pid: appPid, windowId: 520)
        let refreshedTarget = makeManagedRestoreTarget(pid: appPid, windowId: 521)
        var currentTarget = initialTarget
        var restoredTargets: [QuakeTerminalRestoreTarget] = []
        let windowIsFocused = QuakeTerminalFocusBox(false)
        let controller = makeQuakeTerminalTestController(
            captureRestoreTarget: { currentTarget },
            restoreFocusTarget: { restoredTargets.append($0) },
            isWindowFocused: { _ in windowIsFocused.value }
        )

        controller.configureTransitionStateForTests(visible: true, isTransitioning: false)
        controller.captureRestoreTargetForTests()

        currentTarget = refreshedTarget
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        await settleQuakeTerminalFocusUpdates()

        #expect(controller.restoreTargetForTests == refreshedTarget)

        windowIsFocused.value = true
        controller.animateOut()

        #expect(restoredTargets == [refreshedTarget])
    }

    @Test @MainActor func manualCloseWhileQuakeIsNotFocusedDoesNotRestoreFocus() async {
        let initialTarget = makeManagedRestoreTarget(pid: 61, windowId: 610)
        let currentTarget = makeManagedRestoreTarget(pid: 62, windowId: 620)
        var observedTarget = initialTarget
        var restoredTargets: [QuakeTerminalRestoreTarget] = []
        let controller = makeQuakeTerminalTestController(
            captureRestoreTarget: { observedTarget },
            restoreFocusTarget: { restoredTargets.append($0) },
            isWindowFocused: { _ in false }
        )

        controller.configureTransitionStateForTests(visible: true, isTransitioning: false)
        controller.captureRestoreTargetForTests()

        observedTarget = currentTarget
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        await settleQuakeTerminalFocusUpdates()
        controller.animateOut()

        #expect(restoredTargets.isEmpty)
    }

    @Test @MainActor func autoHideOnFocusLossPreservesCurrentFocus() async {
        let initialTarget = makeManagedRestoreTarget(pid: 71, windowId: 710)
        let currentTarget = makeManagedRestoreTarget(pid: 72, windowId: 720)
        var observedTarget = initialTarget
        var restoredTargets: [QuakeTerminalRestoreTarget] = []
        let controller = makeQuakeTerminalTestController(
            autoHide: true,
            captureRestoreTarget: { observedTarget },
            restoreFocusTarget: { restoredTargets.append($0) },
            isWindowFocused: { _ in false }
        )

        controller.configureTransitionStateForTests(visible: true, isTransitioning: false)
        controller.captureRestoreTargetForTests()

        observedTarget = currentTarget
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        await settleQuakeTerminalFocusUpdates()

        #expect(restoredTargets.isEmpty)
        #expect(controller.visible == false)
    }
}

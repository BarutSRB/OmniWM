// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

@MainActor
final class EventInterpreter: EventIntakeSink {
    weak var controller: WMController?

    init(controller: WMController) {
        self.controller = controller
    }

    func handleIntakeEvent(_ stamped: StampedIntakeEvent) {
        guard let controller else { return }

        switch stamped.event {
        case let .activationFactsResolved(facts):
            controller.axEventHandler.handleActivationFactsResolved(facts)

        case .activeSpaceChanged:
            controller.serviceLifecycleManager.handleActiveSpaceDidChange()

        case let .appActivated(pid):
            controller.axEventHandler.handleAppActivation(
                pid: pid,
                source: .workspaceDidActivateApplication
            )

        case let .appDeactivated(pid):
            controller.axEventHandler.handleAppDeactivated(pid: pid)

        case let .appHidden(pid):
            controller.axEventHandler.handleAppHidden(pid: pid)

        case .appLaunched:
            controller.serviceLifecycleManager.handleAppLaunched()

        case let .appTerminated(pid):
            controller.serviceLifecycleManager.handleAppTerminated(pid: pid)

        case let .appUnhidden(pid):
            controller.axEventHandler.handleAppUnhidden(pid: pid)

        case let .axFocusedWindowChanged(pid):
            controller.axEventHandler.handleAppActivation(
                pid: pid,
                source: .focusedWindowChanged
            )

        case let .axWindowDestroyed(pid, windowId):
            controller.axEventHandler.handleRemoved(pid: pid, winId: windowId)

        case let .axWindowMiniaturized(pid, windowId):
            controller.axEventHandler.handleWindowMiniaturized(pid: pid, windowId: windowId)

        case let .cgs(event):
            controller.axEventHandler.handleCGSEvent(event)

        case let .display(event):
            controller.serviceLifecycleManager.handleDisplayEvent(event)

        case let .hotkeyCommand(command):
            _ = controller.commandHandler.handleHotkeyCommand(command)

        case let .intentExpired(intentId):
            controller.axEventHandler.handleIntentExpired(intentId)

        case let .ipcCommand(intake):
            intake.completion(intake.perform(controller))

        case let .mouseDragged(button, location):
            controller.mouseEventHandler.dispatchQueuedMouseDragged(at: location, button: button)

        case let .mouseMoved(location):
            controller.mouseEventHandler.dispatchMouseMoved(at: location)

        case let .mouseScroll(payload):
            controller.mouseEventHandler.dispatchScrollWheel(
                at: payload.location,
                deltaX: payload.deltaX,
                deltaY: payload.deltaY,
                momentumPhase: payload.momentumPhase,
                phase: payload.phase,
                modifiers: payload.modifiers
            )

        case .systemSleep:
            _ = controller.workspaceManager.recordReconcileEvent(.systemSleep(source: .service))
            controller.mouseEventHandler.stopMultitouch()

        case .systemWake:
            _ = controller.workspaceManager.recordReconcileEvent(.systemWake(source: .service))
            controller.workspaceBarManager.cleanup()
            controller.layoutRefreshController.requestFullRescan(reason: .unlock)
            controller.mouseEventHandler.restartMultitouch()

        case let .windowConstraintsResolved(fact):
            controller.layoutRefreshController.applyResolvedConstraints(fact)
        }
    }
}

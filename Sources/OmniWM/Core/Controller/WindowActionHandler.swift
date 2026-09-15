// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
final class WindowActionHandler {
    enum AppUnhideRequestResult {
        case applicationUnavailable
        case requestReportedSent
        case requestReportedNotSent
    }

    weak var controller: WMController?
    private let floatingWindows: FloatingWindowRaiser
    private let appReveal: AppRevealActions

    @ObservationIgnored
    private var overviewControllerStorage: OverviewController?
    private var overviewController: OverviewController {
        if let overviewControllerStorage {
            return overviewControllerStorage
        }
        guard let controller else { fatal("WindowActionHandler requires controller") }
        let oc = OverviewController(wmController: controller, motionPolicy: controller.motionPolicy)
        oc.onActivateWindow = { [weak self] handle, workspaceId in
            self?.activateWindowFromOverview(handle: handle, workspaceId: workspaceId)
        }
        oc.onCloseWindow = { [weak self] handle in
            self?.closeWindow(handle: handle) ?? false
        }
        overviewControllerStorage = oc
        return oc
    }

    init(
        controller: WMController,
        visibleOwnedWindowsProvider: @escaping () -> [NSWindow] = {
            OwnedWindowRegistry.shared.visibleWindows(kind: .utility)
        },
        frontOwnedWindow: @escaping (NSWindow) -> Void = { window in
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        },
        requestApplicationUnhide: @escaping (pid_t) -> AppUnhideRequestResult = { pid in
            guard let app = NSRunningApplication(processIdentifier: pid),
                  !app.isTerminated
            else {
                return .applicationUnavailable
            }
            return app.unhide() ? .requestReportedSent : .requestReportedNotSent
        }
    ) {
        self.controller = controller
        floatingWindows = FloatingWindowRaiser(
            controller: controller,
            visibleOwnedWindowsProvider: visibleOwnedWindowsProvider,
            frontOwnedWindow: frontOwnedWindow
        )
        appReveal = AppRevealActions(controller: controller, requestApplicationUnhide: requestApplicationUnhide)
    }

    func raiseAllFloatingWindows() {
        floatingWindows.raiseAllFloatingWindows()
    }

    func hasRaisableFloatingWindows() -> Bool {
        floatingWindows.hasRaisableFloatingWindows()
    }

    @discardableResult
    func completeAppRevealFocus(intentId: IntentID) -> Bool {
        appReveal.completeAppRevealFocus(intentId: intentId)
    }

    func openMenuAnywhere() {
        guard controller != nil else { return }
        MenuAnywhereController.shared.showNativeMenu()
    }

    func toggleOverview() {
        overviewController.toggle()
    }

    func handleOverviewHotkey(_ invocation: HotkeyInvocation) -> OverviewHotkeyDisposition {
        overviewControllerStorage?.input.handleHotkeyInvocation(invocation) ?? .inactive
    }

    func updateOverviewSettings() {
        overviewControllerStorage?.updateSettings()
    }

    func invalidateOverviewDeferredActionsForServiceStop() {
        overviewControllerStorage?.invalidateDeferredActionsForServiceStop()
    }

    func handleOverviewWindowRemoved(_ entry: WindowState) {
        overviewControllerStorage?.handleManagedWindowRemoved(entry)
    }

    func refreshOverviewProjection(
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        selectedToken: WindowToken? = nil
    ) {
        let selectedHandle = selectedToken.flatMap { controller?.workspaceManager.handle(for: $0) }
        overviewControllerStorage?.refreshCachedOverviewProjection(
            affectedWorkspaceIds: affectedWorkspaceIds,
            selectedHandle: selectedHandle
        )
    }

    func isOverviewOpen() -> Bool {
        overviewControllerStorage?.isOpen == true
    }

    func prepareWindowFromOverview(_ handle: WindowHandle, animated: Bool) {
        guard let controller,
              let entry = controller.workspaceManager.entry(for: handle),
              controller.activeWorkspace()?.id == entry.workspaceId,
              controller.workspaceManager.activeLayoutKind(for: entry.workspaceId) == .niri
        else { return }
        navigateToWindowInternal(
            token: handle.id,
            workspaceId: entry.workspaceId,
            motion: animated ? controller.motionPolicy.snapshot() : .disabled,
            focusAfterLayout: false
        )
    }

    func activateWindowFromOverview(handle: WindowHandle, workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        guard controller.workspaceManager.entry(for: handle) != nil else { return }
        if controller.activeWorkspace()?.id == workspaceId,
           controller.workspaceManager.activeLayoutKind(for: workspaceId) == .niri,
           let node = controller.niriEngine?.findNode(for: handle.id, in: workspaceId),
           controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId == node.id
        {
            controller.focusWindow(handle.id)
        } else {
            navigateToWindowInternal(token: handle.id, workspaceId: workspaceId)
        }
    }

    func closeWindow(handle: WindowHandle) -> Bool {
        guard let controller else { return false }
        guard let entry = controller.workspaceManager.entry(for: handle) else { return false }

        let element = entry.axRef.element
        return MainThreadAXSpanTrace.measure(.closeButtonPress, pid: entry.pid, windowId: entry.windowId) {
            var closeButton: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeButton) == .success,
               let closeButton = AXUIElement.from(closeButton)
            {
                return performAXAction(
                    closeButton,
                    kAXPressAction as CFString,
                    noteKey: "performPressFailed"
                )
            }
            return false
        } succeeded: { $0 }
    }

    @discardableResult
    func navigateToWindow(handle: WindowHandle) -> Bool {
        guard let controller else { return false }
        guard let entry = controller.workspaceManager.entry(for: handle) else { return false }
        return navigateToWindowInternal(token: handle.id, workspaceId: entry.workspaceId)
    }

    @discardableResult
    func navigateToExplicitlySelectedWindow(handle: WindowHandle) -> Bool {
        guard let controller else { return false }
        let destination: AppRevealFocusDestination = controller.workspaceManager
            .scratchpadIndex(for: handle.id)
            .map { .scratchpadWindow(index: $0, monitorId: nil) } ?? .window
        return appReveal.requestIfNeeded(handle: handle, destination: destination)
    }

    @discardableResult
    func revealScratchpadFromBar(
        handle: WindowHandle,
        index: ScratchpadIndex,
        monitorId: Monitor.ID?
    ) -> Bool {
        appReveal.requestIfNeeded(
            handle: handle,
            destination: .scratchpad(index: index, monitorId: monitorId)
        )
    }

    @discardableResult
    func focusWorkspaceFromBar(named name: String) -> Bool {
        guard let controller else { return false }
        if let currentWorkspace = controller.activeWorkspace() {
            controller.workspaceNavigationHandler.saveNiriViewportState(for: currentWorkspace.id)
        }

        guard let result = controller.workspaceManager.focusWorkspace(named: name) else { return false }
        return completeWorkspaceFocusFromBar(result)
    }

    @discardableResult
    func focusWorkspaceFromBar(id workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let controller else { return false }
        if let currentWorkspace = controller.activeWorkspace() {
            controller.workspaceNavigationHandler.saveNiriViewportState(for: currentWorkspace.id)
        }

        guard let result = controller.workspaceManager.focusWorkspace(id: workspaceId) else { return false }
        return completeWorkspaceFocusFromBar(result)
    }

    private func completeWorkspaceFocusFromBar(
        _ result: (workspace: WorkspaceDescriptor, monitor: Monitor)
    ) -> Bool {
        guard let controller else { return false }
        let focusedToken = controller.resolveAndSetWorkspaceFocusToken(for: result.workspace.id)
        if let focusedToken {
            _ = prepareDwindleNavigationTarget(focusedToken, workspaceId: result.workspace.id)
        }
        controller.layoutRefreshController
            .commitWorkspaceTransition(reason: .workspaceTransition) { [weak controller] in
                if let focusedToken {
                    controller?.focusWindow(focusedToken)
                }
            }
        return true
    }

    @discardableResult
    func focusWindowFromBar(token: WindowToken) -> Bool {
        guard let controller else { return false }
        guard let handle = controller.workspaceManager.handle(for: token) else { return false }
        return focusWindowFromBar(handle: handle)
    }

    @discardableResult
    func focusWindowFromBar(handle: WindowHandle) -> Bool {
        let navigated = navigateToExplicitlySelectedWindow(handle: handle)
        if navigated,
           let controller,
           let originalToken = AppRevealActions.suspendedNativeFullscreenOriginalToken(
               for: handle.id,
               controller: controller
           )
        {
            controller.activateNativeFullscreenPlaceholder(originalToken)
        }
        return navigated
    }

    func runningAppsWithWindows() -> [RunningAppInfo] {
        guard let controller else { return [] }
        var appInfoMap: [String: RunningAppInfo] = [:]

        for entry in controller.workspaceManager.allEntries() {
            guard entry.layoutReason == .standard else { continue }

            let cachedInfo = controller.appInfoCache.info(for: entry.pid)
            let bundleId = cachedInfo?.bundleId
            let key = bundleId ?? "pid:\(entry.pid)"

            if appInfoMap[key] != nil { continue }

            let frame = (AXWindowService.framePreferFast(entry.axRef)) ?? .zero

            appInfoMap[key] = RunningAppInfo(
                id: key,
                pid: entry.pid,
                bundleId: bundleId,
                appName: cachedInfo?.name ?? "Unknown",
                icon: cachedInfo?.icon,
                windowSize: frame.size
            )
        }

        return appInfoMap.values.sorted { $0.appName < $1.appName }
    }
}

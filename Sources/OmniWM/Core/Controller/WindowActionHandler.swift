// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation

@MainActor
final class WindowActionHandler {
    private enum RaisableSurfaceBatchKey: Hashable {
        case application(pid_t)
        case ownedApplication
    }

    @MainActor
    private enum RaisableSurface {
        case managed(WindowModel.Entry)
        case external(pid: pid_t, windowId: Int, axRef: AXWindowRef)
        case owned(NSWindow)

        var windowId: Int {
            switch self {
            case let .managed(entry):
                entry.windowId
            case let .external(_, windowId, _):
                windowId
            case let .owned(window):
                window.windowNumber
            }
        }

        var sortPid: pid_t {
            switch self {
            case let .managed(entry):
                entry.pid
            case let .external(pid, _, _):
                pid
            case .owned:
                getpid()
            }
        }

        var batchKey: RaisableSurfaceBatchKey {
            switch self {
            case let .managed(entry):
                .application(entry.pid)
            case let .external(pid, _, _):
                .application(pid)
            case .owned:
                .ownedApplication
            }
        }
    }

    private struct FloatingWindowRaisePlan {
        let batches: [[RaisableSurface]]
    }

    weak var controller: WMController?
    private let orderWindow: (UInt32) -> Void
    private let visibleWindowInfoProvider: () -> [WindowServerInfo]
    private let axWindowRefProvider: (UInt32, pid_t) -> AXWindowRef?
    private let visibleOwnedWindowsProvider: () -> [NSWindow]
    private let frontOwnedWindow: (NSWindow) -> Void
    private let closeWindow: (AXUIElement) -> Void

    @ObservationIgnored
    private lazy var overviewController: OverviewController = {
        guard let controller else { fatalError("WindowActionHandler requires controller") }
        let oc = OverviewController(wmController: controller, motionPolicy: controller.motionPolicy)
        oc.onActivateWindow = { [weak self] handle, workspaceId in
            self?.activateWindowFromOverview(handle: handle, workspaceId: workspaceId)
        }
        oc.onCloseWindow = { [weak self] handle in
            self?.closeWindowFromOverview(handle: handle)
        }
        return oc
    }()

    init(
        controller: WMController,
        platform: WMPlatform = .live,
        orderWindow: ((UInt32) -> Void)? = nil,
        visibleWindowInfoProvider: (() -> [WindowServerInfo])? = nil,
        axWindowRefProvider: ((UInt32, pid_t) -> AXWindowRef?)? = nil,
        visibleOwnedWindowsProvider: (() -> [NSWindow])? = nil,
        frontOwnedWindow: ((NSWindow) -> Void)? = nil,
        closeWindow: ((AXUIElement) -> Void)? = nil
    ) {
        self.controller = controller
        self.orderWindow = orderWindow ?? platform.orderWindowAbove
        self.visibleWindowInfoProvider = visibleWindowInfoProvider ?? platform.visibleWindowInfo
        self.axWindowRefProvider = axWindowRefProvider ?? platform.axWindowRef
        self.visibleOwnedWindowsProvider = visibleOwnedWindowsProvider ?? platform.visibleOwnedWindows
        self.frontOwnedWindow = frontOwnedWindow ?? platform.frontOwnedWindow
        self.closeWindow = closeWindow ?? platform.closeWindow
    }

    func openMenuAnywhere() {
        guard controller != nil else { return }
        MenuAnywhereController.shared.showNativeMenu()
    }

    func toggleOverview() {
        overviewController.toggle()
    }

    func isOverviewOpen() -> Bool {
        overviewController.isOpen
    }

    func isPointInOverview(_ point: CGPoint) -> Bool {
        overviewController.isPointInside(point)
    }

    private func activateWindowFromOverview(handle: WindowHandle, workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        guard controller.workspaceManager.entry(for: handle) != nil else { return }
        navigateToWindowInternal(token: handle.id, workspaceId: workspaceId)
    }

    private func closeWindowFromOverview(handle: WindowHandle) {
        guard let controller else { return }
        guard let entry = controller.workspaceManager.entry(for: handle) else { return }

        let element = entry.axRef.element
        controller.platform.raiseWindow(element)
        closeWindow(element)
    }

    func raiseAllFloatingWindows() {
        guard let controller else { return }
        guard !controller.isLockScreenActive else { return }
        if controller.hasStartedServices {
            guard !controller.isFrontmostAppLockScreen() else { return }
        }

        guard let plan = makeRaiseAllFloatingPlan() else { return }

        for batch in plan.batches {
            for surface in batch {
                orderWindow(UInt32(surface.windowId))
            }
            guard let anchor = batch.last else { continue }
            front(surface: anchor)
        }
    }

    func hasRaisableFloatingWindows() -> Bool {
        makeRaiseAllFloatingPlan() != nil
    }

    private func makeRaiseAllFloatingPlan() -> FloatingWindowRaisePlan? {
        guard let controller else { return nil }

        let managedSurfaces = controller.workspaceManager.visibleWorkspaceIds()
            .flatMap { workspaceId in
                controller.workspaceManager.floatingEntries(in: workspaceId)
            }
            .filter { entry in
                entry.layoutReason == .standard && !controller.workspaceManager.isHiddenInCorner(entry.token)
            }
            .map(RaisableSurface.managed)
        let ownedSurfaces = visibleOwnedWindowsProvider()
            .filter { $0.windowNumber > 0 }
            .map(RaisableSurface.owned)
        var excludedWindowIds = Set(managedSurfaces.map(\.windowId))
        excludedWindowIds.formUnion(ownedSurfaces.map(\.windowId))
        let externalSurfaces = visibleExternalFloatingSurfaces(excludingWindowIds: excludedWindowIds)
        let surfaces = managedSurfaces + ownedSurfaces + externalSurfaces
        guard !surfaces.isEmpty else { return nil }

        let preferredWindowId = preferredWindowId(in: surfaces)
        let orderedSurfaces = surfaces.sorted { lhs, rhs in
            switch (lhs.windowId == preferredWindowId, rhs.windowId == preferredWindowId) {
            case (true, false):
                return false
            case (false, true):
                return true
            default:
                if lhs.sortPid != rhs.sortPid {
                    return lhs.sortPid < rhs.sortPid
                }
                return lhs.windowId < rhs.windowId
            }
        }

        var surfacesByBatchKey: [RaisableSurfaceBatchKey: [RaisableSurface]] = [:]
        var batchOrder: [RaisableSurfaceBatchKey] = []

        for surface in orderedSurfaces {
            if surfacesByBatchKey[surface.batchKey] == nil {
                batchOrder.append(surface.batchKey)
                surfacesByBatchKey[surface.batchKey] = []
            }
            surfacesByBatchKey[surface.batchKey, default: []].append(surface)
        }

        if let preferredBatchKey = orderedSurfaces.last?.batchKey,
           let focusIndex = batchOrder.firstIndex(of: preferredBatchKey)
        {
            let preferredBatchKey = batchOrder.remove(at: focusIndex)
            batchOrder.append(preferredBatchKey)
        }

        let batches = batchOrder.compactMap { surfacesByBatchKey[$0] }
        return FloatingWindowRaisePlan(batches: batches)
    }

    private func visibleExternalFloatingSurfaces(excludingWindowIds: Set<Int>) -> [RaisableSurface] {
        guard let controller else { return [] }

        var seenWindowIds = excludingWindowIds
        return visibleWindowInfoProvider().compactMap { windowInfo in
            let windowId = Int(windowInfo.id)
            guard seenWindowIds.insert(windowId).inserted else { return nil }
            guard !controller.isOwnedWindow(windowNumber: windowId) else { return nil }

            let pid = pid_t(windowInfo.pid)
            guard controller.workspaceManager.entry(forPid: pid, windowId: windowId) == nil else { return nil }
            guard let axRef = axWindowRefProvider(windowInfo.id, pid) else { return nil }

            let evaluation = controller.evaluateWindowDisposition(
                axRef: axRef,
                pid: pid,
                windowInfo: windowInfo
            )
            guard evaluation.decision.trackedMode == .floating || isWindowServerModalFloating(windowInfo) else {
                return nil
            }

            return .external(pid: pid, windowId: windowId, axRef: axRef)
        }
    }

    private func preferredWindowId(in surfaces: [RaisableSurface]) -> Int? {
        guard let controller else { return nil }

        let candidateWindowIds = Set(surfaces.map(\.windowId))
        let preferredOwnedWindowId = (NSApp?.orderedWindows ?? [])
            .map(\.windowNumber)
            .first(where: candidateWindowIds.contains)
            ?? [NSApp?.keyWindow, NSApp?.mainWindow]
            .compactMap { $0?.windowNumber }
            .first(where: candidateWindowIds.contains)
        if let preferredOwnedWindowId {
            return preferredOwnedWindowId
        }

        if let focusedToken = controller.focusedOrFrontmostWindowTokenForAutomation(
            preferFrontmostWhenNonManagedFocusActive: true
        ),
           candidateWindowIds.contains(focusedToken.windowId)
        {
            return focusedToken.windowId
        }

        guard let interactionWorkspaceId = controller.activeWorkspace()?.id else { return nil }
        let lastFloatingFocusedToken = controller.workspaceManager.lastFloatingFocusedToken(
            in: interactionWorkspaceId
        )
        guard let lastFloatingFocusedToken,
              candidateWindowIds.contains(lastFloatingFocusedToken.windowId)
        else {
            return nil
        }
        return lastFloatingFocusedToken.windowId
    }

    private func isWindowServerModalFloating(_ windowInfo: WindowServerInfo) -> Bool {
        let isFloating = (windowInfo.tags & 0x2) != 0
        let isModal = (windowInfo.tags & 0x8000_0000) != 0
        return isFloating && isModal
    }

    private func front(surface: RaisableSurface) {
        guard let controller else { return }

        switch surface {
        case let .managed(entry):
            controller.performWindowFronting(
                pid: entry.pid,
                windowId: entry.windowId,
                axRef: entry.axRef
            )
        case let .external(pid, windowId, axRef):
            controller.performWindowFronting(
                pid: pid,
                windowId: windowId,
                axRef: axRef
            )
        case let .owned(window):
            frontOwnedWindow(window)
        }
    }

    @discardableResult
    func navigateToWindow(handle: WindowHandle) -> Bool {
        guard let controller else { return false }
        guard let entry = controller.workspaceManager.entry(for: handle) else { return false }
        return navigateToWindowInternal(token: handle.id, workspaceId: entry.workspaceId)
    }

    @discardableResult
    func summonWindowRight(handle: WindowHandle) -> Bool {
        guard let controller,
              let currentWorkspace = controller.activeWorkspace(),
              let focusedToken = controller.workspaceManager.focusedToken,
              let focusedEntry = controller.workspaceManager.entry(for: focusedToken),
              focusedEntry.workspaceId == currentWorkspace.id
        else {
            return false
        }

        return summonWindowRight(
            handle: handle,
            anchorToken: focusedToken,
            anchorWorkspaceId: currentWorkspace.id
        )
    }

    @discardableResult
    func summonWindowRight(
        handle: WindowHandle,
        anchorToken: WindowToken,
        anchorWorkspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller,
              let anchorEntry = controller.workspaceManager.entry(for: anchorToken),
              anchorEntry.workspaceId == anchorWorkspaceId,
              let targetEntry = controller.workspaceManager.entry(for: handle)
        else {
            return false
        }

        let token = handle.id
        guard token != anchorToken else { return false }

        let targetWorkspaceId = anchorWorkspaceId
        switch layoutType(for: targetWorkspaceId) {
        case .dwindle:
            return summonWindowRightInDwindle(
                token: token,
                sourceWorkspaceId: targetEntry.workspaceId,
                targetWorkspaceId: targetWorkspaceId,
                focusedToken: anchorToken
            )
        case .niri, .defaultLayout:
            return summonWindowRightInNiri(
                token: token,
                sourceWorkspaceId: targetEntry.workspaceId,
                targetWorkspaceId: targetWorkspaceId,
                focusedToken: anchorToken
            )
        }
    }

    @discardableResult
    func navigateToWindowInternal(token: WindowToken, workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let controller else { return false }
        guard let engine = controller.niriEngine else { return false }
        guard !controller.isManagedWindowSuspendedForNativeFullscreen(token) else { return false }

        let currentWsId = controller.activeWorkspace()?.id

        if workspaceId != currentWsId {
            let wsName = controller.workspaceManager.descriptor(for: workspaceId)?.name ?? ""
            if let result = controller.workspaceManager.focusWorkspace(named: wsName) {
                _ = controller.workspaceManager.setInteractionMonitor(result.monitor.id)
                controller.syncMonitorsToNiriEngine()
            }
        }

        var targetState = controller.workspaceManager.niriViewportState(for: workspaceId)
        if let niriWindow = engine.findNode(for: token) {
            targetState.selectedNodeId = niriWindow.id

            if let column = engine.findColumn(containing: niriWindow, in: workspaceId),
               let colIdx = engine.columnIndex(of: column, in: workspaceId),
               let monitor = controller.workspaceManager.monitor(for: workspaceId)
            {
                engine.activateWindow(niriWindow.id)

                let cols = engine.columns(in: workspaceId)
                let gap = CGFloat(controller.workspaceManager.gaps)
                targetState.snapToColumn(
                    colIdx,
                    columns: cols,
                    gap: gap,
                    viewportWidth: monitor.visibleFrame.width
                )
            }
        }

        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: targetState,
                rememberedFocusToken: token
            )
        )
        controller.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: [workspaceId],
            reason: .workspaceTransition
        ) { [weak controller] in
            controller?.focusWindow(token)
        }
        return true
    }

    @discardableResult
    private func summonWindowRightInNiri(
        token: WindowToken,
        sourceWorkspaceId: WorkspaceDescriptor.ID,
        targetWorkspaceId: WorkspaceDescriptor.ID,
        focusedToken: WindowToken
    ) -> Bool {
        guard let controller,
              let engine = controller.niriEngine,
              let focusedNode = engine.findNode(for: focusedToken),
              let focusedColumn = engine.findColumn(containing: focusedNode, in: targetWorkspaceId),
              let focusedColumnIndex = engine.columnIndex(of: focusedColumn, in: targetWorkspaceId)
        else {
            return false
        }

        let insertIndex = focusedColumnIndex + 1
        let sourceLayoutType = layoutType(for: sourceWorkspaceId)

        if sourceWorkspaceId == targetWorkspaceId {
            guard controller.niriLayoutHandler.insertWindowInNewColumn(
                handle: WindowHandle(id: token),
                insertIndex: insertIndex,
                in: targetWorkspaceId
            ) else {
                return false
            }
            commitSummonedWindowFocus(token: token, workspaceId: targetWorkspaceId, startNiriScrollAnimation: true)
            return true
        }

        guard controller.workspaceNavigationHandler.moveWindow(
            handle: WindowHandle(id: token),
            toWorkspaceId: targetWorkspaceId
        ) else {
            return false
        }

        if sourceLayoutType == .dwindle {
            commitSummonedWindowFocus(
                token: token,
                workspaceId: targetWorkspaceId,
                rememberedFocusToken: focusedToken,
                startNiriScrollAnimation: true
            )
            return true
        }

        guard controller.niriLayoutHandler.insertWindowInNewColumn(
            handle: WindowHandle(id: token),
            insertIndex: insertIndex,
            in: targetWorkspaceId
        ) else {
            return false
        }
        commitSummonedWindowFocus(token: token, workspaceId: targetWorkspaceId, startNiriScrollAnimation: true)
        return true
    }

    @discardableResult
    private func summonWindowRightInDwindle(
        token: WindowToken,
        sourceWorkspaceId: WorkspaceDescriptor.ID,
        targetWorkspaceId: WorkspaceDescriptor.ID,
        focusedToken: WindowToken
    ) -> Bool {
        guard let controller,
              let engine = controller.dwindleEngine,
              let focusedNode = engine.findNode(for: focusedToken),
              focusedNode.isLeaf
        else {
            return false
        }

        if sourceWorkspaceId == targetWorkspaceId {
            guard controller.dwindleLayoutHandler.summonWindowRight(
                token,
                beside: focusedToken,
                in: targetWorkspaceId
            ) else {
                return false
            }
            commitSummonedWindowFocus(token: token, workspaceId: targetWorkspaceId)
            return true
        }

        engine.setSelectedNode(focusedNode, in: targetWorkspaceId)
        engine.setPreselection(.right, in: targetWorkspaceId)

        guard controller.workspaceNavigationHandler.moveWindow(
            handle: WindowHandle(id: token),
            toWorkspaceId: targetWorkspaceId
        ) else {
            return false
        }

        commitSummonedWindowFocus(token: token, workspaceId: targetWorkspaceId)
        return true
    }

    private func commitSummonedWindowFocus(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        rememberedFocusToken: WindowToken? = nil,
        startNiriScrollAnimation: Bool = false
    ) {
        guard let controller else { return }

        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: nil,
                rememberedFocusToken: rememberedFocusToken ?? token
            )
        )
        controller.layoutRefreshController.requestImmediateRelayout(
            reason: .layoutCommand,
            affectedWorkspaceIds: [workspaceId]
        ) { [weak controller] in
            controller?.focusWindow(token)
        }
        if startNiriScrollAnimation {
            controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
        }
    }

    private func layoutType(for workspaceId: WorkspaceDescriptor.ID) -> LayoutType {
        guard let controller,
              let workspaceName = controller.workspaceManager.descriptor(for: workspaceId)?.name
        else {
            return .defaultLayout
        }
        return controller.settings.layoutType(for: workspaceName)
    }

    @discardableResult
    func focusWorkspaceFromBar(named name: String) -> Bool {
        guard let controller else { return false }
        if let currentWorkspace = controller.activeWorkspace() {
            controller.workspaceNavigationHandler.saveNiriViewportState(for: currentWorkspace.id)
        }

        guard let result = controller.workspaceManager.focusWorkspace(named: name) else { return false }

        let focusedToken = controller.resolveAndSetWorkspaceFocusToken(for: result.workspace.id)
        controller.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: [result.workspace.id],
            reason: .workspaceTransition
        ) { [weak controller] in
            if let focusedToken {
                controller?.focusWindow(focusedToken)
            }
        }
        return true
    }

    @discardableResult
    func focusWindowFromBar(token: WindowToken) -> Bool {
        guard let controller else { return false }
        guard let entry = controller.workspaceManager.entry(for: token) else { return false }
        return navigateToWindowInternal(token: token, workspaceId: entry.workspaceId)
    }

    func runningAppsWithWindows() -> [RunningAppInfo] {
        guard let controller else { return [] }
        var appInfoMap: [String: RunningAppInfo] = [:]

        for entry in controller.workspaceManager.allEntries() {
            guard entry.layoutReason == .standard else { continue }

            let cachedInfo = controller.appInfoCache.info(for: entry.handle.pid)
            guard let bundleId = cachedInfo?.bundleId else { continue }

            if appInfoMap[bundleId] != nil { continue }

            let frame = (AXWindowService.framePreferFast(entry.axRef)) ?? .zero

            appInfoMap[bundleId] = RunningAppInfo(
                id: bundleId,
                bundleId: bundleId,
                appName: cachedInfo?.name ?? "Unknown",
                icon: cachedInfo?.icon,
                windowSize: frame.size
            )
        }

        return appInfoMap.values.sorted { $0.appName < $1.appName }
    }
}

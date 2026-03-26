import AppKit
import Foundation
import ScreenCaptureKit

@MainActor
struct OverviewEnvironment {
    var frontmostApplicationPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var currentProcessID: () -> pid_t = { getpid() }
    var activateOmniWM: () -> Void = { NSApp.activate(ignoringOtherApps: true) }
    var activateApplication: (pid_t) -> Void = { pid in
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    }
    var addLocalEventMonitor: (
        NSEvent.EventTypeMask,
        @escaping (NSEvent) -> NSEvent?
    ) -> Any? = { mask, handler in
        NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
    }
    var removeEventMonitor: (Any) -> Void = { monitor in
        NSEvent.removeMonitor(monitor)
    }
    var notificationCenter: NotificationCenter = .default
    var selectionDismissDelayNanoseconds: UInt64 = 50_000_000
}

@MainActor
final class OverviewController {
    private enum ScrollTuning {
        static let preciseScrollMultiplier: CGFloat = 3.5
        static let nonPreciseScrollMultiplier: CGFloat = 2.0
        static let zoomStep: CGFloat = 0.05
        static let zoomEpsilon: CGFloat = 0.0001
    }

    enum OverviewDismissReason {
        case cancel
        case selection
        case externalDeactivation

        var shouldRestorePreviousApplication: Bool {
            switch self {
            case .cancel:
                true
            case .selection, .externalDeactivation:
                false
            }
        }
    }

    private struct OverviewSnapshot {
        var workspaces: [OverviewWorkspaceLayoutItem] = []
        var windows: [WindowHandle: OverviewWindowLayoutData] = [:]

        var windowIds: [Int] {
            windows.values.map(\.entry.windowId).sorted()
        }
    }

    private weak var wmController: WMController?
    private let environment: OverviewEnvironment
    private let ownedWindowRegistry: OwnedWindowRegistry

    private(set) var state: OverviewState = .closed
    private var overviewSnapshot = OverviewSnapshot()
    private var layoutsByMonitor: [Monitor.ID: OverviewLayout] = [:]
    private var searchQuery: String = ""
    private var scale: CGFloat = 1.0
    private var selectedWindowHandle: WindowHandle?
    private var activeInteractionMonitorId: Monitor.ID?

    private var windows: [OverviewWindow] = []
    private var animator: OverviewAnimator?
    private var thumbnailCache: [Int: CGImage] = [:]
    private var thumbnailCaptureTask: Task<Void, Never>?
    private var keyEventMonitor: Any?
    private var flagsEventMonitor: Any?
    private var applicationDidResignObserver: NSObjectProtocol?
    private var previousFrontmostApplicationPID: pid_t?
    private var pendingDismissReason: OverviewDismissReason = .cancel
    private var pendingFocusTargetWindow: WindowHandle?

    private var inputHandler: OverviewInputHandler?
    private var dragGhostController: DragGhostController?
    private var dragSession: DragSession?

    var onActivateWindow: ((WindowHandle, WorkspaceDescriptor.ID) -> Void)?
    var onCloseWindow: ((WindowHandle) -> Void)?
    var isOpen: Bool { state.isOpen }

    init(
        wmController: WMController,
        environment: OverviewEnvironment = .init(),
        ownedWindowRegistry: OwnedWindowRegistry = .shared
    ) {
        self.wmController = wmController
        self.environment = environment
        self.ownedWindowRegistry = ownedWindowRegistry
        animator = OverviewAnimator(controller: self)
        inputHandler = OverviewInputHandler(controller: self)
    }

    func toggle() {
        switch state {
        case .closed:
            open()
        case .open:
            dismiss(reason: .cancel)
        case .opening, .closing:
            break
        }
    }

    func open() {
        guard case .closed = state else { return }
        guard wmController != nil else { return }

        prepareOpenState()
        createWindows()
        beginOwnedSession()
        startThumbnailCapture()

        let monitor = animationMonitor()
        let displayId = monitor?.displayId ?? CGMainDisplayID()
        let refreshRate = detectRefreshRate(for: displayId)

        state = .opening(progress: 0)
        animator?.startOpenAnimation(displayId: displayId, refreshRate: refreshRate)

        updateWindowDisplays()
        showWindows()
        activateOwnedSession()
        primaryOverviewWindow()?.show(asKeyWindow: true)
    }

    func prepareOpenState() {
        guard let wmController else { return }

        activeInteractionMonitorId = wmController.monitorForInteraction()?.id
        buildOverviewSnapshot()

        if let focusedHandle = wmController.workspaceManager.focusedHandle,
           overviewSnapshot.windows[focusedHandle] != nil
        {
            selectedWindowHandle = focusedHandle
        }

        rebuildProjectedLayouts()
    }

    func dismiss(
        reason: OverviewDismissReason = .cancel,
        targetWindow: WindowHandle? = nil,
        animated: Bool = true
    ) {
        switch state {
        case .closed:
            return
        case .closing:
            if reason == .externalDeactivation {
                pendingDismissReason = .externalDeactivation
                pendingFocusTargetWindow = nil
            }
            return
        case .opening, .open:
            break
        }

        let resolvedTargetWindow = reason == .selection ? targetWindow : nil
        pendingDismissReason = reason
        pendingFocusTargetWindow = resolvedTargetWindow

        let monitor = animationMonitor()
        let displayId = monitor?.displayId ?? CGMainDisplayID()
        let refreshRate = detectRefreshRate(for: displayId)

        state = .closing(targetWindow: resolvedTargetWindow, progress: 0)

        if animated {
            animator?.startCloseAnimation(
                targetWindow: resolvedTargetWindow,
                displayId: displayId,
                refreshRate: refreshRate
            )
        } else {
            completeCloseTransition(targetWindow: resolvedTargetWindow)
        }
    }

    private func buildOverviewState() {
        buildOverviewSnapshot()
        rebuildProjectedLayouts()
    }

    private func buildOverviewSnapshot() {
        guard let wmController else { return }
        let workspaceManager = wmController.workspaceManager
        let appInfoCache = wmController.appInfoCache

        var workspaces: [OverviewWorkspaceLayoutItem] = []
        var windowData: [WindowHandle: OverviewWindowLayoutData] = [:]

        for monitor in workspaceManager.monitors {
            let activeWs = workspaceManager.activeWorkspace(on: monitor.id)

            for ws in workspaceManager.workspaces(on: monitor.id) {
                workspaces.append((
                    id: ws.id,
                    name: wmController.settings.displayName(for: ws.name),
                    isActive: ws.id == activeWs?.id
                ))

                for entry in workspaceManager.entries(in: ws.id) {
                    guard entry.layoutReason == .standard else { continue }

                    let title = AXWindowService.titlePreferFast(windowId: UInt32(entry.windowId)) ?? ""
                    let appInfo = appInfoCache.info(for: entry.handle.pid)
                    let frame = AXWindowService.framePreferFast(entry.axRef) ?? .zero

                    windowData[entry.handle] = (
                        entry: entry,
                        title: title.isEmpty ? (appInfo?.name ?? "Window") : title,
                        appName: appInfo?.name ?? "Unknown",
                        appIcon: appInfo?.icon,
                        frame: frame
                    )
                }
            }
        }

        overviewSnapshot = OverviewSnapshot(
            workspaces: workspaces,
            windows: windowData
        )
    }

    private func rebuildProjectedLayouts() {
        guard let wmController else { return }

        let previousLayouts = layoutsByMonitor
        let monitors = wmController.workspaceManager.monitors

        if let selectedWindowHandle,
           overviewSnapshot.windows[selectedWindowHandle] == nil
        {
            self.selectedWindowHandle = nil
        }

        layoutsByMonitor = [:]
        let niriSnapshotsByWorkspace = buildNiriOverviewSnapshots()
        for monitor in monitors {
            var layout = projectedLayout(
                for: monitor,
                niriSnapshotsByWorkspace: niriSnapshotsByWorkspace
            )
            let viewportFrame = OverviewLayoutCalculator.viewportFrame(for: monitor.frame)
            let previousOffset = previousLayouts[monitor.id]?.scrollOffset ?? 0
            layout.scrollOffset = OverviewLayoutCalculator.clampedScrollOffset(
                previousOffset,
                layout: layout,
                screenFrame: viewportFrame
            )
            layout.dragTarget = previousLayouts[monitor.id]?.dragTarget
            layoutsByMonitor[monitor.id] = layout
        }

        reconcileSelectedWindowHandle()
        applySelectedWindowHandleToLayouts()

        if let activeInteractionMonitorId,
           layoutsByMonitor[activeInteractionMonitorId] == nil
        {
            self.activeInteractionMonitorId = nil
        }

        if activeInteractionMonitorId == nil {
            activeInteractionMonitorId = monitors.first?.id
        }
    }

    private func projectedLayout(
        for monitor: Monitor,
        niriSnapshotsByWorkspace: [WorkspaceDescriptor.ID: NiriOverviewWorkspaceSnapshot]
    ) -> OverviewLayout {
        let localizedWindowData = overviewSnapshot.windows.mapValues { windowData in
            (
                entry: windowData.entry,
                title: windowData.title,
                appName: windowData.appName,
                appIcon: windowData.appIcon,
                frame: OverviewLayoutCalculator.localizedFrame(windowData.frame, to: monitor.frame)
            )
        }

        let viewportFrame = OverviewLayoutCalculator.viewportFrame(for: monitor.frame)
        return OverviewLayoutCalculator.calculateLayout(
            workspaces: overviewSnapshot.workspaces,
            windows: localizedWindowData,
            niriSnapshotsByWorkspace: niriSnapshotsByWorkspace,
            screenFrame: viewportFrame,
            searchQuery: searchQuery,
            scale: scale
        )
    }

    private func buildNiriOverviewSnapshots() -> [WorkspaceDescriptor.ID: NiriOverviewWorkspaceSnapshot] {
        guard let engine = wmController?.niriEngine else { return [:] }

        var snapshots: [WorkspaceDescriptor.ID: NiriOverviewWorkspaceSnapshot] = [:]
        snapshots.reserveCapacity(overviewSnapshot.workspaces.count)

        for workspace in overviewSnapshot.workspaces {
            guard isNiriLayout(workspaceId: workspace.id),
                  let snapshot = engine.overviewSnapshot(for: workspace.id)
            else {
                continue
            }
            snapshots[workspace.id] = snapshot
        }

        return snapshots
    }

    private func createWindows() {
        closeWindows()

        guard let wmController else { return }

        for monitor in wmController.workspaceManager.monitors {
            let window = OverviewWindow(monitor: monitor)

            window.onWindowSelected = { [weak self] monitorId, handle in
                self?.activeInteractionMonitorId = monitorId
                self?.selectAndActivateWindow(handle)
            }
            window.onWindowClosed = { [weak self] monitorId, handle in
                self?.activeInteractionMonitorId = monitorId
                self?.closeWindow(handle)
            }
            window.onDismiss = { [weak self] monitorId in
                self?.activeInteractionMonitorId = monitorId
                self?.dismiss(reason: .cancel)
            }
            window.onScroll = { [weak self] monitorId, delta in
                self?.adjustScrollOffset(by: delta, on: monitorId)
            }
            window.onScrollWithModifiers = { [weak self] monitorId, delta, modifiers, isPrecise in
                self?.handleScroll(
                    delta: delta,
                    modifiers: modifiers,
                    isPrecise: isPrecise,
                    on: monitorId
                )
            }
            window.onDragBegin = { [weak self] monitorId, handle, start in
                self?.beginDrag(on: monitorId, handle: handle, startPoint: start)
            }
            window.onDragUpdate = { [weak self] monitorId, point in
                self?.updateDrag(on: monitorId, at: point)
            }
            window.onDragEnd = { [weak self] monitorId, point in
                self?.endDrag(on: monitorId, at: point)
            }
            window.onDragCancel = { [weak self] in
                self?.cancelDrag()
            }

            windows.append(window)
        }
    }

    private func showWindows() {
        let primaryWindow = primaryOverviewWindow()

        if let primaryWindow {
            primaryWindow.show(asKeyWindow: true)
            ownedWindowRegistry.register(primaryWindow)
        }

        for window in windows where primaryWindow == nil || window !== primaryWindow {
            window.show(asKeyWindow: false)
            ownedWindowRegistry.register(window)
        }
    }

    private func primaryOverviewWindow() -> OverviewWindow? {
        guard let primaryMonitorId = activeInteractionMonitorId ?? windows.first?.monitorId else { return nil }
        return windows.first(where: { $0.monitorId == primaryMonitorId })
    }

    private func closeWindows() {
        for window in windows {
            ownedWindowRegistry.unregister(window)
            window.hide()
            window.close()
        }
        windows.removeAll()
    }

    func isPointInside(_ point: CGPoint) -> Bool {
        guard state.isOpen else { return false }
        for window in windows {
            if window.frame.contains(point) {
                return true
            }
        }
        return false
    }

    private func updateWindowDisplays() {
        for window in windows {
            let layout = layoutsByMonitor[window.monitorId] ?? .init()
            window.updateLayout(layout, state: state, searchQuery: searchQuery)
            window.updateThumbnails(thumbnailCache)
        }
    }

    private func startThumbnailCapture() {
        thumbnailCaptureTask?.cancel()
        thumbnailCaptureTask = Task { [weak self] in
            await self?.captureThumbnails()
        }
    }

    private func captureThumbnails() async {
        let requests = thumbnailCaptureRequests()

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let windowMap = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })

            for request in requests {
                guard !Task.isCancelled else { return }
                guard let scWindow = windowMap[CGWindowID(request.windowId)] else { continue }

                if let thumbnail = await captureWindowThumbnail(scWindow: scWindow, request: request) {
                    thumbnailCache[request.windowId] = thumbnail
                }
            }
            updateWindowDisplays()
        } catch {
            return
        }
    }

    private func thumbnailCaptureRequests() -> [OverviewThumbnailCaptureRequest] {
        guard let wmController else { return [] }

        let scaleByMonitorId = wmController.workspaceManager.monitors.reduce(into: [Monitor.ID: CGFloat]()) { scales, monitor in
            scales[monitor.id] = monitorBackingScaleFactor(for: monitor.displayId)
        }

        var projections: [OverviewThumbnailProjection] = []
        projections.reserveCapacity(layoutsByMonitor.values.reduce(0) { partialResult, layout in
            partialResult + layout.allWindows.count
        })

        for (monitorId, layout) in layoutsByMonitor {
            let scaleFactor = scaleByMonitorId[monitorId] ?? 1.0
            for window in layout.allWindows {
                projections.append(
                    OverviewThumbnailProjection(
                        windowId: window.windowId,
                        overviewFrame: window.overviewFrame,
                        backingScaleFactor: scaleFactor
                    )
                )
            }
        }

        return OverviewThumbnailSizing.captureRequests(
            windowIds: overviewSnapshot.windowIds,
            projections: projections
        )
    }

    private func captureWindowThumbnail(
        scWindow: SCWindow,
        request: OverviewThumbnailCaptureRequest
    ) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()

        config.width = request.pixelWidth
        config.height = request.pixelHeight
        config.showsCursor = false
        config.capturesAudio = false
        config.scalesToFit = true

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return image
        } catch {
            return nil
        }
    }

    private func monitorBackingScaleFactor(for displayId: CGDirectDisplayID) -> CGFloat {
        NSScreen.screens.first(where: { $0.displayId == displayId })?.backingScaleFactor ?? 1.0
    }

    func updateAnimationProgress(_ progress: Double, state: OverviewState) {
        self.state = state
        updateWindowDisplays()
    }

    func onAnimationComplete(state: OverviewState) {
        self.state = state
        updateWindowDisplays()
    }

    func completeCloseTransition(targetWindow: WindowHandle?) {
        let dismissReason = pendingDismissReason
        let previousFrontmostApplicationPID = previousFrontmostApplicationPID
        let resolvedTargetWindow = pendingFocusTargetWindow == targetWindow ? targetWindow : pendingFocusTargetWindow

        animator?.cancelAnimation()
        state = .closed
        cleanup()
        endOwnedSession()

        if dismissReason.shouldRestorePreviousApplication,
           let previousFrontmostApplicationPID
        {
            environment.activateApplication(previousFrontmostApplicationPID)
        } else if dismissReason == .selection,
                  let resolvedTargetWindow
        {
            focusTargetWindow(resolvedTargetWindow)
        }

        updateWindowDisplays()
    }

    func focusTargetWindow(_ handle: WindowHandle) {
        guard let wmController else { return }
        guard let entry = wmController.workspaceManager.entry(for: handle) else { return }

        onActivateWindow?(handle, entry.workspaceId)
    }

    func selectAndActivateWindow(_ handle: WindowHandle) {
        setSelectedWindowHandle(handle)
        updateWindowDisplays()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: self.environment.selectionDismissDelayNanoseconds)
            guard self.state.isOpen else { return }
            self.dismiss(reason: .selection, targetWindow: handle)
        }
    }

    func closeWindow(_ handle: WindowHandle) {
        onCloseWindow?(handle)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.rebuildLayoutAfterWindowClose(removedHandle: handle)
        }
    }

    private func rebuildLayoutAfterWindowClose(removedHandle: WindowHandle) {
        let removedWindowId = overviewSnapshot.windows[removedHandle]?.entry.windowId
        if selectedWindowHandle == removedHandle {
            selectedWindowHandle = nil
        }

        buildOverviewState()

        if let removedWindowId {
            thumbnailCache.removeValue(forKey: removedWindowId)
        }

        updateWindowDisplays()
    }

    func updateSearchQuery(_ query: String) {
        searchQuery = query
        inputHandler?.searchQuery = query
        rebuildProjectedLayouts()
        updateWindowDisplays()
    }

    func navigateSelection(_ direction: Direction, on monitorId: Monitor.ID? = nil) {
        let targetMonitorId = monitorId ?? activeInteractionMonitorId
        if let targetMonitorId {
            activeInteractionMonitorId = targetMonitorId
        }

        guard let layout = canonicalLayout(preferredMonitorId: targetMonitorId) else { return }
        if let nextHandle = OverviewLayoutCalculator.findNextWindow(
            in: layout,
            from: selectedWindowHandle,
            direction: direction
        ) {
            setSelectedWindowHandle(nextHandle)
            updateWindowDisplays()
        }
    }

    func activateSelectedWindow() {
        guard let selectedWindowHandle else { return }
        selectAndActivateWindow(selectedWindowHandle)
    }

    func adjustScrollOffset(by delta: CGFloat) {
        guard let monitorId = activeInteractionMonitorId
            ?? wmController?.workspaceManager.monitors.first?.id
        else {
            return
        }
        adjustScrollOffset(by: delta, on: monitorId)
    }

    func adjustScrollOffset(by delta: CGFloat, on monitorId: Monitor.ID) {
        activeInteractionMonitorId = monitorId
        mutateLayout(for: monitorId) { layout in
            let screenFrame = viewportFrame(for: monitorId)
            let nextOffset = layout.scrollOffset + delta
            layout.scrollOffset = OverviewLayoutCalculator.clampedScrollOffset(
                nextOffset,
                layout: layout,
                screenFrame: screenFrame
            )
        }
        updateWindowDisplays()
    }

    func handleScroll(
        delta: CGFloat,
        modifiers: NSEvent.ModifierFlags,
        isPrecise: Bool,
        on monitorId: Monitor.ID
    ) {
        activeInteractionMonitorId = monitorId

        if modifiers.contains([.option, .shift]) {
            guard abs(delta) > ScrollTuning.zoomEpsilon else { return }
            let step: CGFloat = delta > 0 ? ScrollTuning.zoomStep : -ScrollTuning.zoomStep
            scale = (scale + step).clamped(to: 0.5 ... 1.5)
            buildOverviewState()
            updateWindowDisplays()
            return
        }

        let multiplier = isPrecise
            ? ScrollTuning.preciseScrollMultiplier
            : ScrollTuning.nonPreciseScrollMultiplier
        adjustScrollOffset(by: delta * multiplier, on: monitorId)
    }

    func beginOwnedSession() {
        capturePreviousFrontmostApplication()
        installEventMonitors()
        installApplicationDidResignObserver()
        pendingDismissReason = .cancel
        pendingFocusTargetWindow = nil
    }

    func activateOwnedSession() {
        environment.activateOmniWM()
    }

    func handleApplicationDidResignActive() {
        guard state.isOpen else { return }
        dismiss(reason: .externalDeactivation)
    }

    private func cleanup() {
        thumbnailCaptureTask?.cancel()
        thumbnailCaptureTask = nil
        thumbnailCache.removeAll()
        inputHandler?.reset()
        searchQuery = ""
        scale = 1.0
        selectedWindowHandle = nil
        activeInteractionMonitorId = nil
        overviewSnapshot = .init()
        layoutsByMonitor = [:]
        dragGhostController?.endDrag()
        dragGhostController = nil
        dragSession = nil
        closeWindows()
    }

    private func capturePreviousFrontmostApplication() {
        guard let frontmostPID = environment.frontmostApplicationPID(),
              frontmostPID != environment.currentProcessID()
        else {
            previousFrontmostApplicationPID = nil
            return
        }

        previousFrontmostApplicationPID = frontmostPID
    }

    private func installEventMonitors() {
        removeEventMonitors()
        keyEventMonitor = environment.addLocalEventMonitor([.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.inputHandler?.handleKeyDown(event) == true ? nil : event
        }
        flagsEventMonitor = environment.addLocalEventMonitor([.flagsChanged]) { [weak self] event in
            self?.handleModifierFlagsChanged(event.modifierFlags)
            return event
        }
    }

    private func removeEventMonitors() {
        if let keyEventMonitor {
            environment.removeEventMonitor(keyEventMonitor)
            self.keyEventMonitor = nil
        }
        if let flagsEventMonitor {
            environment.removeEventMonitor(flagsEventMonitor)
            self.flagsEventMonitor = nil
        }
    }

    private func handleModifierFlagsChanged(_ modifierFlags: NSEvent.ModifierFlags) {
        guard state.isOpen else { return }
        let optionPressed = modifierFlags.contains(.option)
        for window in windows {
            window.cancelPendingDragIfNeeded(optionPressed: optionPressed)
        }
    }

    private func installApplicationDidResignObserver() {
        removeApplicationDidResignObserver()
        applicationDidResignObserver = environment.notificationCenter.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleApplicationDidResignActive()
            }
        }
    }

    private func removeApplicationDidResignObserver() {
        if let applicationDidResignObserver {
            environment.notificationCenter.removeObserver(applicationDidResignObserver)
            self.applicationDidResignObserver = nil
        }
    }

    private func endOwnedSession() {
        removeEventMonitors()
        removeApplicationDidResignObserver()
        previousFrontmostApplicationPID = nil
        pendingDismissReason = .cancel
        pendingFocusTargetWindow = nil
    }

    private func detectRefreshRate(for displayId: CGDirectDisplayID) -> Double {
        if let mode = CGDisplayCopyDisplayMode(displayId) {
            return mode.refreshRate > 0 ? mode.refreshRate : 60.0
        }
        return 60.0
    }

    private func animationMonitor() -> Monitor? {
        guard let wmController else { return nil }
        if let activeInteractionMonitorId,
           let monitor = wmController.workspaceManager.monitor(byId: activeInteractionMonitorId)
        {
            return monitor
        }
        return wmController.workspaceManager.monitors.first
    }

    private func canonicalLayout(preferredMonitorId: Monitor.ID? = nil) -> OverviewLayout? {
        let monitorId = preferredMonitorId
            ?? activeInteractionMonitorId
            ?? wmController?.workspaceManager.monitors.first?.id
        if let monitorId,
           let layout = layoutsByMonitor[monitorId]
        {
            return layout
        }
        return layoutsByMonitor.values.first
    }

    private func setSelectedWindowHandle(_ handle: WindowHandle?) {
        selectedWindowHandle = handle
        applySelectedWindowHandleToLayouts()
    }

    private func reconcileSelectedWindowHandle() {
        guard let layout = canonicalLayout(preferredMonitorId: activeInteractionMonitorId) else {
            selectedWindowHandle = nil
            return
        }

        if let selectedWindowHandle,
           let selectedWindow = layout.window(for: selectedWindowHandle),
           selectedWindow.matchesSearch
        {
            return
        }

        selectedWindowHandle = OverviewSearchFilter.firstMatchingWindow(in: layout)?.handle
    }

    private func applySelectedWindowHandleToLayouts() {
        for monitorId in layoutsByMonitor.keys {
            mutateLayout(for: monitorId) { layout in
                layout.setSelected(handle: selectedWindowHandle)
            }
        }
    }

    private func mutateLayout(
        for monitorId: Monitor.ID,
        _ mutate: (inout OverviewLayout) -> Void
    ) {
        guard var layout = layoutsByMonitor[monitorId] else { return }
        mutate(&layout)
        layoutsByMonitor[monitorId] = layout
    }

    private func setDragTarget(_ target: OverviewDragTarget?, for monitorId: Monitor.ID) {
        for id in layoutsByMonitor.keys {
            mutateLayout(for: id) { layout in
                layout.dragTarget = id == monitorId ? target : nil
            }
        }
    }

    private func clearDragTargets() {
        for monitorId in layoutsByMonitor.keys {
            mutateLayout(for: monitorId) { layout in
                layout.dragTarget = nil
            }
        }
    }

    private func viewportFrame(for monitorId: Monitor.ID) -> CGRect {
        guard let wmController,
              let monitor = wmController.workspaceManager.monitor(byId: monitorId)
        else {
            return .zero
        }
        return OverviewLayoutCalculator.viewportFrame(for: monitor.frame)
    }

    private func globalPoint(from localPoint: CGPoint, on monitorId: Monitor.ID) -> CGPoint {
        guard let wmController,
              let monitor = wmController.workspaceManager.monitor(byId: monitorId)
        else {
            return localPoint
        }
        return CGPoint(
            x: monitor.frame.minX + localPoint.x,
            y: monitor.frame.minY + localPoint.y
        )
    }

    deinit {
        MainActor.assumeIsolated {
            endOwnedSession()
            cleanup()
        }
    }
}

private extension OverviewController {
    struct DragSession {
        let handle: WindowHandle
        let windowId: Int
        let workspaceId: WorkspaceDescriptor.ID
        let monitorId: Monitor.ID
        let startPoint: CGPoint
    }

    func beginDrag(on monitorId: Monitor.ID, handle: WindowHandle, startPoint: CGPoint) {
        guard let wmController else { return }
        guard let entry = wmController.workspaceManager.entry(for: handle) else { return }

        activeInteractionMonitorId = monitorId
        dragSession = DragSession(
            handle: handle,
            windowId: entry.windowId,
            workspaceId: entry.workspaceId,
            monitorId: monitorId,
            startPoint: startPoint
        )

        if let frame = AXWindowService.framePreferFast(entry.axRef) {
            if dragGhostController == nil {
                dragGhostController = DragGhostController()
            }
            dragGhostController?.beginDrag(
                windowId: entry.windowId,
                originalFrame: frame,
                cursorLocation: globalPoint(from: startPoint, on: monitorId)
            )
        }
    }

    func updateDrag(on monitorId: Monitor.ID, at point: CGPoint) {
        guard dragSession != nil else { return }
        activeInteractionMonitorId = monitorId
        dragGhostController?.updatePosition(cursorLocation: globalPoint(from: point, on: monitorId))

        let target = resolveDragTarget(at: point, on: monitorId)
        let currentTarget = layoutsByMonitor[monitorId]?.dragTarget
        if target != currentTarget {
            setDragTarget(target, for: monitorId)
            updateWindowDisplays()
        }
    }

    func endDrag(on monitorId: Monitor.ID, at point: CGPoint) {
        guard let session = dragSession else { return }
        activeInteractionMonitorId = monitorId
        dragGhostController?.updatePosition(cursorLocation: globalPoint(from: point, on: monitorId))

        let target = layoutsByMonitor[monitorId]?.dragTarget
        clearDragTargets()
        dragGhostController?.endDrag()
        dragSession = nil

        guard let target else {
            updateWindowDisplays()
            return
        }

        performDragAction(
            session: session,
            target: target
        )

        buildOverviewState()
        updateWindowDisplays()
    }

    func cancelDrag() {
        clearDragTargets()
        dragGhostController?.endDrag()
        dragSession = nil
        updateWindowDisplays()
    }

    func resolveDragTarget(at point: CGPoint, on monitorId: Monitor.ID) -> OverviewDragTarget? {
        guard let layout = layoutsByMonitor[monitorId] else { return nil }
        return layout.resolveDragTarget(at: point, draggedHandle: dragSession?.handle)
    }

    func performDragAction(session: DragSession, target: OverviewDragTarget) {
        guard let wmController else { return }

        switch target {
        case let .workspaceMove(targetWsId):
            guard targetWsId != session.workspaceId else { return }
            wmController.workspaceNavigationHandler.moveWindow(
                handle: session.handle,
                toWorkspaceId: targetWsId
            )

        case let .niriWindowInsert(targetWsId, targetHandle, position):
            guard isNiriLayout(workspaceId: targetWsId) else { return }
            if targetWsId != session.workspaceId {
                wmController.workspaceNavigationHandler.moveWindow(
                    handle: session.handle,
                    toWorkspaceId: targetWsId
                )
            }
            let niriPosition = overviewInsertPositionToNiri(position)
            wmController.niriLayoutHandler.insertWindow(
                handle: session.handle,
                targetHandle: targetHandle,
                position: niriPosition,
                in: targetWsId
            )
            wmController.layoutRefreshController.startScrollAnimation(for: targetWsId)

        case let .niriColumnInsert(targetWsId, insertIndex):
            guard isNiriLayout(workspaceId: targetWsId) else { return }
            if targetWsId != session.workspaceId {
                wmController.workspaceNavigationHandler.moveWindow(
                    handle: session.handle,
                    toWorkspaceId: targetWsId
                )
            }
            wmController.niriLayoutHandler.insertWindowInNewColumn(
                handle: session.handle,
                insertIndex: insertIndex,
                in: targetWsId
            )
            wmController.layoutRefreshController.startScrollAnimation(for: targetWsId)
        }

        wmController.layoutRefreshController.requestImmediateRelayout(reason: .overviewMutation)
    }

    func isNiriLayout(workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let wmController else { return false }
        guard let name = wmController.workspaceManager.descriptor(for: workspaceId)?.name else { return false }
        let layoutType = wmController.settings.layoutType(for: name)
        return layoutType != .dwindle
    }

    func overviewInsertPositionToNiri(_ position: InsertPosition) -> InsertPosition {
        switch position {
        case .before:
            return .after
        case .after:
            return .before
        case .swap:
            return .swap
        }
    }

}

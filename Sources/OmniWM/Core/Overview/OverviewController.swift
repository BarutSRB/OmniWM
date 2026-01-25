import AppKit
import Foundation
import ScreenCaptureKit

@MainActor
final class OverviewController {
    private weak var wmController: WMController?

    private(set) var state: OverviewState = .closed
    private var layout: OverviewLayout = .init()
    private var searchQuery: String = ""

    private var windows: [OverviewWindow] = []
    private var animator: OverviewAnimator?
    private var thumbnailCache: [Int: CGImage] = [:]
    private var thumbnailCaptureTask: Task<Void, Never>?

    private var inputHandler: OverviewInputHandler?

    var onActivateWindow: ((WindowHandle, WorkspaceDescriptor.ID) -> Void)?
    var onCloseWindow: ((WindowHandle) -> Void)?

    init(wmController: WMController) {
        self.wmController = wmController
        self.animator = OverviewAnimator(controller: self)
        self.inputHandler = OverviewInputHandler(controller: self)
    }

    func toggle() {
        switch state {
        case .closed:
            open()
        case .open:
            dismiss()
        case .opening, .closing:
            break
        }
    }

    func open() {
        guard case .closed = state else { return }
        guard let wmController else { return }

        buildLayout()
        createWindows()
        startThumbnailCapture()

        let monitor = wmController.internalWorkspaceManager.monitors.first
        let displayId = monitor?.displayId ?? CGMainDisplayID()
        let refreshRate = detectRefreshRate(for: displayId)

        state = .opening(progress: 0)
        animator?.startOpenAnimation(displayId: displayId, refreshRate: refreshRate)

        updateWindowDisplays()

        for window in windows {
            window.show()
        }
    }

    func dismiss() {
        guard state.isOpen else { return }

        let targetWindow = layout.selectedWindow()?.handle
        let monitor = wmController?.internalWorkspaceManager.monitors.first
        let displayId = monitor?.displayId ?? CGMainDisplayID()
        let refreshRate = detectRefreshRate(for: displayId)

        state = .closing(targetWindow: targetWindow, progress: 0)
        animator?.startCloseAnimation(
            targetWindow: targetWindow,
            displayId: displayId,
            refreshRate: refreshRate
        )
    }

    private func buildLayout() {
        guard let wmController else { return }
        let workspaceManager = wmController.internalWorkspaceManager
        let appInfoCache = wmController.appInfoCache

        var workspaces: [(id: WorkspaceDescriptor.ID, name: String, isActive: Bool)] = []
        var windowData: [WindowHandle: (entry: WindowModel.Entry, title: String, appName: String, appIcon: NSImage?, frame: CGRect)] = [:]

        for monitor in workspaceManager.monitors {
            let activeWs = workspaceManager.activeWorkspace(on: monitor.id)

            for ws in workspaceManager.workspaces(on: monitor.id) {
                workspaces.append((
                    id: ws.id,
                    name: wmController.internalSettings.displayName(for: ws.name),
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

        guard let screen = NSScreen.main else { return }

        layout = OverviewLayoutCalculator.calculateLayout(
            workspaces: workspaces,
            windows: windowData,
            screenFrame: screen.frame,
            searchQuery: searchQuery
        )

        if let firstWindow = layout.allWindows.first {
            layout.setSelected(handle: firstWindow.handle)
        }
    }

    private func createWindows() {
        closeWindows()

        guard let wmController else { return }

        for monitor in wmController.internalWorkspaceManager.monitors {
            let window = OverviewWindow(monitor: monitor)

            window.onWindowSelected = { [weak self] handle in
                self?.selectAndActivateWindow(handle)
            }
            window.onWindowClosed = { [weak self] handle in
                self?.closeWindow(handle)
            }
            window.onDismiss = { [weak self] in
                self?.dismiss()
            }
            window.onSearchChanged = { [weak self] query in
                self?.updateSearchQuery(query)
            }
            window.onNavigate = { [weak self] direction in
                self?.navigateSelection(direction)
            }
            window.onScroll = { [weak self] delta in
                self?.adjustScrollOffset(by: delta)
            }

            windows.append(window)
        }
    }

    private func closeWindows() {
        for window in windows {
            window.hide()
            window.close()
        }
        windows.removeAll()
    }

    private func updateWindowDisplays() {
        for window in windows {
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
        let windowIds = layout.allWindows.map(\.windowId)

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let windowMap = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })

            for windowId in windowIds {
                guard !Task.isCancelled else { return }

                guard let scWindow = windowMap[CGWindowID(windowId)] else { continue }

                if let thumbnail = await captureWindowThumbnail(scWindow: scWindow) {
                    thumbnailCache[windowId] = thumbnail
                    updateWindowDisplays()
                }
            }
        } catch {
            return
        }
    }

    private func captureWindowThumbnail(scWindow: SCWindow) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()

        let maxDimension: CGFloat = 400
        let aspectRatio = scWindow.frame.width / max(1, scWindow.frame.height)
        if aspectRatio > 1 {
            config.width = Int(maxDimension)
            config.height = Int(maxDimension / aspectRatio)
        } else {
            config.width = Int(maxDimension * aspectRatio)
            config.height = Int(maxDimension)
        }

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

    func updateAnimationProgress(_ progress: Double, state: OverviewState) {
        self.state = state
        updateWindowDisplays()
    }

    func onAnimationComplete(state: OverviewState) {
        self.state = state

        if case .closed = state {
            cleanup()
        }

        updateWindowDisplays()
    }

    func focusTargetWindow(_ handle: WindowHandle) {
        guard let wmController else { return }
        guard let entry = wmController.internalWorkspaceManager.entry(for: handle) else { return }

        onActivateWindow?(handle, entry.workspaceId)
    }

    func selectAndActivateWindow(_ handle: WindowHandle) {
        layout.setSelected(handle: handle)
        updateWindowDisplays()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            self.dismiss()
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
        let wasSelected = layout.selectedWindow()?.handle == removedHandle

        buildLayout()
        thumbnailCache.removeValue(forKey: layout.allWindows.first { $0.handle == removedHandle }?.windowId ?? 0)

        if wasSelected {
            if let first = layout.allWindows.first {
                layout.setSelected(handle: first.handle)
            }
        }

        updateWindowDisplays()
    }

    func updateSearchQuery(_ query: String) {
        searchQuery = query
        inputHandler?.searchQuery = query

        OverviewSearchFilter.filterWindows(in: &layout, query: query)
        OverviewSearchFilter.updateSelectionForSearch(layout: &layout)

        updateWindowDisplays()
    }

    func navigateSelection(_ direction: Direction) {
        let currentHandle = layout.selectedWindow()?.handle
        if let nextHandle = OverviewLayoutCalculator.findNextWindow(
            in: layout,
            from: currentHandle,
            direction: direction
        ) {
            layout.setSelected(handle: nextHandle)
            updateWindowDisplays()
        }
    }

    func activateSelectedWindow() {
        guard let selected = layout.selectedWindow() else { return }
        selectAndActivateWindow(selected.handle)
    }

    func adjustScrollOffset(by delta: CGFloat) {
        let maxScroll = max(0, layout.totalContentHeight - (NSScreen.main?.frame.height ?? 800))
        layout.scrollOffset = min(max(0, layout.scrollOffset - delta), maxScroll)
        updateWindowDisplays()
    }

    private func cleanup() {
        thumbnailCaptureTask?.cancel()
        thumbnailCaptureTask = nil
        thumbnailCache.removeAll()
        inputHandler?.reset()
        searchQuery = ""
        layout = .init()
        closeWindows()
    }

    private func detectRefreshRate(for displayId: CGDirectDisplayID) -> Double {
        if let mode = CGDisplayCopyDisplayMode(displayId) {
            return mode.refreshRate > 0 ? mode.refreshRate : 60.0
        }
        return 60.0
    }

    deinit {
        MainActor.assumeIsolated {
            cleanup()
        }
    }
}

import Cocoa
import GhosttyKit

@MainActor
final class QuakeTerminalController: NSObject, NSWindowDelegate, QuakeTerminalTabBarDelegate {
    private(set) var window: QuakeTerminalWindow?
    private var ghosttyApp: ghostty_app_t?
    private var ghosttyConfig: ghostty_config_t?

    private var tabs: [QuakeTerminalTab] = []
    private var activeTabIndex: Int = 0

    private var containerView: NSView?
    private var tabBar: QuakeTerminalTabBar?

    private var activeTab: QuakeTerminalTab? {
        guard activeTabIndex >= 0, activeTabIndex < tabs.count else { return nil }
        return tabs[activeTabIndex]
    }

    private var surface: ghostty_surface_t? { activeTab?.focusedSurface }
    private var surfaceView: GhosttySurfaceView? { activeTab?.focusedSurfaceView }

    private(set) var visible: Bool = false
    private var previousApp: NSRunningApplication?
    private var isHandlingResize: Bool = false

    private let settings: SettingsStore

    private static var ghosttyInitialized = false

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
    }

    private func initializeGhosttyIfNeeded() {
        guard !Self.ghosttyInitialized else { return }
        let result = ghostty_init(0, nil)
        if result == GHOSTTY_SUCCESS {
            Self.ghosttyInitialized = true
        } else {
            print("QuakeTerminal: ghostty_init failed with code \(result)")
        }
    }

    func setup() {
        guard ghosttyApp == nil else { return }

        initializeGhosttyIfNeeded()
        guard Self.ghosttyInitialized else {
            print("QuakeTerminal: GhosttyKit not initialized")
            return
        }

        ghosttyConfig = ghostty_config_new()
        guard ghosttyConfig != nil else {
            print("QuakeTerminal: Failed to create ghostty config")
            return
        }

        updateGhosttyOpacityConfig()
        ghostty_config_load_default_files(ghosttyConfig)
        ghostty_config_finalize(ghosttyConfig)

        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = true
        runtimeConfig.wakeup_cb = { userdata in
            guard let userdata else { return }
            DispatchQueue.main.async {
                let controller = Unmanaged<QuakeTerminalController>.fromOpaque(userdata).takeUnretainedValue()
                controller.tick()
            }
        }
        runtimeConfig.action_cb = { _, _, _ in false }
        runtimeConfig.read_clipboard_cb = { userdata, location, state in
            guard let userdata else { return }
            DispatchQueue.main.async {
                let controller = Unmanaged<QuakeTerminalController>.fromOpaque(userdata).takeUnretainedValue()
                controller.readClipboard(location: location, state: state)
            }
        }
        runtimeConfig.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtimeConfig.write_clipboard_cb = { userdata, location, content, len, confirm in
            guard let userdata, let content, len > 0 else { return }
            var plainText: String?
            for i in 0..<len {
                guard let mimePtr = content[i].mime,
                      let dataPtr = content[i].data else { continue }
                let mime = String(cString: mimePtr)
                if mime == "text/plain" {
                    plainText = String(cString: dataPtr)
                    break
                }
            }
            guard let text = plainText else { return }
            DispatchQueue.main.async {
                let controller = Unmanaged<QuakeTerminalController>.fromOpaque(userdata).takeUnretainedValue()
                controller.writeClipboard(location: location, text: text)
            }
        }
        runtimeConfig.close_surface_cb = { userdata, processAlive in
            guard let userdata else { return }
            DispatchQueue.main.async {
                let controller = Unmanaged<QuakeTerminalController>.fromOpaque(userdata).takeUnretainedValue()
                controller.surfaceClosed(processAlive: processAlive)
            }
        }

        ghosttyApp = ghostty_app_new(&runtimeConfig, ghosttyConfig)
        guard ghosttyApp != nil else {
            print("QuakeTerminal: Failed to create ghostty app")
            return
        }

        createWindow()
    }

    func cleanup() {
        for tab in tabs {
            for (surface, _) in tab.allSurfaces() {
                ghostty_surface_free(surface)
            }
        }
        tabs.removeAll()
        activeTabIndex = 0

        if let ghosttyApp {
            ghostty_app_free(ghosttyApp)
            self.ghosttyApp = nil
        }
        if let ghosttyConfig {
            ghostty_config_free(ghosttyConfig)
            self.ghosttyConfig = nil
        }
        window?.close()
        window = nil
        containerView = nil
        tabBar = nil
    }

    private func updateGhosttyOpacityConfig() {
        let opacity = settings.quakeTerminalOpacity
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty")
        let configFile = configDir.appendingPathComponent("config")

        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

            var lines: [String] = []
            if FileManager.default.fileExists(atPath: configFile.path) {
                let content = try String(contentsOf: configFile, encoding: .utf8)
                lines = content.components(separatedBy: .newlines)
            }

            let opacityLine = String(format: "background-opacity = %.2f", opacity)
            var found = false
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("background-opacity") {
                    lines[index] = opacityLine
                    found = true
                    break
                }
            }

            if !found {
                if !lines.isEmpty && !lines.last!.isEmpty {
                    lines.append("")
                }
                lines.append(opacityLine)
            }

            let newContent = lines.joined(separator: "\n")
            try newContent.write(to: configFile, atomically: true, encoding: .utf8)
        } catch {
            print("QuakeTerminal: Failed to update ghostty config: \(error)")
        }
    }

    func reloadOpacityConfig() {
        guard let ghosttyApp else { return }

        updateGhosttyOpacityConfig()

        guard let newConfig = ghostty_config_new() else { return }
        ghostty_config_load_default_files(newConfig)
        ghostty_config_finalize(newConfig)

        ghostty_app_update_config(ghosttyApp, newConfig)
        ghostty_config_free(newConfig)
    }

    private func tick() {
        guard let ghosttyApp else { return }
        ghostty_app_tick(ghosttyApp)
    }

    private func createWindow() {
        let win = QuakeTerminalWindow()
        win.delegate = self
        win.tabController = self
        self.window = win

        let container = NSView(frame: win.contentView?.bounds ?? .zero)
        container.autoresizingMask = [.width, .height]
        win.contentView = container
        self.containerView = container

        let bar = QuakeTerminalTabBar()
        bar.delegate = self
        bar.isHidden = true
        bar.autoresizingMask = [.width]
        bar.frame = NSRect(x: 0, y: container.bounds.height - QuakeTerminalTabBar.barHeight,
                           width: container.bounds.width, height: QuakeTerminalTabBar.barHeight)
        container.addSubview(bar)
        self.tabBar = bar
    }

    private func createSurfaceView() -> GhosttySurfaceView? {
        guard let ghosttyApp else { return nil }
        let userdata = Unmanaged.passUnretained(self).toOpaque()
        let view = GhosttySurfaceView(ghosttyApp: ghosttyApp, userdata: userdata)
        guard view.ghosttySurface != nil else { return nil }
        view.onFrameChanged = { [weak self] frame in
            self?.persistCustomFrame(frame)
        }
        return view
    }

    @discardableResult
    private func createTab() -> QuakeTerminalTab? {
        guard let view = createSurfaceView() else { return nil }

        let splitContainer = QuakeSplitContainer(initialView: view)
        let tab = QuakeTerminalTab(splitContainer: splitContainer)
        tabs.append(tab)
        switchToTab(at: tabs.count - 1)
        return tab
    }

    func splitActivePane(direction: SplitDirection) {
        guard let tab = activeTab,
              let focused = tab.focusedSurfaceView,
              let newView = createSurfaceView() else { return }
        tab.splitContainer.split(view: focused, direction: direction, newView: newView)
        window?.makeFirstResponder(newView)
    }

    func closeActivePane() {
        guard let tab = activeTab,
              let focused = tab.focusedSurfaceView,
              let focusedSurface = focused.ghosttySurface else { return }

        let leafCount = tab.splitContainer.root.leafCount()

        if leafCount <= 1 {
            closeTab(at: activeTabIndex)
            return
        }

        let removed = tab.splitContainer.remove(view: focused)
        if removed {
            ghostty_surface_free(focusedSurface)
            if let newFocus = tab.splitContainer.focusedView {
                window?.makeFirstResponder(newFocus)
            }
        }
    }

    func navigatePane(direction: NavigationDirection) {
        activeTab?.splitContainer.navigate(direction: direction)
    }

    func equalizeSplits() {
        activeTab?.splitContainer.equalize()
    }

    func closeTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }

        let tab = tabs[index]
        for (surface, _) in tab.allSurfaces() {
            ghostty_surface_free(surface)
        }
        tab.splitContainer.removeFromSuperview()
        tabs.remove(at: index)

        if tabs.isEmpty {
            activeTabIndex = 0
            updateTabBarVisibility()
            if visible {
                animateOut()
            }
            return
        }

        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        } else if activeTabIndex > index {
            activeTabIndex -= 1
        } else if activeTabIndex == index {
            activeTabIndex = min(activeTabIndex, tabs.count - 1)
        }

        switchToTab(at: activeTabIndex)
    }

    func switchToTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }

        if activeTabIndex < tabs.count {
            tabs[activeTabIndex].splitContainer.removeFromSuperview()
        }

        activeTabIndex = index
        let tab = tabs[index]

        guard let containerView else { return }
        let showBar = tabs.count > 1
        let barHeight = showBar ? QuakeTerminalTabBar.barHeight : 0
        let surfaceFrame = NSRect(
            x: 0, y: 0,
            width: containerView.bounds.width,
            height: containerView.bounds.height - barHeight
        )
        tab.splitContainer.frame = surfaceFrame
        tab.splitContainer.autoresizingMask = [.width, .height]
        containerView.addSubview(tab.splitContainer)

        if let focused = tab.focusedSurfaceView {
            window?.makeFirstResponder(focused)
        }

        updateTabBarVisibility()
        tab.splitContainer.relayout()
    }

    func selectNextTab() {
        guard tabs.count > 1 else { return }
        switchToTab(at: (activeTabIndex + 1) % tabs.count)
    }

    func selectPreviousTab() {
        guard tabs.count > 1 else { return }
        switchToTab(at: (activeTabIndex - 1 + tabs.count) % tabs.count)
    }

    func selectTab(at index: Int) {
        switchToTab(at: index)
    }

    func requestNewTab() {
        createTab()
    }

    func requestCloseActiveTab() {
        guard !tabs.isEmpty else { return }
        closeTab(at: activeTabIndex)
    }

    private func updateTabBarVisibility() {
        guard let tabBar, let containerView else { return }
        let showBar = tabs.count > 1
        tabBar.isHidden = !showBar

        if showBar {
            tabBar.frame = NSRect(
                x: 0,
                y: containerView.bounds.height - QuakeTerminalTabBar.barHeight,
                width: containerView.bounds.width,
                height: QuakeTerminalTabBar.barHeight
            )
            tabBar.update(
                titles: tabs.map { $0.title },
                selectedIndex: activeTabIndex
            )
        }

        if let activeContainer = activeTab?.splitContainer {
            let barHeight = showBar ? QuakeTerminalTabBar.barHeight : 0
            activeContainer.frame = NSRect(
                x: 0, y: 0,
                width: containerView.bounds.width,
                height: containerView.bounds.height - barHeight
            )
            activeContainer.relayout()
        }
    }

    private func createInitialSurface() {
        guard tabs.isEmpty else { return }
        createTab()

        if let window {
            let screen = targetScreen()
            let position = settings.quakeTerminalPosition
            position.setFinal(
                in: window,
                on: screen,
                widthPercent: settings.quakeTerminalWidthPercent,
                heightPercent: settings.quakeTerminalHeightPercent
            )
        }
    }

    func toggle() {
        if visible {
            animateOut()
        } else {
            animateIn()
        }
    }

    func animateIn() {
        guard let window else { return }
        guard !visible else { return }

        visible = true

        if !NSApp.isActive {
            if let previousApp = NSWorkspace.shared.frontmostApplication,
               previousApp.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.previousApp = previousApp
            }
        }

        if tabs.isEmpty {
            createInitialSurface()
        }

        animateWindowIn(window: window)
    }

    func animateOut() {
        guard let window else { return }
        guard visible else { return }

        if settings.quakeTerminalUseCustomFrame {
            settings.quakeTerminalCustomFrame = window.frame
        }

        visible = false
        animateWindowOut(window: window)
    }

    private func persistCustomFrame(_ frame: NSRect) {
        settings.quakeTerminalCustomFrame = frame
        settings.quakeTerminalUseCustomFrame = true
        UserDefaults.standard.synchronize()
    }

    private func animateWindowIn(window: NSWindow) {
        let quakeWindow = window as? QuakeTerminalWindow
        let screen = targetScreen()

        if settings.quakeTerminalUseCustomFrame,
           let customFrame = settings.quakeTerminalCustomFrame,
           screen.visibleFrame.intersects(customFrame) {
            window.setFrame(customFrame, display: false)
            window.alphaValue = 0
            window.level = .popUpMenu
            window.makeKeyAndOrderFront(nil)

            let finishAnimation: @Sendable () -> Void = { [weak self] in
                Task { @MainActor in
                    guard let self, self.visible else { return }
                    window.level = .floating
                    self.makeWindowKey(window)

                    if !NSApp.isActive {
                        NSApp.activate(ignoringOtherApps: true)
                        DispatchQueue.main.async {
                            guard !window.isKeyWindow else { return }
                            self.makeWindowKey(window, retries: 10)
                        }
                    }
                }
            }

            if settings.animationsEnabled {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = settings.quakeTerminalAnimationDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    window.animator().alphaValue = 1
                }, completionHandler: finishAnimation)
            } else {
                window.alphaValue = 1
                finishAnimation()
            }
            return
        }

        let position = settings.quakeTerminalPosition
        let widthPercent = settings.quakeTerminalWidthPercent
        let heightPercent = settings.quakeTerminalHeightPercent

        position.setInitial(
            in: window,
            on: screen,
            widthPercent: widthPercent,
            heightPercent: heightPercent
        )

        window.level = .popUpMenu
        window.makeKeyAndOrderFront(nil)

        let finishAnimation: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self, self.visible else { return }
                quakeWindow?.isAnimating = false
                window.level = .floating
                self.makeWindowKey(window)

                if !NSApp.isActive {
                    NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.async {
                        guard !window.isKeyWindow else { return }
                        self.makeWindowKey(window, retries: 10)
                    }
                }
            }
        }

        if settings.animationsEnabled {
            quakeWindow?.isAnimating = true
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = settings.quakeTerminalAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                position.setFinal(
                    in: window.animator(),
                    on: screen,
                    widthPercent: widthPercent,
                    heightPercent: heightPercent
                )
            }, completionHandler: finishAnimation)
        } else {
            position.setFinal(
                in: window,
                on: screen,
                widthPercent: widthPercent,
                heightPercent: heightPercent
            )
            finishAnimation()
        }
    }

    private func animateWindowOut(window: NSWindow) {
        let quakeWindow = window as? QuakeTerminalWindow

        if let previousApp = self.previousApp {
            self.previousApp = nil
            if !previousApp.isTerminated {
                _ = previousApp.activate(options: [])
            }
        }

        window.level = .popUpMenu

        let finishAnimation: @Sendable () -> Void = {
            Task { @MainActor in
                window.orderOut(nil)
                window.alphaValue = 1
            }
        }

        if settings.quakeTerminalUseCustomFrame {
            if settings.animationsEnabled {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = settings.quakeTerminalAnimationDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    window.animator().alphaValue = 0
                }, completionHandler: finishAnimation)
            } else {
                window.alphaValue = 0
                finishAnimation()
            }
            return
        }

        let screen = window.screen ?? targetScreen()
        let position = settings.quakeTerminalPosition
        let widthPercent = settings.quakeTerminalWidthPercent
        let heightPercent = settings.quakeTerminalHeightPercent

        if settings.animationsEnabled {
            quakeWindow?.isAnimating = true
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = settings.quakeTerminalAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                position.setInitial(
                    in: window.animator(),
                    on: screen,
                    widthPercent: widthPercent,
                    heightPercent: heightPercent
                )
            }, completionHandler: {
                Task { @MainActor in
                    quakeWindow?.isAnimating = false
                }
                finishAnimation()
            })
        } else {
            position.setInitial(
                in: window,
                on: screen,
                widthPercent: widthPercent,
                heightPercent: heightPercent
            )
            finishAnimation()
        }
    }

    private func makeWindowKey(_ window: NSWindow, retries: UInt8 = 0) {
        guard visible else { return }
        window.makeKeyAndOrderFront(nil)

        if let surfaceView {
            window.makeFirstResponder(surfaceView)
        }

        guard !window.isKeyWindow, retries > 0 else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in
            self?.makeWindowKey(window, retries: retries - 1)
        }
    }

    private func readClipboard(location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) {
        guard let surface else { return }
        let pasteboard = location == GHOSTTY_CLIPBOARD_SELECTION ? NSPasteboard(name: .find) : NSPasteboard.general
        let str = pasteboard.string(forType: .string) ?? ""
        str.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
        }
    }

    private func writeClipboard(location: ghostty_clipboard_e, text: String) {
        let pasteboard = location == GHOSTTY_CLIPBOARD_SELECTION ? NSPasteboard(name: .find) : NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func targetScreen() -> NSScreen {
        let monitors = Monitor.current()

        switch settings.quakeTerminalMonitorMode {
        case .mouseCursor:
            let mouseLocation = NSEvent.mouseLocation
            if let monitor = mouseLocation.monitorApproximation(in: monitors),
               let screen = NSScreen.screens.first(where: { $0.displayId == monitor.displayId }) {
                return screen
            }

        case .focusedWindow:
            if let screen = screenOfFocusedWindow(monitors: monitors) {
                return screen
            }

        case .mainMonitor:
            break
        }

        return NSScreen.main ?? NSScreen.screens.first!
    }

    private func screenOfFocusedWindow(monitors: [Monitor]) -> NSScreen? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier

        for windowInfo in windowList {
            guard let windowPID = windowInfo[kCGWindowOwnerPID as String] as? Int32,
                  windowPID != ownPID,
                  let layer = windowInfo[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"],
                  let y = boundsDict["Y"],
                  let width = boundsDict["Width"],
                  let height = boundsDict["Height"],
                  width > 50, height > 50
            else {
                continue
            }

            let windowCenter = CGPoint(x: x + width / 2, y: y + height / 2)
            let flippedCenter = CGPoint(x: windowCenter.x, y: NSScreen.screens.first!.frame.height - windowCenter.y)

            if let monitor = flippedCenter.monitorApproximation(in: monitors),
               let screen = NSScreen.screens.first(where: { $0.displayId == monitor.displayId }) {
                return screen
            }
        }

        return nil
    }

    private func surfaceClosed(processAlive: Bool) {
        guard !processAlive else {
            if visible { animateOut() }
            return
        }

        guard let closedView = surfaceView else {
            if visible { animateOut() }
            return
        }

        for (tabIndex, tab) in tabs.enumerated() {
            guard tab.splitContainer.contains(view: closedView) else { continue }

            let leafCount = tab.splitContainer.root.leafCount()

            if leafCount <= 1 {
                tab.splitContainer.removeFromSuperview()
                tabs.remove(at: tabIndex)

                if tabs.isEmpty {
                    activeTabIndex = 0
                    updateTabBarVisibility()
                    if visible { animateOut() }
                    return
                }

                if activeTabIndex >= tabs.count {
                    activeTabIndex = tabs.count - 1
                }
                switchToTab(at: activeTabIndex)
                return
            }

            let _ = tab.splitContainer.remove(view: closedView)
            if let newFocus = tab.splitContainer.focusedView {
                window?.makeFirstResponder(newFocus)
            }
            return
        }

        if visible { animateOut() }
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in
            guard visible else { return }
            guard window?.attachedSheet == nil else { return }

            if NSApp.isActive {
                self.previousApp = nil
            }

            if settings.quakeTerminalAutoHide {
                animateOut()
            }
        }
    }

    nonisolated func windowDidResize(_ notification: Notification) {
        guard let notificationWindow = notification.object as? NSWindow else { return }
        Task { @MainActor in
            guard notificationWindow == self.window,
                  visible,
                  !isHandlingResize else { return }
            guard let window = self.window,
                  let screen = window.screen ?? NSScreen.main else { return }

            isHandlingResize = true
            defer { isHandlingResize = false }

            if surfaceView?.isInteracting != true && !settings.quakeTerminalUseCustomFrame {
                let position = settings.quakeTerminalPosition
                switch position {
                case .top, .bottom, .center:
                    let newOrigin = position.centeredOrigin(for: window, on: screen)
                    window.setFrameOrigin(newOrigin)
                case .left, .right:
                    let newOrigin = position.verticallyCenteredOrigin(for: window, on: screen)
                    window.setFrameOrigin(newOrigin)
                }
            }

            updateTabBarVisibility()
        }
    }

    // MARK: - QuakeTerminalTabBarDelegate

    func tabBarDidSelectTab(at index: Int) {
        switchToTab(at: index)
    }

    func tabBarDidRequestNewTab() {
        createTab()
    }

    func tabBarDidRequestCloseTab(at index: Int) {
        closeTab(at: index)
    }
}

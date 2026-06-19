// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Cocoa
import GhosttyKit

enum QuakeTerminalRestoreTarget: Equatable {
    case managed(WindowToken)
    case external(KeyboardFocusTarget)
}

@MainActor
final class QuakeTerminalController: NSObject, NSWindowDelegate, QuakeTerminalTabBarDelegate {
    private enum HideBehavior {
        case restoreLatestTarget
        case preserveCurrentFocus
    }

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

    private var surface: ghostty_surface_t? {
        activeTab?.focusedSurface
    }

    private var surfaceView: GhosttySurfaceView? {
        activeTab?.focusedSurfaceView
    }

    private(set) var visible: Bool = false
    private var restoreTarget: QuakeTerminalRestoreTarget?
    private var pendingRestoreTarget: QuakeTerminalRestoreTarget?
    private var isHandlingResize: Bool = false
    private var isTransitioning = false
    private var animationGeneration: UInt64 = 0
    private var appearanceObserver: NSKeyValueObservation?
    private var appliedColorScheme: ghostty_color_scheme_e?

    private let settings: SettingsStore
    private let motionPolicy: MotionPolicy
    private let ghosttyConfigBuilder: QuakeGhosttyConfigBuilder
    private let surfaceCoordinator = SurfaceCoordinator.shared
    private let captureRestoreTarget: @MainActor () -> QuakeTerminalRestoreTarget?
    private let restoreFocusTarget: @MainActor (QuakeTerminalRestoreTarget) -> Void
    private let isWindowFocused: @MainActor (NSWindow) -> Bool
    private let focusedWindowScreenProvider: @MainActor () -> NSScreen?

    private static var ghosttyInitialized = false

    init(
        settings: SettingsStore,
        motionPolicy: MotionPolicy,
        captureRestoreTarget: @escaping @MainActor () -> QuakeTerminalRestoreTarget? = { nil },
        restoreFocusTarget: @escaping @MainActor (QuakeTerminalRestoreTarget) -> Void = { _ in },
        isWindowFocused: @escaping @MainActor (NSWindow) -> Bool = { $0.isKeyWindow },
        focusedWindowScreenProvider: @escaping @MainActor () -> NSScreen? = { nil },
        ghosttyConfigBuilder: QuakeGhosttyConfigBuilder = QuakeGhosttyConfigBuilder()
    ) {
        self.settings = settings
        self.motionPolicy = motionPolicy
        self.ghosttyConfigBuilder = ghosttyConfigBuilder
        self.captureRestoreTarget = captureRestoreTarget
        self.restoreFocusTarget = restoreFocusTarget
        self.isWindowFocused = isWindowFocused
        self.focusedWindowScreenProvider = focusedWindowScreenProvider
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

        guard let config = makeGhosttyConfig() else {
            print("QuakeTerminal: Failed to create ghostty config")
            return
        }
        ghosttyConfig = config

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
            guard let userdata else { return false }
            DispatchQueue.main.async {
                let controller = Unmanaged<QuakeTerminalController>.fromOpaque(userdata).takeUnretainedValue()
                controller.readClipboard(location: location, state: state)
            }
            return true
        }
        runtimeConfig.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtimeConfig.write_clipboard_cb = { userdata, location, content, len, confirm in
            guard let userdata, let content, len > 0 else { return }
            var plainText: String?
            for i in 0 ..< len {
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

        ghosttyApp = ghostty_app_new(&runtimeConfig, config)
        guard ghosttyApp != nil else {
            print("QuakeTerminal: Failed to create ghostty app")
            ghostty_config_free(config)
            ghosttyConfig = nil
            return
        }

        startGhosttyAppearanceSync()
        applyCurrentGhosttyColorScheme()
        createWindow()
    }

    func cleanup() {
        stopGhosttyAppearanceSync()
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
        surfaceCoordinator.unregister(id: surfaceID)
        window?.close()
        window = nil
        containerView = nil
        tabBar = nil
        restoreTarget = nil
        pendingRestoreTarget = nil
    }

    private func makeGhosttyConfig() -> ghostty_config_t? {
        ghosttyConfigBuilder.build(opacity: settings.quakeTerminalOpacity)
    }

    func reloadOpacityConfig() {
        guard let ghosttyApp else { return }
        guard let newConfig = makeGhosttyConfig() else { return }

        ghostty_app_update_config(ghosttyApp, newConfig)
        ghostty_config_free(newConfig)
        applyCurrentGhosttyColorScheme()
    }

    private func startGhosttyAppearanceSync() {
        appearanceObserver = NSApplication.shared.observe(
            \.effectiveAppearance,
            options: [.new, .initial]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyCurrentGhosttyColorScheme()
            }
        }
    }

    private func stopGhosttyAppearanceSync() {
        appearanceObserver?.invalidate()
        appearanceObserver = nil
        appliedColorScheme = nil
    }

    private func applyCurrentGhosttyColorScheme() {
        applyGhosttyColorScheme(for: NSApplication.shared.effectiveAppearance)
    }

    private func applyGhosttyColorScheme(for appearance: NSAppearance) {
        guard let ghosttyApp else { return }
        let scheme = Self.ghosttyColorScheme(for: appearance)
        guard appliedColorScheme != scheme else { return }
        ghostty_app_set_color_scheme(ghosttyApp, scheme)
        appliedColorScheme = scheme
    }

    static func ghosttyColorScheme(for appearance: NSAppearance) -> ghostty_color_scheme_e {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? GHOSTTY_COLOR_SCHEME_DARK
            : GHOSTTY_COLOR_SCHEME_LIGHT
    }

    func applyGeometryToVisibleWindow() {
        guard let window, visible else { return }
        let screen = targetScreen()

        if let customFrame = customFrameForShow(on: screen) {
            window.setFrame(customFrame, display: true)
            return
        }

        settings.quakeTerminalPosition.setFinal(
            in: window,
            on: screen,
            widthPercent: settings.quakeTerminalWidthPercent,
            heightPercent: settings.quakeTerminalHeightPercent
        )
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
        surfaceCoordinator.register(
            window: win,
            id: surfaceID,
            policy: SurfacePolicy(
                kind: .quake,
                hitTestPolicy: .interactive,
                capturePolicy: .included,
                suppressesManagedFocusRecovery: true
            )
        )

        let container = NSView(frame: win.contentView?.bounds ?? .zero)
        container.autoresizingMask = [.width, .height]
        win.contentView = container
        self.containerView = container

        let bar = QuakeTerminalTabBar()
        bar.delegate = self
        bar.isHidden = true
        bar.autoresizingMask = [.width]
        bar.frame = NSRect(
            x: 0,
            y: container.bounds.height - QuakeTerminalTabBar.barHeight,
            width: container.bounds.width,
            height: QuakeTerminalTabBar.barHeight
        )
        container.addSubview(bar)
        self.tabBar = bar
    }

    private var surfaceID: String {
        "quake-terminal"
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

        restoreTarget = captureRestoreTarget()
        pendingRestoreTarget = nil
        visible = true

        if tabs.isEmpty {
            createInitialSurface()
        }

        animateWindowIn(window: window)
    }

    func animateOut() {
        animateOut(hideBehavior: .restoreLatestTarget)
    }

    private func animateOut(hideBehavior: HideBehavior) {
        guard let window else { return }
        guard visible else { return }

        if settings.quakeTerminalUseCustomFrame {
            settings.quakeTerminalCustomFrame = window.frame
        }

        pendingRestoreTarget = switch hideBehavior {
        case .restoreLatestTarget:
            if isWindowFocused(window) {
                restoreTarget
            } else {
                nil
            }
        case .preserveCurrentFocus:
            nil
        }
        restoreTarget = nil
        visible = false
        animateWindowOut(window: window)
    }

    private func persistCustomFrame(_ frame: NSRect) {
        guard let customFrame = QuakeTerminalGeometryPolicy.normalizedCustomFrame(frame) else {
            settings.resetQuakeTerminalCustomFrame()
            return
        }

        settings.quakeTerminalUseCustomFrame = true
        settings.quakeTerminalCustomFrame = customFrame
    }

    private func animateWindowIn(window: NSWindow) {
        let quakeWindow = window as? QuakeTerminalWindow
        let screen = targetScreen()
        let generation = beginAnimationTransition()

        if let customFrame = customFrameForShow(on: screen) {
            window.setFrame(customFrame, display: false)
            window.level = .popUpMenu
            window.makeKeyAndOrderFront(nil)

            if !motionPolicy.animationsEnabled {
                finishWindowIn(window)
                return
            }

            window.alphaValue = 0
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = settings.quakeTerminalAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 1
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.animationGeneration == generation, self.visible else { return }
                    self.finishWindowIn(window)
                }
            })
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

        if !motionPolicy.animationsEnabled {
            position.setFinal(
                in: window,
                on: screen,
                widthPercent: widthPercent,
                heightPercent: heightPercent
            )
            finishWindowIn(window)
            return
        }

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
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.animationGeneration == generation, self.visible else { return }
                self.finishWindowIn(window)
            }
        })
    }

    private func animateWindowOut(window: NSWindow) {
        let quakeWindow = window as? QuakeTerminalWindow
        let generation = beginAnimationTransition()

        window.level = .popUpMenu

        if settings.quakeTerminalUseCustomFrame {
            if !motionPolicy.animationsEnabled {
                finishWindowOut(window)
                return
            }

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = settings.quakeTerminalAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.animationGeneration == generation, !self.visible else { return }
                    self.finishWindowOut(window)
                }
            })
            return
        }

        let screen = window.screen ?? targetScreen()
        let position = settings.quakeTerminalPosition
        let widthPercent = settings.quakeTerminalWidthPercent
        let heightPercent = settings.quakeTerminalHeightPercent

        if !motionPolicy.animationsEnabled {
            position.setInitial(
                in: window,
                on: screen,
                widthPercent: widthPercent,
                heightPercent: heightPercent
            )
            finishWindowOut(window)
            return
        }

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
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.animationGeneration == generation, !self.visible else { return }
                quakeWindow?.isAnimating = false
                self.finishWindowOut(window)
            }
        })
    }

    private func beginAnimationTransition() -> UInt64 {
        animationGeneration &+= 1
        isTransitioning = true
        return animationGeneration
    }

    private func finishWindowIn(_ window: NSWindow) {
        let quakeWindow = window as? QuakeTerminalWindow
        quakeWindow?.isAnimating = false
        isTransitioning = false
        window.alphaValue = 1
        window.level = .floating
        makeWindowKey(window)

        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.visible, !window.isKeyWindow else { return }
                self.makeWindowKey(window, retries: 10)
            }
        }
    }

    private func finishWindowOut(_ window: NSWindow) {
        let quakeWindow = window as? QuakeTerminalWindow
        quakeWindow?.isAnimating = false
        isTransitioning = false
        window.orderOut(nil)
        window.alphaValue = 1

        if let pendingRestoreTarget {
            self.pendingRestoreTarget = nil
            restoreFocusTarget(pendingRestoreTarget)
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

    private func customFrameForShow(on screen: NSScreen) -> NSRect? {
        guard settings.quakeTerminalUseCustomFrame else { return nil }
        guard let customFrame = QuakeTerminalGeometryPolicy.normalizedCustomFrame(settings.quakeTerminalCustomFrame)
        else {
            settings.resetQuakeTerminalCustomFrame()
            return nil
        }
        guard screen.visibleFrame.intersects(customFrame) else { return nil }
        return customFrame
    }

    private func targetScreen() -> NSScreen {
        let monitors = Monitor.current()

        switch settings.quakeTerminalMonitorMode {
        case .mouseCursor:
            let mouseLocation = NSEvent.mouseLocation
            if let monitor = mouseLocation.monitorApproximation(in: monitors),
               let screen = NSScreen.screens.first(where: { $0.displayId == monitor.displayId })
            {
                return screen
            }

        case .focusedWindow:
            if let screen = focusedWindowScreenProvider() {
                return screen
            }
            if let screen = screenOfFocusedWindow(monitors: monitors) {
                return screen
            }

        case .mainMonitor:
            break
        }

        return NSScreen.main ?? NSScreen.screens.first!
    }

    private func screenOfFocusedWindow(monitors: [Monitor]) -> NSScreen? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        if let displayId = Self.focusedWindowDisplayId(
            monitors: monitors,
            windowList: windowList,
            ownPID: ProcessInfo.processInfo.processIdentifier
        ) {
            return NSScreen.screens.first(where: { $0.displayId == displayId })
        }

        return nil
    }

    static func focusedWindowDisplayId(
        monitors: [Monitor],
        windowList: [[String: Any]],
        ownPID: pid_t,
        toAppKitRect: (CGRect) -> CGRect = ScreenCoordinateSpace.toAppKit(rect:)
    ) -> CGDirectDisplayID? {
        for windowInfo in windowList {
            guard let windowPID = int32Value(windowInfo[kCGWindowOwnerPID as String]),
                  windowPID != ownPID,
                  intValue(windowInfo[kCGWindowLayer as String]) == 0,
                  let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let x = cgFloatValue(boundsDict["X"]),
                  let y = cgFloatValue(boundsDict["Y"]),
                  let width = cgFloatValue(boundsDict["Width"]),
                  let height = cgFloatValue(boundsDict["Height"]),
                  x.isFinite,
                  y.isFinite,
                  width.isFinite,
                  height.isFinite,
                  width > 50,
                  height > 50,
                  width <= QuakeTerminalGeometryPolicy.maximumCustomFrameDimensionPoints,
                  height <= QuakeTerminalGeometryPolicy.maximumCustomFrameDimensionPoints
            else {
                continue
            }

            let appKitFrame = toAppKitRect(CGRect(x: x, y: y, width: width, height: height))
            if let monitor = appKitFrame.center.monitorApproximation(in: monitors) {
                return monitor.displayId
            }
        }

        return nil
    }

    private static func cgFloatValue(_ value: Any?) -> CGFloat? {
        switch value {
        case let value as CGFloat:
            return value
        case let value as Double:
            return CGFloat(value)
        case let value as Float:
            return CGFloat(value)
        case let value as Int:
            return CGFloat(value)
        case let value as NSNumber:
            return CGFloat(truncating: value)
        default:
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as Int32:
            return Int(value)
        case let value as Int64:
            return Int(exactly: value)
        case let value as NSNumber:
            guard let value = exactInt64Value(value) else { return nil }
            return Int(exactly: value)
        default:
            return nil
        }
    }

    private static func int32Value(_ value: Any?) -> Int32? {
        switch value {
        case let value as Int32:
            return value
        case let value as Int:
            return Int32(exactly: value)
        case let value as Int64:
            return Int32(exactly: value)
        case let value as NSNumber:
            guard let value = exactInt64Value(value) else { return nil }
            return Int32(exactly: value)
        default:
            return nil
        }
    }

    private static func exactInt64Value(_ value: NSNumber) -> Int64? {
        let type = CFNumberGetType(value)
        switch type {
        case .charType,
             .shortType,
             .intType,
             .longType,
             .longLongType,
             .sInt8Type,
             .sInt16Type,
             .sInt32Type,
             .sInt64Type,
             .cfIndexType,
             .nsIntegerType:
            var exact: Int64 = 0
            guard CFNumberGetValue(value, .sInt64Type, &exact) else { return nil }
            return exact
        default:
            var doubleValue = 0.0
            guard CFNumberGetValue(value, .doubleType, &doubleValue),
                  doubleValue.isFinite,
                  doubleValue.rounded(.towardZero) == doubleValue,
                  doubleValue >= Double(Int64.min),
                  doubleValue <= Double(Int64.max)
            else {
                return nil
            }
            let exact = Int64(doubleValue)
            guard Double(exact) == doubleValue else { return nil }
            return exact
        }
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

            await Task.yield()
            guard visible else { return }
            restoreTarget = captureRestoreTarget()

            if settings.quakeTerminalAutoHide {
                animateOut(hideBehavior: .preserveCurrentFocus)
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
                case .top,
                     .bottom,
                     .center:
                    let newOrigin = position.centeredOrigin(for: window, on: screen)
                    window.setFrameOrigin(newOrigin)
                case .left,
                     .right:
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

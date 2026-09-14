// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Cocoa
import GhosttyKit

@MainActor
final class QuakeTerminalTabs: QuakeTerminalTabBarDelegate {
    private weak var window: QuakeTerminalWindow?
    private var containerView: NSView?
    private var tabBar: QuakeTerminalTabBar?
    private var makeSurfaceView: (() -> GhosttySurfaceView?)?
    private var onLastTabClosed: (() -> Void)?

    func connect(makeSurfaceView: @escaping () -> GhosttySurfaceView?, onLastTabClosed: @escaping () -> Void) {
        self.makeSurfaceView = makeSurfaceView
        self.onLastTabClosed = onLastTabClosed
    }

    private var tabs: [QuakeTerminalTab] = []
    private var activeTabIndex: Int = 0

    private var activeTab: QuakeTerminalTab? {
        guard activeTabIndex >= 0, activeTabIndex < tabs.count else { return nil }
        return tabs[activeTabIndex]
    }

    var surfaceView: GhosttySurfaceView? {
        activeTab?.focusedSurfaceView
    }

    func removeAll() {
        for tab in tabs {
            for view in tab.splitContainer.allSurfaceViews() {
                view.releaseSurface()
            }
        }
        tabs.removeAll()
        activeTabIndex = 0
        containerView = nil
        tabBar = nil
        window = nil
    }

    var isEmpty: Bool {
        tabs.isEmpty
    }

    func refreshSurfacesForCurrentScreen() {
        guard let container = activeTab?.splitContainer else { return }
        for view in container.allSurfaceViews() {
            view.refreshDisplayStateForCurrentScreen()
        }
    }

    func attach(to window: QuakeTerminalWindow, container: NSView) {
        self.window = window
        containerView = container
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

    @discardableResult
    func createTab() -> QuakeTerminalTab? {
        guard let view = makeSurfaceView?() else { return nil }

        let splitContainer = QuakeSplitContainer(initialView: view)
        let tab = QuakeTerminalTab(splitContainer: splitContainer)
        tabs.append(tab)
        switchToTab(at: tabs.count - 1)
        return tab
    }

    func splitActivePane(direction: SplitDirection) {
        guard let tab = activeTab,
              let focused = tab.focusedSurfaceView,
              let newView = makeSurfaceView?() else { return }
        tab.splitContainer.split(view: focused, direction: direction, newView: newView)
        window?.makeFirstResponder(newView)
    }

    func closeActivePane() {
        guard let tab = activeTab,
              let focused = tab.focusedSurfaceView else { return }

        if tab.splitContainer.root.leafCount() <= 1 {
            closeTab(at: activeTabIndex)
            return
        }

        if tab.splitContainer.remove(view: focused) {
            focused.releaseSurface()
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
        for view in tab.splitContainer.allSurfaceViews() {
            view.releaseSurface()
        }
        tab.splitContainer.removeFromSuperview()
        tabs.remove(at: index)

        if tabs.isEmpty {
            activeTabIndex = 0
            updateTabBarVisibility()
            onLastTabClosed?()
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

    func updateTabBarVisibility() {
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

    func surfaceClosed(_ closedView: GhosttySurfaceView) {
        guard let tabIndex = tabs.firstIndex(where: { $0.splitContainer.contains(view: closedView) }) else {
            closedView.releaseSurface()
            return
        }

        let tab = tabs[tabIndex]
        if tab.splitContainer.root.leafCount() <= 1 {
            closeTab(at: tabIndex)
            return
        }

        if tab.splitContainer.remove(view: closedView) {
            closedView.releaseSurface()
            if tabIndex == activeTabIndex, let newFocus = tab.splitContainer.focusedView {
                window?.makeFirstResponder(newFocus)
            }
        }
    }

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

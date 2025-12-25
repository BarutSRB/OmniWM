import AppKit
import SwiftUI

enum WorkspaceBarWindowLevel: String, CaseIterable, Identifiable {
    case normal
    case floating
    case status
    case popup
    case screensaver

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: "Normal"
        case .floating: "Floating"
        case .status: "Status Bar"
        case .popup: "Popup"
        case .screensaver: "Screen Saver"
        }
    }

    var nsWindowLevel: NSWindow.Level {
        switch self {
        case .normal: .normal
        case .floating: .floating
        case .status: .statusBar
        case .popup: .popUpMenu
        case .screensaver: .screenSaver
        }
    }
}

enum WorkspaceBarPosition: String, CaseIterable, Identifiable {
    case overlappingMenuBar
    case belowMenuBar

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .overlappingMenuBar: "Overlapping Menu Bar"
        case .belowMenuBar: "Below Menu Bar"
        }
    }
}

@MainActor
final class WorkspaceBarManager {
    private struct MonitorBarInstance {
        let monitorId: Monitor.ID
        let panel: NSPanel
        let hostingView: NSHostingView<WorkspaceBarView>
    }

    private var barsByMonitor: [Monitor.ID: MonitorBarInstance] = [:]
    private var screenObserver: Any?
    private var sleepWakeObserver: Any?
    private weak var controller: WMController?
    private weak var settings: SettingsStore?

    init() {
        setupScreenChangeObserver()
        setupSleepWakeObserver()
    }

    func setup(controller: WMController, settings: SettingsStore) {
        self.controller = controller
        self.settings = settings

        guard settings.workspaceBarEnabled else {
            removeAllBars()
            return
        }

        setupBars()
    }

    func update() {
        guard let settings, settings.workspaceBarEnabled else {
            removeAllBars()
            return
        }

        setupBars()
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            setupBars()
        } else {
            removeAllBars()
        }
    }

    func updateSettings() {
        guard settings != nil else { return }
        setupBars()
    }

    private func setupBars() {
        guard controller != nil, let settings else { return }

        let currentMonitors = Monitor.current()
        var existingMonitorIds = Set(barsByMonitor.keys)

        for monitor in currentMonitors {
            existingMonitorIds.remove(monitor.id)
            let resolved = settings.resolvedBarSettings(for: monitor.name)

            if !resolved.enabled {
                removeBarForMonitor(monitor.id)
                continue
            }

            if let existing = barsByMonitor[monitor.id] {
                updateBarForMonitor(monitor, instance: existing)
            } else {
                createBarForMonitor(monitor)
            }
        }

        for monitorId in existingMonitorIds {
            removeBarForMonitor(monitorId)
        }
    }

    private func createBarForMonitor(_ monitor: Monitor) {
        guard let controller, let settings else { return }

        let resolved = settings.resolvedBarSettings(for: monitor.name)
        let panel = createPanel()
        let barHeight = max(menuBarHeight(for: monitor), resolved.height)
        let contentView = WorkspaceBarView(
            controller: controller,
            settings: settings,
            resolvedSettings: resolved,
            monitor: monitor,
            barHeight: CGFloat(barHeight)
        )
        let hostingView = NSHostingView(rootView: contentView)

        panel.contentView = hostingView
        applySettingsToPanel(panel, for: monitor)

        let instance = MonitorBarInstance(
            monitorId: monitor.id,
            panel: panel,
            hostingView: hostingView
        )
        barsByMonitor[monitor.id] = instance

        updateBarFrameAndPosition(for: monitor, instance: instance)
        panel.orderFrontRegardless()
    }

    private func updateBarForMonitor(_ monitor: Monitor, instance: MonitorBarInstance) {
        guard let controller, let settings else { return }

        let resolved = settings.resolvedBarSettings(for: monitor.name)
        let barHeight = max(menuBarHeight(for: monitor), resolved.height)
        instance.hostingView.rootView = WorkspaceBarView(
            controller: controller,
            settings: settings,
            resolvedSettings: resolved,
            monitor: monitor,
            barHeight: CGFloat(barHeight)
        )
        applySettingsToPanel(instance.panel, for: monitor)
        updateBarFrameAndPosition(for: monitor, instance: instance)
    }

    private func removeBarForMonitor(_ monitorId: Monitor.ID) {
        if let instance = barsByMonitor[monitorId] {
            instance.panel.orderOut(nil)
            instance.panel.close()
            barsByMonitor.removeValue(forKey: monitorId)
        }
    }

    func removeAllBars() {
        for (_, instance) in barsByMonitor {
            instance.panel.orderOut(nil)
            instance.panel.close()
        }
        barsByMonitor.removeAll()
    }

    private func createPanel() -> NSPanel {
        let panel = WorkspaceBarPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false

        return panel
    }

    private func updateBarFrameAndPosition(for monitor: Monitor, instance: MonitorBarInstance) {
        guard let settings else { return }
        guard let screen = NSScreen.screens.first(where: { $0.displayId == monitor.id.displayId }) else { return }

        let resolved = settings.resolvedBarSettings(for: monitor.name)
        let fittingSize = instance.hostingView.fittingSize
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let barHeight = max(menuBarHeight(for: monitor), resolved.height)

        let notchAware = resolved.notchAware
        let screenHasNotch = hasNotch(screen: screen)

        let width: CGFloat
        var x: CGFloat
        let height = CGFloat(barHeight)

        var y: CGFloat = if resolved.position == .belowMenuBar {
            visibleFrame.maxY - height
        } else {
            visibleFrame.maxY
        }

        if notchAware, screenHasNotch {
            let notchClearance: CGFloat = 120
            x = screenFrame.midX + notchClearance
            let rightPadding: CGFloat = 20
            width = max(screenFrame.maxX - x - rightPadding, 100)
        } else {
            width = max(fittingSize.width, 300)
            x = screenFrame.midX - width / 2
        }

        x += CGFloat(resolved.xOffset)
        y += CGFloat(resolved.yOffset)

        instance.panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    private func setupScreenChangeObserver() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.setupBars()
            }
        }
    }

    private func setupSleepWakeObserver() {
        sleepWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.handleWakeFromSleep()
            }
        }
    }

    private func handleWakeFromSleep() {
        guard let settings, settings.workspaceBarEnabled else { return }
        removeAllBars()
        setupBars()
    }

    func cleanup() {
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
        if let observer = sleepWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            sleepWakeObserver = nil
        }
        removeAllBars()
    }

    private func applySettingsToPanel(_ panel: NSPanel, for monitor: Monitor) {
        guard let settings else { return }
        let resolved = settings.resolvedBarSettings(for: monitor.name)
        panel.level = resolved.windowLevel.nsWindowLevel
    }

    private func menuBarHeight(for monitor: Monitor) -> Double {
        guard let screen = NSScreen.screens.first(where: { $0.displayId == monitor.id.displayId }) else {
            return 28
        }
        let h = screen.frame.maxY - screen.visibleFrame.maxY
        return h > 0 ? h : 28
    }

    private func hasNotch(screen: NSScreen) -> Bool {
        if #available(macOS 12.0, *) {
            return screen.safeAreaInsets.top > 0
        }
        return false
    }
}

// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

enum WorkspaceBarWindowLevel: String, CaseIterable, Identifiable {
    case normal
    case floating
    case status
    case popup
    case screensaver

    var id: String {
        rawValue
    }

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

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .overlappingMenuBar: "Overlapping Menu Bar"
        case .belowMenuBar: "Below Menu Bar"
        }
    }
}

@MainActor
final class WorkspaceBarManager {
    final class MonitorBarInstance {
        let monitorId: Monitor.ID
        let panel: WorkspaceBarPanel
        let hostingView: NSHostingView<WorkspaceBarView>
        let measurementView: NSHostingView<WorkspaceBarMeasurementView>
        let model: WorkspaceBarModel

        var monitor: Monitor
        var lastAppliedFrame: NSRect?
        var lastMeasuredWidth: CGFloat?
        var screenDisplayId: CGDirectDisplayID?

        init(
            monitor: Monitor,
            panel: WorkspaceBarPanel,
            hostingView: NSHostingView<WorkspaceBarView>,
            measurementView: NSHostingView<WorkspaceBarMeasurementView>,
            model: WorkspaceBarModel,
            screenDisplayId: CGDirectDisplayID?
        ) {
            monitorId = monitor.id
            self.monitor = monitor
            self.panel = panel
            self.hostingView = hostingView
            self.measurementView = measurementView
            self.model = model
            self.screenDisplayId = screenDisplayId
        }
    }

    var screenProvider: @MainActor (CGDirectDisplayID) -> NSScreen? = { displayId in
        NSScreen.screens.first(where: { $0.displayId == displayId })
    }

    var panelFactory: @MainActor @Sendable () -> WorkspaceBarPanel = {
        WorkspaceBarManager.defaultPanel()
    }

    var frameApplier: @MainActor @Sendable (WorkspaceBarPanel, NSRect) -> Void = { panel, frame in
        panel.setFrame(frame, display: true)
    }

    private var barsByMonitor: [Monitor.ID: MonitorBarInstance] = [:]
    private weak var controller: WMController?
    private weak var settings: SettingsStore?
    private let motionPolicy: MotionPolicy
    private let surfaceCoordinator = SurfaceCoordinator.shared

    init(motionPolicy: MotionPolicy) {
        self.motionPolicy = motionPolicy
    }

    func setup(controller: WMController, settings: SettingsStore) {
        self.controller = controller
        self.settings = settings
    }

    func apply(_ bars: [DesiredBarSurface]) {
        guard controller != nil, settings != nil else { return }

        var staleMonitorIds = Set(barsByMonitor.keys)
        for bar in bars where bar.visible {
            staleMonitorIds.remove(bar.monitor.id)
            if let existing = barsByMonitor[bar.monitor.id] {
                if !updateBarForMonitor(bar.monitor, snapshot: bar.snapshot, instance: existing) {
                    removeBarForMonitor(bar.monitor.id)
                    createBarForMonitor(bar.monitor, snapshot: bar.snapshot)
                }
            } else {
                createBarForMonitor(bar.monitor, snapshot: bar.snapshot)
            }
        }

        for monitorId in staleMonitorIds {
            removeBarForMonitor(monitorId)
        }
    }

    func updateAppearance() {
        guard settings != nil else { return }

        for instance in barsByMonitor.values {
            refreshBarAppearance(instance: instance)
        }
    }

    private func createBarForMonitor(_ monitor: Monitor, snapshot: WorkspaceBarSnapshot) {
        guard let controller, let settings else { return }

        let resolved = settings.resolvedBarSettings(for: monitor)
        let model = WorkspaceBarModel(snapshot: snapshot)

        let hostingView = NSHostingView(
            rootView: WorkspaceBarView(
                model: model,
                motionPolicy: motionPolicy,
                onFocusWorkspace: { [weak controller] item in
                    controller?.focusWorkspaceFromBar(named: item.name)
                },
                onFocusWindow: { [weak controller] token in
                    controller?.focusWindowFromBar(token: token)
                },
                onActivateScratchpad: { [weak controller] in
                    controller?.activateScratchpadFromBar(on: monitor.id)
                }
            )
        )
        hostingView.sizingOptions = []

        let measurementView = NSHostingView(rootView: WorkspaceBarMeasurementView(snapshot: snapshot))

        let panel = panelFactory()
        let screen = screenProvider(monitor.displayId)
        panel.targetScreen = screen
        panel.contentView = hostingView
        applyCurrentAppearance(
            to: panel,
            hostingView: hostingView,
            measurementView: measurementView
        )
        applySettingsToPanel(panel, resolved: resolved)

        let instance = MonitorBarInstance(
            monitor: monitor,
            panel: panel,
            hostingView: hostingView,
            measurementView: measurementView,
            model: model,
            screenDisplayId: screen?.displayId
        )
        barsByMonitor[monitor.id] = instance

        updateBarFrameAndPosition(
            for: monitor,
            resolved: resolved,
            snapshot: snapshot,
            instance: instance
        )
        surfaceCoordinator.register(
            window: panel,
            id: surfaceId(for: monitor.id),
            policy: SurfacePolicy(
                kind: .workspaceBar,
                hitTestPolicy: .interactive,
                capturePolicy: .included,
                suppressesManagedFocusRecovery: false
            )
        )
        panel.orderFrontRegardless()
    }

    private func updateBarForMonitor(
        _ monitor: Monitor,
        snapshot: WorkspaceBarSnapshot,
        instance: MonitorBarInstance
    ) -> Bool {
        guard let settings else { return false }

        let screen = screenProvider(monitor.displayId)
        let nextScreenDisplayId = screen?.displayId

        if let currentScreenDisplayId = instance.screenDisplayId,
           nextScreenDisplayId != currentScreenDisplayId
        {
            return false
        }

        if nextScreenDisplayId == nil, instance.screenDisplayId != nil {
            return false
        }

        instance.monitor = monitor
        instance.panel.targetScreen = screen
        instance.screenDisplayId = nextScreenDisplayId

        let resolved = settings.resolvedBarSettings(for: monitor)
        if instance.model.snapshot != snapshot {
            instance.model.snapshot = snapshot
            instance.lastMeasuredWidth = nil
        }
        applyCurrentAppearance(
            to: instance.panel,
            hostingView: instance.hostingView,
            measurementView: instance.measurementView
        )
        applySettingsToPanel(instance.panel, resolved: resolved)
        updateBarFrameAndPosition(
            for: monitor,
            resolved: resolved,
            snapshot: snapshot,
            instance: instance
        )
        return true
    }

    private func refreshBarAppearance(instance: MonitorBarInstance) {
        guard let settings else { return }

        let resolved = settings.resolvedBarSettings(for: instance.monitor)
        let current = instance.model.snapshot
        let snapshot = WorkspaceBarSnapshot(
            projection: current.projection,
            showLabels: current.showLabels,
            backgroundOpacity: current.backgroundOpacity,
            barHeight: current.barHeight,
            accentColor: resolved.accentColor,
            textColor: resolved.textColor
        )

        if snapshot != current {
            instance.model.snapshot = snapshot
        }
    }

    private func removeBarForMonitor(_ monitorId: Monitor.ID) {
        if let instance = barsByMonitor[monitorId] {
            surfaceCoordinator.unregister(id: surfaceId(for: monitorId))
            instance.panel.orderOut(nil)
            instance.panel.close()
            barsByMonitor.removeValue(forKey: monitorId)
        }
    }

    func removeAllBars() {
        for (_, instance) in barsByMonitor {
            surfaceCoordinator.unregister(id: surfaceId(for: instance.monitorId))
            instance.panel.orderOut(nil)
            instance.panel.close()
        }
        barsByMonitor.removeAll()
    }

    private func surfaceId(for monitorId: Monitor.ID) -> String {
        "workspace-bar-\(String(describing: monitorId))"
    }

    private func updateBarFrameAndPosition(
        for monitor: Monitor,
        resolved: ResolvedBarSettings,
        snapshot: WorkspaceBarSnapshot,
        instance: MonitorBarInstance
    ) {
        let fittingWidth: CGFloat
        if let cached = instance.lastMeasuredWidth {
            fittingWidth = cached
        } else {
            fittingWidth = measuredWidth(for: snapshot, using: instance.measurementView)
            instance.lastMeasuredWidth = fittingWidth
        }
        let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
        let frame = geometry.frame(fittingWidth: fittingWidth, monitor: monitor, resolved: resolved)

        guard instance.lastAppliedFrame != frame else { return }

        frameApplier(instance.panel, frame)
        instance.lastAppliedFrame = frame
    }

    private func measuredWidth(
        for snapshot: WorkspaceBarSnapshot,
        using measurementView: NSHostingView<WorkspaceBarMeasurementView>
    ) -> CGFloat {
        measurementView.rootView = WorkspaceBarMeasurementView(snapshot: snapshot)
        measurementView.layoutSubtreeIfNeeded()
        return measurementView.fittingSize.width
    }

    private func applyCurrentAppearance(
        to panel: NSPanel,
        hostingView: NSHostingView<WorkspaceBarView>,
        measurementView: NSHostingView<WorkspaceBarMeasurementView>
    ) {
        let appearance = NSApplication.shared.appearance
        panel.appearance = appearance
        hostingView.appearance = appearance
        measurementView.appearance = appearance
    }

    private static func defaultPanel() -> WorkspaceBarPanel {
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

    nonisolated static func effectivePosition(
        for monitor: Monitor,
        resolved: ResolvedBarSettings
    ) -> WorkspaceBarPosition {
        WorkspaceBarGeometry.effectivePosition(for: monitor, resolved: resolved)
    }

    nonisolated static func barFrame(
        fittingWidth: CGFloat,
        monitor: Monitor,
        resolved: ResolvedBarSettings,
        menuBarHeight: Double
    ) -> NSRect {
        let geometry = WorkspaceBarGeometry.resolve(
            monitor: monitor,
            resolved: resolved,
            isVisible: true,
            menuBarHeight: CGFloat(menuBarHeight)
        )
        return geometry.frame(fittingWidth: fittingWidth, monitor: monitor, resolved: resolved)
    }

    nonisolated static func reservedTopInset(
        for monitor: Monitor,
        resolved: ResolvedBarSettings,
        isVisible: Bool,
        menuBarHeight: Double? = nil
    ) -> CGFloat {
        WorkspaceBarGeometry.resolve(
            monitor: monitor,
            resolved: resolved,
            isVisible: isVisible,
            menuBarHeight: menuBarHeight.map { CGFloat($0) }
        ).reservedTopInset
    }

    func cleanup() {
        removeAllBars()
    }

    private func applySettingsToPanel(_ panel: NSPanel, resolved: ResolvedBarSettings) {
        panel.level = resolved.windowLevel.nsWindowLevel
    }
}

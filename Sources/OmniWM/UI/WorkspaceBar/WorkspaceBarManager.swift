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
    final class MonitorBarInstance {
        let monitorId: Monitor.ID
        let panel: WorkspaceBarPanel
        let hostingView: NSHostingView<WorkspaceBarView>
        let measurementView: NSHostingView<WorkspaceBarMeasurementView>
        let model: WorkspaceBarModel

        var monitor: Monitor
        var lastAppliedFrame: NSRect?
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

    var monitorProvider: @MainActor () -> [Monitor] = { Monitor.current() }
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
    private var screenObserver: Any?
    private var sleepWakeObserver: Any?
    private var pendingReconfigureTask: Task<Void, Never>?
    private weak var controller: WMController?
    private weak var settings: SettingsStore?
    private let motionPolicy: MotionPolicy
    private let surfaceCoordinator = SurfaceCoordinator.shared

    init(motionPolicy: MotionPolicy) {
        self.motionPolicy = motionPolicy
        setupScreenChangeObserver()
        setupSleepWakeObserver()
    }

    func setup(controller: WMController, settings: SettingsStore) {
        self.controller = controller
        self.settings = settings

        cancelPendingReconfigure()
        reconfigureBars()
    }

    func update() {
        guard settings != nil else {
            cancelPendingReconfigure()
            removeAllBars()
            return
        }

        refreshBarsContent()
    }

    func setEnabled(_ enabled: Bool) {
        cancelPendingReconfigure()

        if enabled {
            reconfigureBars()
        } else {
            removeAllBars()
        }
    }

    func updateSettings() {
        guard settings != nil else { return }
        cancelPendingReconfigure()
        reconfigureBars()
    }

    func reconfigureBars() {
        reconfigureBars(using: monitorProvider())
    }

    func reconfigureBars(using monitors: [Monitor]) {
        guard let controller, let settings else { return }

        var existingMonitorIds = Set(barsByMonitor.keys)

        for monitor in monitors {
            existingMonitorIds.remove(monitor.id)
            let resolved = settings.resolvedBarSettings(for: monitor)

            // Global workspace-bar settings are defaults; monitor overrides and runtime visibility decide bar ownership.
            if !controller.isWorkspaceBarVisible(on: monitor, resolved: resolved) {
                removeBarForMonitor(monitor.id)
                continue
            }

            if let existing = barsByMonitor[monitor.id] {
                if !updateBarForMonitor(monitor, instance: existing) {
                    removeBarForMonitor(monitor.id)
                    createBarForMonitor(monitor)
                }
            } else {
                createBarForMonitor(monitor)
            }
        }

        for monitorId in existingMonitorIds {
            removeBarForMonitor(monitorId)
        }
    }

    func scheduleReconfigure(after delayNanoseconds: UInt64) {
        scheduleDeferredUpdate(after: delayNanoseconds) { [weak self] in
            self?.reconfigureBars()
        }
    }

    private func refreshBarsContent() {
        guard settings != nil else { return }

        let currentMonitors = Dictionary(uniqueKeysWithValues: monitorProvider().map { ($0.id, $0) })
        for instance in barsByMonitor.values {
            let monitor = currentMonitors[instance.monitorId] ?? instance.monitor
            refreshBarContent(for: monitor, instance: instance)
        }
    }

    private func createBarForMonitor(_ monitor: Monitor) {
        guard let controller, let settings else { return }

        let resolved = settings.resolvedBarSettings(for: monitor)
        let snapshot = makeSnapshot(for: monitor, resolved: resolved)
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
                }
            )
        )
        configureHostingView(hostingView)

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

    private func updateBarForMonitor(_ monitor: Monitor, instance: MonitorBarInstance) -> Bool {
        guard let settings else { return false }

        let screen = screenProvider(monitor.displayId)
        let nextScreenDisplayId = screen?.displayId

        if let currentScreenDisplayId = instance.screenDisplayId,
           nextScreenDisplayId != currentScreenDisplayId {
            return false
        }

        if nextScreenDisplayId == nil, instance.screenDisplayId != nil {
            return false
        }

        instance.monitor = monitor
        instance.panel.targetScreen = screen
        instance.screenDisplayId = nextScreenDisplayId

        let resolved = settings.resolvedBarSettings(for: monitor)
        let snapshot = makeSnapshot(for: monitor, resolved: resolved)
        instance.model.snapshot = snapshot
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

    private func refreshBarContent(for monitor: Monitor, instance: MonitorBarInstance) {
        guard let settings else { return }

        instance.monitor = monitor

        let resolved = settings.resolvedBarSettings(for: monitor)
        let snapshot = makeSnapshot(for: monitor, resolved: resolved)
        if snapshot != instance.model.snapshot {
            instance.model.snapshot = snapshot
        }
        updateBarFrameAndPosition(
            for: monitor,
            resolved: resolved,
            snapshot: snapshot,
            instance: instance
        )
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
        let fittingWidth = measuredWidth(for: snapshot, using: instance.measurementView)
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

    private func makeSnapshot(
        for monitor: Monitor,
        resolved: ResolvedBarSettings
    ) -> WorkspaceBarSnapshot {
        let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
        let items = controller?.workspaceBarItems(
            for: monitor,
            deduplicate: resolved.deduplicateAppIcons,
            hideEmpty: resolved.hideEmptyWorkspaces
        ) ?? []

        return WorkspaceBarSnapshot(
            items: items,
            showLabels: resolved.showLabels,
            backgroundOpacity: resolved.backgroundOpacity,
            barHeight: geometry.barHeight
        )
    }

    private func configureHostingView<Content: View>(_ hostingView: NSHostingView<Content>) {
        if #available(macOS 13.0, *) {
            hostingView.sizingOptions = []
        }
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

    nonisolated static func effectivePosition(for monitor: Monitor, resolved: ResolvedBarSettings) -> WorkspaceBarPosition {
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

    private func setupScreenChangeObserver() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleReconfigure(after: 150_000_000)
            }
        }
    }

    private func setupSleepWakeObserver() {
        sleepWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleDeferredUpdate(after: 500_000_000) { [weak self] in
                    self?.handleWakeFromSleep()
                }
            }
        }
    }

    private func scheduleDeferredUpdate(
        after delayNanoseconds: UInt64,
        action: @escaping @MainActor () -> Void
    ) {
        cancelPendingReconfigure()
        pendingReconfigureTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }

            guard let self else { return }
            self.pendingReconfigureTask = nil
            action()
        }
    }

    private func cancelPendingReconfigure() {
        pendingReconfigureTask?.cancel()
        pendingReconfigureTask = nil
    }

    private func handleWakeFromSleep() {
        guard settings != nil else { return }
        removeAllBars()
        reconfigureBars()
    }

    func cleanup() {
        cancelPendingReconfigure()

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

    private func applySettingsToPanel(_ panel: NSPanel, resolved: ResolvedBarSettings) {
        panel.level = resolved.windowLevel.nsWindowLevel
    }
}

extension WorkspaceBarManager {
    func activeBarCountForTests() -> Int {
        barsByMonitor.count
    }

    func hostingViewIdentifierForTests(on monitorId: Monitor.ID) -> ObjectIdentifier? {
        barsByMonitor[monitorId].map { ObjectIdentifier($0.hostingView) }
    }

    func lastAppliedFrameForTests(on monitorId: Monitor.ID) -> CGRect? {
        barsByMonitor[monitorId]?.lastAppliedFrame
    }

    func panelEffectiveAppearanceForTests(on monitorId: Monitor.ID) -> NSAppearance.Name? {
        barsByMonitor[monitorId]?.panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
    }

    func hostingViewEffectiveAppearanceForTests(on monitorId: Monitor.ID) -> NSAppearance.Name? {
        barsByMonitor[monitorId]?.hostingView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
    }
}

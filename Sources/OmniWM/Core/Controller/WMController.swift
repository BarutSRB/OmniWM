import AppKit
import Foundation

enum Direction: String, Codable {
    case left, right, up, down

    var displayName: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .up: "Up"
        case .down: "Down"
        }
    }
}

enum HotkeyCommand: Codable, Equatable, Hashable {
    case focus(Direction)
    case focusPrevious
    case move(Direction)
    case swap(Direction)
    case moveToWorkspace(Int)
    case moveWindowToWorkspaceUp
    case moveWindowToWorkspaceDown
    case moveColumnToWorkspace(Int)
    case moveColumnToWorkspaceUp
    case moveColumnToWorkspaceDown
    case switchWorkspace(Int)
    case moveToMonitor(Direction)
    case focusMonitor(Direction)
    case focusMonitorPrevious
    case focusMonitorNext
    case focusMonitorLast
    case moveColumnToMonitor(Direction)
    case toggleFullscreen
    case toggleMaximized
    case toggleNativeFullscreen
    case increaseGaps
    case decreaseGaps
    case increaseWindowSize(Direction)
    case decreaseWindowSize(Direction)
    case resetWindowSize
    case moveColumn(Direction)
    case consumeWindow(Direction)
    case expelWindow(Direction)
    case toggleColumnTabbed

    case focusDownOrLeft
    case focusUpOrRight
    case focusColumnFirst
    case focusColumnLast
    case focusColumn(Int)
    case focusWindowTop
    case focusWindowBottom

    case cycleColumnWidthForward
    case cycleColumnWidthBackward
    case toggleColumnFullWidth
    case cycleWindowHeightForward
    case cycleWindowHeightBackward

    case moveWorkspaceToMonitor(Direction)

    case balanceSizes

    case summonWorkspace(Int)

    case openWindowFinder

    var id: String {
        switch self {
        case let .focus(dir): "focus.\(dir.rawValue)"
        case .focusPrevious: "focusPrevious"
        case let .move(dir): "move.\(dir.rawValue)"
        case let .swap(dir): "swap.\(dir.rawValue)"
        case let .moveToWorkspace(idx): "moveToWorkspace.\(idx)"
        case .moveWindowToWorkspaceUp: "moveWindowToWorkspaceUp"
        case .moveWindowToWorkspaceDown: "moveWindowToWorkspaceDown"
        case let .moveColumnToWorkspace(idx): "moveColumnToWorkspace.\(idx)"
        case .moveColumnToWorkspaceUp: "moveColumnToWorkspaceUp"
        case .moveColumnToWorkspaceDown: "moveColumnToWorkspaceDown"
        case let .switchWorkspace(idx): "switchWorkspace.\(idx)"
        case let .moveToMonitor(dir): "moveToMonitor.\(dir.rawValue)"
        case let .focusMonitor(dir): "focusMonitor.\(dir.rawValue)"
        case .focusMonitorPrevious: "focusMonitorPrevious"
        case .focusMonitorNext: "focusMonitorNext"
        case .focusMonitorLast: "focusMonitorLast"
        case let .moveColumnToMonitor(dir): "moveColumnToMonitor.\(dir.rawValue)"
        case .toggleFullscreen: "toggleFullscreen"
        case .toggleMaximized: "toggleMaximized"
        case .toggleNativeFullscreen: "toggleNativeFullscreen"
        case .increaseGaps: "increaseGaps"
        case .decreaseGaps: "decreaseGaps"
        case let .increaseWindowSize(dir): "increaseWindowSize.\(dir.rawValue)"
        case let .decreaseWindowSize(dir): "decreaseWindowSize.\(dir.rawValue)"
        case .resetWindowSize: "resetWindowSize"
        case let .moveColumn(dir): "moveColumn.\(dir.rawValue)"
        case let .consumeWindow(dir): "consumeWindow.\(dir.rawValue)"
        case let .expelWindow(dir): "expelWindow.\(dir.rawValue)"
        case .toggleColumnTabbed: "toggleColumnTabbed"
        case .focusDownOrLeft: "focusDownOrLeft"
        case .focusUpOrRight: "focusUpOrRight"
        case .focusColumnFirst: "focusColumnFirst"
        case .focusColumnLast: "focusColumnLast"
        case let .focusColumn(idx): "focusColumn.\(idx)"
        case .focusWindowTop: "focusWindowTop"
        case .focusWindowBottom: "focusWindowBottom"
        case .cycleColumnWidthForward: "cycleColumnWidthForward"
        case .cycleColumnWidthBackward: "cycleColumnWidthBackward"
        case .toggleColumnFullWidth: "toggleColumnFullWidth"
        case .cycleWindowHeightForward: "cycleWindowHeightForward"
        case .cycleWindowHeightBackward: "cycleWindowHeightBackward"
        case let .moveWorkspaceToMonitor(dir): "moveWorkspaceToMonitor.\(dir.rawValue)"
        case .balanceSizes: "balanceSizes"
        case let .summonWorkspace(idx): "summonWorkspace.\(idx)"
        case .openWindowFinder: "openWindowFinder"
        }
    }

    var displayName: String {
        switch self {
        case let .focus(dir): "Focus \(dir.displayName)"
        case .focusPrevious: "Focus Previous Window"
        case let .move(dir): "Move \(dir.displayName)"
        case let .swap(dir): "Swap \(dir.displayName)"
        case let .moveToWorkspace(idx): "Move to Workspace \(idx + 1)"
        case .moveWindowToWorkspaceUp: "Move Window to Workspace Up"
        case .moveWindowToWorkspaceDown: "Move Window to Workspace Down"
        case let .moveColumnToWorkspace(idx): "Move Column to Workspace \(idx + 1)"
        case .moveColumnToWorkspaceUp: "Move Column to Workspace Up"
        case .moveColumnToWorkspaceDown: "Move Column to Workspace Down"
        case let .switchWorkspace(idx): "Switch to Workspace \(idx + 1)"
        case let .moveToMonitor(dir): "Move to \(dir.displayName) Monitor"
        case let .focusMonitor(dir): "Focus \(dir.displayName) Monitor"
        case .focusMonitorPrevious: "Focus Previous Monitor"
        case .focusMonitorNext: "Focus Next Monitor"
        case .focusMonitorLast: "Focus Last Monitor"
        case let .moveColumnToMonitor(dir): "Move Column to \(dir.displayName) Monitor"
        case .toggleFullscreen: "Toggle Fullscreen"
        case .toggleMaximized: "Toggle Maximized"
        case .toggleNativeFullscreen: "Toggle Native Fullscreen"
        case .increaseGaps: "Increase Gaps"
        case .decreaseGaps: "Decrease Gaps"
        case let .increaseWindowSize(dir): "Increase Size \(dir.displayName)"
        case let .decreaseWindowSize(dir): "Decrease Size \(dir.displayName)"
        case .resetWindowSize: "Reset Window Size"
        case let .moveColumn(dir): "Move Column \(dir.displayName)"
        case let .consumeWindow(dir): "Consume Window from \(dir.displayName)"
        case let .expelWindow(dir): "Expel Window to \(dir.displayName)"
        case .toggleColumnTabbed: "Toggle Column Tabbed"
        case .focusDownOrLeft: "Focus Down or Left"
        case .focusUpOrRight: "Focus Up or Right"
        case .focusColumnFirst: "Focus First Column"
        case .focusColumnLast: "Focus Last Column"
        case let .focusColumn(idx): "Focus Column \(idx + 1)"
        case .focusWindowTop: "Focus Top Window"
        case .focusWindowBottom: "Focus Bottom Window"
        case .cycleColumnWidthForward: "Cycle Column Width Forward"
        case .cycleColumnWidthBackward: "Cycle Column Width Backward"
        case .toggleColumnFullWidth: "Toggle Column Full Width"
        case .cycleWindowHeightForward: "Cycle Window Height Forward"
        case .cycleWindowHeightBackward: "Cycle Window Height Backward"
        case let .moveWorkspaceToMonitor(dir): "Move Workspace to \(dir.displayName) Monitor"
        case .balanceSizes: "Balance Sizes"
        case let .summonWorkspace(idx): "Summon Workspace \(idx + 1)"
        case .openWindowFinder: "Open Window Finder"
        }
    }
}

@MainActor @Observable
final class WMController {
    var isEnabled: Bool = true
    var hotkeysEnabled: Bool = true
    private var focusFollowsMouseEnabled: Bool = false
    private var moveMouseToFocusedWindowEnabled: Bool = false

    private let settings: SettingsStore
    private let workspaceManager: WorkspaceManager
    private let hotkeys = HotkeyCenter()
    private let secureInputMonitor = SecureInputMonitor()
    private var wasHotkeysEnabledBeforeSecureInput = true
    private let lockScreenObserver = LockScreenObserver()
    private let windowStateCache = WindowStateCache()
    private var isLockScreenActive: Bool = false
    private let axManager = AXManager()
    private var focusedHandle: WindowHandle?
    private var isNonManagedFocusActive: Bool = false
    private var isAppFullscreenActive: Bool = false
    private var lastFocusedByWorkspace: [WorkspaceDescriptor.ID: WindowHandle] = [:]
    private var refreshTimer: Timer?

    private var activeMonitorId: Monitor.ID?
    private var previousMonitorId: Monitor.ID?

    private var niriEngine: NiriLayoutEngine?

    private var displayObserver: DisplayConfigurationObserver?

    private var pendingNavigationTask: Task<Void, Never>?
    private var isProcessingNavigation = false
    private var navigationQueue: [Direction] = []

    private var pendingFocusHandle: WindowHandle?
    private var deferredFocusHandle: WindowHandle?
    private var isFocusOperationPending = false
    private var lastFocusTime: Date = .distantPast
    private var lastAnyFocusTime: Date = .distantPast
    private let globalFocusCooldown: TimeInterval = 0.0

    private var isRefreshInProgress: Bool = false
    private var hasPendingRefresh: Bool = false
    private var isImmediateLayoutInProgress: Bool = false

    private let tabbedOverlayManager = TabbedColumnOverlayManager()
    @ObservationIgnored
    private lazy var borderManager: BorderManager = .init()
    @ObservationIgnored
    private lazy var workspaceBarManager: WorkspaceBarManager = .init()

    private var mouseMovedMonitor: Any?
    private var mouseMovedLocalMonitor: Any?
    private var mouseDownMonitor: Any?
    private var mouseDraggedMonitor: Any?
    private var mouseUpMonitor: Any?
    private var currentHoveredEdges: ResizeEdge = []
    private var isResizing: Bool = false
    private var isMoving: Bool = false
    private var lastFocusFollowsMouseTime: Date = .distantPast
    private var lastFocusFollowsMouseHandle: WindowHandle?
    private let focusFollowsMouseDebounce: TimeInterval = 0.1
    private var appActivationObserver: NSObjectProtocol?
    private var appHideObserver: NSObjectProtocol?
    private var appUnhideObserver: NSObjectProtocol?

    private var hiddenAppPIDs: Set<pid_t> = []

    private var appRulesByBundleId: [String: AppRule] = [:]

    init(settings: SettingsStore) {
        self.settings = settings
        workspaceManager = WorkspaceManager(settings: settings)
        hotkeys.onCommand = { [weak self] command in
            self?.handle(command)
        }
        tabbedOverlayManager.onSelect = { [weak self] workspaceId, columnId, index in
            self?.selectTabInNiri(workspaceId: workspaceId, columnId: columnId, index: index)
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func setHotkeysEnabled(_ enabled: Bool) {
        hotkeysEnabled = enabled
        enabled ? hotkeys.start() : hotkeys.stop()
    }

    func setGapSize(_ size: Double) {
        workspaceManager.setGaps(to: size)
    }

    func setOuterGaps(left: Double, right: Double, top: Double, bottom: Double) {
        workspaceManager.setOuterGaps(left: left, right: right, top: top, bottom: bottom)
    }

    func setBordersEnabled(_ enabled: Bool) {
        borderManager.setEnabled(enabled)
    }

    func updateBorderConfig(_ config: BorderConfig) {
        borderManager.updateConfig(config)
    }

    func setWorkspaceBarEnabled(_ enabled: Bool) {
        if enabled {
            workspaceBarManager.setup(controller: self, settings: settings)
        } else {
            workspaceBarManager.removeAllBars()
        }
    }

    func updateWorkspaceBar() {
        workspaceBarManager.update()
    }

    func updateWorkspaceBarSettings() {
        workspaceBarManager.updateSettings()
    }

    func workspaceBarItems(for monitor: Monitor, deduplicate: Bool, hideEmpty: Bool) -> [WorkspaceBarItem] {
        var workspaces = workspaceManager.workspaces(on: monitor.id)

        if hideEmpty {
            workspaces = workspaces.filter { !workspaceManager.entries(in: $0.id).isEmpty }
        }

        let activeWorkspaceId = workspaceManager.activeWorkspace(on: monitor.id)?.id

        return workspaces.map { workspace in
            let entries = workspaceManager.entries(in: workspace.id)
            let orderMap = workspaceBarOrderMap(for: workspace.id)
            let orderedEntries = sortWorkspaceBarEntries(entries, orderMap: orderMap)
            let useLayoutOrder = orderMap?.isEmpty == false
            let windows: [WorkspaceBarWindowItem] = if deduplicate {
                createDedupedWindowItems(entries: orderedEntries, useLayoutOrder: useLayoutOrder)
            } else {
                createIndividualWindowItems(entries: orderedEntries)
            }

            return WorkspaceBarItem(
                id: workspace.id,
                name: workspace.name,
                isFocused: workspace.id == activeWorkspaceId,
                windows: windows
            )
        }
    }

    private struct WorkspaceBarSortKey {
        let group: Int
        let primary: Int
        let secondary: Int
    }

    private func workspaceBarOrderMap(
        for workspaceId: WorkspaceDescriptor.ID
    ) -> [WindowHandle: WorkspaceBarSortKey]? {
        guard let engine = niriEngine else { return nil }

        var order: [WindowHandle: WorkspaceBarSortKey] = [:]
        let columns = engine.columns(in: workspaceId)

        for (colIdx, column) in columns.enumerated() {
            for (rowIdx, window) in column.windowNodes.enumerated() {
                order[window.handle] = WorkspaceBarSortKey(group: 0, primary: colIdx, secondary: rowIdx)
            }
        }

        return order
    }

    private func sortWorkspaceBarEntries(
        _ entries: [WindowModel.Entry],
        orderMap: [WindowHandle: WorkspaceBarSortKey]?
    ) -> [WindowModel.Entry] {
        guard let orderMap else { return entries }
        let fallbackOrder = Dictionary(uniqueKeysWithValues: entries.enumerated()
            .map { ($0.element.handle, $0.offset) })

        return entries.sorted { lhs, rhs in
            let lhsKey = orderMap[lhs.handle] ?? WorkspaceBarSortKey(group: 2, primary: Int.max, secondary: Int.max)
            let rhsKey = orderMap[rhs.handle] ?? WorkspaceBarSortKey(group: 2, primary: Int.max, secondary: Int.max)

            if lhsKey.group != rhsKey.group { return lhsKey.group < rhsKey.group }
            if lhsKey.primary != rhsKey.primary { return lhsKey.primary < rhsKey.primary }
            if lhsKey.secondary != rhsKey.secondary { return lhsKey.secondary < rhsKey.secondary }

            let lhsFallback = fallbackOrder[lhs.handle] ?? 0
            let rhsFallback = fallbackOrder[rhs.handle] ?? 0
            return lhsFallback < rhsFallback
        }
    }

    private func createDedupedWindowItems(
        entries: [WindowModel.Entry],
        useLayoutOrder: Bool
    ) -> [WorkspaceBarWindowItem] {
        if useLayoutOrder {
            var groupedByApp: [String: [WindowModel.Entry]] = [:]
            var orderedAppNames: [String] = []

            for entry in entries {
                let app = NSRunningApplication(processIdentifier: entry.handle.pid)
                let appName = app?.localizedName ?? "Unknown"

                if groupedByApp[appName] == nil {
                    groupedByApp[appName] = []
                    orderedAppNames.append(appName)
                }

                groupedByApp[appName]?.append(entry)
            }

            return orderedAppNames.compactMap { appName in
                guard let appEntries = groupedByApp[appName], let firstEntry = appEntries.first else { return nil }
                let app = NSRunningApplication(processIdentifier: firstEntry.handle.pid)
                let anyFocused = appEntries.contains { $0.handle.id == focusedHandle?.id }

                let windowInfos = appEntries.map { entry -> WorkspaceBarWindowInfo in
                    WorkspaceBarWindowInfo(
                        id: entry.handle.id,
                        windowId: entry.windowId,
                        title: getWindowTitle(for: entry) ?? appName,
                        isFocused: entry.handle.id == focusedHandle?.id
                    )
                }

                return WorkspaceBarWindowItem(
                    id: firstEntry.handle.id,
                    windowId: firstEntry.windowId,
                    appName: appName,
                    icon: app?.icon,
                    isFocused: anyFocused,
                    windowCount: appEntries.count,
                    allWindows: windowInfos
                )
            }
        }

        let groupedByApp = Dictionary(grouping: entries) { entry -> String in
            let app = NSRunningApplication(processIdentifier: entry.handle.pid)
            return app?.localizedName ?? "Unknown"
        }

        return groupedByApp.map { appName, appEntries -> WorkspaceBarWindowItem in
            let firstEntry = appEntries.first!
            let app = NSRunningApplication(processIdentifier: firstEntry.handle.pid)
            let anyFocused = appEntries.contains { $0.handle.id == focusedHandle?.id }

            let windowInfos = appEntries.map { entry -> WorkspaceBarWindowInfo in
                WorkspaceBarWindowInfo(
                    id: entry.handle.id,
                    windowId: entry.windowId,
                    title: getWindowTitle(for: entry) ?? appName,
                    isFocused: entry.handle.id == focusedHandle?.id
                )
            }

            return WorkspaceBarWindowItem(
                id: firstEntry.handle.id,
                windowId: firstEntry.windowId,
                appName: appName,
                icon: app?.icon,
                isFocused: anyFocused,
                windowCount: appEntries.count,
                allWindows: windowInfos
            )
        }.sorted { $0.appName < $1.appName }
    }

    private func createIndividualWindowItems(entries: [WindowModel.Entry]) -> [WorkspaceBarWindowItem] {
        entries.map { entry in
            let app = NSRunningApplication(processIdentifier: entry.handle.pid)
            let appName = app?.localizedName ?? "Unknown"
            let title = getWindowTitle(for: entry) ?? appName

            return WorkspaceBarWindowItem(
                id: entry.handle.id,
                windowId: entry.windowId,
                appName: appName,
                icon: app?.icon,
                isFocused: entry.handle.id == focusedHandle?.id,
                windowCount: 1,
                allWindows: [
                    WorkspaceBarWindowInfo(
                        id: entry.handle.id,
                        windowId: entry.windowId,
                        title: title,
                        isFocused: entry.handle.id == focusedHandle?.id
                    )
                ]
            )
        }
    }

    private func getWindowTitle(for entry: WindowModel.Entry) -> String? {
        guard let title = try? AXWindowService.title(entry.axRef), !title.isEmpty else { return nil }
        return title
    }

    func focusWorkspaceFromBar(named name: String) {
        if let currentWorkspace = activeWorkspace() {
            saveNiriViewportState(for: currentWorkspace.id)
        }

        guard let result = workspaceManager.focusWorkspace(named: name) else { return }

        let currentMonitorId = activeMonitorId ?? monitorForInteraction()?.id
        if let currentMonitorId, currentMonitorId != result.monitor.id {
            previousMonitorId = currentMonitorId
        }
        activeMonitorId = result.monitor.id

        focusedHandle = lastFocusedByWorkspace[result.workspace.id]
            ?? workspaceManager.entries(in: result.workspace.id).first?.handle

        refreshWindowsAndLayout()
        if let handle = focusedHandle {
            focusWindow(handle)
        }
    }

    func focusWindowFromBar(windowId: Int) {
        guard let engine = niriEngine else { return }

        var foundEntry: WindowModel.Entry?
        for ws in workspaceManager.workspaces {
            for entry in workspaceManager.entries(in: ws.id) {
                if entry.windowId == windowId {
                    foundEntry = entry
                    break
                }
            }
            if foundEntry != nil { break }
        }

        guard let entry = foundEntry else { return }

        let currentWsId = activeWorkspace()?.id

        if entry.workspaceId != currentWsId {
            let wsName = workspaceManager.descriptor(for: entry.workspaceId)?.name ?? ""
            if let result = workspaceManager.focusWorkspace(named: wsName) {
                activeMonitorId = result.monitor.id
                syncMonitorsToNiriEngine()
            }
        }

        if let niriWindow = engine.findNode(for: entry.handle) {
            var state = workspaceManager.niriViewportState(for: entry.workspaceId)
            state.selectedNodeId = niriWindow.id

            if let column = engine.findColumn(containing: niriWindow, in: entry.workspaceId),
               let colIdx = engine.columnIndex(of: column, in: entry.workspaceId)
            {
                let cols = engine.columns(in: entry.workspaceId)
                state.snapToColumn(
                    colIdx,
                    totalColumns: cols.count,
                    visibleCap: engine.maxVisibleColumns,
                    infiniteLoop: engine.infiniteLoop
                )
            }

            workspaceManager.updateNiriViewportState(state, for: entry.workspaceId)
        }

        refreshWindowsAndLayout()

        focusedHandle = entry.handle
        lastFocusedByWorkspace[entry.workspaceId] = entry.handle
        focusWindow(entry.handle)
    }

    func setFocusFollowsMouse(_ enabled: Bool) {
        focusFollowsMouseEnabled = enabled
    }

    func setMoveMouseToFocusedWindow(_ enabled: Bool) {
        moveMouseToFocusedWindowEnabled = enabled
    }

    private func insetWorkingFrame(from frame: CGRect) -> CGRect {
        let outer = workspaceManager.outerGaps
        let newWidth = max(0, frame.width - outer.left - outer.right)
        let newHeight = max(0, frame.height - outer.top - outer.bottom)
        return CGRect(
            x: frame.origin.x + outer.left,
            y: frame.origin.y + outer.bottom,
            width: newWidth,
            height: newHeight
        )
    }

    func updateHotkeyBindings(_ bindings: [HotkeyBinding]) {
        hotkeys.updateBindings(bindings)
    }

    func updateWorkspaceConfig() {
        workspaceManager.applySettings()
        syncMonitorsToNiriEngine()
        refreshWindowsAndLayout()
    }

    func rebuildAppRulesCache() {
        appRulesByBundleId = Dictionary(
            settings.appRules.map { ($0.bundleId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func updateAppRules() {
        rebuildAppRulesCache()
        refreshWindowsAndLayout()
    }

    var hotkeyRegistrationFailures: Set<HotkeyCommand> {
        hotkeys.registrationFailures
    }

    func start() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let granted = await axManager.ensurePermission()
            guard granted else {
                isEnabled = false
                hotkeysEnabled = false
                hotkeys.stop()
                return
            }
            startServices()
        }
    }

    private func startServices() {
        if hotkeysEnabled {
            hotkeys.start()
        }
        axManager.onWindowEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleAxEvent(event)
            }
        }
        setupWorkspaceObservation()
        setupMouseEventMonitors()
        setupDisplayObserver()
        setupAppActivationObserver()
        setupAppHideObservers()
        workspaceManager.onGapsChanged = { [weak self] in
            self?.refreshWindowsAndLayout()
        }

        refreshWindowsAndLayout()
        startRefreshTimer()
        startSecureInputMonitor()
        startLockScreenObserver()
    }

    private func startLockScreenObserver() {
        lockScreenObserver.onLockDetected = { [weak self] in
            self?.handleLockScreenDetected()
        }
        lockScreenObserver.onUnlockDetected = { [weak self] in
            self?.handleLockScreenEnded()
        }
        lockScreenObserver.start()
    }

    private func handleLockScreenDetected() {
        isLockScreenActive = true
        windowStateCache.captureState(
            workspaceManager: workspaceManager,
            niriEngine: niriEngine
        )
    }

    private func handleLockScreenEnded() {
        isLockScreenActive = false
        refreshWindowsAndLayout()
        workspaceBarManager.update()
    }

    private func startSecureInputMonitor() {
        secureInputMonitor.start { [weak self] isSecure in
            self?.handleSecureInputChange(isSecure)
        }
    }

    private func handleSecureInputChange(_ isSecure: Bool) {
        if isSecure {
            wasHotkeysEnabledBeforeSecureInput = hotkeysEnabled
            if hotkeysEnabled {
                hotkeys.stop()
                SecureInputIndicatorController.shared.show()
            }
        } else {
            SecureInputIndicatorController.shared.hide()
            if wasHotkeysEnabledBeforeSecureInput {
                hotkeys.start()
            }
        }
    }

    private func setupDisplayObserver() {
        displayObserver = DisplayConfigurationObserver()
        displayObserver?.setEventHandler { [weak self] _ in
            Task { @MainActor in
                self?.handleDisplayEvent()
            }
        }
    }

    private func handleDisplayEvent() {
        handleMonitorConfigurationChanged()
    }

    private func handleMonitorConfigurationChanged() {
        workspaceManager.updateMonitors(Monitor.current())
        syncMonitorsToNiriEngine()

        if let activeMonitorId, !workspaceManager.monitors.contains(where: { $0.id == activeMonitorId }) {
            self.activeMonitorId = workspaceManager.monitors.first?.id
        }
        if let previousMonitorId, !workspaceManager.monitors.contains(where: { $0.id == previousMonitorId }) {
            self.previousMonitorId = nil
        }

        refreshWindowsAndLayout()
    }

    private func setupWorkspaceObservation() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    @objc private func workspaceDidChange() {
        refreshWindowsAndLayout()
    }

    private func setupAppActivationObserver() {
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            let pid = app.processIdentifier
            Task { @MainActor in
                self?.handleAppActivation(pid: pid)
            }
        }
    }

    private func setupAppHideObservers() {
        appHideObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            Task { @MainActor in
                self?.handleAppHidden(pid: app.processIdentifier)
            }
        }

        appUnhideObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            Task { @MainActor in
                self?.handleAppUnhidden(pid: app.processIdentifier)
            }
        }
    }

    private func handleAppHidden(pid: pid_t) {
        hiddenAppPIDs.insert(pid)

        for ws in workspaceManager.workspaces {
            for entry in workspaceManager.entries(in: ws.id) {
                if entry.handle.pid == pid {
                    workspaceManager.setLayoutReason(.macosHiddenApp, for: entry.handle)
                }
            }
        }
        refreshWindowsAndLayout()
    }

    private func handleAppUnhidden(pid: pid_t) {
        hiddenAppPIDs.remove(pid)

        for ws in workspaceManager.workspaces {
            for entry in workspaceManager.entries(in: ws.id) {
                if entry.handle.pid == pid, workspaceManager.layoutReason(for: entry.handle) == .macosHiddenApp {
                    _ = workspaceManager.restoreFromNativeState(for: entry.handle)
                }
            }
        }
        refreshWindowsAndLayout()
    }

    private func handleAppActivation(pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)

        guard result == .success, let windowElement = focusedWindow else {
            isNonManagedFocusActive = true
            isAppFullscreenActive = false
            borderManager.hideBorder()
            return
        }

        let axRef = AXWindowRef(id: UUID(), element: windowElement as! AXUIElement)
        guard let winId = try? AXWindowService.windowId(axRef) else {
            isNonManagedFocusActive = true
            isAppFullscreenActive = false
            borderManager.hideBorder()
            return
        }

        for ws in workspaceManager.workspaces {
            for entry in workspaceManager.entries(in: ws.id) {
                if entry.windowId == winId, entry.handle.pid == pid {
                    isNonManagedFocusActive = false

                    focusedHandle = entry.handle
                    lastFocusedByWorkspace[ws.id] = entry.handle

                    if let engine = niriEngine,
                       let node = engine.findNode(for: entry.handle)
                    {
                        var state = workspaceManager.niriViewportState(for: ws.id)
                        state.selectedNodeId = node.id
                        workspaceManager.updateNiriViewportState(state, for: ws.id)
                        engine.updateFocusTimestamp(for: node.id)
                    }

                    if let frame = try? AXWindowService.frame(entry.axRef) {
                        updateBorderIfAllowed(handle: entry.handle, frame: frame, windowId: entry.windowId)
                    }
                    updateTabbedColumnOverlays()
                    return
                }
            }
        }
        isNonManagedFocusActive = true
        isAppFullscreenActive = false
        borderManager.hideBorder()
    }

    private func setupMouseEventMonitors() {
        mouseMovedMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in
                self?.handleMouseMoved()
            }
        }

        mouseMovedLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseMoved()
            }
            return event
        }

        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor in
                self?.handleMouseDown()
            }
        }

        mouseDraggedMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            Task { @MainActor in
                self?.handleMouseDragged()
            }
        }

        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            Task { @MainActor in
                self?.handleMouseUp()
            }
        }
    }

    private func cleanupMouseEventMonitors() {
        if let monitor = mouseMovedMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMovedMonitor = nil
        }
        if let monitor = mouseMovedLocalMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMovedLocalMonitor = nil
        }
        if let monitor = mouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            mouseDownMonitor = nil
        }
        if let monitor = mouseDraggedMonitor {
            NSEvent.removeMonitor(monitor)
            mouseDraggedMonitor = nil
        }
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }
        currentHoveredEdges = []
        isResizing = false
    }

    private func handleMouseMoved() {
        guard isEnabled else {
            if !currentHoveredEdges.isEmpty {
                NSCursor.arrow.set()
                currentHoveredEdges = []
            }
            return
        }

        let location = NSEvent.mouseLocation

        if focusFollowsMouseEnabled, !isResizing {
            handleFocusFollowsMouse(at: location)
        }

        guard !isResizing else { return }

        guard let engine = niriEngine,
              let wsId = activeWorkspace()?.id
        else {
            if !currentHoveredEdges.isEmpty {
                NSCursor.arrow.set()
                currentHoveredEdges = []
            }
            return
        }

        if let hitResult = engine.hitTestResize(point: location, in: wsId) {
            if hitResult.edges != currentHoveredEdges {
                hitResult.edges.cursor.set()
                currentHoveredEdges = hitResult.edges
            }
        } else {
            if !currentHoveredEdges.isEmpty {
                NSCursor.arrow.set()
                currentHoveredEdges = []
            }
        }
    }

    private func handleFocusFollowsMouse(at location: CGPoint) {
        guard !isNonManagedFocusActive, !isAppFullscreenActive else {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastFocusFollowsMouseTime) >= focusFollowsMouseDebounce else {
            return
        }

        guard let engine = niriEngine,
              let wsId = activeWorkspace()?.id
        else {
            return
        }

        if let tiledWindow = engine.hitTestTiled(point: location, in: wsId) {
            let handle = tiledWindow.handle
            if handle != lastFocusFollowsMouseHandle, handle != focusedHandle {
                lastFocusFollowsMouseTime = now
                lastFocusFollowsMouseHandle = handle
                var state = workspaceManager.niriViewportState(for: wsId)
                state.selectedNodeId = tiledWindow.id
                workspaceManager.updateNiriViewportState(state, for: wsId)
                engine.updateFocusTimestamp(for: tiledWindow.id)
                focusedHandle = handle
                lastFocusedByWorkspace[wsId] = handle
                focusWindow(handle)
            }
            return
        }
    }

    private func handleMouseDown() {
        guard isEnabled else { return }

        guard let engine = niriEngine,
              let wsId = activeWorkspace()?.id
        else {
            return
        }

        let location = NSEvent.mouseLocation
        let modifiers = NSEvent.modifierFlags

        if modifiers.contains(.option) {
            if let tiledWindow = engine.hitTestTiled(point: location, in: wsId) {
                if engine.interactiveMoveBegin(
                    windowId: tiledWindow.id,
                    windowHandle: tiledWindow.handle,
                    startLocation: location,
                    in: wsId
                ) {
                    isMoving = true
                    NSCursor.closedHand.set()
                    return
                }
            }
        }

        guard !currentHoveredEdges.isEmpty else { return }

        if let hitResult = engine.hitTestResize(point: location, in: wsId) {
            if engine.interactiveResizeBegin(
                windowId: hitResult.nodeId,
                edges: hitResult.edges,
                startLocation: location,
                in: wsId
            ) {
                isResizing = true

                hitResult.edges.cursor.set()
            }
        }
    }

    private func handleMouseDragged() {
        guard isEnabled else { return }

        let location = NSEvent.mouseLocation

        if isMoving {
            guard let engine = niriEngine,
                  let wsId = activeWorkspace()?.id
            else {
                return
            }

            _ = engine.interactiveMoveUpdate(currentLocation: location, in: wsId)
            return
        }

        guard isResizing else { return }

        guard let engine = niriEngine,
              let monitor = monitorForInteraction()
        else {
            return
        }

        let gaps = LayoutGaps(
            horizontal: CGFloat(workspaceManager.gaps),
            vertical: CGFloat(workspaceManager.gaps),
            outer: workspaceManager.outerGaps
        )
        let insetFrame = insetWorkingFrame(from: monitor.visibleFrame)

        if engine.interactiveResizeUpdate(
            currentLocation: location,
            monitorFrame: insetFrame,
            gaps: gaps
        ) {
            executeLayoutRefreshImmediate()
        }
    }

    private func handleMouseUp() {
        let location = NSEvent.mouseLocation

        if isMoving {
            if let engine = niriEngine,
               let wsId = activeWorkspace()?.id
            {
                var state = workspaceManager.niriViewportState(for: wsId)
                if engine.interactiveMoveEnd(at: location, in: wsId, state: &state) {
                    workspaceManager.updateNiriViewportState(state, for: wsId)
                    executeLayoutRefreshImmediate()
                }
            }

            isMoving = false
            NSCursor.arrow.set()
            return
        }

        guard isResizing else { return }

        if let engine = niriEngine {
            engine.interactiveResizeEnd()
        }

        isResizing = false

        if let engine = niriEngine,
           let wsId = activeWorkspace()?.id,
           let hitResult = engine.hitTestResize(point: location, in: wsId)
        {
            hitResult.edges.cursor.set()
            currentHoveredEdges = hitResult.edges
        } else {
            NSCursor.arrow.set()
            currentHoveredEdges = []
        }
    }

    func stop() {
        pendingNavigationTask?.cancel()
        pendingNavigationTask = nil

        isRefreshInProgress = false
        hasPendingRefresh = false
        isProcessingNavigation = false
        isFocusOperationPending = false
        navigationQueue.removeAll()

        cleanupMouseEventMonitors()

        tabbedOverlayManager.removeAll()
        borderManager.cleanup()
        workspaceBarManager.cleanup()

        axManager.cleanup()

        displayObserver = nil

        secureInputMonitor.stop()
        SecureInputIndicatorController.shared.hide()
        lockScreenObserver.stop()
        hotkeys.stop()
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let observer = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appActivationObserver = nil
        }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func executeLayoutRefreshImmediate() {
        guard !isImmediateLayoutInProgress else { return }
        isImmediateLayoutInProgress = true
        defer { isImmediateLayoutInProgress = false }

        var activeWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        for monitor in workspaceManager.monitors {
            if let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id) {
                activeWorkspaceIds.insert(workspace.id)
            }
        }

        layoutWithNiriEngine(activeWorkspaces: activeWorkspaceIds)
    }

    private func backingScale(for monitor: Monitor) -> CGFloat {
        NSScreen.screens.first(where: { $0.displayId == monitor.id.displayId })?.backingScaleFactor ?? 2.0
    }

    private func handle(_ command: HotkeyCommand) {
        guard isEnabled else { return }

        handleNiriCommand(command)
    }

    func enableNiriLayout(
        maxWindowsPerColumn: Int = 3,
        centerFocusedColumn: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false
    ) {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: maxWindowsPerColumn)
        engine.centerFocusedColumn = centerFocusedColumn
        engine.alwaysCenterSingleColumn = alwaysCenterSingleColumn
        engine.renderStyle.tabIndicatorHeight = TabbedColumnOverlayManager.tabIndicatorHeight
        niriEngine = engine

        syncMonitorsToNiriEngine()

        refreshWindowsAndLayout()
    }

    private func syncMonitorsToNiriEngine() {
        guard let engine = niriEngine else { return }

        let currentMonitors = workspaceManager.monitors
        engine.updateMonitors(currentMonitors)

        for workspace in workspaceManager.workspaces {
            guard let monitor = workspaceManager.monitor(for: workspace.id) else { continue }
            engine.moveWorkspace(workspace.id, to: monitor.id, monitor: monitor)
        }

        for monitor in currentMonitors {
            let orderedWorkspaceIds = workspaceManager.workspaces(on: monitor.id).map(\.id)
            if let niriMonitor = engine.monitor(for: monitor.id) {
                niriMonitor.workspaceOrder = orderedWorkspaceIds
                if let activeWorkspace = workspaceManager.activeWorkspace(on: monitor.id) {
                    niriMonitor.activateWorkspace(activeWorkspace.id)
                }
            }
        }
    }

    func updateNiriConfig(
        maxWindowsPerColumn: Int? = nil,
        maxVisibleColumns: Int? = nil,
        infiniteLoop: Bool? = nil,
        centerFocusedColumn: CenterFocusedColumn? = nil,
        alwaysCenterSingleColumn: Bool? = nil,
        singleWindowAspectRatio: SingleWindowAspectRatio? = nil
    ) {
        niriEngine?.updateConfiguration(
            maxWindowsPerColumn: maxWindowsPerColumn,
            maxVisibleColumns: maxVisibleColumns,
            infiniteLoop: infiniteLoop,
            centerFocusedColumn: centerFocusedColumn,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            singleWindowAspectRatio: singleWindowAspectRatio
        )
        refreshWindowsAndLayout()
    }

    private func handleNiriCommand(_ command: HotkeyCommand) {
        switch command {
        case let .focus(direction):
            focusNeighborInNiri(direction: direction)
        case .focusPrevious:
            focusPreviousInNiri()
        case let .move(direction):
            moveWindowInNiri(direction: direction)
        case let .swap(direction):
            swapWindowInNiri(direction: direction)
        case let .moveToWorkspace(index):
            moveFocusedWindow(toWorkspaceIndex: index)
        case .moveWindowToWorkspaceUp:
            moveWindowToAdjacentWorkspace(direction: .up)
        case .moveWindowToWorkspaceDown:
            moveWindowToAdjacentWorkspace(direction: .down)
        case let .moveColumnToWorkspace(index):
            moveColumnToWorkspaceByIndex(index: index)
        case .moveColumnToWorkspaceUp:
            moveColumnToAdjacentWorkspace(direction: .up)
        case .moveColumnToWorkspaceDown:
            moveColumnToAdjacentWorkspace(direction: .down)
        case let .switchWorkspace(index):
            switchWorkspace(index: index)
        case let .moveToMonitor(direction):
            moveFocusedWindowToMonitor(direction: direction)
        case let .focusMonitor(direction):
            focusMonitorInDirection(direction)
        case .focusMonitorPrevious:
            focusMonitorCyclic(previous: true)
        case .focusMonitorNext:
            focusMonitorCyclic(previous: false)
        case .focusMonitorLast:
            focusLastMonitor()
        case let .moveColumnToMonitor(direction):
            moveColumnToMonitorInDirection(direction)
        case .toggleFullscreen:
            toggleNiriFullscreen()
        case .toggleMaximized:
            toggleNiriMaximized()
        case .toggleNativeFullscreen:
            toggleNativeFullscreenForFocused()
        case .increaseGaps:
            workspaceManager.bumpGaps(by: 1)
        case .decreaseGaps:
            workspaceManager.bumpGaps(by: -1)
        case let .increaseWindowSize(direction):
            resizeWindowInNiri(factor: 1.1, direction: direction)
        case let .decreaseWindowSize(direction):
            resizeWindowInNiri(factor: 0.9, direction: direction)
        case .resetWindowSize:
            resetWindowSizeInNiri()
        case let .moveColumn(direction):
            moveColumnInNiri(direction: direction)
        case let .consumeWindow(direction):
            consumeWindowInNiri(direction: direction)
        case let .expelWindow(direction):
            expelWindowInNiri(direction: direction)
        case .toggleColumnTabbed:
            toggleColumnTabbedInNiri()
        case .focusDownOrLeft:
            focusDownOrLeftInNiri()
        case .focusUpOrRight:
            focusUpOrRightInNiri()
        case .focusColumnFirst:
            focusColumnFirstInNiri()
        case .focusColumnLast:
            focusColumnLastInNiri()
        case let .focusColumn(index):
            focusColumnInNiri(index: index)
        case .focusWindowTop:
            focusWindowTopInNiri()
        case .focusWindowBottom:
            focusWindowBottomInNiri()
        case .cycleColumnWidthForward:
            cycleColumnWidthInNiri(forwards: true)
        case .cycleColumnWidthBackward:
            cycleColumnWidthInNiri(forwards: false)
        case .toggleColumnFullWidth:
            toggleColumnFullWidthInNiri()
        case .cycleWindowHeightForward:
            cycleWindowHeightInNiri(forwards: true)
        case .cycleWindowHeightBackward:
            cycleWindowHeightInNiri(forwards: false)
        case let .moveWorkspaceToMonitor(direction):
            moveCurrentWorkspaceToMonitor(direction: direction)
        case .balanceSizes:
            balanceSizesInNiri()
        case let .summonWorkspace(index):
            summonWorkspace(index: index)
        case .openWindowFinder:
            openWindowFinder()
        }
    }

    private func focusNeighborInNiri(direction: Direction) {
        pendingNavigationTask?.cancel()

        if isProcessingNavigation {
            navigationQueue = [direction]
            pendingNavigationTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000)
                if let self, let queued = navigationQueue.first {
                    navigationQueue.removeAll()
                    executeFocusNeighborInNiri(direction: queued)
                }
            }
            return
        }

        executeFocusNeighborInNiri(direction: direction)
    }

    private func executeFocusNeighborInNiri(direction: Direction) {
        isProcessingNavigation = true
        defer { isProcessingNavigation = false }

        guard let engine = niriEngine else { return }
        guard let wsId = activeWorkspace()?.id else { return }
        var state = workspaceManager.niriViewportState(for: wsId)

        guard let currentId = state.selectedNodeId,
              let currentNode = engine.findNode(by: currentId)
        else {
            if let lastFocused = lastFocusedByWorkspace[wsId],
               let lastNode = engine.findNode(for: lastFocused)
            {
                state.selectedNodeId = lastNode.id
                workspaceManager.updateNiriViewportState(state, for: wsId)
                focusedHandle = lastFocused
                engine.updateFocusTimestamp(for: lastNode.id)
                focusWindow(lastFocused)
            } else if let firstHandle = workspaceManager.entries(in: wsId).first?.handle,
                      let firstNode = engine.findNode(for: firstHandle)
            {
                state.selectedNodeId = firstNode.id
                workspaceManager.updateNiriViewportState(state, for: wsId)
                focusedHandle = firstHandle
                engine.updateFocusTimestamp(for: firstNode.id)
                focusWindow(firstHandle)
            }
            return
        }

        if let newNode = engine.focusTarget(
            direction: direction,
            currentSelection: currentNode,
            in: wsId,
            state: &state
        ) {
            state.selectedNodeId = newNode.id
            workspaceManager.updateNiriViewportState(state, for: wsId)

            if let windowNode = newNode as? NiriWindow {
                focusedHandle = windowNode.handle

                engine.updateFocusTimestamp(for: windowNode.id)

                focusWindow(windowNode.handle)
            }

            executeLayoutRefreshImmediate()
        }
    }

    private func focusPreviousInNiri() {
        guard let engine = niriEngine else { return }
        guard let wsId = activeWorkspace()?.id else { return }
        var state = workspaceManager.niriViewportState(for: wsId)

        if let currentId = state.selectedNodeId {
            engine.updateFocusTimestamp(for: currentId)
        }

        guard let previousWindow = engine.focusPrevious(
            currentNodeId: state.selectedNodeId,
            in: wsId,
            state: &state,
            limitToWorkspace: true
        ) else {
            return
        }

        state.selectedNodeId = previousWindow.id
        workspaceManager.updateNiriViewportState(state, for: wsId)

        focusedHandle = previousWindow.handle

        focusWindow(previousWindow.handle)

        executeLayoutRefreshImmediate()
    }

    private func focusDownOrLeftInNiri() {
        executeCombinedNavigation { engine, currentNode, wsId, state in
            engine.focusDownOrLeft(currentSelection: currentNode, in: wsId, state: &state)
        }
    }

    private func focusUpOrRightInNiri() {
        executeCombinedNavigation { engine, currentNode, wsId, state in
            engine.focusUpOrRight(currentSelection: currentNode, in: wsId, state: &state)
        }
    }

    private func focusColumnFirstInNiri() {
        executeCombinedNavigation { engine, currentNode, wsId, state in
            engine.focusColumnFirst(currentSelection: currentNode, in: wsId, state: &state)
        }
    }

    private func focusColumnLastInNiri() {
        executeCombinedNavigation { engine, currentNode, wsId, state in
            engine.focusColumnLast(currentSelection: currentNode, in: wsId, state: &state)
        }
    }

    private func focusColumnInNiri(index: Int) {
        executeCombinedNavigation { engine, currentNode, wsId, state in
            engine.focusColumn(index, currentSelection: currentNode, in: wsId, state: &state)
        }
    }

    private func focusWindowTopInNiri() {
        executeCombinedNavigation { engine, currentNode, wsId, state in
            engine.focusWindowTop(currentSelection: currentNode, in: wsId, state: &state)
        }
    }

    private func focusWindowBottomInNiri() {
        executeCombinedNavigation { engine, currentNode, wsId, state in
            engine.focusWindowBottom(currentSelection: currentNode, in: wsId, state: &state)
        }
    }

    private func cycleColumnWidthInNiri(forwards: Bool) {
        guard let engine = niriEngine else { return }
        guard let wsId = activeWorkspace()?.id else { return }
        let state = workspaceManager.niriViewportState(for: wsId)

        guard let currentId = state.selectedNodeId,
              let windowNode = engine.findNode(by: currentId) as? NiriWindow,
              let column = engine.findColumn(containing: windowNode, in: wsId)
        else {
            return
        }

        engine.toggleColumnWidth(column, forwards: forwards)
        refreshWindowsAndLayout()
    }

    private func toggleColumnFullWidthInNiri() {
        guard let engine = niriEngine else { return }
        guard let wsId = activeWorkspace()?.id else { return }
        let state = workspaceManager.niriViewportState(for: wsId)

        guard let currentId = state.selectedNodeId,
              let windowNode = engine.findNode(by: currentId) as? NiriWindow,
              let column = engine.findColumn(containing: windowNode, in: wsId)
        else {
            return
        }

        engine.toggleFullWidth(column)
        refreshWindowsAndLayout()
    }

    private func cycleWindowHeightInNiri(forwards: Bool) {
        guard let engine = niriEngine else { return }
        guard let wsId = activeWorkspace()?.id else { return }
        let state = workspaceManager.niriViewportState(for: wsId)

        guard let currentId = state.selectedNodeId,
              let windowNode = engine.findNode(by: currentId) as? NiriWindow
        else {
            return
        }

        engine.toggleWindowHeight(windowNode, forwards: forwards)
        refreshWindowsAndLayout()
    }

    private func executeCombinedNavigation(
        _ navigationAction: (NiriLayoutEngine, NiriNode, WorkspaceDescriptor.ID, inout ViewportState) -> NiriNode?
    ) {
        guard let engine = niriEngine else { return }
        guard let wsId = activeWorkspace()?.id else { return }
        var state = workspaceManager.niriViewportState(for: wsId)

        guard let currentId = state.selectedNodeId,
              let currentNode = engine.findNode(by: currentId)
        else {
            return
        }

        guard let newNode = navigationAction(engine, currentNode, wsId, &state) else {
            return
        }

        state.selectedNodeId = newNode.id
        workspaceManager.updateNiriViewportState(state, for: wsId)

        if let windowNode = newNode as? NiriWindow {
            focusedHandle = windowNode.handle
            engine.updateFocusTimestamp(for: windowNode.id)

            focusWindow(windowNode.handle)
        }
    }

    private func moveWindowInNiri(direction: Direction) {
        guard let engine = niriEngine else { return }
        guard let wsId = activeWorkspace()?.id else { return }
        var state = workspaceManager.niriViewportState(for: wsId)

        guard let currentId = state.selectedNodeId,
              let currentNode = engine.findNode(by: currentId),
              let windowNode = currentNode as? NiriWindow
        else {
            return
        }

        if engine.moveWindow(windowNode, direction: direction, in: wsId, state: &state) {
            workspaceManager.updateNiriViewportState(state, for: wsId)
            refreshWindowsAndLayout()
        }
    }

    private func swapWindowInNiri(direction: Direction) {
        guard let engine = niriEngine else { return }
        guard let wsId = activeWorkspace()?.id else { return }

        var state = workspaceManager.niriViewportState(for: wsId)
        guard let currentId = state.selectedNodeId,
              let currentNode = engine.findNode(by: currentId),
              let windowNode = currentNode as? NiriWindow
        else {
            return
        }

        if engine.swapWindow(windowNode, direction: direction, in: wsId, state: &state) {
            workspaceManager.updateNiriViewportState(state, for: wsId)
            refreshWindowsAndLayout()
        }
    }

    private func toggleNiriFullscreen() {
        guard let engine = niriEngine else { return }
        guard let wsId = activeWorkspace()?.id else { return }
        let state = workspaceManager.niriViewportState(for: wsId)

        guard let currentId = state.selectedNodeId,
              let currentNode = engine.findNode(by: currentId),
              let windowNode = currentNode as? NiriWindow
        else {
            return
        }

        if windowNode.sizingMode == .fullscreen {
            windowNode.sizingMode = .normal

            if let savedHeight = windowNode.savedHeight {
                windowNode.height = savedHeight
                windowNode.savedHeight = nil
            }
        } else {
            windowNode.savedHeight = windowNode.height
            windowNode.sizingMode = .fullscreen
        }
        refreshWindowsAndLayout()
    }

    private func toggleNiriMaximized() {
        guard let engine = niriEngine else { return }
        guard let wsId = activeWorkspace()?.id else { return }
        let state = workspaceManager.niriViewportState(for: wsId)

        guard let currentId = state.selectedNodeId,
              let currentNode = engine.findNode(by: currentId),
              let windowNode = currentNode as? NiriWindow
        else {
            return
        }

        if windowNode.sizingMode == .maximized {
            windowNode.sizingMode = .normal

            if let savedHeight = windowNode.savedHeight {
                windowNode.height = savedHeight
                windowNode.savedHeight = nil
            }
        } else {
            windowNode.savedHeight = windowNode.height
            windowNode.sizingMode = .maximized
        }
        refreshWindowsAndLayout()
    }

    private func toggleNativeFullscreenForFocused() {
        guard let handle = focusedHandle else { return }
        guard let entry = workspaceManager.entry(for: handle) else { return }

        let currentState = AXWindowService.isFullscreen(entry.axRef)
        let newState = !currentState

        _ = AXWindowService.setNativeFullscreen(entry.axRef, fullscreen: newState)

        if newState {
            borderManager.hideBorder()
        }
    }

    private func resizeWindowInNiri(factor: CGFloat, direction: Direction) {
        guard let engine = niriEngine else { return }
        guard let wsId = activeWorkspace()?.id else { return }
        let state = workspaceManager.niriViewportState(for: wsId)

        guard let currentId = state.selectedNodeId,
              let currentNode = engine.findNode(by: currentId),
              let windowNode = currentNode as? NiriWindow
        else {
            return
        }

        if direction == .left || direction == .right {
            if let column = engine.findColumn(containing: windowNode, in: wsId) {
                column.size *= factor

                engine.normalizeColumnSizes(in: wsId)
            }
        } else {
            windowNode.size *= factor

            if let column = engine.findColumn(containing: windowNode, in: wsId) {
                engine.normalizeWindowSizes(in: column)
            }
        }

        refreshWindowsAndLayout()
    }

    private func resetWindowSizeInNiri() {
        guard let engine = niriEngine else { return }
        guard let wsId = activeWorkspace()?.id else { return }
        let state = workspaceManager.niriViewportState(for: wsId)

        guard let currentId = state.selectedNodeId,
              let currentNode = engine.findNode(by: currentId),
              let windowNode = currentNode as? NiriWindow
        else {
            return
        }

        windowNode.size = 1.0

        if let column = engine.findColumn(containing: windowNode, in: wsId) {
            column.size = 1.0
        }

        refreshWindowsAndLayout()
    }

    private func moveColumnInNiri(direction: Direction) {
        guard let engine = niriEngine else { return }
        guard let wsId = activeWorkspace()?.id else { return }
        var state = workspaceManager.niriViewportState(for: wsId)

        guard let currentId = state.selectedNodeId,
              let currentNode = engine.findNode(by: currentId),
              let windowNode = currentNode as? NiriWindow,
              let column = engine.findColumn(containing: windowNode, in: wsId)
        else {
            return
        }

        if engine.moveColumn(column, direction: direction, in: wsId, state: &state) {
            workspaceManager.updateNiriViewportState(state, for: wsId)
            refreshWindowsAndLayout()
        }
    }

    private func consumeWindowInNiri(direction: Direction) {
        guard let engine = niriEngine else { return }
        guard let wsId = activeWorkspace()?.id else { return }
        var state = workspaceManager.niriViewportState(for: wsId)

        guard let currentId = state.selectedNodeId,
              let currentNode = engine.findNode(by: currentId),
              let windowNode = currentNode as? NiriWindow
        else {
            return
        }

        if engine.consumeWindow(into: windowNode, from: direction, in: wsId, state: &state) {
            workspaceManager.updateNiriViewportState(state, for: wsId)
            refreshWindowsAndLayout()
        }
    }

    private func expelWindowInNiri(direction: Direction) {
        guard let engine = niriEngine else { return }
        guard let wsId = activeWorkspace()?.id else { return }
        var state = workspaceManager.niriViewportState(for: wsId)

        guard let currentId = state.selectedNodeId,
              let currentNode = engine.findNode(by: currentId),
              let windowNode = currentNode as? NiriWindow
        else {
            return
        }

        if engine.expelWindow(windowNode, to: direction, in: wsId, state: &state) {
            workspaceManager.updateNiriViewportState(state, for: wsId)
            refreshWindowsAndLayout()
        }
    }

    private func toggleColumnTabbedInNiri() {
        guard let engine = niriEngine else { return }
        guard let wsId = activeWorkspace()?.id else { return }
        let state = workspaceManager.niriViewportState(for: wsId)

        if engine.toggleColumnTabbed(in: wsId, state: state) {
            refreshWindowsAndLayout()
        }
    }

    private func moveWindowToAdjacentWorkspace(direction: Direction) {
        guard let engine = niriEngine else { return }
        guard let monitor = monitorForInteraction() else { return }
        guard let wsId = activeWorkspace()?.id else { return }

        let workspaceIds = workspaceManager.workspaces(on: monitor.id).map(\.id)

        guard let targetWsId = engine.adjacentWorkspace(
            from: wsId,
            direction: direction,
            workspaceIds: workspaceIds
        ) else {
            return
        }

        var sourceState = workspaceManager.niriViewportState(for: wsId)
        var targetState = workspaceManager.niriViewportState(for: targetWsId)

        guard let currentId = sourceState.selectedNodeId,
              let windowNode = engine.findNode(by: currentId) as? NiriWindow
        else {
            return
        }

        guard let result = engine.moveWindowToWorkspace(
            windowNode,
            from: wsId,
            to: targetWsId,
            sourceState: &sourceState,
            targetState: &targetState
        ) else {
            return
        }

        workspaceManager.updateNiriViewportState(sourceState, for: wsId)
        workspaceManager.updateNiriViewportState(targetState, for: targetWsId)

        if let newFocusId = result.newFocusNodeId,
           let newFocusNode = engine.findNode(by: newFocusId) as? NiriWindow
        {
            focusedHandle = newFocusNode.handle
            lastFocusedByWorkspace[wsId] = newFocusNode.handle
        } else {
            focusedHandle = workspaceManager.entries(in: wsId).first?.handle
        }

        refreshWindowsAndLayout()

        if let handle = focusedHandle {
            focusWindow(handle)
        }
    }

    private func moveColumnToAdjacentWorkspace(direction: Direction) {
        guard let engine = niriEngine else { return }
        guard let monitor = monitorForInteraction() else { return }
        guard let wsId = activeWorkspace()?.id else { return }

        let workspaceIds = workspaceManager.workspaces(on: monitor.id).map(\.id)

        guard let targetWsId = engine.adjacentWorkspace(
            from: wsId,
            direction: direction,
            workspaceIds: workspaceIds
        ) else {
            return
        }

        var sourceState = workspaceManager.niriViewportState(for: wsId)
        var targetState = workspaceManager.niriViewportState(for: targetWsId)

        guard let currentId = sourceState.selectedNodeId,
              let windowNode = engine.findNode(by: currentId) as? NiriWindow,
              let column = engine.findColumn(containing: windowNode, in: wsId)
        else {
            return
        }

        guard let result = engine.moveColumnToWorkspace(
            column,
            from: wsId,
            to: targetWsId,
            sourceState: &sourceState,
            targetState: &targetState
        ) else {
            return
        }

        workspaceManager.updateNiriViewportState(sourceState, for: wsId)
        workspaceManager.updateNiriViewportState(targetState, for: targetWsId)

        if let newFocusId = result.newFocusNodeId,
           let newFocusNode = engine.findNode(by: newFocusId) as? NiriWindow
        {
            focusedHandle = newFocusNode.handle
            lastFocusedByWorkspace[wsId] = newFocusNode.handle
        } else {
            focusedHandle = workspaceManager.entries(in: wsId).first?.handle
        }

        refreshWindowsAndLayout()

        if let handle = focusedHandle {
            focusWindow(handle)
        }
    }

    private func moveColumnToWorkspaceByIndex(index: Int) {
        guard let engine = niriEngine else { return }
        guard let wsId = activeWorkspace()?.id else { return }

        let targetName = String(max(0, index) + 1)
        guard let targetWsId = workspaceManager.workspaceId(for: targetName, createIfMissing: true) else { return }

        guard targetWsId != wsId else { return }

        var sourceState = workspaceManager.niriViewportState(for: wsId)
        var targetState = workspaceManager.niriViewportState(for: targetWsId)

        guard let currentId = sourceState.selectedNodeId,
              let windowNode = engine.findNode(by: currentId) as? NiriWindow,
              let column = engine.findColumn(containing: windowNode, in: wsId)
        else {
            return
        }

        guard let result = engine.moveColumnToWorkspace(
            column,
            from: wsId,
            to: targetWsId,
            sourceState: &sourceState,
            targetState: &targetState
        ) else {
            return
        }

        workspaceManager.updateNiriViewportState(sourceState, for: wsId)
        workspaceManager.updateNiriViewportState(targetState, for: targetWsId)

        if let newFocusId = result.newFocusNodeId,
           let newFocusNode = engine.findNode(by: newFocusId) as? NiriWindow
        {
            focusedHandle = newFocusNode.handle
            lastFocusedByWorkspace[wsId] = newFocusNode.handle
        } else {
            focusedHandle = workspaceManager.entries(in: wsId).first?.handle
        }

        refreshWindowsAndLayout()

        if let handle = focusedHandle {
            focusWindow(handle)
        }
    }

    private func focusMonitorInDirection(_ direction: Direction) {
        guard let currentMonitorId = activeMonitorId ?? monitorForInteraction()?.id else { return }

        guard let targetMonitor = workspaceManager.adjacentMonitor(
            from: currentMonitorId,
            direction: direction
        ) else {
            return
        }

        switchToMonitor(targetMonitor.id, fromMonitor: currentMonitorId)
    }

    private func focusMonitorCyclic(previous: Bool) {
        guard let currentMonitorId = activeMonitorId ?? monitorForInteraction()?.id else { return }

        let targetMonitor: Monitor? = if previous {
            workspaceManager.previousMonitor(from: currentMonitorId)
        } else {
            workspaceManager.nextMonitor(from: currentMonitorId)
        }

        guard let target = targetMonitor else { return }
        switchToMonitor(target.id, fromMonitor: currentMonitorId)
    }

    private func focusLastMonitor() {
        guard let previousId = previousMonitorId else { return }
        guard let currentMonitorId = activeMonitorId ?? monitorForInteraction()?.id else { return }

        guard workspaceManager.monitors.contains(where: { $0.id == previousId }) else {
            previousMonitorId = nil
            return
        }

        switchToMonitor(previousId, fromMonitor: currentMonitorId)
    }

    private func switchToMonitor(_ targetMonitorId: Monitor.ID, fromMonitor currentMonitorId: Monitor.ID) {
        previousMonitorId = currentMonitorId

        guard let targetWorkspace = workspaceManager.activeWorkspaceOrFirst(on: targetMonitorId) else {
            return
        }

        activeMonitorId = targetMonitorId

        let targetHandle = lastFocusedByWorkspace[targetWorkspace.id] ??
            workspaceManager.entries(in: targetWorkspace.id).first?.handle

        if let handle = targetHandle {
            focusedHandle = handle
            focusWindow(handle)
        }

        refreshWindowsAndLayout()
    }

    private func moveCurrentWorkspaceToMonitor(direction: Direction) {
        guard let currentMonitorId = activeMonitorId ?? monitorForInteraction()?.id else { return }
        guard let wsId = activeWorkspace()?.id else { return }

        guard let targetMonitor = workspaceManager.adjacentMonitor(
            from: currentMonitorId,
            direction: direction
        ) else { return }

        guard workspaceManager.moveWorkspaceToMonitor(wsId, to: targetMonitor.id) else { return }

        previousMonitorId = currentMonitorId
        activeMonitorId = targetMonitor.id

        refreshWindowsAndLayout()
    }

    private func moveColumnToMonitorInDirection(_ direction: Direction) {
        guard let engine = niriEngine else { return }
        guard let currentMonitorId = activeMonitorId ?? monitorForInteraction()?.id else { return }
        guard let wsId = activeWorkspace()?.id else { return }

        guard let targetMonitor = workspaceManager.adjacentMonitor(
            from: currentMonitorId,
            direction: direction
        ) else {
            return
        }

        var sourceState = workspaceManager.niriViewportState(for: wsId)

        guard let currentId = sourceState.selectedNodeId,
              let windowNode = engine.findNode(by: currentId) as? NiriWindow,
              let column = engine.findColumn(containing: windowNode, in: wsId)
        else {
            return
        }

        guard let targetWorkspace = workspaceManager.activeWorkspaceOrFirst(on: targetMonitor.id) else {
            return
        }

        var targetState = workspaceManager.niriViewportState(for: targetWorkspace.id)

        guard let result = engine.moveColumnToWorkspace(
            column,
            from: wsId,
            to: targetWorkspace.id,
            sourceState: &sourceState,
            targetState: &targetState
        ) else {
            return
        }

        workspaceManager.updateNiriViewportState(sourceState, for: wsId)
        workspaceManager.updateNiriViewportState(targetState, for: targetWorkspace.id)

        for window in column.windowNodes {
            workspaceManager.setWorkspace(for: window.handle, to: targetWorkspace.id)
        }

        previousMonitorId = currentMonitorId
        activeMonitorId = targetMonitor.id

        if let movedHandle = result.movedHandle {
            focusedHandle = movedHandle
            lastFocusedByWorkspace[targetWorkspace.id] = movedHandle
            focusWindow(movedHandle)
        }

        refreshWindowsAndLayout()
    }

    private func refreshWindowsAndLayout() {
        if isRefreshInProgress {
            hasPendingRefresh = true
            return
        }

        isRefreshInProgress = true
        hasPendingRefresh = false

        Task { @MainActor [weak self] in
            await self?.executeLayoutRefresh()
            self?.finishRefresh()
        }
    }

    private func finishRefresh() {
        isRefreshInProgress = false

        if hasPendingRefresh {
            hasPendingRefresh = false
            refreshWindowsAndLayout()
        }
    }

    private func executeLayoutRefresh() async {
        let interval = signpostInterval("executeLayoutRefresh")
        defer { interval.end() }

        if lockScreenObserver.isFrontmostAppLockScreen() || isLockScreenActive {
            return
        }

        let windows = await axManager.currentWindowsAsync()
        var seenKeys: Set<WindowModel.WindowKey> = []
        let focusedWorkspaceId = activeWorkspace()?.id

        windowStateCache.captureState(
            workspaceManager: workspaceManager,
            niriEngine: niriEngine
        )

        for (ax, pid, winId) in windows {
            if let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
               bundleId == LockScreenObserver.lockScreenAppBundleId
            {
                continue
            }

            if let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
               appRulesByBundleId[bundleId]?.alwaysFloat == true
            {
                continue
            }

            let wsForWindow: WorkspaceDescriptor.ID
            if let cachedWsId = windowStateCache.frozenWorkspaceId(for: winId) {
                wsForWindow = cachedWsId
            } else {
                let defaultWorkspace = resolveWorkspaceForNewWindow(
                    axRef: ax,
                    pid: pid,
                    fallbackWorkspaceId: focusedWorkspaceId
                )
                wsForWindow = workspaceAssignment(pid: pid, windowId: winId) ?? defaultWorkspace
            }

            _ = workspaceManager.addWindow(ax, pid: pid, windowId: winId, to: wsForWindow)
            seenKeys.insert(.init(pid: pid, windowId: winId))
        }
        workspaceManager.removeMissing(keys: seenKeys)
        workspaceManager.garbageCollectUnusedWorkspaces(focusedWorkspaceId: focusedWorkspaceId)

        var activeWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        for monitor in workspaceManager.monitors {
            if let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id) {
                activeWorkspaceIds.insert(workspace.id)
            }
        }

        layoutWithNiriEngine(activeWorkspaces: activeWorkspaceIds)

        if let focusedWorkspaceId {
            ensureFocusedHandleValid(in: focusedWorkspaceId)
        }
    }

    private func layoutWithNiriEngine(activeWorkspaces: Set<WorkspaceDescriptor.ID>) {
        guard let engine = niriEngine else { return }

        let cornersByMonitor = CornerHidingService.calculateOptimalCorners(for: workspaceManager.monitors)

        for monitor in workspaceManager.monitors {
            guard let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id) else { continue }
            unhideWorkspace(workspace.id, monitor: monitor)
        }

        for monitor in workspaceManager.monitors {
            guard let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id) else { continue }
            let wsId = workspace.id

            let windowHandles = workspaceManager.entries(in: wsId).map(\.handle)
            let currentSelection = workspaceManager.niriViewportState(for: wsId).selectedNodeId
            _ = engine.syncWindows(windowHandles, in: wsId, selectedNodeId: currentSelection)

            for entry in workspaceManager.entries(in: wsId) {
                let currentSize = (try? AXWindowService.frame(entry.axRef))?.size
                var constraints = AXWindowService.sizeConstraints(entry.axRef, currentSize: currentSize)

                if let bundleId = NSRunningApplication(processIdentifier: entry.handle.pid)?.bundleIdentifier,
                   let rule = appRulesByBundleId[bundleId]
                {
                    if let minW = rule.minWidth {
                        constraints.minSize.width = max(constraints.minSize.width, minW)
                    }
                    if let minH = rule.minHeight {
                        constraints.minSize.height = max(constraints.minSize.height, minH)
                    }
                }

                engine.updateWindowConstraints(for: entry.handle, constraints: constraints)
            }

            var state = workspaceManager.niriViewportState(for: wsId)

            if let selectedId = state.selectedNodeId {
                if engine.findNode(by: selectedId) == nil {
                    state.selectedNodeId = engine.validateSelection(selectedId, in: wsId)
                }
            }

            if state.selectedNodeId == nil {
                if let firstHandle = windowHandles.first,
                   let firstNode = engine.findNode(for: firstHandle)
                {
                    state.selectedNodeId = firstNode.id
                }
            }

            if let selectedId = state.selectedNodeId,
               let selectedNode = engine.findNode(by: selectedId) as? NiriWindow
            {
                lastFocusedByWorkspace[wsId] = selectedNode.handle
                if let currentFocused = focusedHandle {
                    if workspaceManager.workspace(for: currentFocused) == wsId {
                        focusedHandle = selectedNode.handle
                    }
                } else {
                    focusedHandle = selectedNode.handle
                }
            }

            let gaps = LayoutGaps(
                horizontal: CGFloat(workspaceManager.gaps),
                vertical: CGFloat(workspaceManager.gaps),
                outer: workspaceManager.outerGaps
            )

            let insetFrame = insetWorkingFrame(from: monitor.visibleFrame)
            let area = WorkingAreaContext(
                workingFrame: insetFrame,
                viewFrame: monitor.frame,
                scale: backingScale(for: monitor)
            )

            let frames = engine.calculateCombinedLayout(
                in: wsId,
                monitor: monitor,
                gaps: gaps,
                state: state,
                workingArea: area
            )

            let hiddenHandles = engine.hiddenWindowHandles(in: wsId, state: state)
            let corner = cornersByMonitor[monitor.id] ?? .bottomRightCorner

            for entry in workspaceManager.entries(in: wsId) {
                if hiddenHandles.contains(entry.handle) {
                    hideWindow(entry, monitor: monitor, corner: corner)
                } else {
                    unhideWindow(entry, monitor: monitor)
                }
            }

            var frameUpdates: [(pid: pid_t, windowId: Int, frame: CGRect)] = []
            for (handle, frame) in frames {
                if hiddenHandles.contains(handle) { continue }
                if let entry = workspaceManager.entry(for: handle) {
                    frameUpdates.append((handle.pid, entry.windowId, frame))
                }
            }
            axManager.applyFramesParallel(frameUpdates)

            if let focusedHandle {
                if hiddenHandles.contains(focusedHandle) {
                    borderManager.hideBorder()
                } else if let frame = frames[focusedHandle],
                          let entry = workspaceManager.entry(for: focusedHandle)
                {
                    updateBorderIfAllowed(handle: focusedHandle, frame: frame, windowId: entry.windowId)
                }
            }

            workspaceManager.updateNiriViewportState(state, for: wsId)
        }

        updateTabbedColumnOverlays()
        updateWorkspaceBar()

        for ws in workspaceManager.workspaces where !activeWorkspaces.contains(ws.id) {
            guard let monitor = workspaceManager.monitor(for: ws.id) else { continue }
            guard let corner = cornersByMonitor[monitor.id] else { continue }
            hideWorkspace(ws.id, monitor: monitor, corner: corner)
        }
    }

    private func unhideWorkspace(_ workspaceId: WorkspaceDescriptor.ID, monitor: Monitor) {
        for entry in workspaceManager.entries(in: workspaceId) {
            unhideWindow(entry, monitor: monitor)
        }
    }

    private func hideWorkspace(_ workspaceId: WorkspaceDescriptor.ID, monitor: Monitor, corner: OptimalHideCorner) {
        for entry in workspaceManager.entries(in: workspaceId) {
            hideWindow(entry, monitor: monitor, corner: corner)
        }
    }

    private func hideWindow(_ entry: WindowModel.Entry, monitor: Monitor, corner: OptimalHideCorner) {
        guard let frame = try? AXWindowService.frame(entry.axRef) else { return }
        if !workspaceManager.isHiddenInCorner(entry.handle) {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let referenceFrame = center.monitorApproximation(in: workspaceManager.monitors)?.frame ?? monitor.frame
            let proportional = proportionalPosition(topLeft: frame.topLeftCorner, in: referenceFrame)
            workspaceManager.setHiddenProportionalPosition(proportional, for: entry.handle)
        }
        let origin = hiddenOrigin(for: frame.size, monitor: monitor, corner: corner, pid: entry.handle.pid)
        try? AXWindowService.setFrame(entry.axRef, frame: CGRect(origin: origin, size: frame.size))
    }

    private func unhideWindow(_ entry: WindowModel.Entry, monitor _: Monitor) {
        workspaceManager.setHiddenProportionalPosition(nil, for: entry.handle)
    }

    private func proportionalPosition(topLeft: CGPoint, in frame: CGRect) -> CGPoint {
        let width = max(1, frame.width)
        let height = max(1, frame.height)
        let x = (topLeft.x - frame.minX) / width
        let y = (frame.maxY - topLeft.y) / height
        return CGPoint(x: min(max(0, x), 1), y: min(max(0, y), 1))
    }

    private func topLeftFromProportion(_ proportion: CGPoint, in frame: CGRect) -> CGPoint {
        let x = frame.minX + proportion.x * frame.width
        let y = frame.maxY - proportion.y * frame.height
        return CGPoint(x: x, y: y)
    }

    private func hiddenOrigin(
        for size: CGSize,
        monitor: Monitor,
        corner: OptimalHideCorner,
        pid: pid_t
    ) -> CGPoint {
        let visible = monitor.visibleFrame
        let offset: CGFloat = isZoomApp(pid) ? 0 : 1
        switch corner {
        case .bottomLeftCorner:
            return CGPoint(x: visible.minX - size.width + offset, y: visible.minY + offset - size.height)
        case .bottomRightCorner:
            return CGPoint(x: visible.maxX - offset, y: visible.minY + offset - size.height)
        }
    }

    private func isZoomApp(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.bundleIdentifier == "us.zoom.xos"
    }

    private func updateTabbedColumnOverlays() {
        guard let engine = niriEngine else {
            tabbedOverlayManager.removeAll()
            return
        }

        var infos: [TabbedColumnOverlayInfo] = []
        for monitor in workspaceManager.monitors {
            guard let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id) else { continue }

            for column in engine.columns(in: workspace.id) where column.isTabbed {
                guard let frame = column.frame else { continue }
                guard TabbedColumnOverlayManager.shouldShowOverlay(
                    columnFrame: frame,
                    visibleFrame: monitor.visibleFrame
                ) else { continue }

                let windows = column.windowNodes
                guard !windows.isEmpty else { continue }

                let activeIndex = min(max(0, column.activeTileIdx), windows.count - 1)
                let activeHandle = windows[activeIndex].handle
                let activeWindowId = workspaceManager.entry(for: activeHandle)?.windowId

                infos.append(
                    TabbedColumnOverlayInfo(
                        workspaceId: workspace.id,
                        columnId: column.id,
                        columnFrame: frame,
                        tabCount: windows.count,
                        activeIndex: activeIndex,
                        activeWindowId: activeWindowId
                    )
                )
            }
        }

        tabbedOverlayManager.updateOverlays(infos)
    }

    private func selectTabInNiri(workspaceId: WorkspaceDescriptor.ID, columnId: NodeId, index: Int) {
        guard let engine = niriEngine else { return }
        guard let column = engine.columns(in: workspaceId).first(where: { $0.id == columnId }) else { return }

        let windows = column.windowNodes
        guard windows.indices.contains(index) else { return }

        column.setActiveTileIdx(index)
        engine.updateTabbedColumnVisibility(column: column)

        let target = windows[index]
        var state = workspaceManager.niriViewportState(for: workspaceId)
        state.selectedNodeId = target.id
        engine.ensureSelectionVisible(node: target, in: workspaceId, state: &state, edge: .left)
        workspaceManager.updateNiriViewportState(state, for: workspaceId)

        focusedHandle = target.handle
        engine.updateFocusTimestamp(for: target.id)
        focusWindow(target.handle)
        updateTabbedColumnOverlays()
    }

    private func monitorForInteraction() -> Monitor? {
        if let focused = focusedHandle,
           let workspaceId = workspaceManager.workspace(for: focused),
           let monitor = workspaceManager.monitor(for: workspaceId)
        {
            return monitor
        }
        return workspaceManager.monitors.first
    }

    private func activeWorkspace() -> WorkspaceDescriptor? {
        guard let monitor = monitorForInteraction() else { return nil }
        return workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
    }

    private func switchWorkspace(index: Int) {
        if let currentWorkspace = activeWorkspace() {
            saveNiriViewportState(for: currentWorkspace.id)
        }

        let targetName = String(max(0, index) + 1)
        guard let result = workspaceManager.focusWorkspace(named: targetName) else { return }

        let currentMonitorId = activeMonitorId ?? monitorForInteraction()?.id
        if let currentMonitorId, currentMonitorId != result.monitor.id {
            previousMonitorId = currentMonitorId
        }
        activeMonitorId = result.monitor.id

        focusedHandle = lastFocusedByWorkspace[result.workspace.id]
            ?? workspaceManager.entries(in: result.workspace.id).first?.handle

        refreshWindowsAndLayout()
        if let handle = focusedHandle {
            focusWindow(handle)
        }
    }

    private func saveNiriViewportState(for workspaceId: WorkspaceDescriptor.ID) {
        guard let engine = niriEngine else { return }
        var state = workspaceManager.niriViewportState(for: workspaceId)

        if let focused = focusedHandle,
           workspaceManager.workspace(for: focused) == workspaceId,
           let focusedNode = engine.findNode(for: focused)
        {
            state.selectedNodeId = focusedNode.id
        }

        workspaceManager.updateNiriViewportState(state, for: workspaceId)
    }

    private func moveFocusedWindow(toWorkspaceIndex index: Int) {
        guard let handle = focusedHandle else { return }
        let targetName = String(max(0, index) + 1)
        guard let targetId = workspaceManager.workspaceId(for: targetName, createIfMissing: true),
              let target = workspaceManager.descriptor(for: targetId)
        else {
            return
        }
        let currentWorkspaceId = workspaceManager.workspace(for: handle)

        if let engine = niriEngine, let sourceWsId = currentWorkspaceId {
            var sourceState = workspaceManager.niriViewportState(for: sourceWsId)

            if let currentNode = engine.findNode(for: handle),
               sourceState.selectedNodeId == currentNode.id
            {
                sourceState.selectedNodeId = engine.fallbackSelectionOnRemoval(
                    removing: currentNode.id,
                    in: sourceWsId
                )
                workspaceManager.updateNiriViewportState(sourceState, for: sourceWsId)
            }
        }

        workspaceManager.setWorkspace(for: handle, to: target.id)

        if target.id != activeWorkspace()?.id, let currentWorkspaceId {
            if let engine = niriEngine {
                let sourceState = workspaceManager.niriViewportState(for: currentWorkspaceId)
                if let newSelectedId = sourceState.selectedNodeId,
                   let newSelectedNode = engine.findNode(by: newSelectedId) as? NiriWindow
                {
                    focusedHandle = newSelectedNode.handle
                } else {
                    focusedHandle = workspaceManager.entries(in: currentWorkspaceId).first?.handle
                }
            } else {
                focusedHandle = workspaceManager.entries(in: currentWorkspaceId).first?.handle
            }
        }

        refreshWindowsAndLayout()

        if target.id == activeWorkspace()?.id {
            if let engine = niriEngine,
               let movedNode = engine.findNode(for: handle)
            {
                var targetState = workspaceManager.niriViewportState(for: target.id)
                targetState.selectedNodeId = movedNode.id

                engine.ensureSelectionVisible(
                    node: movedNode,
                    in: target.id,
                    state: &targetState,
                    edge: .left
                )
                workspaceManager.updateNiriViewportState(targetState, for: target.id)
            }
            focusWindow(handle)
        }
    }

    private func moveFocusedWindowToMonitor(direction: Direction) {
        guard let handle = focusedHandle,
              let currentWorkspaceId = workspaceManager.workspace(for: handle),
              let targetWorkspace = workspaceManager
              .move(handle: handle, from: currentWorkspaceId, direction: direction) else { return }

        if let monitor = workspaceManager.monitor(for: targetWorkspace.id) {
            _ = workspaceManager.setActiveWorkspace(targetWorkspace.id, on: monitor.id)
        }
        focusedHandle = handle
        refreshWindowsAndLayout()
        focusWindow(handle)
    }

    private func resolveWorkspaceForNewWindow(
        axRef: AXWindowRef,
        pid: pid_t,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?
    ) -> WorkspaceDescriptor.ID {
        if let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           let rule = appRulesByBundleId[bundleId],
           let wsName = rule.assignToWorkspace,
           let wsId = workspaceManager.workspaceId(for: wsName, createIfMissing: false)
        {
            return wsId
        }

        if let frame = try? AXWindowService.frame(axRef) {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            if let monitor = workspaceManager.monitors.first(where: { $0.visibleFrame.contains(center) }),
               let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
            {
                return workspace.id
            }
        }
        if let fallbackWorkspaceId {
            return fallbackWorkspaceId
        }
        return workspaceManager.primaryWorkspace()?.id ?? workspaceManager.workspaces.first!.id
    }

    private func workspaceAssignment(pid: pid_t, windowId: Int) -> WorkspaceDescriptor.ID? {
        for ws in workspaceManager.workspaces {
            let entries = workspaceManager.entries(in: ws.id)
            if entries.contains(where: { $0.windowId == windowId && $0.handle.pid == pid }) {
                return ws.id
            }
        }
        return nil
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshWindowsAndLayout()
            }
        }
        if let timer = refreshTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func handleAxEvent(_ event: AXEvent) {
        switch event {
        case let .created(ref, pid, winId):
            handleCreated(ref: ref, pid: pid, winId: winId)
        case let .removed(_, pid, winId):
            handleRemoved(pid: pid, winId: winId)
        case let .focused(ref, pid, winId):
            handleFocused(ref: ref, pid: pid, winId: winId)
        case .changed:
            refreshWindowsAndLayout()
        }
    }

    private func handleCreated(ref: AXWindowRef, pid: pid_t, winId: Int) {
        if let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           appRulesByBundleId[bundleId]?.alwaysFloat == true
        {
            return
        }

        let workspaceId = resolveWorkspaceForNewWindow(axRef: ref, pid: pid, fallbackWorkspaceId: activeWorkspace()?.id)
        _ = workspaceManager.addWindow(ref, pid: pid, windowId: winId, to: workspaceId)

        refreshWindowsAndLayout()
    }

    private func handleRemoved(pid: pid_t, winId: Int) {
        var affectedWorkspaceId: WorkspaceDescriptor.ID?
        var removedHandle: WindowHandle?
        for ws in workspaceManager.workspaces {
            for entry in workspaceManager.entries(in: ws.id) {
                if entry.windowId == winId, entry.handle.pid == pid {
                    affectedWorkspaceId = ws.id
                    removedHandle = entry.handle
                    break
                }
            }
            if affectedWorkspaceId != nil { break }
        }

        workspaceManager.removeWindow(pid: pid, windowId: winId)

        if let wsId = affectedWorkspaceId {
            layoutWithNiriEngine(activeWorkspaces: [wsId])

            if let removed = removedHandle, removed.id == focusedHandle?.id {
                ensureFocusedHandleValid(in: wsId)
            }
        }

        if let focused = focusedHandle,
           let entry = workspaceManager.entry(for: focused),
           let frame = try? AXWindowService.frame(entry.axRef)
        {
            updateBorderIfAllowed(handle: focused, frame: frame, windowId: entry.windowId)
        } else {
            borderManager.hideBorder()
        }
    }

    private func handleFocused(ref: AXWindowRef, pid: pid_t, winId: Int) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            let windowType = AXWindowService.windowType(ref, appPolicy: app.activationPolicy)
            if windowType != .tiling {
                isNonManagedFocusActive = true
                isAppFullscreenActive = false
                borderManager.hideBorder()
                return
            }
        }
        isNonManagedFocusActive = false
        for ws in workspaceManager.workspaces {
            for entry in workspaceManager.entries(in: ws.id) {
                if entry.windowId == winId, entry.handle.pid == pid {
                    if ws.id != activeWorkspace()?.id {
                        guard let monitor = workspaceManager.monitor(for: ws.id),
                              workspaceManager.workspaces(on: monitor.id).contains(where: { $0.id == ws.id })
                        else {
                            return
                        }

                        if let currentMonitorId = activeMonitorId ?? monitorForInteraction()?.id,
                           currentMonitorId != monitor.id
                        {
                            previousMonitorId = currentMonitorId
                        }
                        activeMonitorId = monitor.id
                        _ = workspaceManager.setActiveWorkspace(ws.id, on: monitor.id)
                        refreshWindowsAndLayout()
                    }

                    focusedHandle = entry.handle
                    lastFocusedByWorkspace[ws.id] = entry.handle

                    if let engine = niriEngine,
                       let node = engine.findNode(for: entry.handle)
                    {
                        var state = workspaceManager.niriViewportState(for: ws.id)
                        state.selectedNodeId = node.id
                        workspaceManager.updateNiriViewportState(state, for: ws.id)

                        engine.updateFocusTimestamp(for: node.id)
                    }

                    if let frame = try? AXWindowService.frame(entry.axRef) {
                        updateBorderIfAllowed(handle: entry.handle, frame: frame, windowId: entry.windowId)
                    }
                    return
                }
            }
        }
        borderManager.hideBorder()
        handleCreated(ref: ref, pid: pid, winId: winId)
    }

    private func updateBorderIfAllowed(handle: WindowHandle, frame: CGRect, windowId: Int) {
        if isNonManagedFocusActive {
            borderManager.hideBorder()
            return
        }

        if let entry = workspaceManager.entry(for: handle) {
            isAppFullscreenActive = AXWindowService.isFullscreen(entry.axRef)
        } else {
            isAppFullscreenActive = false
        }

        if isAppFullscreenActive || isManagedWindowFullscreen(handle) {
            borderManager.hideBorder()
            return
        }
        borderManager.updateFocusedWindow(frame: frame, windowId: windowId)
    }

    private func isManagedWindowFullscreen(_ handle: WindowHandle) -> Bool {
        guard let engine = niriEngine,
              let windowNode = engine.findNode(for: handle)
        else {
            return false
        }
        return windowNode.isFullscreen
    }

    private func focusWindow(_ handle: WindowHandle) {
        guard let entry = workspaceManager.entry(for: handle) else { return }
        isNonManagedFocusActive = false

        let now = Date()

        if now.timeIntervalSince(lastAnyFocusTime) < globalFocusCooldown {
            return
        }

        if pendingFocusHandle == handle {
            let timeSinceFocus = now.timeIntervalSince(lastFocusTime)
            if timeSinceFocus < 0.016 {
                return
            }
        }

        if isFocusOperationPending {
            deferredFocusHandle = handle
            return
        }

        isFocusOperationPending = true
        defer {
            isFocusOperationPending = false
            if let deferred = deferredFocusHandle, deferred != handle {
                deferredFocusHandle = nil
                focusWindow(deferred)
            }
        }

        pendingFocusHandle = handle
        lastFocusTime = now
        lastAnyFocusTime = now
        lastFocusedByWorkspace[entry.workspaceId] = handle

        let app = AXUIElementCreateApplication(handle.pid)
        let focusResult = AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, entry.axRef.element)
        let raiseResult = AXUIElementPerformAction(entry.axRef.element, kAXRaiseAction as CFString)

        if let runningApp = NSRunningApplication(processIdentifier: handle.pid) {
            runningApp.activate()
        }

        if focusResult != .success || raiseResult != .success {
            NSLog("WMController: Focus failed - focus: \(focusResult.rawValue), raise: \(raiseResult.rawValue)")
        }

        if moveMouseToFocusedWindowEnabled {
            moveMouseToWindow(handle)
        }

        let handleForBorder = handle
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let entry = workspaceManager.entry(for: handleForBorder) else { return }
            if let frame = try? AXWindowService.frame(entry.axRef) {
                updateBorderIfAllowed(handle: entry.handle, frame: frame, windowId: entry.windowId)
            }
        }
    }

    private func ensureFocusedHandleValid(in workspaceId: WorkspaceDescriptor.ID) {
        if let focused = focusedHandle,
           workspaceManager.entry(for: focused)?.workspaceId == workspaceId
        {
            lastFocusedByWorkspace[workspaceId] = focused
            return
        }
        if let remembered = lastFocusedByWorkspace[workspaceId],
           workspaceManager.entry(for: remembered) != nil
        {
            focusedHandle = remembered
            return
        }
        focusedHandle = workspaceManager.entries(in: workspaceId).first?.handle
        if let focusedHandle {
            lastFocusedByWorkspace[workspaceId] = focusedHandle
        }
    }

    private func balanceSizesInNiri() {
        guard let engine = niriEngine else { return }
        guard let wsId = activeWorkspace()?.id else { return }

        engine.balanceSizes(in: wsId)
        refreshWindowsAndLayout()
    }

    private func summonWorkspace(index: Int) {
        guard let currentMonitorId = activeMonitorId ?? monitorForInteraction()?.id else { return }

        let targetName = String(max(0, index) + 1)
        guard let targetWsId = workspaceManager.workspaceId(for: targetName, createIfMissing: false) else { return }

        guard let targetMonitorId = workspaceManager.monitorId(for: targetWsId),
              targetMonitorId != currentMonitorId
        else {
            switchWorkspace(index: index)
            return
        }

        guard workspaceManager.summonWorkspace(targetWsId, to: currentMonitorId) else { return }

        syncMonitorsToNiriEngine()

        focusedHandle = lastFocusedByWorkspace[targetWsId]
            ?? workspaceManager.entries(in: targetWsId).first?.handle

        refreshWindowsAndLayout()
        if let handle = focusedHandle {
            focusWindow(handle)
        }
    }

    private func openWindowFinder() {
        let entries = workspaceManager.allEntries()
        var items: [WindowFinderItem] = []

        for entry in entries {
            guard entry.layoutReason == .standard else { continue }

            let title = (try? AXWindowService.title(entry.axRef)) ?? ""

            let app = NSRunningApplication(processIdentifier: entry.handle.pid)
            let appName = app?.localizedName ?? "Unknown"
            let appIcon = app?.icon

            let workspaceName = workspaceManager.descriptor(for: entry.workspaceId)?.name ?? "?"

            items.append(WindowFinderItem(
                id: entry.handle.id,
                handle: entry.handle,
                title: title,
                appName: appName,
                appIcon: appIcon,
                workspaceName: workspaceName,
                workspaceId: entry.workspaceId
            ))
        }

        items.sort { ($0.appName, $0.title) < ($1.appName, $1.title) }

        WindowFinderController.shared.show(windows: items) { [weak self] item in
            self?.navigateToWindow(item)
        }
    }

    private func navigateToWindow(_ item: WindowFinderItem) {
        guard let engine = niriEngine else { return }
        guard let entry = workspaceManager.entry(for: item.handle) else { return }

        let currentWsId = activeWorkspace()?.id

        if entry.workspaceId != currentWsId {
            let wsName = workspaceManager.descriptor(for: entry.workspaceId)?.name ?? ""
            if let result = workspaceManager.focusWorkspace(named: wsName) {
                activeMonitorId = result.monitor.id
                syncMonitorsToNiriEngine()
            }
        }

        if let niriWindow = engine.findNode(for: item.handle) {
            var state = workspaceManager.niriViewportState(for: entry.workspaceId)
            state.selectedNodeId = niriWindow.id

            if let column = engine.findColumn(containing: niriWindow, in: entry.workspaceId),
               let colIdx = engine.columnIndex(of: column, in: entry.workspaceId)
            {
                let cols = engine.columns(in: entry.workspaceId)
                state.snapToColumn(
                    colIdx,
                    totalColumns: cols.count,
                    visibleCap: engine.maxVisibleColumns,
                    infiniteLoop: engine.infiniteLoop
                )
            }

            workspaceManager.updateNiriViewportState(state, for: entry.workspaceId)
        }

        refreshWindowsAndLayout()

        focusedHandle = item.handle
        lastFocusedByWorkspace[entry.workspaceId] = item.handle
        focusWindow(item.handle)
    }

    func moveMouseToWindow(_ handle: WindowHandle) {
        guard let entry = workspaceManager.entry(for: handle),
              let frame = try? AXWindowService.frame(entry.axRef) else { return }

        let center = CGPoint(x: frame.midX, y: frame.midY)

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            let flippedY = screen.frame.height - center.y + screen.frame.origin.y
            CGWarpMouseCursorPosition(CGPoint(x: center.x, y: flippedY))
        } else {
            CGWarpMouseCursorPosition(center)
        }
    }

    func runningAppsWithWindows() -> [RunningAppInfo] {
        var appInfoMap: [String: RunningAppInfo] = [:]

        for entry in workspaceManager.allEntries() {
            guard entry.layoutReason == .standard else { continue }

            let app = NSRunningApplication(processIdentifier: entry.handle.pid)
            guard let bundleId = app?.bundleIdentifier else { continue }

            if appInfoMap[bundleId] != nil { continue }

            let frame = (try? AXWindowService.frame(entry.axRef)) ?? .zero

            appInfoMap[bundleId] = RunningAppInfo(
                id: bundleId,
                bundleId: bundleId,
                appName: app?.localizedName ?? bundleId,
                icon: app?.icon,
                windowSize: frame.size
            )
        }

        return appInfoMap.values.sorted { $0.appName < $1.appName }
    }
}

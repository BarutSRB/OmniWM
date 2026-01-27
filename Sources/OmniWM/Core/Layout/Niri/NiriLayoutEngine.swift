import AppKit
import Foundation

enum CenterFocusedColumn: String, CaseIterable, Codable, Identifiable {
    case never
    case always
    case onOverflow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .never: "Never"
        case .always: "Always"
        case .onOverflow: "On Overflow"
        }
    }
}

enum SingleWindowAspectRatio: String, CaseIterable, Codable, Identifiable {
    case none
    case ratio16x9 = "16:9"
    case ratio4x3 = "4:3"
    case ratio21x9 = "21:9"
    case square = "1:1"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "None (Fill)"
        case .ratio16x9: "16:9"
        case .ratio4x3: "4:3"
        case .ratio21x9: "21:9"
        case .square: "Square"
        }
    }

    var ratio: CGFloat? {
        switch self {
        case .none: nil
        case .ratio16x9: 16.0 / 9.0
        case .ratio4x3: 4.0 / 3.0
        case .ratio21x9: 21.0 / 9.0
        case .square: 1.0
        }
    }
}

struct WorkingAreaContext {
    var workingFrame: CGRect
    var viewFrame: CGRect
    var scale: CGFloat
}

struct Struts {
    var left: CGFloat = 0
    var right: CGFloat = 0
    var top: CGFloat = 0
    var bottom: CGFloat = 0

    static let zero = Struts()
}

func computeWorkingArea(
    parentArea: CGRect,
    scale: CGFloat,
    struts: Struts
) -> CGRect {
    var workingArea = parentArea

    workingArea.size.width = max(0, workingArea.size.width - struts.left - struts.right)
    workingArea.origin.x += struts.left

    workingArea.size.height = max(0, workingArea.size.height - struts.top - struts.bottom)
    workingArea.origin.y += struts.top

    let physicalX = ceil(workingArea.origin.x * scale) / scale
    let physicalY = ceil(workingArea.origin.y * scale) / scale

    let xDiff = min(workingArea.size.width, physicalX - workingArea.origin.x)
    let yDiff = min(workingArea.size.height, physicalY - workingArea.origin.y)

    workingArea.size.width -= xDiff
    workingArea.size.height -= yDiff
    workingArea.origin.x = physicalX
    workingArea.origin.y = physicalY

    return workingArea
}

struct NiriRenderStyle {
    var tabIndicatorWidth: CGFloat

    static let `default` = NiriRenderStyle(
        tabIndicatorWidth: 0
    )
}

final class NiriLayoutEngine {
    private(set) var monitors: [Monitor.ID: NiriMonitor] = [:]

    private var roots: [WorkspaceDescriptor.ID: NiriRoot] = [:]

    private var handleToNode: [WindowHandle: NiriWindow] = [:]

    private var closingHandles: Set<WindowHandle> = []

    private var framePool: [WindowHandle: CGRect] = [:]
    private var hiddenPool: [WindowHandle: HideSide] = [:]

    var maxWindowsPerColumn: Int
    var maxVisibleColumns: Int
    var infiniteLoop: Bool

    var centerFocusedColumn: CenterFocusedColumn = .never

    var alwaysCenterSingleColumn: Bool = true

    var singleWindowAspectRatio: SingleWindowAspectRatio = .none

    var renderStyle: NiriRenderStyle = .default

    private(set) var interactiveResize: InteractiveResize?
    private(set) var interactiveMove: InteractiveMove?

    var resizeConfiguration = ResizeConfiguration.default
    var moveConfiguration = MoveConfiguration.default

    var windowMovementAnimationConfig: SpringConfig = .balanced.with(
        epsilon: 0.0001,
        velocityEpsilon: 0.01
    )
    var animationClock: AnimationClock?
    var displayRefreshRate: Double = 60.0
    var animationsEnabled: Bool = true

    var presetColumnWidths: [PresetSize] = [
        .proportion(1.0 / 3.0),
        .proportion(0.5),
        .proportion(2.0 / 3.0)
    ]

    init(maxWindowsPerColumn: Int = 3, maxVisibleColumns: Int = 3, infiniteLoop: Bool = false) {
        self.maxWindowsPerColumn = max(1, min(10, maxWindowsPerColumn))
        self.maxVisibleColumns = max(1, min(5, maxVisibleColumns))
        self.infiniteLoop = infiniteLoop
        centerFocusedColumn = .onOverflow
    }

    func ensureMonitor(
        for monitorId: Monitor.ID,
        monitor: Monitor,
        orientation: Monitor.Orientation? = nil
    ) -> NiriMonitor {
        if let existing = monitors[monitorId] {
            if let orientation {
                existing.updateOrientation(orientation)
            }
            return existing
        }
        let niriMonitor = NiriMonitor(monitor: monitor, orientation: orientation)
        monitors[monitorId] = niriMonitor
        return niriMonitor
    }

    func monitor(for monitorId: Monitor.ID) -> NiriMonitor? {
        monitors[monitorId]
    }

    func updateMonitors(_ newMonitors: [Monitor], orientations: [Monitor.ID: Monitor.Orientation] = [:]) {
        for monitor in newMonitors {
            if let niriMonitor = monitors[monitor.id] {
                let orientation = orientations[monitor.id]
                niriMonitor.updateOutputSize(monitor: monitor, orientation: orientation)
            }
        }

        let newIds = Set(newMonitors.map(\.id))
        monitors = monitors.filter { newIds.contains($0.key) }
    }

    func cleanupRemovedMonitor(_ monitorId: Monitor.ID) {
        guard let niriMonitor = monitors[monitorId] else { return }

        for workspaceId in niriMonitor.workspaceRoots.keys {
            roots.removeValue(forKey: workspaceId)
        }

        monitors.removeValue(forKey: monitorId)
    }

    func updateMonitorOrientations(_ orientations: [Monitor.ID: Monitor.Orientation]) {
        for (monitorId, orientation) in orientations {
            monitors[monitorId]?.updateOrientation(orientation)
        }
    }

    func updateMonitorSettings(_ settings: ResolvedNiriSettings, for monitorId: Monitor.ID) {
        monitors[monitorId]?.resolvedSettings = settings
    }

    func effectiveMaxVisibleColumns(for monitorId: Monitor.ID) -> Int {
        monitors[monitorId]?.resolvedSettings?.maxVisibleColumns ?? maxVisibleColumns
    }

    func effectiveMaxWindowsPerColumn(for monitorId: Monitor.ID) -> Int {
        monitors[monitorId]?.resolvedSettings?.maxWindowsPerColumn ?? maxWindowsPerColumn
    }

    func effectiveCenterFocusedColumn(for monitorId: Monitor.ID) -> CenterFocusedColumn {
        monitors[monitorId]?.resolvedSettings?.centerFocusedColumn ?? centerFocusedColumn
    }

    func effectiveAlwaysCenterSingleColumn(for monitorId: Monitor.ID) -> Bool {
        monitors[monitorId]?.resolvedSettings?.alwaysCenterSingleColumn ?? alwaysCenterSingleColumn
    }

    func effectiveInfiniteLoop(for monitorId: Monitor.ID) -> Bool {
        monitors[monitorId]?.resolvedSettings?.infiniteLoop ?? infiniteLoop
    }

    func moveWorkspace(
        _ workspaceId: WorkspaceDescriptor.ID,
        to monitorId: Monitor.ID,
        monitor: Monitor
    ) {
        let targetMonitor = ensureMonitor(for: monitorId, monitor: monitor)

        if let currentMonitorId = monitorContaining(workspace: workspaceId),
           currentMonitorId == monitorId
        {
            return
        }

        if let currentMonitorId = monitorContaining(workspace: workspaceId),
           let currentMonitor = monitors[currentMonitorId]
        {
            if let root = currentMonitor.workspaceRoots.removeValue(forKey: workspaceId) {
                targetMonitor.workspaceRoots[workspaceId] = root
                roots[workspaceId] = root
            }
            if let state = currentMonitor.viewportStates.removeValue(forKey: workspaceId) {
                targetMonitor.viewportStates[workspaceId] = state
            }
            currentMonitor.workspaceOrder.removeAll { $0 == workspaceId }
        }

        if targetMonitor.workspaceRoots[workspaceId] == nil {
            let root = ensureRoot(for: workspaceId)
            targetMonitor.workspaceRoots[workspaceId] = root
        }
        if targetMonitor.viewportStates[workspaceId] == nil {
            targetMonitor.viewportStates[workspaceId] = ViewportState()
        }
        if !targetMonitor.workspaceOrder.contains(workspaceId) {
            targetMonitor.workspaceOrder.append(workspaceId)
        }
    }

    func monitorContaining(workspace workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        for (monitorId, niriMonitor) in monitors {
            if niriMonitor.containsWorkspace(workspaceId) {
                return monitorId
            }
        }
        return nil
    }

    func monitorForWorkspace(_ workspaceId: WorkspaceDescriptor.ID) -> NiriMonitor? {
        for niriMonitor in monitors.values {
            if niriMonitor.containsWorkspace(workspaceId) {
                return niriMonitor
            }
        }
        return nil
    }

    private func ensureRoot(for workspaceId: WorkspaceDescriptor.ID) -> NiriRoot {
        if let existing = roots[workspaceId] {
            return existing
        }
        let root = NiriRoot(workspaceId: workspaceId)
        roots[workspaceId] = root

        let initialColumn = NiriContainer()
        root.appendChild(initialColumn)
        return root
    }

    private func claimEmptyColumnIfWorkspaceEmpty(in root: NiriRoot) -> NiriContainer? {
        guard root.allWindows.isEmpty else { return nil }

        let emptyColumns = root.columns.filter(\.children.isEmpty)
        guard let target = emptyColumns.first else { return nil }

        for column in emptyColumns.dropFirst() {
            column.remove()
        }

        return target
    }

    private func removeEmptyColumnsIfWorkspaceEmpty(in root: NiriRoot) {
        guard root.allWindows.isEmpty else { return }

        let emptyColumns = root.columns.filter(\.children.isEmpty)
        for column in emptyColumns {
            column.remove()
        }
    }

    func root(for workspaceId: WorkspaceDescriptor.ID) -> NiriRoot? {
        roots[workspaceId]
    }

    func columns(in workspaceId: WorkspaceDescriptor.ID) -> [NiriContainer] {
        guard let root = roots[workspaceId] else { return [] }
        return root.columns
    }

    func hiddenWindowHandles(
        in workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        workingFrame: CGRect? = nil,
        gaps: CGFloat = 0
    ) -> [WindowHandle: HideSide] {
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return [:] }

        guard let workingFrame else {
            return [:]
        }

        let viewOffset = state.viewOffsetPixels.current()
        let viewLeft = -viewOffset
        let viewRight = viewLeft + workingFrame.width

        var columnPositions = [CGFloat]()
        columnPositions.reserveCapacity(cols.count)
        var runningX: CGFloat = 0
        for column in cols {
            columnPositions.append(runningX)
            runningX += column.cachedWidth + gaps
        }

        var hiddenHandles = [WindowHandle: HideSide]()
        for (colIdx, column) in cols.enumerated() {
            let colX = columnPositions[colIdx]
            let colRight = colX + column.cachedWidth

            if colRight <= viewLeft {
                for window in column.windowNodes {
                    hiddenHandles[window.handle] = .left
                }
            } else if colX >= viewRight {
                for window in column.windowNodes {
                    hiddenHandles[window.handle] = .right
                }
            } else {
                for window in column.windowNodes {
                    if let windowFrame = window.frame {
                        let visibleWidth = min(windowFrame.maxX, workingFrame.maxX) - max(
                            windowFrame.minX,
                            workingFrame.minX
                        )
                        if visibleWidth < 1.0 {
                            let side: HideSide = windowFrame.midX < workingFrame.midX ? .left : .right
                            hiddenHandles[window.handle] = side
                        }
                    }
                }
            }
        }
        return hiddenHandles
    }

    private func wrapIndex(_ idx: Int, total: Int) -> Int? {
        guard total > 0 else { return nil }
        if infiniteLoop {
            let modulo = total
            return ((idx % modulo) + modulo) % modulo
        } else {
            return (idx >= 0 && idx < total) ? idx : nil
        }
    }

    func findNode(by id: NodeId) -> NiriNode? {
        for root in roots.values {
            if let found = root.findNode(by: id) {
                return found
            }
        }
        return nil
    }

    func findNode(for handle: WindowHandle) -> NiriWindow? {
        handleToNode[handle]
    }

    func updateWindowConstraints(for handle: WindowHandle, constraints: WindowSizeConstraints) {
        guard let node = handleToNode[handle] else { return }
        node.constraints = constraints
    }

    func column(of node: NiriNode) -> NiriContainer? {
        var current = node
        while let parent = current.parent {
            if parent is NiriRoot {
                return current as? NiriContainer
            }
            current = parent
        }
        return nil
    }

    func columnIndex(of column: NiriNode, in workspaceId: WorkspaceDescriptor.ID) -> Int? {
        columns(in: workspaceId).firstIndex { $0.id == column.id }
    }

    private func columnX(at index: Int, columns: [NiriContainer], gaps: CGFloat) -> CGFloat {
        var x: CGFloat = 0
        for i in 0 ..< index where i < columns.count {
            x += columns[i].cachedWidth + gaps
        }
        return x
    }

    func findColumn(containing window: NiriWindow, in workspaceId: WorkspaceDescriptor.ID) -> NiriContainer? {
        guard let root = roots[workspaceId] else { return nil }
        for col in root.columns {
            for child in col.children {
                if child.id == window.id {
                    return col
                }
            }
        }
        return nil
    }

    func addWindow(
        handle: WindowHandle,
        to workspaceId: WorkspaceDescriptor.ID,
        afterSelection selectedNodeId: NodeId?,
        focusedHandle: WindowHandle? = nil
    ) -> NiriWindow {
        let root = ensureRoot(for: workspaceId)

        if let existingColumn = claimEmptyColumnIfWorkspaceEmpty(in: root) {
            existingColumn.width = .proportion(1.0 / CGFloat(maxVisibleColumns))
            let windowNode = NiriWindow(handle: handle)
            existingColumn.appendChild(windowNode)
            handleToNode[handle] = windowNode
            return windowNode
        }

        let referenceColumn: NiriContainer? = if let focused = focusedHandle,
                                                 let focusedNode = handleToNode[focused],
                                                 let col = column(of: focusedNode)
        {
            col
        } else if let selId = selectedNodeId,
                  let selNode = root.findNode(by: selId),
                  let col = column(of: selNode)
        {
            col
        } else {
            root.columns.last
        }

        let newColumn = NiriContainer()
        newColumn.width = .proportion(1.0 / CGFloat(maxVisibleColumns))
        if let refCol = referenceColumn {
            root.insertAfter(newColumn, reference: refCol)
        } else {
            root.appendChild(newColumn)
        }

        let windowNode = NiriWindow(handle: handle)
        newColumn.appendChild(windowNode)

        handleToNode[handle] = windowNode

        return windowNode
    }

    func removeWindow(handle: WindowHandle) {
        guard let node = handleToNode[handle] else { return }
        closingHandles.remove(handle)

        guard let column = node.parent as? NiriContainer else { return }

        if column.displayMode == .tabbed {
            let windowIdx = column.children.firstIndex { $0.id == node.id }
            if let idx = windowIdx {
                if idx == column.activeTileIdx {
                    if column.children.count > 1 {
                        if idx < column.children.count - 1 {
                        } else {
                            column.activeTileIdx = max(0, idx - 1)
                        }
                    }
                } else if idx < column.activeTileIdx {
                    column.activeTileIdx = max(0, column.activeTileIdx - 1)
                }
            }
        }

        node.remove()
        handleToNode.removeValue(forKey: handle)

        if column.displayMode == .tabbed, !column.children.isEmpty {
            column.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: column)
        }

        if column.children.isEmpty {
            let root = column.parent as? NiriRoot
            column.remove()

            if let root {
                let cols = root.columns
                if cols.isEmpty {
                    let emptyColumn = NiriContainer()
                    root.appendChild(emptyColumn)
                } else {
                    for col in cols {
                        col.cachedWidth = 0
                    }
                }
            }
        }
    }

    struct ColumnRemovalResult {
        let fallbackSelectionId: NodeId?
        let restorePreviousViewOffset: CGFloat?
    }

    func animateColumnsForRemoval(
        columnIndex removedIdx: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        gaps: CGFloat
    ) -> ColumnRemovalResult {
        let cols = columns(in: workspaceId)
        guard removedIdx >= 0, removedIdx < cols.count else {
            return ColumnRemovalResult(
                fallbackSelectionId: nil,
                restorePreviousViewOffset: nil
            )
        }

        let activeIdx = state.activeColumnIndex
        let offset = columnX(at: removedIdx + 1, columns: cols, gaps: gaps)
                   - columnX(at: removedIdx, columns: cols, gaps: gaps)
        let postRemovalCount = cols.count - 1

        if animationsEnabled {
            if activeIdx <= removedIdx {
                for col in cols[(removedIdx + 1)...] {
                    if col.hasMoveAnimationRunning {
                        col.offsetMoveAnimCurrent(offset)
                    } else {
                        col.animateMoveFrom(
                            displacement: CGPoint(x: offset, y: 0),
                            clock: animationClock,
                            config: windowMovementAnimationConfig,
                            displayRefreshRate: displayRefreshRate
                        )
                    }
                }
            } else {
                for col in cols[..<removedIdx] {
                    if col.hasMoveAnimationRunning {
                        col.offsetMoveAnimCurrent(-offset)
                    } else {
                        col.animateMoveFrom(
                            displacement: CGPoint(x: -offset, y: 0),
                            clock: animationClock,
                            config: windowMovementAnimationConfig,
                            displayRefreshRate: displayRefreshRate
                        )
                    }
                }
            }
        }

        let removingNode = cols[removedIdx].windowNodes.first
        let fallback = removingNode.flatMap { fallbackSelectionOnRemoval(removing: $0.id, in: workspaceId) }

        if removedIdx < activeIdx {
            state.activeColumnIndex = activeIdx - 1
            state.viewOffsetPixels.offset(delta: Double(offset))
            state.activatePrevColumnOnRemoval = nil
            return ColumnRemovalResult(
                fallbackSelectionId: fallback,
                restorePreviousViewOffset: nil
            )
        } else if removedIdx == activeIdx,
                  let prevOffset = state.activatePrevColumnOnRemoval {
            let newActiveIdx = max(0, activeIdx - 1)
            state.activeColumnIndex = newActiveIdx
            state.activatePrevColumnOnRemoval = nil
            return ColumnRemovalResult(
                fallbackSelectionId: fallback,
                restorePreviousViewOffset: prevOffset
            )
        } else if removedIdx == activeIdx {
            let newActiveIdx = min(activeIdx, max(0, postRemovalCount - 1))
            state.activeColumnIndex = newActiveIdx
            state.activatePrevColumnOnRemoval = nil
            return ColumnRemovalResult(
                fallbackSelectionId: fallback,
                restorePreviousViewOffset: nil
            )
        } else {
            state.activatePrevColumnOnRemoval = nil
            return ColumnRemovalResult(
                fallbackSelectionId: fallback,
                restorePreviousViewOffset: nil
            )
        }
    }

    func animateColumnsForAddition(
        columnIndex addedIdx: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        gaps: CGFloat,
        workingAreaWidth: CGFloat
    ) {
        let cols = columns(in: workspaceId)
        guard addedIdx >= 0, addedIdx < cols.count else { return }

        let addedCol = cols[addedIdx]
        let activeIdx = state.activeColumnIndex

        if addedCol.cachedWidth <= 0 {
            addedCol.resolveAndCacheWidth(workingAreaWidth: workingAreaWidth, gaps: gaps)
        }

        let offset = addedCol.cachedWidth + gaps

        guard animationsEnabled else { return }

        if activeIdx <= addedIdx {
            for col in cols[(addedIdx + 1)...] {
                if col.hasMoveAnimationRunning {
                    col.offsetMoveAnimCurrent(-offset)
                } else {
                    col.animateMoveFrom(
                        displacement: CGPoint(x: -offset, y: 0),
                        clock: animationClock,
                        config: windowMovementAnimationConfig,
                        displayRefreshRate: displayRefreshRate
                    )
                }
            }
        } else {
            for col in cols[..<addedIdx] {
                if col.hasMoveAnimationRunning {
                    col.offsetMoveAnimCurrent(offset)
                } else {
                    col.animateMoveFrom(
                        displacement: CGPoint(x: offset, y: 0),
                        clock: animationClock,
                        config: windowMovementAnimationConfig,
                        displayRefreshRate: displayRefreshRate
                    )
                }
            }
        }
    }

    func tickAllColumnAnimations(in workspaceId: WorkspaceDescriptor.ID, at time: TimeInterval) -> Bool {
        guard let root = roots[workspaceId] else { return false }
        var anyRunning = false
        for column in root.columns {
            if column.tickMoveAnimation(at: time) { anyRunning = true }
            if column.tickWidthAnimation(at: time) { anyRunning = true }
        }
        return anyRunning
    }

    func tickWorkspaceSwitchAnimation(for workspaceId: WorkspaceDescriptor.ID, at time: TimeInterval) -> Bool {
        guard let monitorId = monitorContaining(workspace: workspaceId),
              let monitor = monitors[monitorId] else {
            return false
        }
        return monitor.tickWorkspaceSwitchAnimation(at: time)
    }

    func hasAnyColumnAnimationsRunning(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let root = roots[workspaceId] else { return false }
        return root.columns.contains { $0.hasMoveAnimationRunning || $0.hasWidthAnimationRunning }
    }

    @discardableResult
    func syncWindows(
        _ handles: [WindowHandle],
        in workspaceId: WorkspaceDescriptor.ID,
        selectedNodeId: NodeId?,
        focusedHandle: WindowHandle? = nil
    ) -> Set<WindowHandle> {
        let root = ensureRoot(for: workspaceId)
        let existingIdSet = root.windowIdSet

        var currentIdSet = Set<UUID>(minimumCapacity: handles.count)
        for handle in handles {
            currentIdSet.insert(handle.id)
        }

        var removedHandles = Set<WindowHandle>()

        for window in root.allWindows {
            if !currentIdSet.contains(window.windowId) {
                removedHandles.insert(window.handle)
                removeWindow(handle: window.handle)
            }
        }

        for handle in handles {
            if !existingIdSet.contains(handle.id) {
                _ = addWindow(
                    handle: handle,
                    to: workspaceId,
                    afterSelection: selectedNodeId,
                    focusedHandle: focusedHandle
                )
            }
        }

        return removedHandles
    }

    func validateSelection(
        _ selectedNodeId: NodeId?,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NodeId? {
        guard let selectedId = selectedNodeId else {
            return columns(in: workspaceId).first?.firstChild()?.id
        }

        guard let root = roots[workspaceId],
              let existingNode = root.findNode(by: selectedId)
        else {
            return columns(in: workspaceId).first?.firstChild()?.id
        }

        return existingNode.id
    }

    func fallbackSelectionOnRemoval(
        removing removingNodeId: NodeId,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NodeId? {
        guard let root = roots[workspaceId],
              let removingNode = root.findNode(by: removingNodeId)
        else {
            return nil
        }

        if let nextSibling = removingNode.nextSibling() {
            return nextSibling.id
        }

        if let prevSibling = removingNode.prevSibling() {
            return prevSibling.id
        }

        let cols = columns(in: workspaceId)
        if let currentCol = column(of: removingNode),
           let currentIdx = cols.firstIndex(where: { $0.id == currentCol.id })
        {
            if currentIdx > 0, let window = cols[currentIdx - 1].firstChild() {
                return window.id
            }
            if currentIdx < cols.count - 1, let window = cols[currentIdx + 1].firstChild() {
                return window.id
            }
        }

        for col in cols {
            if col.id != column(of: removingNode)?.id {
                if let firstWindow = col.firstChild() {
                    return firstWindow.id
                }
            }
        }

        return nil
    }

    func updateConfiguration(
        maxWindowsPerColumn: Int? = nil,
        maxVisibleColumns: Int? = nil,
        infiniteLoop: Bool? = nil,
        centerFocusedColumn: CenterFocusedColumn? = nil,
        alwaysCenterSingleColumn: Bool? = nil,
        singleWindowAspectRatio: SingleWindowAspectRatio? = nil,
        animationsEnabled: Bool? = nil
    ) {
        if let max = maxWindowsPerColumn {
            self.maxWindowsPerColumn = max.clamped(to: 1 ... 10)
        }
        if let max = maxVisibleColumns {
            self.maxVisibleColumns = max.clamped(to: 1 ... 5)
        }
        if let loop = infiniteLoop {
            self.infiniteLoop = loop
        }
        if let center = centerFocusedColumn {
            self.centerFocusedColumn = center
        }
        if let centerSingle = alwaysCenterSingleColumn {
            self.alwaysCenterSingleColumn = centerSingle
        }
        if let aspectRatio = singleWindowAspectRatio {
            self.singleWindowAspectRatio = aspectRatio
        }

        if let enabled = animationsEnabled {
            self.animationsEnabled = enabled
            for monitor in monitors.values {
                for workspaceId in monitor.viewportStates.keys {
                    monitor.viewportStates[workspaceId]?.animationsEnabled = enabled
                }
            }
        }
    }

    func moveWindow(
        _ node: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        switch direction {
        case .down, .up:
            moveWindowVertical(node, direction: direction)
        case .left, .right:
            moveWindowHorizontal(
                node,
                direction: direction,
                in: workspaceId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }
    }

    func swapWindow(
        _ node: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        switch direction {
        case .down, .up:
            swapWindowVertical(node, direction: direction)
        case .left, .right:
            swapWindowHorizontal(
                node,
                direction: direction,
                in: workspaceId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }
    }

    private func moveWindowVertical(_ node: NiriWindow, direction: Direction) -> Bool {
        guard let column = node.parent as? NiriContainer else {
            return false
        }

        let sibling: NiriNode?
        switch direction {
        case .up:
            sibling = node.nextSibling()
        case .down:
            sibling = node.prevSibling()
        default:
            return false
        }

        guard let targetSibling = sibling else {
            return false
        }

        let nodeIdx = column.children.firstIndex { $0.id == node.id }
        let siblingIdx = column.children.firstIndex { $0.id == targetSibling.id }

        node.swapWith(targetSibling)

        if column.displayMode == .tabbed, let nIdx = nodeIdx, let sIdx = siblingIdx {
            if nIdx == column.activeTileIdx {
                column.activeTileIdx = sIdx
            } else if sIdx == column.activeTileIdx {
                column.activeTileIdx = nIdx
            }
        }

        return true
    }

    private func swapWindowVertical(_ node: NiriWindow, direction: Direction) -> Bool {
        guard let column = node.parent as? NiriContainer else {
            return false
        }

        let sibling: NiriNode?
        switch direction {
        case .up:
            sibling = node.nextSibling()
        case .down:
            sibling = node.prevSibling()
        default:
            return false
        }

        guard let targetSibling = sibling else {
            return false
        }

        let nodeIdx = column.children.firstIndex { $0.id == node.id }
        let siblingIdx = column.children.firstIndex { $0.id == targetSibling.id }

        node.swapWith(targetSibling)

        if column.displayMode == .tabbed, let nIdx = nodeIdx, let sIdx = siblingIdx {
            if nIdx == column.activeTileIdx {
                column.activeTileIdx = sIdx
            } else if sIdx == column.activeTileIdx {
                column.activeTileIdx = nIdx
            }
        }

        return true
    }

    private func moveWindowHorizontal(
        _ node: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return false }

        guard let currentColumn = column(of: node),
              let currentColIdx = columnIndex(of: currentColumn, in: workspaceId)
        else {
            return false
        }

        let step = (direction == .right) ? 1 : -1
        let len = cols.count
        let targetColIdx: Int

        if infiniteLoop {
            targetColIdx = ((currentColIdx + step) % len + len) % len
        } else {
            let raw = currentColIdx + step
            guard raw >= 0, raw < len else { return false }
            targetColIdx = raw
        }

        let targetColumn = cols[targetColIdx]

        if targetColumn.id == currentColumn.id {
            return false
        }

        guard targetColumn.children.count < maxWindowsPerColumn else {
            return false
        }

        moveWindowToColumn(
            node,
            from: currentColumn,
            to: targetColumn,
            in: workspaceId,
            direction: direction,
            state: &state
        )

        ensureSelectionVisible(
            node: node,
            in: workspaceId,
            state: &state,
            edge: direction == .right ? .right : .left,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return true
    }

    private func swapWindowHorizontal(
        _ node: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return false }

        guard let currentColumn = column(of: node),
              let currentColIdx = columnIndex(of: currentColumn, in: workspaceId)
        else {
            return false
        }

        let step = (direction == .right) ? 1 : -1
        let len = cols.count
        let targetColIdx: Int

        if infiniteLoop {
            targetColIdx = ((currentColIdx + step) % len + len) % len
        } else {
            let raw = currentColIdx + step
            guard raw >= 0, raw < len else { return false }
            targetColIdx = raw
        }

        let targetColumn = cols[targetColIdx]
        if targetColumn.id == currentColumn.id {
            return false
        }

        let sourceWindows = currentColumn.windowNodes
        let targetWindows = targetColumn.windowNodes
        guard !targetWindows.isEmpty else { return false }

        if sourceWindows.count == 1 && targetWindows.count == 1 {
            return moveColumn(
                currentColumn,
                direction: direction,
                in: workspaceId,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }

        let now = animationClock?.now() ?? CACurrentMediaTime()

        let sourceActiveTileIdx = currentColumn.activeTileIdx.clamped(to: 0 ... (sourceWindows.count - 1))
        let targetActiveTileIdx = targetColumn.activeTileIdx.clamped(to: 0 ... (targetWindows.count - 1))

        let sourceActiveWindow = sourceWindows[sourceActiveTileIdx]
        let targetActiveWindow = targetWindows[targetActiveTileIdx]

        let sourceColX = state.columnX(at: currentColIdx, columns: cols, gap: gaps)
        let targetColX = state.columnX(at: targetColIdx, columns: cols, gap: gaps)
        let sourceColRenderOffset = currentColumn.renderOffset(at: now)
        let targetColRenderOffset = targetColumn.renderOffset(at: now)
        let sourceTileOffset = computeTileOffset(column: currentColumn, tileIdx: sourceActiveTileIdx, gaps: gaps)
        let targetTileOffset = computeTileOffset(column: targetColumn, tileIdx: targetActiveTileIdx, gaps: gaps)

        let sourcePt = CGPoint(
            x: sourceColX + sourceColRenderOffset.x,
            y: sourceTileOffset
        )
        let targetPt = CGPoint(
            x: targetColX + targetColRenderOffset.x,
            y: targetTileOffset
        )

        let sourceWidth = currentColumn.width
        let sourceIsFullWidth = currentColumn.isFullWidth
        let targetWidth = targetColumn.width
        let targetIsFullWidth = targetColumn.isFullWidth

        sourceActiveWindow.detach()
        targetActiveWindow.detach()

        let sourceInsertIdx = min(sourceActiveTileIdx, currentColumn.children.count)
        let targetInsertIdx = min(targetActiveTileIdx, targetColumn.children.count)

        currentColumn.insertChild(targetActiveWindow, at: sourceInsertIdx)
        targetColumn.insertChild(sourceActiveWindow, at: targetInsertIdx)

        currentColumn.width = targetWidth
        currentColumn.isFullWidth = targetIsFullWidth
        targetColumn.width = sourceWidth
        targetColumn.isFullWidth = sourceIsFullWidth

        currentColumn.setActiveTileIdx(sourceActiveTileIdx)
        targetColumn.setActiveTileIdx(targetActiveTileIdx)

        let newCols = columns(in: workspaceId)
        let newSourceColIdx = columnIndex(of: currentColumn, in: workspaceId) ?? currentColIdx
        let newTargetColIdx = columnIndex(of: targetColumn, in: workspaceId) ?? targetColIdx
        let newSourceColX = state.columnX(at: newSourceColIdx, columns: newCols, gap: gaps)
        let newTargetColX = state.columnX(at: newTargetColIdx, columns: newCols, gap: gaps)
        let newSourceTileOffset = computeTileOffset(column: currentColumn, tileIdx: sourceInsertIdx, gaps: gaps)
        let newTargetTileOffset = computeTileOffset(column: targetColumn, tileIdx: targetInsertIdx, gaps: gaps)

        let newSourcePt = CGPoint(x: newSourceColX, y: newSourceTileOffset)
        let newTargetPt = CGPoint(x: newTargetColX, y: newTargetTileOffset)

        targetActiveWindow.stopMoveAnimations()
        targetActiveWindow.animateMoveFrom(
            displacement: CGPoint(x: targetPt.x - newSourcePt.x, y: targetPt.y - newSourcePt.y),
            clock: animationClock,
            config: windowMovementAnimationConfig,
            displayRefreshRate: displayRefreshRate
        )

        sourceActiveWindow.stopMoveAnimations()
        sourceActiveWindow.animateMoveFrom(
            displacement: CGPoint(x: sourcePt.x - newTargetPt.x, y: sourcePt.y - newTargetPt.y),
            clock: animationClock,
            config: windowMovementAnimationConfig,
            displayRefreshRate: displayRefreshRate
        )

        if currentColumn.isTabbed {
            updateTabbedColumnVisibility(column: currentColumn)
        }
        if targetColumn.isTabbed {
            updateTabbedColumnVisibility(column: targetColumn)
        }

        let edge: NiriRevealEdge = direction == .right ? .right : .left
        ensureSelectionVisible(
            node: sourceActiveWindow,
            in: workspaceId,
            state: &state,
            edge: edge,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return true
    }

    private func moveWindowToColumn(
        _ node: NiriWindow,
        from sourceColumn: NiriContainer,
        to targetColumn: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        direction _: Direction = .right,
        state: inout ViewportState
    ) {
        let sourceWasTabbed = sourceColumn.displayMode == .tabbed
        if sourceWasTabbed {
            let nodeIdx = sourceColumn.children.firstIndex { $0.id == node.id }
            if let idx = nodeIdx {
                if idx == sourceColumn.activeTileIdx {
                    if sourceColumn.children.count > 1 {
                        if idx < sourceColumn.children.count - 1 {
                        } else {
                            sourceColumn.activeTileIdx = max(0, idx - 1)
                        }
                    }
                } else if idx < sourceColumn.activeTileIdx {
                    sourceColumn.activeTileIdx = max(0, sourceColumn.activeTileIdx - 1)
                }
            }
        }

        node.detach()
        targetColumn.appendChild(node)

        if sourceWasTabbed, !sourceColumn.children.isEmpty {
            sourceColumn.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: sourceColumn)
        }

        if targetColumn.displayMode == .tabbed {
            node.isHiddenInTabbedMode = true
            updateTabbedColumnVisibility(column: targetColumn)
        } else {
            node.isHiddenInTabbedMode = false
        }

        cleanupEmptyColumn(sourceColumn, in: workspaceId, state: &state)
    }

    private func createColumnAndMove(
        _ node: NiriWindow,
        from sourceColumn: NiriContainer,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        gaps: CGFloat,
        workingAreaWidth: CGFloat
    ) {
        guard let root = roots[workspaceId] else { return }

        let sourceWasTabbed = sourceColumn.displayMode == .tabbed
        if sourceWasTabbed {
            let nodeIdx = sourceColumn.children.firstIndex { $0.id == node.id }
            if let idx = nodeIdx {
                if idx == sourceColumn.activeTileIdx {
                    if sourceColumn.children.count > 1 {
                        if idx < sourceColumn.children.count - 1 {
                        } else {
                            sourceColumn.activeTileIdx = max(0, idx - 1)
                        }
                    }
                } else if idx < sourceColumn.activeTileIdx {
                    sourceColumn.activeTileIdx = max(0, sourceColumn.activeTileIdx - 1)
                }
            }
        }

        let newColumn = NiriContainer()
        newColumn.width = .proportion(1.0 / CGFloat(maxVisibleColumns))

        if direction == .right {
            root.insertAfter(newColumn, reference: sourceColumn)
        } else {
            root.insertBefore(newColumn, reference: sourceColumn)
        }

        if let newColIdx = columnIndex(of: newColumn, in: workspaceId) {
            if newColIdx == state.activeColumnIndex + 1 {
                state.activatePrevColumnOnRemoval = state.stationary()
            }
            animateColumnsForAddition(
                columnIndex: newColIdx,
                in: workspaceId,
                state: state,
                gaps: gaps,
                workingAreaWidth: workingAreaWidth
            )
        }

        node.detach()
        newColumn.appendChild(node)

        node.isHiddenInTabbedMode = false

        if sourceWasTabbed, !sourceColumn.children.isEmpty {
            sourceColumn.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: sourceColumn)
        }

        cleanupEmptyColumn(sourceColumn, in: workspaceId, state: &state)
    }

    private func cleanupEmptyColumn(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) {
        guard column.children.isEmpty else { return }

        column.remove()

        if let root = roots[workspaceId], root.columns.isEmpty {
            let emptyColumn = NiriContainer()
            root.appendChild(emptyColumn)
        }
    }

    func normalizeColumnSizes(in workspaceId: WorkspaceDescriptor.ID) {
        let cols = columns(in: workspaceId)
        guard cols.count > 1 else { return }

        let totalSize = cols.reduce(CGFloat(0)) { $0 + $1.size }
        let avgSize = totalSize / CGFloat(cols.count)

        for col in cols {
            let normalized = col.size / avgSize
            col.size = max(0.5, min(2.0, normalized))
        }
    }

    func normalizeWindowSizes(in column: NiriContainer) {
        let windows = column.children.compactMap { $0 as? NiriWindow }
        guard !windows.isEmpty else { return }

        let totalSize = windows.reduce(CGFloat(0)) { $0 + $1.size }
        let avgSize = totalSize / CGFloat(windows.count)

        for window in windows {
            let normalized = window.size / avgSize
            window.size = max(0.5, min(2.0, normalized))
        }
    }

    func balanceSizes(
        in workspaceId: WorkspaceDescriptor.ID,
        workingAreaWidth: CGFloat,
        gaps: CGFloat
    ) {
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return }

        let balancedWidth = 1.0 / CGFloat(maxVisibleColumns)
        let targetPixels = (workingAreaWidth - gaps) * balancedWidth

        for column in cols {
            column.width = .proportion(balancedWidth)
            column.isFullWidth = false
            column.presetWidthIdx = nil

            column.animateWidthTo(
                newWidth: targetPixels,
                clock: animationClock,
                config: windowMovementAnimationConfig,
                displayRefreshRate: displayRefreshRate
            )

            for window in column.windowNodes {
                window.size = 1.0
            }
        }
    }

    func moveColumn(
        _ column: NiriContainer,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard direction == .left || direction == .right else { return false }

        let cols = columns(in: workspaceId)
        guard let currentIdx = columnIndex(of: column, in: workspaceId) else { return false }

        let currentColX = state.columnX(at: currentIdx, columns: cols, gap: gaps)
        let nextColX = currentIdx + 1 < cols.count
            ? state.columnX(at: currentIdx + 1, columns: cols, gap: gaps)
            : currentColX + (column.cachedWidth > 0 ? column.cachedWidth : workingFrame.width / CGFloat(maxVisibleColumns)) + gaps

        let step = (direction == .right) ? 1 : -1
        let targetIdx: Int

        if infiniteLoop {
            targetIdx = ((currentIdx + step) % cols.count + cols.count) % cols.count
        } else {
            let raw = currentIdx + step
            guard raw >= 0, raw < cols.count else { return false }
            targetIdx = raw
        }

        if targetIdx == currentIdx { return false }

        let targetColumn = cols[targetIdx]

        guard let root = roots[workspaceId] else { return false }
        root.swapChildren(column, targetColumn)

        let newCols = columns(in: workspaceId)
        let viewOffsetDelta = -state.columnX(at: currentIdx, columns: newCols, gap: gaps) + currentColX
        state.offsetViewport(by: viewOffsetDelta)

        let newColX = state.columnX(at: targetIdx, columns: newCols, gap: gaps)
        column.animateMoveFrom(
            displacement: CGPoint(x: currentColX - newColX, y: 0),
            clock: animationClock,
            config: windowMovementAnimationConfig,
            displayRefreshRate: displayRefreshRate
        )

        let othersXOffset = nextColX - currentColX
        if currentIdx < targetIdx {
            for i in currentIdx ..< targetIdx {
                let col = newCols[i]
                if col.id != column.id {
                    col.animateMoveFrom(
                        displacement: CGPoint(x: othersXOffset, y: 0),
                        clock: animationClock,
                        config: windowMovementAnimationConfig,
                        displayRefreshRate: displayRefreshRate
                    )
                }
            }
        } else {
            for i in (targetIdx + 1) ... currentIdx {
                let col = newCols[i]
                if col.id != column.id {
                    col.animateMoveFrom(
                        displacement: CGPoint(x: -othersXOffset, y: 0),
                        clock: animationClock,
                        config: windowMovementAnimationConfig,
                        displayRefreshRate: displayRefreshRate
                    )
                }
            }
        }

        let edge: NiriRevealEdge = direction == .right ? .right : .left
        ensureColumnVisible(
            column,
            in: workspaceId,
            state: &state,
            edge: edge,
            workingFrame: workingFrame,
            gaps: gaps,
            animationConfig: windowMovementAnimationConfig,
            fromColumnIndex: currentIdx
        )

        return true
    }

    func consumeWindow(
        into window: NiriWindow,
        from direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard direction == .left || direction == .right else { return false }

        guard let currentColumn = findColumn(containing: window, in: workspaceId),
              let currentIdx = columnIndex(of: currentColumn, in: workspaceId)
        else {
            return false
        }

        guard currentColumn.children.count < maxWindowsPerColumn else { return false }

        let cols = columns(in: workspaceId)
        let step = (direction == .right) ? 1 : -1
        let neighborIdx: Int

        if infiniteLoop {
            neighborIdx = ((currentIdx + step) % cols.count + cols.count) % cols.count
        } else {
            let raw = currentIdx + step
            guard raw >= 0, raw < cols.count else { return false }
            neighborIdx = raw
        }

        if neighborIdx == currentIdx { return false }

        let neighborColumn = cols[neighborIdx]

        let consumedWindow: NiriWindow? = if direction == .right {
            neighborColumn.children.first as? NiriWindow
        } else {
            neighborColumn.children.last as? NiriWindow
        }

        guard let windowToConsume = consumedWindow else { return false }

        let now = animationClock?.now() ?? CACurrentMediaTime()

        let sourceTileIdx = neighborColumn.windowNodes.firstIndex(where: { $0.id == windowToConsume.id }) ?? 0
        let sourceColX = state.columnX(at: neighborIdx, columns: cols, gap: gaps)
        let sourceColRenderOffset = neighborColumn.renderOffset(at: now)
        let sourceTileOffset = computeTileOffset(column: neighborColumn, tileIdx: sourceTileIdx, gaps: gaps)

        windowToConsume.detach()

        let newTileIdx: Int
        if direction == .right {
            currentColumn.appendChild(windowToConsume)
            newTileIdx = currentColumn.windowNodes.count - 1
        } else {
            currentColumn.insertChild(windowToConsume, at: 0)
            newTileIdx = 0

            if currentColumn.displayMode == .tabbed {
                currentColumn.activeTileIdx += 1
            }
        }

        let newCols = columns(in: workspaceId)
        let targetColIdx = columnIndex(of: currentColumn, in: workspaceId) ?? currentIdx
        let targetColX = state.columnX(at: targetColIdx, columns: newCols, gap: gaps)
        let targetColRenderOffset = currentColumn.renderOffset(at: now)
        let targetTileOffset = computeTileOffset(column: currentColumn, tileIdx: newTileIdx, gaps: gaps)

        let displacement = CGPoint(
            x: sourceColX + sourceColRenderOffset.x - (targetColX + targetColRenderOffset.x),
            y: sourceTileOffset - targetTileOffset
        )

        if displacement.x != 0 || displacement.y != 0 {
            windowToConsume.animateMoveFrom(
                displacement: displacement,
                clock: animationClock,
                config: windowMovementAnimationConfig,
                displayRefreshRate: displayRefreshRate
            )
        }

        if currentColumn.displayMode == .tabbed {
            updateTabbedColumnVisibility(column: currentColumn)
        }

        cleanupEmptyColumn(neighborColumn, in: workspaceId, state: &state)

        ensureSelectionVisible(
            node: window,
            in: workspaceId,
            state: &state,
            edge: direction == .right ? .right : .left,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return true
    }

    func expelWindow(
        _ window: NiriWindow,
        to direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard direction == .left || direction == .right else { return false }

        guard let currentColumn = findColumn(containing: window, in: workspaceId),
              let root = roots[workspaceId],
              let currentColIdx = columnIndex(of: currentColumn, in: workspaceId)
        else {
            return false
        }

        let now = animationClock?.now() ?? CACurrentMediaTime()
        let cols = columns(in: workspaceId)

        let sourceTileIdx = currentColumn.windowNodes.firstIndex(where: { $0.id == window.id }) ?? 0
        let sourceColX = state.columnX(at: currentColIdx, columns: cols, gap: gaps)
        let sourceColRenderOffset = currentColumn.renderOffset(at: now)
        let sourceTileOffset = computeTileOffset(column: currentColumn, tileIdx: sourceTileIdx, gaps: gaps)

        let wasTabbed = currentColumn.displayMode == .tabbed
        if wasTabbed {
            let windowIdx = currentColumn.children.firstIndex { $0.id == window.id }
            if let idx = windowIdx {
                if idx == currentColumn.activeTileIdx {
                    if currentColumn.children.count > 1 {
                        if idx < currentColumn.children.count - 1 {
                        } else {
                            currentColumn.activeTileIdx = max(0, idx - 1)
                        }
                    }
                } else if idx < currentColumn.activeTileIdx {
                    currentColumn.activeTileIdx = max(0, currentColumn.activeTileIdx - 1)
                }
            }
        }

        let newColumn = NiriContainer()
        newColumn.width = .proportion(1.0 / CGFloat(maxVisibleColumns))

        if direction == .right {
            root.insertAfter(newColumn, reference: currentColumn)
        } else {
            root.insertBefore(newColumn, reference: currentColumn)
        }

        if let newColIdx = columnIndex(of: newColumn, in: workspaceId) {
            animateColumnsForAddition(
                columnIndex: newColIdx,
                in: workspaceId,
                state: state,
                gaps: gaps,
                workingAreaWidth: workingFrame.width
            )
        }

        window.detach()
        newColumn.appendChild(window)

        window.isHiddenInTabbedMode = false

        let newCols = columns(in: workspaceId)
        if let newColIdx = columnIndex(of: newColumn, in: workspaceId) {
            let targetColX = state.columnX(at: newColIdx, columns: newCols, gap: gaps)
            let targetColRenderOffset = newColumn.renderOffset(at: now)

            let displacement = CGPoint(
                x: sourceColX + sourceColRenderOffset.x - (targetColX + targetColRenderOffset.x),
                y: sourceTileOffset
            )

            if displacement.x != 0 || displacement.y != 0 {
                window.animateMoveFrom(
                    displacement: displacement,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate
                )
            }
        }

        if wasTabbed, !currentColumn.children.isEmpty {
            currentColumn.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: currentColumn)
        }

        cleanupEmptyColumn(currentColumn, in: workspaceId, state: &state)

        ensureSelectionVisible(
            node: window,
            in: workspaceId,
            state: &state,
            edge: direction == .right ? .right : .left,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return true
    }

    private func ensureColumnVisible(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        edge: NiriRevealEdge,
        workingFrame: CGRect,
        gaps: CGFloat,
        animationConfig: SpringConfig? = nil,
        fromColumnIndex: Int? = nil
    ) {
        if let firstWindow = column.windowNodes.first {
            ensureSelectionVisible(
                node: firstWindow,
                in: workspaceId,
                state: &state,
                edge: edge,
                workingFrame: workingFrame,
                gaps: gaps,
                alwaysCenterSingleColumn: alwaysCenterSingleColumn,
                animationConfig: animationConfig,
                fromColumnIndex: fromColumnIndex
            )
        }
    }

    struct WorkspaceMoveResult {
        let newFocusNodeId: NodeId?

        let movedHandle: WindowHandle?

        let targetWorkspaceId: WorkspaceDescriptor.ID
    }

    func moveWindowToWorkspace(
        _ window: NiriWindow,
        from sourceWorkspaceId: WorkspaceDescriptor.ID,
        to targetWorkspaceId: WorkspaceDescriptor.ID,
        sourceState: inout ViewportState,
        targetState: inout ViewportState
    ) -> WorkspaceMoveResult? {
        guard sourceWorkspaceId != targetWorkspaceId else { return nil }

        guard roots[sourceWorkspaceId] != nil,
              let sourceColumn = findColumn(containing: window, in: sourceWorkspaceId)
        else {
            return nil
        }

        let targetRoot = ensureRoot(for: targetWorkspaceId)

        let fallbackSelection = fallbackSelectionOnRemoval(removing: window.id, in: sourceWorkspaceId)

        window.detach()

        let targetColumn: NiriContainer
        if let existingColumn = claimEmptyColumnIfWorkspaceEmpty(in: targetRoot) {
            existingColumn.width = .proportion(1.0 / CGFloat(maxVisibleColumns))
            targetColumn = existingColumn
        } else {
            let newColumn = NiriContainer()
            newColumn.width = .proportion(1.0 / CGFloat(maxVisibleColumns))
            targetRoot.appendChild(newColumn)
            targetColumn = newColumn
        }
        targetColumn.appendChild(window)

        cleanupEmptyColumn(sourceColumn, in: sourceWorkspaceId, state: &sourceState)

        sourceState.selectedNodeId = fallbackSelection

        targetState.selectedNodeId = window.id

        return WorkspaceMoveResult(
            newFocusNodeId: fallbackSelection,
            movedHandle: window.handle,
            targetWorkspaceId: targetWorkspaceId
        )
    }

    func moveColumnToWorkspace(
        _ column: NiriContainer,
        from sourceWorkspaceId: WorkspaceDescriptor.ID,
        to targetWorkspaceId: WorkspaceDescriptor.ID,
        sourceState: inout ViewportState,
        targetState: inout ViewportState
    ) -> WorkspaceMoveResult? {
        guard sourceWorkspaceId != targetWorkspaceId else { return nil }

        guard let sourceRoot = roots[sourceWorkspaceId],
              columnIndex(of: column, in: sourceWorkspaceId) != nil
        else {
            return nil
        }

        let targetRoot = ensureRoot(for: targetWorkspaceId)

        removeEmptyColumnsIfWorkspaceEmpty(in: targetRoot)

        let allCols = columns(in: sourceWorkspaceId)
        var fallbackSelection: NodeId?
        if let colIdx = columnIndex(of: column, in: sourceWorkspaceId) {
            if colIdx > 0 {
                fallbackSelection = allCols[colIdx - 1].firstChild()?.id
            } else if allCols.count > 1 {
                fallbackSelection = allCols[1].firstChild()?.id
            }
        }

        column.detach()

        targetRoot.appendChild(column)

        if sourceRoot.columns.isEmpty {
            let emptyColumn = NiriContainer()
            sourceRoot.appendChild(emptyColumn)
        }

        sourceState.selectedNodeId = fallbackSelection

        targetState.selectedNodeId = column.firstChild()?.id

        let firstWindowHandle = column.windowNodes.first?.handle

        return WorkspaceMoveResult(
            newFocusNodeId: fallbackSelection,
            movedHandle: firstWindowHandle,
            targetWorkspaceId: targetWorkspaceId
        )
    }

    func adjacentWorkspace(
        from workspaceId: WorkspaceDescriptor.ID,
        direction: Direction,
        workspaceIds: [WorkspaceDescriptor.ID]
    ) -> WorkspaceDescriptor.ID? {
        guard direction == .up || direction == .down else { return nil }

        guard let currentIdx = workspaceIds.firstIndex(of: workspaceId) else { return nil }

        let targetIdx: Int = if direction == .up {
            currentIdx - 1
        } else {
            currentIdx + 1
        }

        guard workspaceIds.indices.contains(targetIdx) else { return nil }
        return workspaceIds[targetIdx]
    }

    func hitTestResize(
        point: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        threshold: CGFloat? = nil
    ) -> ResizeHitTestResult? {
        guard let root = roots[workspaceId] else { return nil }

        let threshold = threshold ?? resizeConfiguration.edgeThreshold

        for (colIdx, column) in root.columns.enumerated() {
            for (winIdx, child) in column.children.enumerated() {
                guard let window = child as? NiriWindow,
                      let frame = window.frame else { continue }

                if window.isFullscreen {
                    continue
                }

                let edges = detectEdges(point: point, frame: frame, threshold: threshold)
                if !edges.isEmpty {
                    return ResizeHitTestResult(
                        windowHandle: window.handle,
                        nodeId: window.id,
                        edges: edges,
                        columnIndex: colIdx,
                        windowIndexInColumn: winIdx,
                        windowFrame: frame
                    )
                }
            }
        }

        return nil
    }

    func hitTestTiled(
        point: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NiriWindow? {
        guard let root = roots[workspaceId] else { return nil }

        for column in root.columns {
            for child in column.children {
                guard let window = child as? NiriWindow,
                      let frame = window.frame else { continue }

                if frame.contains(point) {
                    return window
                }
            }
        }

        return nil
    }

    private func detectEdges(point: CGPoint, frame: CGRect, threshold: CGFloat) -> ResizeEdge {
        var edges: ResizeEdge = []

        let expandedFrame = frame.insetBy(dx: -threshold, dy: -threshold)
        guard expandedFrame.contains(point) else {
            return []
        }

        let innerFrame = frame.insetBy(dx: threshold, dy: threshold)
        if innerFrame.contains(point) {
            return []
        }

        if point.x <= frame.minX + threshold, point.x >= frame.minX - threshold {
            edges.insert(.left)
        }
        if point.x >= frame.maxX - threshold, point.x <= frame.maxX + threshold {
            edges.insert(.right)
        }
        if point.y <= frame.minY + threshold, point.y >= frame.minY - threshold {
            edges.insert(.bottom)
        }
        if point.y >= frame.maxY - threshold, point.y <= frame.maxY + threshold {
            edges.insert(.top)
        }

        return edges
    }

    func interactiveResizeBegin(
        windowId: NodeId,
        edges: ResizeEdge,
        startLocation: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard interactiveResize == nil else { return false }

        guard let windowNode = findNode(by: windowId) as? NiriWindow else { return false }
        guard let column = findColumn(containing: windowNode, in: workspaceId) else { return false }
        guard let colIdx = columnIndex(of: column, in: workspaceId) else { return false }

        if windowNode.isFullscreen {
            return false
        }

        if windowNode.constraints.isFixed {
            return false
        }

        let winIdx = column.children.firstIndex { $0.id == windowId } ?? 0
        let isTopmost = winIdx == 0

        let originalColumnWidth = edges.hasHorizontal ? column.cachedWidth : nil
        let originalWindowHeight = edges.hasVertical ? windowNode.size : nil

        interactiveResize = InteractiveResize(
            windowId: windowId,
            workspaceId: workspaceId,
            originalColumnWidth: originalColumnWidth,
            originalWindowHeight: originalWindowHeight,
            edges: edges,
            startMouseLocation: startLocation,
            columnIndex: colIdx,
            windowIndexInColumn: winIdx,
            isTopmostWindow: isTopmost
        )

        return true
    }

    func interactiveResizeUpdate(
        currentLocation: CGPoint,
        monitorFrame: CGRect,
        gaps: LayoutGaps
    ) -> Bool {
        guard let resize = interactiveResize else { return false }

        guard let windowNode = findNode(by: resize.windowId) as? NiriWindow else {
            clearInteractiveResize()
            return false
        }

        guard let column = findColumn(containing: windowNode, in: resize.workspaceId) else {
            clearInteractiveResize()
            return false
        }

        let delta = CGPoint(
            x: currentLocation.x - resize.startMouseLocation.x,
            y: currentLocation.y - resize.startMouseLocation.y
        )

        var changed = false

        if resize.edges.hasHorizontal, let originalWidth = resize.originalColumnWidth {
            var dx = delta.x

            if resize.edges.contains(.left) {
                dx = -dx
            }

            let minWidth = column.windowNodes.map(\.constraints.minSize.width).max() ?? 50
            let maxWidth = monitorFrame.width - gaps.horizontal

            let newWidth = originalWidth + dx
            column.cachedWidth = newWidth.clamped(to: minWidth ... maxWidth)
            column.width = .fixed(column.cachedWidth)
            changed = true
        }

        if resize.edges.hasVertical, let originalHeight = resize.originalWindowHeight {
            var dy = delta.y

            if resize.edges.contains(.bottom) {
                dy = -dy
            }

            let pixelsPerWeight = calculateVerticalPixelsPerWeightUnit(
                column: column,
                monitorFrame: monitorFrame,
                gaps: gaps
            )

            if pixelsPerWeight > 0 {
                let weightDelta = dy / pixelsPerWeight
                let newWeight = originalHeight + weightDelta
                windowNode.size = newWeight.clamped(
                    to: resizeConfiguration.minWindowWeight ... resizeConfiguration.maxWindowWeight
                )
                changed = true
            }
        }

        return changed
    }

    private func clearInteractiveResize() {
        interactiveResize = nil
    }

    func interactiveResizeEnd(
        windowId: NodeId? = nil,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        guard let resize = interactiveResize else { return }

        if let windowId, windowId != resize.windowId {
            return
        }

        if let windowNode = findNode(by: resize.windowId) as? NiriWindow {
            ensureSelectionVisible(
                node: windowNode,
                in: resize.workspaceId,
                state: &state,
                edge: .left,
                workingFrame: workingFrame,
                gaps: gaps,
                alwaysCenterSingleColumn: alwaysCenterSingleColumn
            )
        }

        interactiveResize = nil
    }

    func interactiveMoveBegin(
        windowId: NodeId,
        windowHandle: WindowHandle,
        startLocation: CGPoint,
        isInsertMode: Bool = false,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard interactiveMove == nil else { return false }
        guard interactiveResize == nil else { return false }

        guard let windowNode = findNode(by: windowId) as? NiriWindow else { return false }
        guard let column = findColumn(containing: windowNode, in: workspaceId) else { return false }
        guard let colIdx = columnIndex(of: column, in: workspaceId) else { return false }

        if windowNode.isFullscreen {
            return false
        }

        let winIdx = column.children.firstIndex { $0.id == windowId } ?? 0

        interactiveMove = InteractiveMove(
            windowId: windowId,
            windowHandle: windowHandle,
            workspaceId: workspaceId,
            startMouseLocation: startLocation,
            originalColumnIndex: colIdx,
            originalWindowIndexInColumn: winIdx,
            originalFrame: windowNode.frame ?? .zero,
            isInsertMode: isInsertMode,
            currentHoverTarget: nil
        )

        let cols = columns(in: workspaceId)
        state.transitionToColumn(
            colIdx,
            columns: cols,
            gap: gaps,
            viewportWidth: workingFrame.width,
            animate: false,
            centerMode: centerFocusedColumn,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return true
    }

    func interactiveMoveUpdate(
        currentLocation: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> MoveHoverTarget? {
        guard var move = interactiveMove else { return nil }

        let dragDistance = hypot(
            currentLocation.x - move.startMouseLocation.x,
            currentLocation.y - move.startMouseLocation.y
        )
        guard dragDistance >= moveConfiguration.dragThreshold else {
            return nil
        }

        let hoverTarget = hitTestMoveTarget(
            point: currentLocation,
            excludingWindowId: move.windowId,
            isInsertMode: move.isInsertMode,
            in: workspaceId
        )

        move.currentHoverTarget = hoverTarget
        interactiveMove = move

        return hoverTarget
    }

    func interactiveMoveEnd(
        at _: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard let move = interactiveMove else { return false }
        defer { interactiveMove = nil }

        guard let target = move.currentHoverTarget else {
            return false
        }

        switch target {
        case let .window(targetNodeId, _, position):
            switch position {
            case .swap:
                return swapWindowsByMove(
                    sourceWindowId: move.windowId,
                    targetWindowId: targetNodeId,
                    in: workspaceId,
                    state: &state,
                    workingFrame: workingFrame,
                    gaps: gaps
                )
            case .before, .after:
                return insertWindowByMove(
                    sourceWindowId: move.windowId,
                    targetWindowId: targetNodeId,
                    position: position,
                    in: workspaceId,
                    state: &state,
                    workingFrame: workingFrame,
                    gaps: gaps
                )
            }

        case .columnGap, .workspaceEdge:
            return false
        }
    }

    func interactiveMoveCancel() {
        interactiveMove = nil
    }

    func hitTestMoveTarget(
        point: CGPoint,
        excludingWindowId: NodeId,
        isInsertMode: Bool = false,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> MoveHoverTarget? {
        guard let root = roots[workspaceId] else { return nil }

        for column in root.columns {
            for child in column.children {
                guard let window = child as? NiriWindow,
                      window.id != excludingWindowId,
                      let frame = window.frame else { continue }

                if frame.contains(point) {
                    let position: InsertPosition = if isInsertMode {
                        point.y < frame.midY ? .before : .after
                    } else {
                        .swap
                    }
                    return .window(
                        nodeId: window.id,
                        handle: window.handle,
                        insertPosition: position
                    )
                }
            }
        }

        return nil
    }

    func swapWindowsByMove(
        sourceWindowId: NodeId,
        targetWindowId: NodeId,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        fromColumnIndex: Int? = nil
    ) -> Bool {
        guard let sourceWindow = findNode(by: sourceWindowId) as? NiriWindow,
              let targetWindow = findNode(by: targetWindowId) as? NiriWindow
        else {
            return false
        }

        guard let sourceColumn = findColumn(containing: sourceWindow, in: workspaceId),
              let targetColumn = findColumn(containing: targetWindow, in: workspaceId)
        else {
            return false
        }

        if sourceColumn.id == targetColumn.id {
            sourceWindow.swapWith(targetWindow)

            if sourceColumn.isTabbed {
                sourceColumn.clampActiveTileIdx()
            }
        } else {
            guard let sourceIdx = sourceColumn.children.firstIndex(where: { $0.id == sourceWindowId }),
                  let targetIdx = targetColumn.children.firstIndex(where: { $0.id == targetWindowId })
            else {
                return false
            }

            let sourceSize = sourceWindow.size
            let sourceHeight = sourceWindow.height
            let targetSize = targetWindow.size
            let targetHeight = targetWindow.height

            sourceWindow.detach()
            targetWindow.detach()

            sourceColumn.insertChild(targetWindow, at: sourceIdx)
            targetColumn.insertChild(sourceWindow, at: targetIdx)

            sourceWindow.size = targetSize
            sourceWindow.height = targetHeight
            targetWindow.size = sourceSize
            targetWindow.height = sourceHeight

            if sourceColumn.isTabbed {
                sourceColumn.clampActiveTileIdx()
            }
            if targetColumn.isTabbed {
                targetColumn.clampActiveTileIdx()
            }
        }

        ensureSelectionVisible(
            node: sourceWindow,
            in: workspaceId,
            state: &state,
            edge: .left,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return true
    }

    func insertWindowByMove(
        sourceWindowId: NodeId,
        targetWindowId: NodeId,
        position: InsertPosition,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard let sourceWindow = findNode(by: sourceWindowId) as? NiriWindow,
              let targetWindow = findNode(by: targetWindowId) as? NiriWindow
        else {
            return false
        }

        guard let sourceColumn = findColumn(containing: sourceWindow, in: workspaceId),
              let targetColumn = findColumn(containing: targetWindow, in: workspaceId)
        else {
            return false
        }

        guard let targetIdx = targetColumn.children.firstIndex(where: { $0.id == targetWindowId }) else {
            return false
        }

        let sameColumn = sourceColumn.id == targetColumn.id
        let sourceColumnWillBeEmpty = sourceColumn.children.count == 1 && !sameColumn

        sourceWindow.detach()

        let insertIdx: Int
        if sameColumn {
            let currentTargetIdx = targetColumn.children.firstIndex(where: { $0.id == targetWindowId }) ?? targetIdx
            insertIdx = position == .before ? currentTargetIdx : currentTargetIdx + 1
        } else {
            insertIdx = position == .before ? targetIdx : targetIdx + 1
        }

        targetColumn.insertChild(sourceWindow, at: insertIdx)

        sourceWindow.size = 1.0
        sourceWindow.height = .default

        if sourceColumnWillBeEmpty {
            sourceColumn.remove()
        }

        if sourceColumn.isTabbed {
            sourceColumn.clampActiveTileIdx()
        }
        if targetColumn.isTabbed {
            targetColumn.clampActiveTileIdx()
        }

        ensureSelectionVisible(
            node: sourceWindow,
            in: workspaceId,
            state: &state,
            edge: .left,
            workingFrame: workingFrame,
            gaps: gaps,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        return true
    }

    func insertionDropzoneFrame(
        targetWindowId: NodeId,
        position: InsertPosition,
        in workspaceId: WorkspaceDescriptor.ID,
        gaps: CGFloat
    ) -> CGRect? {
        guard let targetWindow = findNode(by: targetWindowId) as? NiriWindow,
              let targetFrame = targetWindow.frame,
              let column = findColumn(containing: targetWindow, in: workspaceId)
        else {
            return nil
        }

        let windows = column.windowNodes
        let n = windows.count
        let postInsertionCount = n + 1
        let firstFrame = windows.first?.frame
        let lastFrame = windows.last?.frame
        guard let top = firstFrame?.minY, let bottom = lastFrame?.maxY else { return nil }

        let columnHeight = bottom - top
        let totalGaps = CGFloat(postInsertionCount - 1) * gaps
        let newHeight = max(0, (columnHeight - totalGaps) / CGFloat(postInsertionCount))
        let x = targetFrame.minX
        let width = targetFrame.width

        let y: CGFloat = switch position {
        case .before:
            max(top, targetFrame.minY - gaps - newHeight)
        case .after:
            targetFrame.maxY + gaps
        case .swap:
            targetFrame.minY
        }

        return CGRect(x: x, y: y, width: width, height: newHeight)
    }

    private func calculateHorizontalPixelsPerWeightUnit(
        in workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        gaps: LayoutGaps
    ) -> CGFloat {
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return 0 }

        let totalWeight = cols.reduce(CGFloat(0)) { $0 + $1.size }
        guard totalWeight > 0 else { return 0 }

        let totalGaps = CGFloat(max(0, cols.count - 1)) * gaps.horizontal
        let usableWidth = monitorFrame.width - totalGaps

        return usableWidth / totalWeight
    }

    private func calculateVerticalPixelsPerWeightUnit(
        column: NiriContainer,
        monitorFrame: CGRect,
        gaps: LayoutGaps
    ) -> CGFloat {
        let windows = column.children
        guard !windows.isEmpty else { return 0 }

        let totalWeight = windows.reduce(CGFloat(0)) { $0 + $1.size }
        guard totalWeight > 0 else { return 0 }

        let totalGaps = CGFloat(max(0, windows.count - 1)) * gaps.vertical
        let usableHeight = monitorFrame.height - totalGaps

        return usableHeight / totalWeight
    }

    func setWindowSizingMode(
        _ window: NiriWindow,
        mode: SizingMode,
        in _: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) {
        let previousMode = window.sizingMode

        if previousMode == mode {
            return
        }

        if previousMode == .fullscreen, mode == .normal {
            if let savedHeight = window.savedHeight {
                window.height = savedHeight
                window.savedHeight = nil
            }

            if let savedOffset = state.viewOffsetToRestore {
                state.animateViewOffsetRestore(savedOffset)
            }
        }

        if previousMode == .normal, mode == .fullscreen {
            window.savedHeight = window.height
            state.saveViewOffsetForFullscreen()
        }

        window.sizingMode = mode
    }

    func toggleFullscreen(
        _ window: NiriWindow,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) {
        let newMode: SizingMode = window.sizingMode == .fullscreen ? .normal : .fullscreen
        setWindowSizingMode(window, mode: newMode, in: workspaceId, state: &state)
    }

    func toggleColumnWidth(
        _ column: NiriContainer,
        forwards: Bool,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        guard !presetColumnWidths.isEmpty else { return }

        if column.isFullWidth {
            column.isFullWidth = false
            if let saved = column.savedWidth {
                column.width = saved
                column.savedWidth = nil
            }
        }

        let presetCount = presetColumnWidths.count

        let nextIdx: Int
        if let currentIdx = column.presetWidthIdx {
            if forwards {
                nextIdx = (currentIdx + 1) % presetCount
            } else {
                nextIdx = (currentIdx - 1 + presetCount) % presetCount
            }
        } else {
            let currentValue = column.width.value
            var nearestIdx = 0
            var nearestDist = CGFloat.infinity
            for (i, preset) in presetColumnWidths.enumerated() {
                let dist = abs(preset.kind.value - currentValue)
                if dist < nearestDist {
                    nearestDist = dist
                    nearestIdx = i
                }
            }

            if forwards {
                nextIdx = (nearestIdx + 1) % presetCount
            } else {
                nextIdx = nearestIdx
            }
        }

        let newWidth = presetColumnWidths[nextIdx].asColumnWidth
        column.width = newWidth
        column.presetWidthIdx = nextIdx

        let workingAreaWidth = workingFrame.width
        let targetPixels: CGFloat
        switch newWidth {
        case .proportion(let p):
            targetPixels = (workingAreaWidth - gaps) * p
        case .fixed(let f):
            targetPixels = f
        }

        column.animateWidthTo(
            newWidth: targetPixels,
            clock: animationClock,
            config: windowMovementAnimationConfig,
            displayRefreshRate: displayRefreshRate
        )

        if let window = column.windowNodes.first {
            ensureSelectionVisible(
                node: window,
                in: workspaceId,
                state: &state,
                edge: .left,
                workingFrame: workingFrame,
                gaps: gaps,
                alwaysCenterSingleColumn: alwaysCenterSingleColumn
            )
        }
    }

    func toggleFullWidth(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        let workingAreaWidth = workingFrame.width
        let targetPixels: CGFloat
        if column.isFullWidth {
            column.isFullWidth = false
            if let saved = column.savedWidth {
                column.width = saved
                column.savedWidth = nil
            }
            switch column.width {
            case .proportion(let p):
                targetPixels = (workingAreaWidth - gaps) * p
            case .fixed(let f):
                targetPixels = f
            }
        } else {
            column.savedWidth = column.width
            column.isFullWidth = true
            column.presetWidthIdx = nil
            targetPixels = workingAreaWidth
        }

        column.animateWidthTo(
            newWidth: targetPixels,
            clock: animationClock,
            config: windowMovementAnimationConfig,
            displayRefreshRate: displayRefreshRate
        )

        if let window = column.windowNodes.first {
            ensureSelectionVisible(
                node: window,
                in: workspaceId,
                state: &state,
                edge: .left,
                workingFrame: workingFrame,
                gaps: gaps,
                alwaysCenterSingleColumn: alwaysCenterSingleColumn
            )
        }
    }

    func setWindowHeight(_ window: NiriWindow, height: WindowHeight) {
        window.height = height
    }

    @discardableResult
    func toggleColumnTabbed(in workspaceId: WorkspaceDescriptor.ID, state: ViewportState) -> Bool {
        guard let selectedId = state.selectedNodeId,
              let selectedNode = findNode(by: selectedId),
              let column = column(of: selectedNode)
        else {
            return false
        }

        let newMode: ColumnDisplay = column.displayMode == .normal ? .tabbed : .normal
        return setColumnDisplay(newMode, for: column, in: workspaceId)
    }

    @discardableResult
    func setColumnDisplay(_ mode: ColumnDisplay, for column: NiriContainer, in _: WorkspaceDescriptor.ID, gaps: CGFloat = 0) -> Bool {
        guard column.displayMode != mode else { return false }

        if let resize = interactiveResize,
           let resizeWindow = findNode(by: resize.windowId) as? NiriWindow,
           let resizeColumn = findColumn(containing: resizeWindow, in: resize.workspaceId),
           resizeColumn.id == column.id
        {
            clearInteractiveResize()
        }

        let windows = column.windowNodes
        guard !windows.isEmpty else {
            column.displayMode = mode
            return true
        }

        let prevOrigin = tilesOrigin(column: column)

        column.displayMode = mode
        let newOrigin = tilesOrigin(column: column)
        let originDelta = CGPoint(x: prevOrigin.x - newOrigin.x, y: prevOrigin.y - newOrigin.y)

        column.displayMode = .normal
        let tileOffsets = computeTileOffsets(column: column, gaps: gaps)

        for (idx, window) in windows.enumerated() {
            var yDelta = idx < tileOffsets.count ? tileOffsets[idx] : 0
            yDelta -= prevOrigin.y

            if mode == .normal {
                yDelta *= -1
            }

            let delta = CGPoint(x: originDelta.x, y: originDelta.y + yDelta)
            if delta.x != 0 || delta.y != 0 {
                window.animateMoveFrom(
                    displacement: delta,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate
                )
            }
        }

        for (idx, window) in windows.enumerated() {
            if idx != column.activeTileIdx {
                let (fromAlpha, toAlpha): (CGFloat, CGFloat) = mode == .tabbed ? (1, 0) : (0, 1)
                window.animateAlpha(
                    from: fromAlpha,
                    to: toAlpha,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate
                )
            } else {
                window.baseAlpha = 1.0
                window.alphaAnimation = nil
            }
        }

        column.displayMode = mode
        updateTabbedColumnVisibility(column: column)

        return true
    }

    func updateTabbedColumnVisibility(column: NiriContainer) {
        let windows = column.windowNodes
        guard !windows.isEmpty else { return }

        column.clampActiveTileIdx()

        if column.displayMode == .tabbed {
            for (idx, window) in windows.enumerated() {
                let isActive = idx == column.activeTileIdx
                window.isHiddenInTabbedMode = !isActive
            }
        } else {
            for window in windows {
                window.isHiddenInTabbedMode = false
            }
        }
    }

    @discardableResult
    func activateTab(at index: Int, in column: NiriContainer) -> Bool {
        guard column.displayMode == .tabbed else { return false }

        let prevIdx = column.activeTileIdx
        column.setActiveTileIdx(index)

        if prevIdx != column.activeTileIdx {
            updateTabbedColumnVisibility(column: column)
            return true
        }
        return false
    }

    func activeColumn(in _: WorkspaceDescriptor.ID, state: ViewportState) -> NiriContainer? {
        guard let selectedId = state.selectedNodeId,
              let selectedNode = findNode(by: selectedId)
        else {
            return nil
        }
        return column(of: selectedNode)
    }

    func updateFocusTimestamp(for nodeId: NodeId) {
        guard let node = findNode(by: nodeId) as? NiriWindow else { return }
        node.lastFocusedTime = Date()
    }

    func updateFocusTimestamp(for handle: WindowHandle) {
        guard let node = findNode(for: handle) else { return }
        node.lastFocusedTime = Date()
    }

    func findMostRecentlyFocusedWindow(
        excluding excludingNodeId: NodeId?,
        in workspaceId: WorkspaceDescriptor.ID? = nil
    ) -> NiriWindow? {
        let allWindows: [NiriWindow] = if let wsId = workspaceId, let root = root(for: wsId) {
            root.allWindows
        } else {
            Array(roots.values.flatMap(\.allWindows))
        }

        let candidates = allWindows.filter { window in
            window.id != excludingNodeId && window.lastFocusedTime != nil
        }

        return candidates.max { ($0.lastFocusedTime ?? .distantPast) < ($1.lastFocusedTime ?? .distantPast) }
    }

    func workspaceContaining(handle: WindowHandle) -> WorkspaceDescriptor.ID? {
        for (wsId, root) in roots {
            if root.allWindows.contains(where: { $0.handle.id == handle.id }) {
                return wsId
            }
        }
        return nil
    }
}

extension NiriLayoutEngine {
    func calculateCombinedLayout(
        in workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        gaps: LayoutGaps,
        state: ViewportState,
        workingArea: WorkingAreaContext? = nil,
        animationTime: TimeInterval? = nil
    ) -> [WindowHandle: CGRect] {
        calculateCombinedLayoutWithVisibility(
            in: workspaceId,
            monitor: monitor,
            gaps: gaps,
            state: state,
            workingArea: workingArea,
            animationTime: animationTime
        ).frames
    }

    func calculateCombinedLayoutWithVisibility(
        in workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        gaps: LayoutGaps,
        state: ViewportState,
        workingArea: WorkingAreaContext? = nil,
        animationTime: TimeInterval? = nil
    ) -> LayoutResult {
        let area = workingArea ?? WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: 2.0
        )

        let orientation = self.monitor(for: monitor.id)?.orientation ?? monitor.autoOrientation

        return calculateLayoutWithVisibility(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: monitor.visibleFrame,
            screenFrame: monitor.frame,
            gaps: gaps.asTuple,
            scale: area.scale,
            workingArea: area,
            orientation: orientation,
            animationTime: animationTime
        )
    }

    func calculateCombinedLayoutUsingPools(
        in workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        gaps: LayoutGaps,
        state: ViewportState,
        workingArea: WorkingAreaContext? = nil,
        animationTime: TimeInterval? = nil
    ) -> (frames: [WindowHandle: CGRect], hiddenHandles: [WindowHandle: HideSide]) {
        framePool.removeAll(keepingCapacity: true)
        hiddenPool.removeAll(keepingCapacity: true)

        let area = workingArea ?? WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: 2.0
        )

        let orientation = self.monitor(for: monitor.id)?.orientation ?? monitor.autoOrientation

        calculateLayoutInto(
            frames: &framePool,
            hiddenHandles: &hiddenPool,
            state: state,
            workspaceId: workspaceId,
            monitorFrame: monitor.visibleFrame,
            screenFrame: monitor.frame,
            gaps: gaps.asTuple,
            scale: area.scale,
            workingArea: area,
            orientation: orientation,
            animationTime: animationTime
        )

        return (framePool, hiddenPool)
    }

    func captureWindowFrames(in workspaceId: WorkspaceDescriptor.ID) -> [WindowHandle: CGRect] {
        guard let root = root(for: workspaceId) else { return [:] }
        var frames: [WindowHandle: CGRect] = [:]
        for window in root.allWindows {
            if let frame = window.frame {
                frames[window.handle] = frame
            }
        }
        return frames
    }

    func targetFrameForWindow(
        _ handle: WindowHandle,
        in workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> CGRect? {
        guard let windowNode = findNode(for: handle),
              let column = windowNode.parent as? NiriContainer,
              let colIdx = columnIndex(of: column, in: workspaceId)
        else { return nil }

        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return nil }

        for col in cols {
            if col.cachedWidth <= 0 {
                col.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gaps)
            }
        }

        func columnX(at index: Int) -> CGFloat {
            var x: CGFloat = 0
            for i in 0 ..< index {
                x += cols[i].cachedWidth + gaps
            }
            return x
        }

        let totalColumnsWidth = cols.reduce(0) { $0 + $1.cachedWidth } + CGFloat(max(0, cols.count - 1)) * gaps

        let targetViewOffset = state.viewOffsetPixels.target()

        let centeringOffset: CGFloat = if totalColumnsWidth < workingFrame.width {
            if alwaysCenterSingleColumn || cols.count == 1 {
                (workingFrame.width - totalColumnsWidth) / 2
            } else {
                0
            }
        } else {
            0
        }

        let colX = columnX(at: colIdx)
        let screenX = workingFrame.origin.x + colX + targetViewOffset + centeringOffset

        let tabOffset = column.isTabbed ? renderStyle.tabIndicatorWidth : 0
        let contentY = workingFrame.origin.y
        let availableHeight = workingFrame.height

        let windowNodes = column.windowNodes
        guard let windowIndex = windowNodes.firstIndex(where: { $0.handle == handle }) else { return nil }

        let targetY: CGFloat
        let targetHeight: CGFloat

        if windowNodes.count == 1 || column.isTabbed {
            targetY = contentY
            targetHeight = availableHeight
        } else {
            var y = contentY
            for i in 0 ..< windowIndex {
                let h = windowNodes[i].resolvedHeight ?? (availableHeight / CGFloat(windowNodes.count))
                y += h + gaps
            }
            targetY = y
            targetHeight = windowNodes[windowIndex].resolvedHeight ?? (availableHeight / CGFloat(windowNodes.count))
        }

        return CGRect(
            x: screenX + tabOffset,
            y: targetY,
            width: column.cachedWidth - tabOffset,
            height: targetHeight
        )
    }

    func triggerMoveAnimations(
        in workspaceId: WorkspaceDescriptor.ID,
        oldFrames: [WindowHandle: CGRect],
        newFrames: [WindowHandle: CGRect],
        threshold: CGFloat = 1.0
    ) -> Bool {
        guard animationsEnabled else { return false }
        guard let root = root(for: workspaceId) else { return false }
        var anyAnimationStarted = false

        for window in root.allWindows {
            guard let oldFrame = oldFrames[window.handle],
                  let newFrame = newFrames[window.handle]
            else {
                continue
            }

            let dx = oldFrame.origin.x - newFrame.origin.x
            let dy = oldFrame.origin.y - newFrame.origin.y

            if abs(dx) > threshold || abs(dy) > threshold {
                window.animateMoveFrom(
                    displacement: CGPoint(x: dx, y: dy),
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate
                )
                anyAnimationStarted = true
            }
        }

        return anyAnimationStarted
    }

    func hasAnyWindowAnimationsRunning(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let root = root(for: workspaceId) else { return false }
        return root.allWindows.contains { $0.hasMoveAnimationsRunning }
    }

    func tickAllWindowAnimations(in workspaceId: WorkspaceDescriptor.ID, at time: TimeInterval) -> Bool {
        guard let root = root(for: workspaceId) else { return false }
        var anyRunning = false
        for window in root.allWindows {
            if window.tickMoveAnimations(at: time) {
                anyRunning = true
            }
            if window.tickAlphaAnimation(at: time) {
                anyRunning = true
            }
        }
        return anyRunning
    }

    func computeTileOffset(column: NiriContainer, tileIdx: Int, gaps: CGFloat) -> CGFloat {
        let windows = column.windowNodes
        guard tileIdx > 0, tileIdx < windows.count else { return 0 }

        var offset: CGFloat = 0
        for i in 0 ..< tileIdx {
            let height = windows[i].resolvedHeight ?? windows[i].frame?.height ?? 0
            offset += height
            offset += gaps
        }
        return offset
    }

    func computeTileOffsets(column: NiriContainer, gaps: CGFloat) -> [CGFloat] {
        let windows = column.windowNodes
        guard !windows.isEmpty else { return [] }

        var offsets: [CGFloat] = [0]
        var y: CGFloat = 0
        for i in 0 ..< windows.count - 1 {
            let height = windows[i].resolvedHeight ?? windows[i].frame?.height ?? 0
            y += height + gaps
            offsets.append(y)
        }
        return offsets
    }

    func tilesOrigin(column: NiriContainer) -> CGPoint {
        let xOffset = column.isTabbed ? renderStyle.tabIndicatorWidth : 0
        return CGPoint(x: xOffset, y: 0)
    }
}

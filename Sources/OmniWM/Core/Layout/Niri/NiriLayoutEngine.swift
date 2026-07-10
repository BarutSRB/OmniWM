// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

enum CenterFocusedColumn: String, CaseIterable, Codable, Identifiable {
    case never
    case always
    case onOverflow

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .never: "Never"
        case .always: "Always"
        case .onOverflow: "On Overflow"
        }
    }
}

struct WorkingAreaContext {
    var workingFrame: CGRect
    var fullscreenLayoutFrame: CGRect
    var viewFrame: CGRect
    var scale: CGFloat

    init(
        workingFrame: CGRect,
        fullscreenLayoutFrame: CGRect? = nil,
        viewFrame: CGRect,
        scale: CGFloat
    ) {
        self.workingFrame = workingFrame
        self.fullscreenLayoutFrame = fullscreenLayoutFrame ?? workingFrame
        self.viewFrame = viewFrame
        self.scale = scale
    }
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
    workingArea.origin.y += struts.bottom

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

func normalizedTopStrut(top: CGFloat, menuBarInset: CGFloat, reservedTopInset: CGFloat) -> CGFloat {
    max(0, top - menuBarInset) + reservedTopInset
}

struct NiriRenderStyle {
    var tabIndicatorWidth: CGFloat

    static let `default` = NiriRenderStyle(
        tabIndicatorWidth: 0
    )
}

final class NiriWorkspaceState {
    let root: NiriRoot
    var nodesByToken: [WindowToken: NiriWindow] = [:]

    init(workspaceId: WorkspaceDescriptor.ID) {
        root = NiriRoot(workspaceId: workspaceId)
    }

    func index(_ window: NiriWindow) {
        if let existing = nodesByToken[window.token] {
            precondition(existing === window)
            return
        }
        nodesByToken[window.token] = window
    }

    func unindex(_ window: NiriWindow) {
        if nodesByToken[window.token] === window {
            nodesByToken.removeValue(forKey: window.token)
        }
    }
}

final class NiriLayoutEngine {
    static let defaultPresetColumnWidthValues: [CGFloat] = [1.0 / 3.0, 0.5, 2.0 / 3.0]
    static let defaultPresetColumnWidths: [PresetSize] = defaultPresetColumnWidthValues.map { .proportion($0) }
    static let defaultPresetWindowHeightValues: [CGFloat] = [1.0 / 3.0, 0.5, 2.0 / 3.0]
    static let defaultPresetWindowHeights: [PresetSize] = defaultPresetWindowHeightValues.map { .proportion($0) }
    private static let presetMatchTolerance: CGFloat = 0.001

    var monitors: [Monitor.ID: NiriMonitor] = [:]

    var states: [WorkspaceDescriptor.ID: NiriWorkspaceState] = [:]

    var framePool: [WindowToken: CGRect] = [:]
    var hiddenPool: [WindowToken: HideSide] = [:]

    var axisSolveCache: [NiriAxisSolveKey: [NiriAxisSolver.Output]] = [:]

    var maxVisibleColumns: Int
    var infiniteLoop: Bool

    var centerFocusedColumn: CenterFocusedColumn = .never

    var alwaysCenterSingleColumn: Bool = false

    var singleWindowFit: SingleWindowFit = .fullScreen

    var renderStyle: NiriRenderStyle = .default

    var interactiveResize: InteractiveResize?
    var interactiveMove: InteractiveMove?

    var resizeConfiguration = ResizeConfiguration.default
    var moveConfiguration = MoveConfiguration.default

    var windowMovementAnimationConfig: SpringConfig = .niriWindowMovement
    var animationClock: AnimationClock?
    var isMutationSanctioned = true

    func assertSanctionedMutation(_ operation: StaticString = #function) {
        assert(
            isMutationSanctioned,
            "\(operation) mutated the Niri layout tree outside a sanctioned WorldStore scope"
        )
    }

    func cancelInteractions(in workspaceId: WorkspaceDescriptor.ID) {
        if interactiveMove?.workspaceId == workspaceId {
            interactiveMoveCancel()
        }
        if interactiveResize?.workspaceId == workspaceId {
            clearInteractiveResize()
        }
    }

    func cancelInteractions(for windowIds: Set<NodeId>, in workspaceId: WorkspaceDescriptor.ID) {
        if let move = interactiveMove,
           move.workspaceId == workspaceId,
           windowIds.contains(move.windowId)
        {
            interactiveMoveCancel()
        }
        if let resize = interactiveResize,
           resize.workspaceId == workspaceId,
           windowIds.contains(resize.windowId)
        {
            clearInteractiveResize()
        }
    }

    var presetColumnWidths: [PresetSize] = NiriLayoutEngine.defaultPresetColumnWidths
    var presetWindowHeights: [PresetSize] = NiriLayoutEngine.defaultPresetWindowHeights
    var defaultColumnWidth: CGFloat? = 0.5

    init(maxVisibleColumns: Int = 2, infiniteLoop: Bool = false) {
        self.maxVisibleColumns = max(1, min(5, maxVisibleColumns))
        self.infiniteLoop = infiniteLoop
    }

    func ensureState(for workspaceId: WorkspaceDescriptor.ID) -> NiriWorkspaceState {
        if let existing = states[workspaceId] {
            return existing
        }
        let state = NiriWorkspaceState(workspaceId: workspaceId)
        states[workspaceId] = state
        return state
    }

    func ensureRoot(for workspaceId: WorkspaceDescriptor.ID) -> NiriRoot {
        ensureState(for: workspaceId).root
    }

    func claimEmptyColumnIfWorkspaceEmpty(in root: NiriRoot) -> NiriContainer? {
        guard root.allWindows.isEmpty else { return nil }

        let emptyColumns = root.columns.filter(\.children.isEmpty)
        guard let target = emptyColumns.first else { return nil }

        for column in emptyColumns.dropFirst() {
            column.remove()
        }

        return target
    }

    func removeEmptyColumnsIfWorkspaceEmpty(in root: NiriRoot) {
        guard root.allWindows.isEmpty else { return }

        let emptyColumns = root.columns.filter(\.children.isEmpty)
        for column in emptyColumns {
            column.remove()
        }
    }

    func resolvedColumnResetWidth(in workspaceId: WorkspaceDescriptor
        .ID) -> (proportion: CGFloat, presetWidthIdx: Int?)
    {
        if let defaultColumnWidth {
            return (defaultColumnWidth, matchingPresetIndex(for: defaultColumnWidth))
        }

        return (1.0 / CGFloat(effectiveMaxVisibleColumns(in: workspaceId)), nil)
    }

    func initializeNewColumnWidth(_ column: NiriContainer, in workspaceId: WorkspaceDescriptor.ID) {
        let resolvedWidth = resolvedColumnResetWidth(in: workspaceId)
        column.width = .proportion(resolvedWidth.proportion)
        column.presetWidthIdx = resolvedWidth.presetWidthIdx

        column.cachedWidth = 0
        column.isFullWidth = false
        column.savedWidth = nil
        column.hasManualSingleWindowWidthOverride = false
        column.widthAnimation = nil
        column.targetWidth = nil
    }

    private func matchingPresetIndex(for width: CGFloat) -> Int? {
        presetColumnWidths.firstIndex { preset in
            guard case let .proportion(presetWidth) = preset.kind else { return false }
            return abs(presetWidth - width) <= Self.presetMatchTolerance
        }
    }

    func root(for workspaceId: WorkspaceDescriptor.ID) -> NiriRoot? {
        states[workspaceId]?.root
    }

    func columns(in workspaceId: WorkspaceDescriptor.ID) -> [NiriContainer] {
        root(for: workspaceId)?.columns ?? []
    }

    struct SingleWindowLayoutContext {
        let container: NiriContainer
        let window: NiriWindow
        let fit: SingleWindowFit
    }

    func singleWindowLayoutContext(in workspaceId: WorkspaceDescriptor.ID) -> SingleWindowLayoutContext? {
        let fit = effectiveSingleWindowFit(in: workspaceId)
        guard fit.mode != .columnWidth else {
            return nil
        }

        let workspaceColumns = columns(in: workspaceId)
        guard workspaceColumns.count == 1,
              let column = workspaceColumns.first,
              !column.isTabbed
        else {
            return nil
        }

        let windows = column.windowNodes
        guard windows.count == 1,
              let window = windows.first,
              window.sizingMode == .normal
        else {
            return nil
        }

        return SingleWindowLayoutContext(
            container: column,
            window: window,
            fit: fit
        )
    }

    func wrapIndex(_ idx: Int, total: Int, in workspaceId: WorkspaceDescriptor.ID) -> Int? {
        guard total > 0 else { return nil }
        if effectiveInfiniteLoop(in: workspaceId) {
            let modulo = total
            return ((idx % modulo) + modulo) % modulo
        } else {
            return (idx >= 0 && idx < total) ? idx : nil
        }
    }

    func findNode(by id: NodeId, in workspaceId: WorkspaceDescriptor.ID) -> NiriNode? {
        root(for: workspaceId)?.findNode(by: id)
    }

    func findNode(for handle: WindowHandle, in workspaceId: WorkspaceDescriptor.ID) -> NiriWindow? {
        findNode(for: handle.id, in: workspaceId)
    }

    func isWindowFullscreen(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        states[workspaceId]?.nodesByToken[token]?.isFullscreen ?? false
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
        columns(in: workspaceId).firstIndex { $0 === column }
    }

    func activateWindow(_ nodeId: NodeId, in workspaceId: WorkspaceDescriptor.ID) {
        assertSanctionedMutation()
        guard let node = findNode(by: nodeId, in: workspaceId),
              let col = column(of: node) else { return }
        let windowNodes = col.windowNodes
        let idx = windowNodes.firstIndex(where: { $0.id == nodeId }) ?? 0
        col.setActiveTileIdx(idx)
    }

    func columnX(at index: Int, columns: [NiriContainer], gaps: CGFloat) -> CGFloat {
        var x: CGFloat = 0
        for i in 0 ..< index where i < columns.count {
            x += columns[i].cachedWidth + gaps
        }
        return x
    }

    func findColumn(containing window: NiriWindow, in workspaceId: WorkspaceDescriptor.ID) -> NiriContainer? {
        guard let col = column(of: window),
              let root = col.parent as? NiriRoot,
              self.root(for: workspaceId)?.id == root.id else { return nil }
        return col
    }

    func updateConfiguration(
        maxVisibleColumns: Int? = nil,
        infiniteLoop: Bool? = nil,
        centerFocusedColumn: CenterFocusedColumn? = nil,
        alwaysCenterSingleColumn: Bool? = nil,
        singleWindowFit: SingleWindowFit? = nil,
        presetColumnWidths: [PresetSize]? = nil,
        defaultColumnWidth: CGFloat?? = nil
    ) {
        assertSanctionedMutation()
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
        if let singleWindowFit {
            self.singleWindowFit = singleWindowFit
        }
        // Double optional distinguishes "no config change" from "set Auto/nil".
        if let defaultColumnWidth {
            self.defaultColumnWidth = defaultColumnWidth?.clamped(to: 0.05 ... 1.0)
        }

        if let presets = presetColumnWidths, !presets.isEmpty {
            self.presetColumnWidths = presets
            resetAllPresetWidthIndices()
        }
    }

    private func resetAllPresetWidthIndices() {
        for state in states.values {
            for child in state.root.children {
                if let column = child as? NiriContainer {
                    column.presetWidthIdx = nil
                }
            }
        }
    }
}

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

struct NiriRenderStyle {
    var tabIndicatorWidth: CGFloat

    static let `default` = NiriRenderStyle(
        tabIndicatorWidth: 0
    )
}

final class NiriLayoutEngine {
    var monitors: [Monitor.ID: NiriMonitor] = [:]

    var roots: [WorkspaceDescriptor.ID: NiriRoot] = [:]

    /// Viewport states rescued from monitors removed during display ID changes (e.g. KVM switch).
    /// Consumed by moveWorkspace when re-associating workspaces to new monitors.
    var orphanedViewportStates: [WorkspaceDescriptor.ID: ViewportState] = [:]

    var handleToNode: [WindowHandle: NiriWindow] = [:]

    var closingHandles: Set<WindowHandle> = []

    var framePool: [WindowHandle: CGRect] = [:]
    var hiddenPool: [WindowHandle: HideSide] = [:]

    var maxWindowsPerColumn: Int
    var maxVisibleColumns: Int
    var infiniteLoop: Bool

    var centerFocusedColumn: CenterFocusedColumn = .never

    var alwaysCenterSingleColumn: Bool = true

    var singleWindowAspectRatio: SingleWindowAspectRatio = .none

    var renderStyle: NiriRenderStyle = .default

    var interactiveResize: InteractiveResize?
    var interactiveMove: InteractiveMove?

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

    func ensureRoot(for workspaceId: WorkspaceDescriptor.ID) -> NiriRoot {
        if let existing = roots[workspaceId] {
            return existing
        }
        let root = NiriRoot(workspaceId: workspaceId)
        roots[workspaceId] = root

        let initialColumn = NiriContainer()
        root.appendChild(initialColumn)
        return root
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

    func root(for workspaceId: WorkspaceDescriptor.ID) -> NiriRoot? {
        roots[workspaceId]
    }

    func columns(in workspaceId: WorkspaceDescriptor.ID) -> [NiriContainer] {
        guard let root = roots[workspaceId] else { return [] }
        return root.columns
    }

    func wrapIndex(_ idx: Int, total: Int) -> Int? {
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

    func activateWindow(_ nodeId: NodeId) {
        guard let node = findNode(by: nodeId),
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
              roots[workspaceId]?.id == root.id else { return nil }
        return col
    }

    func updateConfiguration(
        maxWindowsPerColumn: Int? = nil,
        maxVisibleColumns: Int? = nil,
        infiniteLoop: Bool? = nil,
        centerFocusedColumn: CenterFocusedColumn? = nil,
        alwaysCenterSingleColumn: Bool? = nil,
        singleWindowAspectRatio: SingleWindowAspectRatio? = nil,
        animationsEnabled: Bool? = nil,
        presetColumnWidths: [PresetSize]? = nil
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

        if let presets = presetColumnWidths, !presets.isEmpty {
            self.presetColumnWidths = presets
            resetAllPresetWidthIndices()
        }
    }

    private func resetAllPresetWidthIndices() {
        for monitor in monitors.values {
            for root in monitor.workspaceRoots.values {
                for child in root.children {
                    if let column = child as? NiriContainer {
                        column.presetWidthIdx = nil
                    }
                }
            }
        }
    }
}

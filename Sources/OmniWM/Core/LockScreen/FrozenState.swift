import CoreGraphics
import Foundation

struct FrozenWindow: Sendable {
    let windowId: Int
    let pid: pid_t
    let workspaceId: WorkspaceDescriptor.ID
    let parentKind: ParentKind

    let columnIndex: Int
    let windowIndexInColumn: Int

    let size: CGFloat
    let height: FrozenWindowHeight
    let width: FrozenColumnWidth?
    let sizingMode: FrozenSizingMode
}

enum FrozenColumnWidth: Sendable {
    case proportion(CGFloat)
    case fixed(CGFloat)

    init(from columnWidth: ColumnWidth) {
        switch columnWidth {
        case let .proportion(p): self = .proportion(p)
        case let .fixed(f): self = .fixed(f)
        }
    }

    var toColumnWidth: ColumnWidth {
        switch self {
        case let .proportion(p): .proportion(p)
        case let .fixed(f): .fixed(f)
        }
    }
}

enum FrozenWindowHeight: Sendable {
    case auto(weight: CGFloat)
    case fixed(CGFloat)

    init(from height: WindowHeight) {
        switch height {
        case let .auto(weight): self = .auto(weight: weight)
        case let .fixed(f): self = .fixed(f)
        }
    }

    var toWindowHeight: WindowHeight {
        switch self {
        case let .auto(weight): .auto(weight: weight)
        case let .fixed(f): .fixed(f)
        }
    }
}

enum FrozenSizingMode: Sendable {
    case normal
    case fullscreen

    init(from sizingMode: SizingMode) {
        switch sizingMode {
        case .normal: self = .normal
        case .fullscreen: self = .fullscreen
        }
    }

    var toSizingMode: SizingMode {
        switch self {
        case .normal: .normal
        case .fullscreen: .fullscreen
        }
    }
}

enum FrozenColumnDisplay: Sendable {
    case normal
    case tabbed

    init(from displayMode: ColumnDisplay) {
        switch displayMode {
        case .normal: self = .normal
        case .tabbed: self = .tabbed
        }
    }

    var toColumnDisplay: ColumnDisplay {
        switch self {
        case .normal: .normal
        case .tabbed: .tabbed
        }
    }
}

struct FrozenColumn: Sendable {
    let index: Int
    let width: FrozenColumnWidth
    let displayMode: FrozenColumnDisplay
    let activeTileIdx: Int
    let isFullWidth: Bool
    let windowIds: [Int]
}

struct FrozenWorkspace: Sendable {
    let workspaceId: WorkspaceDescriptor.ID
    let columns: [FrozenColumn]
    let viewportState: FrozenViewportState
}

struct FrozenViewportState: Sendable {
    let activeColumnIndex: Int
    let viewOffsetPixels: CGFloat
    let selectionProgress: CGFloat

    init(from state: ViewportState) {
        activeColumnIndex = state.activeColumnIndex
        viewOffsetPixels = state.viewOffsetPixels.current()
        selectionProgress = state.selectionProgress
    }

    func toViewportState() -> ViewportState {
        var state = ViewportState()
        state.activeColumnIndex = activeColumnIndex
        state.viewOffsetPixels = .static(viewOffsetPixels)
        state.selectionProgress = selectionProgress
        return state
    }
}

struct FrozenMonitor: Sendable {
    let displayId: CGDirectDisplayID
    let visibleWorkspaceId: WorkspaceDescriptor.ID
}

struct FrozenWorld: Sendable {
    let workspaces: [FrozenWorkspace]
    let monitors: [FrozenMonitor]
    let windows: [Int: FrozenWindow]
    let timestamp: Date

    static let empty = FrozenWorld(
        workspaces: [],
        monitors: [],
        windows: [:],
        timestamp: .distantPast
    )

    var isEmpty: Bool {
        windows.isEmpty
    }

    var windowIds: Set<Int> {
        Set(windows.keys)
    }
}

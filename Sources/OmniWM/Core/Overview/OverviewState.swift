import AppKit
import Foundation

enum OverviewState {
    case closed
    case opening(progress: Double)
    case open
    case closing(targetWindow: WindowHandle?, progress: Double)

    var isOpen: Bool {
        switch self {
        case .open, .opening, .closing:
            return true
        case .closed:
            return false
        }
    }

    var isAnimating: Bool {
        switch self {
        case .opening, .closing:
            return true
        case .open, .closed:
            return false
        }
    }
}

struct OverviewWorkspaceSection {
    let workspaceId: WorkspaceDescriptor.ID
    let name: String
    var windows: [OverviewWindowItem]
    var sectionFrame: CGRect
    var labelFrame: CGRect
    var gridFrame: CGRect
    var isActive: Bool
}

struct OverviewWindowItem {
    let handle: WindowHandle
    let windowId: Int
    let workspaceId: WorkspaceDescriptor.ID
    var thumbnail: CGImage?
    var title: String
    var appName: String
    var appIcon: NSImage?
    var originalFrame: CGRect
    var overviewFrame: CGRect
    var isHovered: Bool
    var isSelected: Bool
    var matchesSearch: Bool
    var closeButtonHovered: Bool

    var closeButtonFrame: CGRect {
        let size: CGFloat = 20
        let padding: CGFloat = 6
        return CGRect(
            x: overviewFrame.maxX - size - padding,
            y: overviewFrame.maxY - size - padding,
            width: size,
            height: size
        )
    }

    func interpolatedFrame(progress: Double) -> CGRect {
        let t = CGFloat(progress)
        return CGRect(
            x: originalFrame.origin.x + (overviewFrame.origin.x - originalFrame.origin.x) * t,
            y: originalFrame.origin.y + (overviewFrame.origin.y - originalFrame.origin.y) * t,
            width: originalFrame.width + (overviewFrame.width - originalFrame.width) * t,
            height: originalFrame.height + (overviewFrame.height - originalFrame.height) * t
        )
    }
}

struct OverviewLayout {
    private struct WindowPosition {
        let sectionIndex: Int
        let windowIndex: Int
    }

    var workspaceSections: [OverviewWorkspaceSection] {
        didSet { rebuildWindowIndex() }
    }
    var searchBarFrame: CGRect
    var totalContentHeight: CGFloat
    var scrollOffset: CGFloat
    var scale: CGFloat
    var niriColumnDropZonesByWorkspace: [WorkspaceDescriptor.ID: [OverviewColumnDropZone]]
    var dragTarget: OverviewDragTarget?
    var niriColumnsByWorkspace: [WorkspaceDescriptor.ID: [OverviewNiriColumn]]
    private var windowPositionByHandle: [WindowHandle: WindowPosition]
    private var lastHoveredHandle: WindowHandle?
    private var lastSelectedHandle: WindowHandle?

    init() {
        workspaceSections = []
        searchBarFrame = .zero
        totalContentHeight = 0
        scrollOffset = 0
        scale = 1.0
        niriColumnDropZonesByWorkspace = [:]
        dragTarget = nil
        niriColumnsByWorkspace = [:]
        windowPositionByHandle = [:]
        lastHoveredHandle = nil
        lastSelectedHandle = nil
        rebuildWindowIndex()
    }

    var allWindows: [OverviewWindowItem] {
        workspaceSections.flatMap(\.windows)
    }

    private mutating func rebuildWindowIndex() {
        windowPositionByHandle.removeAll(keepingCapacity: true)
        for sectionIndex in workspaceSections.indices {
            for windowIndex in workspaceSections[sectionIndex].windows.indices {
                let handle = workspaceSections[sectionIndex].windows[windowIndex].handle
                windowPositionByHandle[handle] = WindowPosition(sectionIndex: sectionIndex, windowIndex: windowIndex)
            }
        }
        if let lastHoveredHandle, windowPositionByHandle[lastHoveredHandle] == nil {
            self.lastHoveredHandle = nil
        }
        if let lastSelectedHandle, windowPositionByHandle[lastSelectedHandle] == nil {
            self.lastSelectedHandle = nil
        }
    }

    @discardableResult
    private mutating func mutateWindow(
        for handle: WindowHandle,
        _ mutate: (inout OverviewWindowItem) -> Void
    ) -> Bool {
        if let position = windowPositionByHandle[handle],
           workspaceSections.indices.contains(position.sectionIndex),
           workspaceSections[position.sectionIndex].windows.indices.contains(position.windowIndex)
        {
            mutate(&workspaceSections[position.sectionIndex].windows[position.windowIndex])
            return true
        }
        rebuildWindowIndex()
        guard let position = windowPositionByHandle[handle],
              workspaceSections.indices.contains(position.sectionIndex),
              workspaceSections[position.sectionIndex].windows.indices.contains(position.windowIndex)
        else {
            return false
        }
        mutate(&workspaceSections[position.sectionIndex].windows[position.windowIndex])
        return true
    }

    mutating func updateWindowFrame(handle: WindowHandle, frame: CGRect) {
        _ = mutateWindow(for: handle) { $0.overviewFrame = frame }
    }

    mutating func setHovered(handle: WindowHandle?, closeButtonHovered: Bool = false) {
        if let previous = lastHoveredHandle, previous != handle {
            _ = mutateWindow(for: previous) {
                $0.isHovered = false
                $0.closeButtonHovered = false
            }
        }

        guard let handle else {
            lastHoveredHandle = nil
            return
        }

        let updated = mutateWindow(for: handle) {
            $0.isHovered = true
            $0.closeButtonHovered = closeButtonHovered
        }
        lastHoveredHandle = updated ? handle : nil
    }

    mutating func setSelected(handle: WindowHandle?) {
        if let previous = lastSelectedHandle, previous != handle {
            _ = mutateWindow(for: previous) { $0.isSelected = false }
        }

        guard let handle else {
            lastSelectedHandle = nil
            return
        }

        let updated = mutateWindow(for: handle) { $0.isSelected = true }
        lastSelectedHandle = updated ? handle : nil
    }

    func windowAt(point: CGPoint) -> OverviewWindowItem? {
        let adjustedPoint = CGPoint(x: point.x, y: point.y + scrollOffset)
        for section in workspaceSections {
            for window in section.windows where window.matchesSearch {
                if window.overviewFrame.contains(adjustedPoint) {
                    return window
                }
            }
        }
        return nil
    }

    func isCloseButtonAt(point: CGPoint) -> Bool {
        let adjustedPoint = CGPoint(x: point.x, y: point.y + scrollOffset)
        for section in workspaceSections {
            for window in section.windows where window.matchesSearch {
                if window.closeButtonFrame.contains(adjustedPoint) {
                    return true
                }
            }
        }
        return false
    }

    func workspaceSection(at point: CGPoint) -> OverviewWorkspaceSection? {
        let adjustedPoint = CGPoint(x: point.x, y: point.y + scrollOffset)
        for section in workspaceSections {
            if section.sectionFrame.contains(adjustedPoint) {
                return section
            }
        }
        return nil
    }

    func columnDropZone(at point: CGPoint) -> OverviewColumnDropZone? {
        let adjustedPoint = CGPoint(x: point.x, y: point.y + scrollOffset)
        for (_, zones) in niriColumnDropZonesByWorkspace {
            for zone in zones where zone.frame.contains(adjustedPoint) {
                return zone
            }
        }
        return nil
    }

    func insertPosition(for window: OverviewWindowItem, at point: CGPoint) -> InsertPosition {
        let adjustedPoint = CGPoint(x: point.x, y: point.y + scrollOffset)
        return adjustedPoint.y > window.overviewFrame.midY ? .before : .after
    }

    func window(for handle: WindowHandle) -> OverviewWindowItem? {
        guard let position = windowPositionByHandle[handle],
              workspaceSections.indices.contains(position.sectionIndex),
              workspaceSections[position.sectionIndex].windows.indices.contains(position.windowIndex)
        else {
            return nil
        }
        return workspaceSections[position.sectionIndex].windows[position.windowIndex]
    }

    func selectedWindow() -> OverviewWindowItem? {
        guard let handle = lastSelectedHandle,
              let position = windowPositionByHandle[handle] else { return nil }
        return workspaceSections[position.sectionIndex].windows[position.windowIndex]
    }

    func hoveredWindow() -> OverviewWindowItem? {
        guard let handle = lastHoveredHandle,
              let position = windowPositionByHandle[handle] else { return nil }
        return workspaceSections[position.sectionIndex].windows[position.windowIndex]
    }
}

struct OverviewNiriColumn: Equatable {
    let workspaceId: WorkspaceDescriptor.ID
    let columnIndex: Int
    let frame: CGRect
    let windowHandles: [WindowHandle]
}

enum OverviewDragTarget: Equatable {
    case niriWindowInsert(
        workspaceId: WorkspaceDescriptor.ID,
        targetHandle: WindowHandle,
        position: InsertPosition
    )
    case niriColumnInsert(
        workspaceId: WorkspaceDescriptor.ID,
        insertIndex: Int
    )
    case workspaceMove(
        workspaceId: WorkspaceDescriptor.ID
    )
}

struct OverviewColumnDropZone: Equatable {
    let workspaceId: WorkspaceDescriptor.ID
    let insertIndex: Int
    let frame: CGRect
}

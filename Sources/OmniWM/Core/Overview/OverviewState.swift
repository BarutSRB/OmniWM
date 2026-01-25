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
    var workspaceSections: [OverviewWorkspaceSection]
    var searchBarFrame: CGRect
    var totalContentHeight: CGFloat
    var scrollOffset: CGFloat
    var scale: CGFloat

    init() {
        workspaceSections = []
        searchBarFrame = .zero
        totalContentHeight = 0
        scrollOffset = 0
        scale = 1.0
    }

    var allWindows: [OverviewWindowItem] {
        workspaceSections.flatMap(\.windows)
    }

    mutating func updateWindowFrame(handle: WindowHandle, frame: CGRect) {
        for sectionIndex in workspaceSections.indices {
            for windowIndex in workspaceSections[sectionIndex].windows.indices {
                if workspaceSections[sectionIndex].windows[windowIndex].handle == handle {
                    workspaceSections[sectionIndex].windows[windowIndex].overviewFrame = frame
                    return
                }
            }
        }
    }

    mutating func setHovered(handle: WindowHandle?, closeButtonHovered: Bool = false) {
        for sectionIndex in workspaceSections.indices {
            for windowIndex in workspaceSections[sectionIndex].windows.indices {
                let windowHandle = workspaceSections[sectionIndex].windows[windowIndex].handle
                let isMatch = windowHandle == handle
                workspaceSections[sectionIndex].windows[windowIndex].isHovered = isMatch
                workspaceSections[sectionIndex].windows[windowIndex].closeButtonHovered = isMatch && closeButtonHovered
            }
        }
    }

    mutating func setSelected(handle: WindowHandle?) {
        for sectionIndex in workspaceSections.indices {
            for windowIndex in workspaceSections[sectionIndex].windows.indices {
                let windowHandle = workspaceSections[sectionIndex].windows[windowIndex].handle
                workspaceSections[sectionIndex].windows[windowIndex].isSelected = windowHandle == handle
            }
        }
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

    func selectedWindow() -> OverviewWindowItem? {
        allWindows.first { $0.isSelected }
    }

    func hoveredWindow() -> OverviewWindowItem? {
        allWindows.first { $0.isHovered }
    }
}

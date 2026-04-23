// SPDX-License-Identifier: GPL-2.0-only
import CoreGraphics

enum MouseWarpAxis: String, Codable, CaseIterable {
    case horizontal
    case vertical

    var displayName: String {
        switch self {
        case .horizontal: "Horizontal"
        case .vertical: "Vertical"
        }
    }

    var orderDescription: String {
        switch self {
        case .horizontal: "left-to-right"
        case .vertical: "top-to-bottom"
        }
    }

    var leadingSymbolName: String {
        switch self {
        case .horizontal: "chevron.left"
        case .vertical: "chevron.up"
        }
    }

    var trailingSymbolName: String {
        switch self {
        case .horizontal: "chevron.right"
        case .vertical: "chevron.down"
        }
    }

    func sortedMonitors(_ monitors: [Monitor]) -> [Monitor] {
        monitors.sorted { lhs, rhs in
            if primaryCoordinate(for: lhs.frame) != primaryCoordinate(for: rhs.frame) {
                return primaryCoordinate(for: lhs.frame) < primaryCoordinate(for: rhs.frame)
            }
            if secondaryCoordinate(for: lhs.frame) != secondaryCoordinate(for: rhs.frame) {
                return secondaryCoordinate(for: lhs.frame) < secondaryCoordinate(for: rhs.frame)
            }
            return lhs.displayId < rhs.displayId
        }
    }

    private func primaryCoordinate(for frame: CGRect) -> CGFloat {
        switch self {
        case .horizontal:
            frame.minX
        case .vertical:
            -frame.maxY
        }
    }

    private func secondaryCoordinate(for frame: CGRect) -> CGFloat {
        switch self {
        case .horizontal:
            -frame.maxY
        case .vertical:
            frame.minX
        }
    }
}

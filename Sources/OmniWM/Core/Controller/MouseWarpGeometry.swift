// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics

enum MouseWarpGeometry {
    enum Edge: Equatable {
        case left
        case right
        case top
        case bottom
    }

    struct Crossing: Equatable {
        let direction: Direction
        let entryEdge: Edge
        let ratio: CGFloat
    }

    static func crossing(location: CGPoint, frame: CGRect, margin: CGFloat) -> Crossing? {
        if location.x <= frame.minX + margin {
            return Crossing(direction: .left, entryEdge: .right, ratio: yRatio(location, frame))
        }
        if location.x >= frame.maxX - margin {
            return Crossing(direction: .right, entryEdge: .left, ratio: yRatio(location, frame))
        }
        if location.y >= frame.maxY - margin {
            return Crossing(direction: .up, entryEdge: .bottom, ratio: xRatio(location, frame))
        }
        if location.y <= frame.minY + margin {
            return Crossing(direction: .down, entryEdge: .top, ratio: xRatio(location, frame))
        }
        return nil
    }

    static func destinationPoint(on frame: CGRect, entryEdge: Edge, ratio: CGFloat, margin: CGFloat) -> CGPoint {
        let clampedRatio = min(max(ratio, 0), 1)

        switch entryEdge {
        case .left,
             .right:
            let x = entryEdge == .left ? frame.minX + margin + 1 : frame.maxX - margin - 1
            let y = clampMapped(frame.maxY - (clampedRatio * frame.height), frame.minY, frame.maxY)
            return CGPoint(x: x, y: y)
        case .top,
             .bottom:
            let y = entryEdge == .top ? frame.maxY - margin - 1 : frame.minY + margin + 1
            let x = clampMapped(frame.minX + (clampedRatio * frame.width), frame.minX, frame.maxX)
            return CGPoint(x: x, y: y)
        }
    }

    private static func yRatio(_ point: CGPoint, _ frame: CGRect) -> CGFloat {
        guard frame.height > 0 else { return 0.5 }
        return (frame.maxY - point.y) / frame.height
    }

    private static func xRatio(_ point: CGPoint, _ frame: CGRect) -> CGFloat {
        guard frame.width > 0 else { return 0.5 }
        return (point.x - frame.minX) / frame.width
    }

    private static func clampMapped(_ value: CGFloat, _ minCoordinate: CGFloat, _ maxCoordinate: CGFloat) -> CGFloat {
        guard minCoordinate < maxCoordinate else { return minCoordinate }
        return min(max(value, minCoordinate), maxCoordinate.nextDown)
    }
}

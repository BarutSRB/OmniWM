// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

@MainActor
enum OverviewNavigation {
    private static let navigationGeometryEpsilon: CGFloat = 0.5

    private struct HorizontalCandidate {
        let handle: WindowHandle
        let midX: CGFloat
        let midY: CGFloat
        let horizontalDistance: CGFloat
        let verticalDistance: CGFloat
        let verticalOverlap: CGFloat
    }

    private struct VerticalCandidate {
        let handle: WindowHandle
        let verticalDistance: CGFloat
        let horizontalDistance: CGFloat
        let midY: CGFloat
    }

    static func findNextWindow(
        in layout: OverviewLayout,
        from currentHandle: WindowHandle?,
        direction: Direction
    ) -> WindowHandle? {
        guard let firstMatchingHandle = OverviewSearchFilter.firstMatchingWindow(in: layout)?.handle else {
            return nil
        }
        guard let currentHandle,
              let currentWindow = layout.window(for: currentHandle),
              currentWindow.matchesSearch
        else {
            return firstMatchingHandle
        }

        switch direction {
        case .left:
            return findHorizontalWindow(
                in: layout,
                from: currentWindow,
                movingLeft: true
            )

        case .right:
            return findHorizontalWindow(
                in: layout,
                from: currentWindow,
                movingLeft: false
            )

        case .up:
            return findVerticalWindow(in: layout, from: currentWindow, movingUp: true)

        case .down:
            return findVerticalWindow(in: layout, from: currentWindow, movingUp: false)
        }
    }

    static func findCycledWindow(
        in layout: OverviewLayout,
        from currentHandle: WindowHandle?,
        forward: Bool
    ) -> WindowHandle? {
        var firstHandle: WindowHandle?
        var lastHandle: WindowHandle?
        var previousHandle: WindowHandle?
        var previousBeforeCurrent: WindowHandle?
        var foundCurrent = false

        for section in layout.workspaceSections {
            for window in section.windows where window.matchesSearch {
                firstHandle = firstHandle ?? window.handle
                lastHandle = window.handle
                if foundCurrent, forward {
                    return window.handle
                }
                if window.handle == currentHandle {
                    foundCurrent = true
                    previousBeforeCurrent = previousHandle
                }
                previousHandle = window.handle
            }
        }

        guard foundCurrent else { return firstHandle }
        return forward
            ? firstHandle
            : previousBeforeCurrent ?? lastHandle
    }

    private static func findHorizontalWindow(
        in layout: OverviewLayout,
        from currentWindow: OverviewWindowItem,
        movingLeft: Bool
    ) -> WindowHandle {
        let currentFrame = currentWindow.overviewFrame
        var directCandidate: HorizontalCandidate?
        var wrappedCandidate: HorizontalCandidate?

        for section in layout.workspaceSections where section.workspaceId == currentWindow.workspaceId {
            for window in section.windows where window.matchesSearch && window.handle != currentWindow.handle {
                let frame = window.overviewFrame
                let horizontalDelta = frame.midX - currentFrame.midX
                let verticalOverlap = min(frame.maxY, currentFrame.maxY) - max(frame.minY, currentFrame.minY)
                guard abs(horizontalDelta) > navigationGeometryEpsilon,
                      verticalOverlap > navigationGeometryEpsilon
                else {
                    continue
                }

                let candidate = HorizontalCandidate(
                    handle: window.handle,
                    midX: frame.midX,
                    midY: frame.midY,
                    horizontalDistance: abs(horizontalDelta),
                    verticalDistance: abs(frame.midY - currentFrame.midY),
                    verticalOverlap: verticalOverlap
                )
                let isDirect = movingLeft ? horizontalDelta < 0 : horizontalDelta > 0
                if isDirect,
                   directCandidate.map({ isBetterAligned(candidate, than: $0) }) ?? true
                {
                    directCandidate = candidate
                }
                if wrappedCandidate.map({
                    isBetterWrapped(candidate, than: $0, movingLeft: movingLeft)
                }) ?? true {
                    wrappedCandidate = candidate
                }
            }
        }

        return directCandidate?.handle ?? wrappedCandidate?.handle ?? currentWindow.handle
    }

    private static func findVerticalWindow(
        in layout: OverviewLayout,
        from currentWindow: OverviewWindowItem,
        movingUp: Bool
    ) -> WindowHandle? {
        let currentFrame = currentWindow.overviewFrame
        var bestCandidate: VerticalCandidate?
        var bestAlignedCandidate: VerticalCandidate?

        for section in layout.workspaceSections {
            for window in section.windows where window.matchesSearch && window.handle != currentWindow.handle {
                let frame = window.overviewFrame
                let signedDistance = frame.midY - currentFrame.midY
                guard movingUp ? signedDistance > 0 : signedDistance < 0 else { continue }

                let candidate = VerticalCandidate(
                    handle: window.handle,
                    verticalDistance: abs(signedDistance),
                    horizontalDistance: abs(frame.midX - currentFrame.midX),
                    midY: frame.midY
                )
                if bestCandidate.map({ isBetterVerticalDirection(candidate, than: $0, movingUp: movingUp) }) ?? true {
                    bestCandidate = candidate
                }
                if candidate.horizontalDistance < currentFrame.width,
                   bestAlignedCandidate.map({
                       isBetterVerticalDirection(candidate, than: $0, movingUp: movingUp)
                   }) ?? true
                {
                    bestAlignedCandidate = candidate
                }
            }
        }

        return bestAlignedCandidate?.handle ?? bestCandidate?.handle
    }

    private static func isBetterVerticalDirection(
        _ candidate: VerticalCandidate,
        than current: VerticalCandidate,
        movingUp: Bool
    ) -> Bool {
        if candidate.verticalDistance < 100,
           current.verticalDistance < 100,
           candidate.horizontalDistance != current.horizontalDistance
        {
            return candidate.horizontalDistance < current.horizontalDistance
        }
        if candidate.verticalDistance != current.verticalDistance {
            return candidate.verticalDistance < current.verticalDistance
        }
        if candidate.horizontalDistance != current.horizontalDistance {
            return candidate.horizontalDistance < current.horizontalDistance
        }
        if candidate.midY != current.midY {
            return movingUp ? candidate.midY < current.midY : candidate.midY > current.midY
        }
        if candidate.handle.pid != current.handle.pid {
            return candidate.handle.pid < current.handle.pid
        }
        return candidate.handle.windowId < current.handle.windowId
    }

    private static func isBetterAligned(
        _ candidate: HorizontalCandidate,
        than current: HorizontalCandidate
    ) -> Bool {
        if candidate.horizontalDistance != current.horizontalDistance {
            return candidate.horizontalDistance < current.horizontalDistance
        }
        return isBetterVerticalMatch(candidate, than: current)
    }

    private static func isBetterWrapped(
        _ candidate: HorizontalCandidate,
        than current: HorizontalCandidate,
        movingLeft: Bool
    ) -> Bool {
        if candidate.midX != current.midX {
            return movingLeft ? candidate.midX > current.midX : candidate.midX < current.midX
        }
        return isBetterVerticalMatch(candidate, than: current)
    }

    private static func isBetterVerticalMatch(
        _ candidate: HorizontalCandidate,
        than current: HorizontalCandidate
    ) -> Bool {
        if candidate.verticalOverlap != current.verticalOverlap {
            return candidate.verticalOverlap > current.verticalOverlap
        }
        if candidate.verticalDistance != current.verticalDistance {
            return candidate.verticalDistance < current.verticalDistance
        }
        if candidate.midY != current.midY {
            return candidate.midY > current.midY
        }
        if candidate.handle.pid != current.handle.pid {
            return candidate.handle.pid < current.handle.pid
        }
        return candidate.handle.windowId < current.handle.windowId
    }
}

extension OverviewNavigation {
    static func selectionAfterRemoving(
        _ removedHandle: WindowHandle,
        from visibleOrder: [WindowHandle],
        availableHandles: Set<WindowHandle>
    ) -> WindowHandle? {
        guard let removedIndex = visibleOrder.firstIndex(of: removedHandle) else {
            return visibleOrder.first { availableHandles.contains($0) }
        }
        if removedIndex + 1 < visibleOrder.count,
           let next = visibleOrder[(removedIndex + 1)...].first(where: { availableHandles.contains($0) })
        {
            return next
        }
        return visibleOrder[..<removedIndex].reversed().first { availableHandles.contains($0) }
    }
}

// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics

enum TrackpadGestureMode: Equatable {
    case columnScroll
    case workspaceSwitch(axis: WorkspaceSwipeAxis)
    case windowMove
    case windowResize

    var isWindowInteraction: Bool {
        switch self {
        case .windowMove,
             .windowResize:
            true
        case .columnScroll,
             .workspaceSwitch:
            false
        }
    }
}

enum TrackpadGestureIntent {
    struct Config: Equatable {
        var columnScrollEnabled: Bool
        var columnScrollFingerCount: Int
        var workspaceSwipeEnabled: Bool
        var workspaceSwipeFingerCount: Int
        var workspaceSwipeAxis: WorkspaceSwipeAxis
        var windowMoveEnabled = false
        var windowMoveFingerCount = 4
        var windowResizeEnabled = false
        var windowResizeFingerCount = 3
    }

    static let workspaceSwipeTriggerUnits: CGFloat = 140.0
    static let workspaceSwipeReleaseVelocityFloor: Double = 800.0

    /// Window gestures own their finger count outright: they are omnidirectional, so a shared count
    /// cannot be disambiguated by swipe axis the way column scroll and workspace swipe are. When move
    /// and resize share a count, move wins.
    static func windowGestureMode(_ config: Config, fingerCount: Int) -> TrackpadGestureMode? {
        if config.windowMoveEnabled, fingerCount == config.windowMoveFingerCount {
            return .windowMove
        }
        if config.windowResizeEnabled, fingerCount == config.windowResizeFingerCount {
            return .windowResize
        }
        return nil
    }

    static func allowsGestureStart(_ config: Config, fingerCount: Int) -> Bool {
        windowGestureMode(config, fingerCount: fingerCount) != nil
            || (config.columnScrollEnabled && fingerCount == config.columnScrollFingerCount)
            || (config.workspaceSwipeEnabled && fingerCount == config.workspaceSwipeFingerCount)
    }

    static func hasCandidateMode(
        _ config: Config,
        fingerCount: Int,
        columnContextAvailable: Bool,
        windowContextAvailable: Bool = false
    ) -> Bool {
        if windowGestureMode(config, fingerCount: fingerCount) != nil {
            return windowContextAvailable
        }
        return (config.columnScrollEnabled && fingerCount == config.columnScrollFingerCount && columnContextAvailable)
            || (config.workspaceSwipeEnabled && fingerCount == config.workspaceSwipeFingerCount)
    }

    static func resolveMode(
        _ config: Config,
        fingerCount: Int,
        cumulativeTranslation: CGVector,
        columnScrollAxis: WorkspaceSwipeAxis,
        columnContextAvailable: Bool,
        windowContextAvailable: Bool = false
    ) -> TrackpadGestureMode? {
        if let windowMode = windowGestureMode(config, fingerCount: fingerCount) {
            return windowContextAvailable ? windowMode : nil
        }
        let dominantAxis: WorkspaceSwipeAxis = abs(cumulativeTranslation.dx) > abs(cumulativeTranslation.dy) ?
            .horizontal : .vertical
        let columnCandidate = config.columnScrollEnabled
            && fingerCount == config.columnScrollFingerCount
            && columnContextAvailable
        if columnCandidate, dominantAxis == columnScrollAxis {
            return .columnScroll
        }
        guard config.workspaceSwipeEnabled, fingerCount == config.workspaceSwipeFingerCount else { return nil }
        let axis = if columnCandidate {
            switch columnScrollAxis {
            case .horizontal: WorkspaceSwipeAxis.vertical
            case .vertical: WorkspaceSwipeAxis.horizontal
            }
        } else {
            config.workspaceSwipeAxis
        }
        guard axis == dominantAxis else { return nil }
        return .workspaceSwitch(axis: axis)
    }

    /// Maps trackpad travel onto the screen: a full traversal of the trackpad crosses the whole monitor
    /// at sensitivity 1.0. `clampToMonitor` keeps the result on the monitor so drop targets stay reachable.
    static func windowGestureLocation(
        start: CGPoint,
        startTouch: CGPoint,
        currentTouch: CGPoint,
        monitorFrame: CGRect,
        sensitivity: CGFloat,
        clampToMonitor: Bool = true
    ) -> CGPoint {
        let x = start.x + (currentTouch.x - startTouch.x) * monitorFrame.width * sensitivity
        let y = start.y + (currentTouch.y - startTouch.y) * monitorFrame.height * sensitivity
        guard clampToMonitor else { return CGPoint(x: x, y: y) }
        return CGPoint(
            x: min(max(x, monitorFrame.minX), monitorFrame.maxX),
            y: min(max(y, monitorFrame.minY), monitorFrame.maxY)
        )
    }

    static func isNextWorkspace(
        axis: WorkspaceSwipeAxis,
        displacement: CGFloat,
        naturalDirection: Bool
    ) -> Bool? {
        guard displacement != 0 else { return nil }
        switch axis {
        case .horizontal:
            return naturalDirection ? displacement < 0 : displacement > 0
        case .vertical:
            return naturalDirection ? displacement > 0 : displacement < 0
        }
    }

    static func releaseFlickDisplacement(cumulativeAxisUnits: CGFloat, velocity: Double) -> CGFloat? {
        guard abs(velocity) >= workspaceSwipeReleaseVelocityFloor else { return nil }
        if cumulativeAxisUnits != 0, (velocity > 0) != (cumulativeAxisUnits > 0) {
            return nil
        }
        return CGFloat(velocity)
    }
}

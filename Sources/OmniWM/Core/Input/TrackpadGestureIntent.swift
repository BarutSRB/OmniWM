// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics

enum TrackpadGestureMode: Equatable {
    case overview
    case columnScroll
    case workspaceSwitch(axis: WorkspaceSwipeAxis)
}

enum TrackpadGestureIntent {
    private static let overviewSwipeTriggerUnits: CGFloat = 24.0

    static func overviewTriggered(translation: CGPoint) -> Bool {
        translation.y >= overviewSwipeTriggerUnits && translation.y > abs(translation.x)
    }

    struct Config: Equatable {
        var columnScrollEnabled: Bool
        var columnScrollFingerCount: Int
        var workspaceSwipeEnabled: Bool
        var workspaceSwipeFingerCount: Int
        var workspaceSwipeAxis: WorkspaceSwipeAxis
        var overviewEnabled: Bool = false
        var overviewFingerCount: Int = 4
    }

    static let workspaceSwipeTriggerUnits: CGFloat = 140.0
    static let workspaceSwipeReleaseVelocityFloor: Double = 800.0

    static func allowsGestureStart(_ config: Config, fingerCount: Int) -> Bool {
        (config.overviewEnabled && fingerCount == config.overviewFingerCount)
            || (config.columnScrollEnabled && fingerCount == config.columnScrollFingerCount)
            || (config.workspaceSwipeEnabled && fingerCount == config.workspaceSwipeFingerCount)
    }

    static func hasCandidateMode(_ config: Config, fingerCount: Int, columnContextAvailable: Bool) -> Bool {
        (config.overviewEnabled && fingerCount == config.overviewFingerCount)
            || (config.columnScrollEnabled && fingerCount == config.columnScrollFingerCount && columnContextAvailable)
            || (config.workspaceSwipeEnabled && fingerCount == config.workspaceSwipeFingerCount)
    }

    static func resolveMode(
        _ config: Config,
        fingerCount: Int,
        cumulativeTranslation: CGVector,
        columnScrollAxis: WorkspaceSwipeAxis,
        columnContextAvailable: Bool
    ) -> TrackpadGestureMode? {
        let dominantAxis: WorkspaceSwipeAxis = abs(cumulativeTranslation.dx) > abs(cumulativeTranslation.dy) ?
            .horizontal : .vertical
        let columnCandidate = config.columnScrollEnabled
            && fingerCount == config.columnScrollFingerCount
            && columnContextAvailable
        let workspaceCandidate = config.workspaceSwipeEnabled && fingerCount == config.workspaceSwipeFingerCount
        let workspaceAxis = columnCandidate
            ? (columnScrollAxis == .horizontal ? WorkspaceSwipeAxis.vertical : .horizontal)
            : config.workspaceSwipeAxis
        if config.overviewEnabled, fingerCount == config.overviewFingerCount,
           dominantAxis == .vertical, cumulativeTranslation.dy > 0,
           !(columnCandidate && columnScrollAxis == .vertical),
           !(workspaceCandidate && workspaceAxis == .vertical)
        {
            return .overview
        }
        if columnCandidate, dominantAxis == columnScrollAxis {
            return .columnScroll
        }
        guard workspaceCandidate, workspaceAxis == dominantAxis else { return nil }
        return .workspaceSwitch(axis: workspaceAxis)
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

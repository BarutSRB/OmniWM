// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

enum DisplayEnvironmentDiagnostics {
    private static let dockInsetThreshold: CGFloat = 24

    static func issues(monitors: [Monitor], spacesMode: DisplaySpacesMode) -> [DiagnosticsIssue] {
        var issues = fixedDockIssues(monitors: monitors)
        issues.append(contentsOf: horizontalArrangementIssues(monitors: monitors, spacesMode: spacesMode))
        return issues
    }

    private static func fixedDockIssues(monitors: [Monitor]) -> [DiagnosticsIssue] {
        monitors.flatMap { monitor -> [DiagnosticsIssue] in
            let frame = monitor.frame
            let visible = monitor.visibleFrame
            let insets: [(DockEdge, CGFloat)] = [
                (.left, visible.minX - frame.minX),
                (.right, frame.maxX - visible.maxX),
                (.bottom, visible.minY - frame.minY)
            ]
            return insets.compactMap { edge, inset in
                guard inset >= dockInsetThreshold else { return nil }
                return DiagnosticsIssue(kind: .fixedDock(
                    monitorName: monitor.name,
                    edge: edge,
                    inset: inset,
                    displayId: monitor.displayId
                ))
            }
        }
    }

    private static func horizontalArrangementIssues(
        monitors: [Monitor],
        spacesMode: DisplaySpacesMode
    ) -> [DiagnosticsIssue] {
        guard spacesMode != .enabled, monitors.count > 1 else { return [] }
        var issues: [DiagnosticsIssue] = []
        for firstIndex in monitors.indices {
            for secondIndex in monitors.indices where secondIndex > firstIndex {
                let first = monitors[firstIndex]
                let second = monitors[secondIndex]
                let verticalOverlap = overlap(
                    first.frame.minY ... first.frame.maxY,
                    second.frame.minY ... second.frame.maxY
                )
                guard verticalOverlap > 1 else { continue }
                let horizontalOverlap = overlap(
                    first.frame.minX ... first.frame.maxX,
                    second.frame.minX ... second.frame.maxX
                )
                guard horizontalOverlap < 1 else { continue }
                issues.append(DiagnosticsIssue(kind: .horizontalDisplayArrangement(
                    firstName: first.name,
                    secondName: second.name,
                    firstDisplayId: first.displayId,
                    secondDisplayId: second.displayId
                )))
            }
        }
        return issues
    }

    private static func overlap(_ lhs: ClosedRange<CGFloat>, _ rhs: ClosedRange<CGFloat>) -> CGFloat {
        max(0, min(lhs.upperBound, rhs.upperBound) - max(lhs.lowerBound, rhs.lowerBound))
    }
}

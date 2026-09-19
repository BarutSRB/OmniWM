// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct ObservedAxisHint: Equatable {
    let requested: CGFloat
    let observed: CGFloat

    func floor(for proposed: CGFloat, limit: CGFloat) -> CGFloat? {
        guard proposed >= requested - FrameTolerance.frameWrite else { return nil }
        return min(observed, limit)
    }

    func packed(_ proposed: CGFloat, limit: CGFloat) -> CGFloat {
        floor(for: proposed, limit: limit).map { max(proposed, $0) } ?? proposed
    }

    func isWithinFrameTolerance(of other: ObservedAxisHint) -> Bool {
        abs(requested - other.requested) <= FrameTolerance.frameWrite
            && abs(observed - other.observed) <= FrameTolerance.frameWrite
    }

    var traceDescription: String {
        String(format: "%.1f→%.1f", requested, observed)
    }
}

struct ObservedPackingHints: Equatable {
    var width: ObservedAxisHint?
    var height: ObservedAxisHint?

    static let none = ObservedPackingHints()

    var isEmpty: Bool {
        width == nil && height == nil
    }

    func primary(for orientation: Monitor.Orientation) -> ObservedAxisHint? {
        orientation == .horizontal ? width : height
    }

    func secondary(for orientation: Monitor.Orientation) -> ObservedAxisHint? {
        orientation == .horizontal ? height : width
    }

    func isWithinFrameTolerance(of other: ObservedPackingHints) -> Bool {
        Self.matches(width, other.width) && Self.matches(height, other.height)
    }

    private static func matches(_ lhs: ObservedAxisHint?, _ rhs: ObservedAxisHint?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): lhs.isWithinFrameTolerance(of: rhs)
        default: false
        }
    }
}

struct ObservedSizeEvidence: Equatable {
    var minSize = CGSize(width: 1, height: 1)
    var hints = ObservedPackingHints.none

    var isEmpty: Bool {
        minSize.width <= 1 && minSize.height <= 1 && hints.isEmpty
    }

    func isWithinFrameTolerance(of other: ObservedSizeEvidence) -> Bool {
        minSize.isWithinFrameTolerance(of: other.minSize) && hints.isWithinFrameTolerance(of: other.hints)
    }

    var traceDescription: String {
        var parts: [String] = []
        if minSize.width > 1 || minSize.height > 1 {
            parts.append(String(format: "minSize=%.1fx%.1f", minSize.width, minSize.height))
        }
        if let width = hints.width {
            parts.append("widthHint=\(width.traceDescription)")
        }
        if let height = hints.height {
            parts.append("heightHint=\(height.traceDescription)")
        }
        return parts.joined(separator: " ")
    }
}

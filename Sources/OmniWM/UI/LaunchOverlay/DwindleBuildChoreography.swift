// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import QuartzCore

struct DwindleBuildChoreography {
    struct TileTrack {
        let positions: [CGPoint]
        let sizes: [CGSize]
        let opacities: [CGFloat]
        let keyTimes: [Double]
        let timings: [CAMediaTimingFunction]
    }

    let bounds: CGRect
    let gap: CGFloat

    static let transition = 0.30
    static let stageGrow = 0.22
    static let splitTimes: [Double] = [0.34, 0.64, 0.94, 1.24]
    static let buildDuration = 1.54

    var tracks: [TileTrack] {
        Self.stops.map(track(for:))
    }

    private func track(for stops: [Stop]) -> TileTrack {
        TileTrack(
            positions: stops.map { center(of: $0.rect) },
            sizes: stops.map { size(of: $0.rect) },
            opacities: stops.map(\.opacity),
            keyTimes: stops.map { $0.time / Self.buildDuration },
            timings: stops.dropFirst().map(\.ease.function)
        )
    }

    private func frame(of rect: NRect) -> CGRect {
        let boundsW = bounds.width
        let boundsH = bounds.height
        let originX = rect.x * boundsW + gap / 2
        let originY = (1 - rect.y - rect.height) * boundsH + gap / 2
        let tileW = max(0, rect.width * boundsW - gap)
        let tileH = max(0, rect.height * boundsH - gap)
        return CGRect(x: originX, y: originY, width: tileW, height: tileH)
    }

    private func center(of rect: NRect) -> CGPoint {
        let box = frame(of: rect)
        return CGPoint(x: box.midX, y: box.midY)
    }

    private func size(of rect: NRect) -> CGSize {
        frame(of: rect).size
    }
}

private struct NRect {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private enum SegEase {
    case dwindle
    case linear

    var function: CAMediaTimingFunction {
        switch self {
        case .dwindle: DwindleBuildChoreography.dwindleTiming
        case .linear: CAMediaTimingFunction(name: .linear)
        }
    }
}

private struct Stop {
    let time: Double
    let rect: NRect
    let opacity: CGFloat
    let ease: SegEase
}

extension DwindleBuildChoreography {
    static var dwindleTiming: CAMediaTimingFunction {
        let curve = CubicConfig.hyprlandDwindle
        return CAMediaTimingFunction(
            controlPoints: Float(curve.controlPoint1.x),
            Float(curve.controlPoint1.y),
            Float(curve.controlPoint2.x),
            Float(curve.controlPoint2.y)
        )
    }

    private static let stops: [[Stop]] = [
        [
            Stop(time: 0, rect: from0, opacity: 0, ease: .linear),
            Stop(time: stageGrow, rect: full, opacity: 1, ease: .dwindle),
            Stop(time: splitTimes[0], rect: full, opacity: 1, ease: .linear),
            Stop(time: splitTimes[0] + transition, rect: leftHalf, opacity: 1, ease: .dwindle),
            Stop(time: buildDuration, rect: leftHalf, opacity: 1, ease: .linear)
        ],
        [
            Stop(time: 0, rect: from1, opacity: 0, ease: .linear),
            Stop(time: splitTimes[0], rect: from1, opacity: 0, ease: .linear),
            Stop(time: splitTimes[0] + transition, rect: rightFull, opacity: 1, ease: .dwindle),
            Stop(time: splitTimes[1] + transition, rect: topRight, opacity: 1, ease: .dwindle),
            Stop(time: buildDuration, rect: topRight, opacity: 1, ease: .linear)
        ],
        [
            Stop(time: 0, rect: from2, opacity: 0, ease: .linear),
            Stop(time: splitTimes[1], rect: from2, opacity: 0, ease: .linear),
            Stop(time: splitTimes[1] + transition, rect: botRight, opacity: 1, ease: .dwindle),
            Stop(time: splitTimes[2] + transition, rect: botRightLeft, opacity: 1, ease: .dwindle),
            Stop(time: buildDuration, rect: botRightLeft, opacity: 1, ease: .linear)
        ],
        [
            Stop(time: 0, rect: from3, opacity: 0, ease: .linear),
            Stop(time: splitTimes[2], rect: from3, opacity: 0, ease: .linear),
            Stop(time: splitTimes[2] + transition, rect: botRightRight, opacity: 1, ease: .dwindle),
            Stop(time: buildDuration, rect: botRightTop, opacity: 1, ease: .dwindle)
        ],
        [
            Stop(time: 0, rect: from4, opacity: 0, ease: .linear),
            Stop(time: splitTimes[3], rect: from4, opacity: 0, ease: .linear),
            Stop(time: buildDuration, rect: botRightBottom, opacity: 1, ease: .dwindle)
        ]
    ]

    private static let full = NRect(x: 0, y: 0, width: 1, height: 1)
    private static let leftHalf = NRect(x: 0, y: 0, width: 0.5, height: 1)
    private static let rightFull = NRect(x: 0.5, y: 0, width: 0.5, height: 1)
    private static let topRight = NRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
    private static let botRight = NRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
    private static let botRightLeft = NRect(x: 0.5, y: 0.5, width: 0.25, height: 0.5)
    private static let botRightRight = NRect(x: 0.75, y: 0.5, width: 0.25, height: 0.5)
    private static let botRightTop = NRect(x: 0.75, y: 0.5, width: 0.25, height: 0.25)
    private static let botRightBottom = NRect(x: 0.75, y: 0.75, width: 0.25, height: 0.25)

    private static let from0 = NRect(x: 0.5, y: 0.5, width: 0, height: 0)
    private static let from1 = NRect(x: 0.5, y: 0, width: 0, height: 1)
    private static let from2 = NRect(x: 0.5, y: 0.5, width: 0.5, height: 0)
    private static let from3 = NRect(x: 0.75, y: 0.5, width: 0, height: 0.5)
    private static let from4 = NRect(x: 0.75, y: 0.75, width: 0.25, height: 0)
}

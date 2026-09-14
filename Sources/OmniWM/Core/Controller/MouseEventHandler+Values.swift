// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    enum ViewportGestureTerminationDisposition {
        case settleLiveOffset
        case settleLiveOffsetWithoutRelayout
        case viewportAlreadySettled
    }

    struct PerformanceSnapshot: Equatable, Sendable {
        let cgEvents: UInt64
        let mouseMovedEvents: UInt64
        let mouseDraggedEvents: UInt64
        let scrollEvents: UInt64
        let buttonEvents: UInt64
        let droppedTrackpadScrollEvents: UInt64
        let mouseWarpSamples: UInt64
        let multitouch: MultitouchFrameMailbox.PerformanceSnapshot?
    }

    enum MouseButton: Hashable {
        case left
        case right

        var pressedMask: Int {
            switch self {
            case .left: 1
            case .right: 2
            }
        }
    }

    enum MouseMoveMode: Equatable {
        case swap
        case insert
    }

    struct GestureTouchSample: Equatable, Sendable {
        let phase: NSTouch.Phase
        let normalizedPosition: CGPoint?
    }

    struct GestureEventSnapshot: Sendable {
        static let normalizedPositionToGestureUnits: CGFloat = 500.0
        let location: CGPoint
        let phaseRawValue: NSEvent.Phase.RawValue
        let timestamp: TimeInterval
        let touches: [GestureTouchSample]

        init(
            location: CGPoint,
            phaseRawValue: NSEvent.Phase.RawValue,
            timestamp: TimeInterval = CACurrentMediaTime(),
            touches: [GestureTouchSample]
        ) {
            self.location = location
            self.phaseRawValue = phaseRawValue
            self.timestamp = timestamp
            self.touches = touches
        }
    }
}

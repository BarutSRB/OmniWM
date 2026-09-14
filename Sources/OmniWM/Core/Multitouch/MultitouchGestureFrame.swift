// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreHID
import Foundation
import IOKit
import os
import Synchronization

private let multitouchTouchStride = 96
private let multitouchStateByteOffset = 20
private let multitouchPositionXByteOffset = 32
private let multitouchPositionYByteOffset = 36
private let multitouchTouchingState: Int32 = 4

extension MultitouchGestureSource {
    struct RawTouch: Sendable {
        let x: Float
        let y: Float
    }

    struct RawTouchBuffer: RandomAccessCollection, Sendable {
        private var inline = InlineArray<16, RawTouch>(repeating: RawTouch(x: 0, y: 0))
        private var overflow: [RawTouch] = []
        private(set) var count = 0

        var startIndex: Int {
            0
        }

        var endIndex: Int {
            count
        }

        init() {}

        init(_ touches: [RawTouch]) {
            for touch in touches {
                append(touch)
            }
        }

        mutating func append(_ touch: RawTouch) {
            if count < inline.count {
                inline[count] = touch
            } else {
                overflow.append(touch)
            }
            count += 1
        }

        subscript(index: Int) -> RawTouch {
            index < inline.count ? inline[index] : overflow[index - inline.count]
        }
    }

    struct RawFrame: Sendable {
        let touches: RawTouchBuffer
        let timestamp: Double

        init(touches: [RawTouch], timestamp: Double) {
            self.touches = RawTouchBuffer(touches)
            self.timestamp = timestamp
        }

        init(touches: consuming RawTouchBuffer, timestamp: Double) {
            self.touches = consume touches
            self.timestamp = timestamp
        }
    }

    static func makeSnapshot(
        frame: RawFrame,
        location: CGPoint,
        previousActiveCount: Int
    ) -> (snapshot: MouseEventHandler.GestureEventSnapshot?, activeCount: Int) {
        let activeCount = frame.touches.count
        if activeCount == 0 {
            guard previousActiveCount > 0 else { return (nil, 0) }
            return (liftSnapshot(.ended, location: location, timestamp: frame.timestamp), 0)
        }

        let phase: NSEvent.Phase = previousActiveCount == 0 ? .began : .changed
        let touches = frame.touches.map { touch in
            MouseEventHandler.GestureTouchSample(
                phase: .moved,
                normalizedPosition: normalizedPosition(x: touch.x, y: touch.y)
            )
        }
        let snapshot = MouseEventHandler.GestureEventSnapshot(
            location: location,
            phaseRawValue: phase.rawValue,
            timestamp: frame.timestamp,
            touches: touches
        )
        return (snapshot, activeCount)
    }

    static func liftSnapshot(
        _ phase: NSEvent.Phase,
        location: CGPoint,
        timestamp: Double
    ) -> MouseEventHandler.GestureEventSnapshot {
        MouseEventHandler.GestureEventSnapshot(
            location: location,
            phaseRawValue: phase.rawValue,
            timestamp: timestamp,
            touches: []
        )
    }

    private static func normalizedPosition(x: Float, y: Float) -> CGPoint? {
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }

    nonisolated static func buildRawFrame(
        fingers: UnsafeMutableRawPointer?,
        count: Int32,
        timestamp: Double
    ) -> RawFrame {
        guard let fingers, count > 0 else { return RawFrame(touches: [], timestamp: timestamp) }
        var touches = RawTouchBuffer()
        for index in 0 ..< Int(count) {
            let base = index * multitouchTouchStride
            let state = fingers.load(fromByteOffset: base + multitouchStateByteOffset, as: Int32.self)
            guard state == multitouchTouchingState else { continue }
            let x = fingers.load(fromByteOffset: base + multitouchPositionXByteOffset, as: Float.self)
            let y = fingers.load(fromByteOffset: base + multitouchPositionYByteOffset, as: Float.self)
            touches.append(RawTouch(x: x, y: y))
        }
        return RawFrame(touches: touches, timestamp: timestamp)
    }
}

// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

struct MousePerformanceCounters {
    var cgEvents: UInt64 = 0
    var mouseMovedEvents: UInt64 = 0
    var mouseDraggedEvents: UInt64 = 0
    var scrollEvents: UInt64 = 0
    var buttonEvents: UInt64 = 0
    var droppedTrackpadScrollEvents: UInt64 = 0
    var mouseWarpSamples: UInt64 = 0
    var retiredMultitouch: MultitouchFrameMailbox.PerformanceSnapshot?

    func snapshot(multitouch: MultitouchFrameMailbox.PerformanceSnapshot?) -> MouseEventHandler.PerformanceSnapshot {
        MouseEventHandler.PerformanceSnapshot(
            cgEvents: cgEvents,
            mouseMovedEvents: mouseMovedEvents,
            mouseDraggedEvents: mouseDraggedEvents,
            scrollEvents: scrollEvents,
            buttonEvents: buttonEvents,
            droppedTrackpadScrollEvents: droppedTrackpadScrollEvents,
            mouseWarpSamples: mouseWarpSamples,
            multitouch: mergedMultitouch(with: multitouch)
        )
    }

    mutating func accumulateRetiredMultitouch(
        _ snapshot: MultitouchFrameMailbox.PerformanceSnapshot
    ) {
        retiredMultitouch = if let retiredMultitouch {
            Self.mergeMultitouch(retiredMultitouch, snapshot, pendingFrames: 0)
        } else {
            Self.mergeMultitouch(snapshot, nil, pendingFrames: 0)
        }
    }

    private func mergedMultitouch(
        with current: MultitouchFrameMailbox.PerformanceSnapshot?
    ) -> MultitouchFrameMailbox.PerformanceSnapshot? {
        guard let retiredMultitouch else { return current }
        return Self.mergeMultitouch(
            retiredMultitouch,
            current,
            pendingFrames: current?.pendingFrames ?? 0
        )
    }

    private static func mergeMultitouch(
        _ accumulated: MultitouchFrameMailbox.PerformanceSnapshot,
        _ current: MultitouchFrameMailbox.PerformanceSnapshot?,
        pendingFrames: Int
    ) -> MultitouchFrameMailbox.PerformanceSnapshot {
        guard let current else {
            return MultitouchFrameMailbox.PerformanceSnapshot(
                rawCallbacks: accumulated.rawCallbacks,
                staleCallbacks: accumulated.staleCallbacks,
                drainBatches: accumulated.drainBatches,
                overwrittenChanges: accumulated.overwrittenChanges,
                transitionsQueued: accumulated.transitionsQueued,
                cursorSamples: accumulated.cursorSamples,
                pendingFrames: pendingFrames,
                maximumPendingFrames: accumulated.maximumPendingFrames
            )
        }
        return MultitouchFrameMailbox.PerformanceSnapshot(
            rawCallbacks: accumulated.rawCallbacks &+ current.rawCallbacks,
            staleCallbacks: accumulated.staleCallbacks &+ current.staleCallbacks,
            drainBatches: accumulated.drainBatches &+ current.drainBatches,
            overwrittenChanges: accumulated.overwrittenChanges &+ current.overwrittenChanges,
            transitionsQueued: accumulated.transitionsQueued &+ current.transitionsQueued,
            cursorSamples: accumulated.cursorSamples &+ current.cursorSamples,
            pendingFrames: pendingFrames,
            maximumPendingFrames: max(
                accumulated.maximumPendingFrames,
                current.maximumPendingFrames
            )
        )
    }
}

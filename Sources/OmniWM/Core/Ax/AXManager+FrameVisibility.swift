// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension AXManager {
    func cancelPendingFrameJobs(_ entries: [(pid: pid_t, windowId: Int)], reason: String) {
        var deliveries: [AXFrameTerminalDelivery] = []
        var terminalFailures: [AXFrameApplyResult] = []
        let traceActive = FrameApplyTrace.shared.isActive
        for (pid, windowId) in AXFrameEntryGrouping.unique(entries) {
            if traceActive {
                recordFrameJobCancellation(pid: pid, windowId: windowId, reason: reason)
            }
            AppAXContextRegistry.contexts[pid]?.cancelFrameJob(for: windowId)
            let cancellation = frameLedger.cancelFrameJob(pid: pid, windowId: windowId)
            let retryCancellation = cancelPendingFrameRetry(for: windowId)
            deliveries.append(contentsOf: cancellation.deliveries)
            if let terminalFailure = cancellation.terminalFailure ?? retryCancellation {
                terminalFailures.append(terminalFailure)
            }
        }
        for delivery in deliveries {
            delivery.deliver()
        }
        for terminalFailure in terminalFailures {
            handleTerminalFrameApplyFailure(terminalFailure)
        }
    }

    private func recordFrameJobCancellation(pid: pid_t, windowId: Int, reason: String) {
        let pendingFrame = frameLedger.pendingFrameWrite(for: windowId)
        let state = [
            pendingFrame != nil ? "pending" : nil,
            frameLedger.hasTerminalRefusal(for: windowId) ? "refusal" : nil
        ].compactMap(\.self)
        guard !state.isEmpty else { return }
        FrameApplyTrace.recordEvent(
            pid: pid,
            windowId: windowId,
            outcome: "outcome=cancelled/\(reason)/\(state.joined(separator: "+"))",
            target: pendingFrame
        )
    }

    func suppressFrameWrites(_ entries: [(pid: pid_t, windowId: Int)]) {
        var deliveries: [AXFrameTerminalDelivery] = []
        let entries = AXFrameEntryGrouping.unique(entries)
        for (pid, windowIds) in groupedWindowIdsByPid(entries) {
            AppAXContextRegistry.contexts[pid]?.suppressFrameWrites(for: windowIds)
        }
        for (_, windowId) in entries {
            deliveries.append(contentsOf: frameLedger.suppressFrameWrite(windowId: windowId))
            cancelPendingFrameRetry(for: windowId)
            clearSkyLightLivePosition(for: windowId)
        }
        for delivery in deliveries {
            delivery.deliver()
        }
    }

    func unsuppressFrameWrites(_ entries: [(pid: pid_t, windowId: Int)]) {
        let entries = AXFrameEntryGrouping.unique(entries)
        parkLedger.cancelParkFrameJobs(entries, reason: "shown")
        for (pid, windowIds) in groupedWindowIdsByPid(entries) {
            AppAXContextRegistry.contexts[pid]?.unsuppressFrameWrites(for: windowIds)
        }
        for (_, windowId) in entries {
            clearSkyLightLivePosition(for: windowId)
        }
    }

    func setMacOSAppHidden(
        _ hidden: Bool,
        pid: pid_t,
        entries: [(pid: pid_t, windowId: Int)]
    ) {
        let entries = AXFrameEntryGrouping.unique(entries)
        let windowIds = entries.lazy.filter { $0.pid == pid }.map(\.windowId)
        if hidden {
            markAppHidden(pid)
            AppAXContextRegistry.setMacOSAppHidden(true, pid: pid, windowIds: Array(windowIds))
            var deliveries: [AXFrameTerminalDelivery] = []
            for (_, windowId) in entries {
                deliveries.append(contentsOf: frameLedger.suppressFrameWrite(windowId: windowId))
                cancelPendingFrameRetry(for: windowId)
                clearSkyLightLivePosition(for: windowId)
            }
            parkLedger.cancelParkFrameJobs(entries, reason: "app-hidden")
            for delivery in deliveries {
                delivery.deliver()
            }
        } else {
            markAppShown(pid)
            AppAXContextRegistry.setMacOSAppHidden(false, pid: pid, windowIds: Array(windowIds))
            for (_, windowId) in entries {
                clearSkyLightLivePosition(for: windowId)
            }
        }
        if AppVisibilityTrace.isActive {
            AppVisibilityTrace.record(
                .axFence,
                pid: pid,
                visibility: hidden ? .hidden : .visible,
                outcome: hidden ? .enabled : .disabled,
                managedWindowCount: entries.lazy.filter { $0.pid == pid }.count
            )
        }
    }

    private func groupedWindowIdsByPid(
        _ entries: [(pid: pid_t, windowId: Int)]
    ) -> [pid_t: [Int]] {
        var grouped: [pid_t: [Int]] = [:]
        for (pid, windowId) in entries {
            grouped[pid, default: []].append(windowId)
        }
        return grouped
    }

    @discardableResult
    func applyPositionsViaSkyLight(
        _ positions: [SkyLightPositionTarget],
        allowInactive: Bool = false
    ) -> SkyLight.TransactionSubmissionResult {
        let filtered = positions.filter {
            (allowInactive || !inactiveWorkspaceWindowIds.contains($0.token.windowId))
                && !macOSHiddenAppPIDs.contains($0.token.pid)
                && !excludeFrameWriteForNativeTitleBarDrag(pid: $0.token.pid, windowId: $0.token.windowId)
        }
        guard !filtered.isEmpty else { return .submitted }
        return SkyLight.shared.batchMoveWindows(Self.windowServerPositions(filtered))
    }

    static func windowServerPositions(
        _ positions: [SkyLightPositionTarget]
    ) -> [(windowId: UInt32, origin: CGPoint)] {
        positions.map {
            (
                windowId: UInt32($0.token.windowId),
                origin: ScreenCoordinateSpace.toWindowServer(rect: $0.frame).origin
            )
        }
    }
}

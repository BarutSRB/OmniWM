// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

struct ManagedReplacementTraceEvent: Equatable {
    enum Kind: Equatable {
        case enqueued(
            policy: String,
            createCount: Int,
            destroyCount: Int,
            holdCount: Int,
            deadlineReset: Bool
        )
        case flushed(
            policy: String,
            createCount: Int,
            destroyCount: Int,
            holdCount: Int,
            elapsedMillis: Int
        )
        case matched(policy: String, elapsedMillis: Int)
    }

    let timestamp: TimeInterval
    let pid: pid_t
    let workspaceId: WorkspaceDescriptor.ID
    let kind: Kind
}

@MainActor
struct AXEventDiagnostics {
    private static let createFocusTraceLimit = 128
    private static let managedReplacementTraceLimit = 128
    private static let createFocusTraceLoggingEnabled =
        ProcessInfo.processInfo.environment["OMNIWM_DEBUG_NIRI_CREATE_FOCUS"] == "1"
    private static let managedReplacementTraceLoggingEnabled =
        ProcessInfo.processInfo.environment["OMNIWM_DEBUG_MANAGED_REPLACEMENT"] == "1"
    private var createFocusTrace =
        RingBuffer<NiriCreateFocusTraceEvent>(capacity: Self.createFocusTraceLimit)
    private var managedReplacementTrace =
        RingBuffer<ManagedReplacementTraceEvent>(capacity: Self.managedReplacementTraceLimit)

    mutating func recordNiriCreateFocusTrace(_ event: NiriCreateFocusTraceEvent) {
        createFocusTrace.append(event)

        if Self.createFocusTraceLoggingEnabled {
            Log.ax.debug("[NiriCreateFocus] \(event.description)")
        }
    }

    func createFocusTraceDump() -> String {
        let events = createFocusTrace.snapshot()
        guard !events.isEmpty else { return "none" }
        return events
            .map { "\($0.timestamp.ISO8601Format()) \($0.description)" }
            .joined(separator: "\n")
    }

    func managedReplacementTraceDump() -> String {
        let events = managedReplacementTrace.snapshot()
        guard !events.isEmpty else { return "none" }
        return events
            .map {
                "uptime=\(String(format: "%.3f", $0.timestamp)) pid=\($0.pid)"
                    + " workspace=\($0.workspaceId.uuidString) \(String(describing: $0.kind))"
            }
            .joined(separator: "\n")
    }

    mutating func recordManagedReplacementTrace(
        key: AXEventHandler.ManagedReplacementKey,
        kind: ManagedReplacementTraceEvent.Kind
    ) {
        let event = ManagedReplacementTraceEvent(
            timestamp: ProcessInfo.processInfo.systemUptime,
            pid: key.pid,
            workspaceId: key.workspaceId,
            kind: kind
        )
        managedReplacementTrace.append(event)

        if Self.managedReplacementTraceLoggingEnabled {
            Log.ax.debug(
                "[ManagedReplacement] pid=\(key.pid) workspace=\(key.workspaceId.uuidString) kind=\(String(describing: kind))"
            )
        }
    }
}

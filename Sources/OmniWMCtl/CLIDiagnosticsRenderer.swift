// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import OmniWMIPC

enum CLIDiagnosticsRenderer {
    static func formattedCapture(_ payload: IPCCaptureResult, format: CLIOutputFormat) -> String {
        let artifact = payload.lastArtifact
        return CLITableRenderer.formatRows(
            headers: ["FIELD", "VALUE"],
            rows: [
                ["phase", payload.phase.rawValue],
                ["profile", payload.profile?.rawValue ?? "-"],
                ["started-at", payload.startedAt ?? "-"],
                ["last-artifact-profile", artifact?.profile.rawValue ?? "-"],
                ["last-artifact-path", artifact?.path ?? "-"],
                ["last-artifact-started-at", artifact?.startedAt ?? "-"],
                ["last-artifact-ended-at", artifact?.endedAt ?? "-"],
                ["failure-reason", payload.failureReason ?? "-"]
            ],
            format: format
        )
    }

    static func formattedMetrics(_ payload: IPCMetricsQueryResult, format: CLIOutputFormat) -> String {
        let rows = payload.axWrites.byApp.map { bucket in
            [
                bucket.app ?? String(bucket.pid),
                String(bucket.context),
                bucket.lane,
                String(bucket.count),
                String(bucket.failureCount),
                String(format: "%.1f", bucket.meanMicroseconds / 1_000),
                String(format: "%.1f", bucket.maxMicroseconds / 1_000)
            ]
        }
        let table = CLITableRenderer.formatRows(
            headers: ["APP", "CONTEXT", "LANE", "WRITES", "FAILED", "MEAN MS", "MAX MS"],
            rows: rows,
            format: format
        )
        guard format == .text || format == .table else { return table }

        var lines: [String] = []
        appendMetricsSummary(payload, to: &lines)
        if !rows.isEmpty {
            lines.append("")
            lines.append("live app contexts (rows retire with the app's AX context):")
            lines.append(table)
        }
        return lines.joined(separator: "\n")
    }

    private static func appendMetricsSummary(_ payload: IPCMetricsQueryResult, to lines: inout [String]) {
        lines.append(
            "ax frame writes since launch: \(payload.axWrites.count) attempts"
                + " mean \(String(format: "%.2f", payload.axWrites.meanMicroseconds / 1_000)) ms"
                + " max \(String(format: "%.2f", payload.axWrites.maxMicroseconds / 1_000)) ms"
                + " failed \(payload.axWrites.failureCount)"
        )
        let ticks = payload.displayTicks
        lines.append(
            "display ticks: \(ticks.tickCount)"
                + " timing anomalies \(ticks.timingAnomalyCount)"
                + " (\(String(format: "%.1f", ticks.timingAnomalyPercent))%)"
                + " long-gap \(ticks.longTimestampGapCount)"
                + " work-over-period \(ticks.workExceededNominalPeriodCount)"
                + " completion-past-target \(ticks.completionPastTargetCount)"
        )
        lines.append(
            "  work mean \(String(format: "%.2f", ticks.meanWorkMicroseconds / 1_000)) ms"
                + " max \(String(format: "%.2f", ticks.maxWorkMicroseconds / 1_000)) ms;"
                + " max interval \(String(format: "%.2f", ticks.maxIntervalMicroseconds / 1_000)) ms;"
                + " min slack at entry \(String(format: "%.2f", ticks.minEntrySlackMicroseconds / 1_000)) ms"
                + " at completion \(String(format: "%.2f", ticks.minCompletionSlackMicroseconds / 1_000)) ms"
                + " (negative = past the frame's target timestamp)"
        )
        lines.append(
            "layout builds: \(payload.layoutBuilds.totalBuilds)"
                + " cycles \(payload.layoutBuilds.completedRelayoutCycles)"
        )
        if let process = payload.process {
            lines.append(
                "energy: \(process.energyNanojoules / 1_000_000) mJ"
                    + " cpu \(String(format: "%.1f", Double(process.userTimeNanoseconds + process.systemTimeNanoseconds) / 1_000_000_000)) s"
                    + " wakeups \(process.packageIdleWakeups)"
                    + " footprint \(process.physicalFootprintBytes / 1_048_576) MB"
            )
        }
        lines.append("trace capture active: \(payload.traceCaptureActive)")
    }
}

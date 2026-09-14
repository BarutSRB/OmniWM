// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import OmniWMIPC

extension IPCMetricsQueryResult {
    init(
        axWrites snapshot: AXWriteMetricsSnapshot,
        displayTicks ticks: DisplayTickMetrics,
        layoutBuilds: (totalBuilds: Int, completedRelayoutCycles: Int),
        process: ProcessResourceSnapshot?,
        traceCaptureActive: Bool,
        timebase: MachTimebase = .current
    ) {
        self.init(
            traceCaptureActive: traceCaptureActive,
            axWrites: IPCAXWriteMetrics(snapshot: snapshot),
            displayTicks: IPCDisplayTickMetrics(ticks: ticks),
            layoutBuilds: IPCLayoutBuildMetrics(
                totalBuilds: layoutBuilds.totalBuilds,
                completedRelayoutCycles: layoutBuilds.completedRelayoutCycles
            ),
            process: process.map { IPCProcessResourceMetrics(snapshot: $0, timebase: timebase) }
        )
    }
}

extension IPCAXWriteMetrics {
    init(snapshot: AXWriteMetricsSnapshot) {
        let buckets = snapshot.buckets.map { bucket in
            IPCAXWriteMetricsBucket(
                pid: bucket.pid,
                context: bucket.callbackGeneration,
                app: bucket.app,
                bundleId: bucket.bundleId,
                lane: bucket.lane.traceDescription,
                count: bucket.writeCount,
                failureCount: bucket.failureCount,
                meanMicroseconds: Double(bucket.meanNanoseconds) / 1_000,
                maxMicroseconds: Double(bucket.maxNanoseconds) / 1_000,
                totalMicroseconds: Double(bucket.totalNanoseconds) / 1_000
            )
        }

        self.init(
            count: snapshot.totalCount,
            failureCount: snapshot.totalFailureCount,
            meanMicroseconds: Double(snapshot.meanNanoseconds) / 1_000,
            maxMicroseconds: Double(snapshot.maxNanoseconds) / 1_000,
            totalMicroseconds: Double(snapshot.totalNanoseconds) / 1_000,
            byApp: buckets
        )
    }
}

extension IPCDisplayTickMetrics {
    init(ticks: DisplayTickMetrics) {
        self.init(
            tickCount: ticks.tickCount,
            timingAnomalyCount: ticks.timingAnomalyCount,
            longTimestampGapCount: ticks.longTimestampGapCount,
            workExceededNominalPeriodCount: ticks.workExceededNominalPeriodCount,
            completionPastTargetCount: ticks.completionPastTargetCount,
            timingAnomalyPercent: ticks.timingAnomalyFraction * 100,
            meanWorkMicroseconds: Double(ticks.meanWorkMicros),
            maxWorkMicroseconds: Double(ticks.maxWorkMicros),
            maxIntervalMicroseconds: Double(ticks.maxIntervalMicros),
            minEntrySlackMicroseconds: Double(ticks.minEntrySlackMicros),
            minCompletionSlackMicroseconds: Double(ticks.minCompletionSlackMicros)
        )
    }
}

extension IPCProcessResourceMetrics {
    init(snapshot resource: ProcessResourceSnapshot, timebase: MachTimebase) {
        self.init(
            energyNanojoules: resource.energyNanojoules,
            userTimeNanoseconds: timebase.nanoseconds(fromMachTicks: resource.userTime),
            systemTimeNanoseconds: timebase.nanoseconds(fromMachTicks: resource.systemTime),
            packageIdleWakeups: resource.packageIdleWakeups,
            interruptWakeups: resource.interruptWakeups,
            residentSizeBytes: resource.residentSize,
            physicalFootprintBytes: resource.physicalFootprint
        )
    }
}

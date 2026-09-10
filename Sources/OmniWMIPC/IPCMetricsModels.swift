// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

public struct IPCAXWriteMetricsBucket: Codable, Equatable, Sendable {
    public let pid: Int32
    public let context: UInt64
    public let app: String?
    public let bundleId: String?
    public let lane: String
    public let count: Int
    public let failureCount: Int
    public let meanMicroseconds: Double
    public let maxMicroseconds: Double
    public let totalMicroseconds: Double

    public init(
        pid: Int32,
        context: UInt64,
        app: String?,
        bundleId: String?,
        lane: String,
        count: Int,
        failureCount: Int,
        meanMicroseconds: Double,
        maxMicroseconds: Double,
        totalMicroseconds: Double
    ) {
        self.pid = pid
        self.context = context
        self.app = app
        self.bundleId = bundleId
        self.lane = lane
        self.count = count
        self.failureCount = failureCount
        self.meanMicroseconds = meanMicroseconds
        self.maxMicroseconds = maxMicroseconds
        self.totalMicroseconds = totalMicroseconds
    }
}

public struct IPCAXWriteMetrics: Codable, Equatable, Sendable {
    public let count: Int
    public let failureCount: Int
    public let meanMicroseconds: Double
    public let maxMicroseconds: Double
    public let totalMicroseconds: Double
    public let byApp: [IPCAXWriteMetricsBucket]

    public init(
        count: Int,
        failureCount: Int,
        meanMicroseconds: Double,
        maxMicroseconds: Double,
        totalMicroseconds: Double,
        byApp: [IPCAXWriteMetricsBucket]
    ) {
        self.count = count
        self.failureCount = failureCount
        self.meanMicroseconds = meanMicroseconds
        self.maxMicroseconds = maxMicroseconds
        self.totalMicroseconds = totalMicroseconds
        self.byApp = byApp
    }
}

public struct IPCProcessResourceMetrics: Codable, Equatable, Sendable {
    public let energyNanojoules: UInt64
    public let userTimeNanoseconds: UInt64
    public let systemTimeNanoseconds: UInt64
    public let packageIdleWakeups: UInt64
    public let interruptWakeups: UInt64
    public let residentSizeBytes: UInt64
    public let physicalFootprintBytes: UInt64

    public init(
        energyNanojoules: UInt64,
        userTimeNanoseconds: UInt64,
        systemTimeNanoseconds: UInt64,
        packageIdleWakeups: UInt64,
        interruptWakeups: UInt64,
        residentSizeBytes: UInt64,
        physicalFootprintBytes: UInt64
    ) {
        self.energyNanojoules = energyNanojoules
        self.userTimeNanoseconds = userTimeNanoseconds
        self.systemTimeNanoseconds = systemTimeNanoseconds
        self.packageIdleWakeups = packageIdleWakeups
        self.interruptWakeups = interruptWakeups
        self.residentSizeBytes = residentSizeBytes
        self.physicalFootprintBytes = physicalFootprintBytes
    }
}

public struct IPCDisplayTickMetrics: Codable, Equatable, Sendable {
    public let tickCount: Int
    public let timingAnomalyCount: Int
    public let longTimestampGapCount: Int
    public let workExceededNominalPeriodCount: Int
    public let completionPastTargetCount: Int
    public let timingAnomalyPercent: Double
    public let meanWorkMicroseconds: Double
    public let maxWorkMicroseconds: Double
    public let maxIntervalMicroseconds: Double
    public let minEntrySlackMicroseconds: Double
    public let minCompletionSlackMicroseconds: Double

    public init(
        tickCount: Int,
        timingAnomalyCount: Int,
        longTimestampGapCount: Int,
        workExceededNominalPeriodCount: Int,
        completionPastTargetCount: Int,
        timingAnomalyPercent: Double,
        meanWorkMicroseconds: Double,
        maxWorkMicroseconds: Double,
        maxIntervalMicroseconds: Double,
        minEntrySlackMicroseconds: Double,
        minCompletionSlackMicroseconds: Double
    ) {
        self.tickCount = tickCount
        self.timingAnomalyCount = timingAnomalyCount
        self.longTimestampGapCount = longTimestampGapCount
        self.workExceededNominalPeriodCount = workExceededNominalPeriodCount
        self.completionPastTargetCount = completionPastTargetCount
        self.timingAnomalyPercent = timingAnomalyPercent
        self.meanWorkMicroseconds = meanWorkMicroseconds
        self.maxWorkMicroseconds = maxWorkMicroseconds
        self.maxIntervalMicroseconds = maxIntervalMicroseconds
        self.minEntrySlackMicroseconds = minEntrySlackMicroseconds
        self.minCompletionSlackMicroseconds = minCompletionSlackMicroseconds
    }
}

public struct IPCLayoutBuildMetrics: Codable, Equatable, Sendable {
    public let totalBuilds: Int
    public let completedRelayoutCycles: Int

    public init(totalBuilds: Int, completedRelayoutCycles: Int) {
        self.totalBuilds = totalBuilds
        self.completedRelayoutCycles = completedRelayoutCycles
    }
}

public struct IPCMetricsQueryResult: Codable, Equatable, Sendable {
    public let traceCaptureActive: Bool
    public let axWrites: IPCAXWriteMetrics
    public let displayTicks: IPCDisplayTickMetrics
    public let layoutBuilds: IPCLayoutBuildMetrics
    public let process: IPCProcessResourceMetrics?

    public init(
        traceCaptureActive: Bool,
        axWrites: IPCAXWriteMetrics,
        displayTicks: IPCDisplayTickMetrics,
        layoutBuilds: IPCLayoutBuildMetrics,
        process: IPCProcessResourceMetrics?
    ) {
        self.traceCaptureActive = traceCaptureActive
        self.axWrites = axWrites
        self.displayTicks = displayTicks
        self.layoutBuilds = layoutBuilds
        self.process = process
    }
}

// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class SystemStatsSamplerTests: XCTestCase {
    func testCPUUsageFromTickDeltas() {
        let previous = CPUTicks(busy: 1000, idle: 3000)
        let current = CPUTicks(busy: 1300, idle: 3900)

        XCTAssertEqual(SystemStatsSampler.cpuUsage(previous: previous, current: current), 0.25)
    }

    func testCPUUsageZeroDeltaReturnsNil() {
        let ticks = CPUTicks(busy: 500, idle: 500)

        XCTAssertNil(SystemStatsSampler.cpuUsage(previous: ticks, current: ticks))
    }

    func testCPUUsageFirstSampleReturnsNil() {
        XCTAssertNil(SystemStatsSampler.cpuUsage(previous: nil, current: CPUTicks(busy: 1, idle: 1)))
        XCTAssertNil(SystemStatsSampler.cpuUsage(previous: CPUTicks(busy: 1, idle: 1), current: nil))
    }

    func testMemoryUsedFormula() {
        XCTAssertEqual(
            SystemStatsSampler.memoryUsed(activePages: 100, wiredPages: 50, compressedPages: 25, pageSize: 16384),
            175 * 16384
        )
    }

    func testMemoryPressureMapping() {
        XCTAssertEqual(SystemStatsSampler.pressureLevel(fromSysctlValue: 1), .normal)
        XCTAssertEqual(SystemStatsSampler.pressureLevel(fromSysctlValue: 2), .warning)
        XCTAssertEqual(SystemStatsSampler.pressureLevel(fromSysctlValue: 4), .critical)
        XCTAssertNil(SystemStatsSampler.pressureLevel(fromSysctlValue: 0))
        XCTAssertNil(SystemStatsSampler.pressureLevel(fromSysctlValue: 3))
        XCTAssertNil(SystemStatsSampler.pressureLevel(fromSysctlValue: -1))
        XCTAssertNil(SystemStatsSampler.pressureLevel(fromSysctlValue: nil))
    }

    func testDashboardFormattingHelpers() {
        XCTAssertEqual(SystemStatsView.percentText(0.246), "25%")
        XCTAssertEqual(SystemStatsView.percentText(nil), "—")
        XCTAssertEqual(SystemStatsView.uptimeText(65), "1m")
        XCTAssertEqual(SystemStatsView.uptimeText(3665), "1h 1m")
        XCTAssertEqual(SystemStatsView.uptimeText(90065), "1d 1h 1m")
        XCTAssertEqual(SystemStatsView.fraction(used: 25, total: 100), 0.25)
        XCTAssertEqual(SystemStatsView.fraction(used: 150, total: 100), 1)
        XCTAssertNil(SystemStatsView.fraction(used: 1, total: 0))
    }
}

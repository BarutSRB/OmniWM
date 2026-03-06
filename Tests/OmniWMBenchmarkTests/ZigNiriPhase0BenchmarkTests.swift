import Foundation
import XCTest

@testable import OmniWM

@MainActor
final class ZigNiriPhase0BenchmarkTests: XCTestCase {
    private static var cachedReport: ZigNiriPhase0BenchmarkReport?
    private static var cachedScenario: ZigNiriPhase0Scenario?

    func testPercentilesAreMonotonic() {
        let stats = ZigNiriLatencyStats.from(samplesNanoseconds: [
            9_100_000,
            1_300_000,
            5_500_000,
            2_200_000,
            8_400_000,
            3_700_000,
            6_000_000,
        ])

        XCTAssertGreaterThan(stats.count, 0)
        XCTAssertLessThanOrEqual(stats.p50Ms, stats.p95Ms)
        XCTAssertLessThanOrEqual(stats.p95Ms, stats.p99Ms)
    }

    func testEmptyAndLowSampleStatsAreStable() {
        let empty = ZigNiriLatencyStats.from(samplesNanoseconds: [])
        XCTAssertEqual(empty, .empty)

        let single = ZigNiriLatencyStats.from(samplesNanoseconds: [1_250_000])
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single.minMs, single.meanMs, accuracy: 0.000_001)
        XCTAssertEqual(single.meanMs, single.p50Ms, accuracy: 0.000_001)
        XCTAssertEqual(single.p50Ms, single.p95Ms, accuracy: 0.000_001)
        XCTAssertEqual(single.p95Ms, single.p99Ms, accuracy: 0.000_001)
        XCTAssertEqual(single.p99Ms, single.maxMs, accuracy: 0.000_001)
    }

    func testResetClearsSamples() throws {
        try requireBenchmarkEnabled()

        ZigNiriLatencyProbe.reset()
        ZigNiriLatencyProbe.record(.layoutPass, elapsedNanoseconds: 2_000_000)
        let before = ZigNiriLatencyProbe.snapshot()
        XCTAssertEqual(before[.layoutPass]?.count, 1)

        ZigNiriLatencyProbe.reset()
        let after = ZigNiriLatencyProbe.snapshot()
        XCTAssertEqual(after[.layoutPass]?.count, 0)
    }

    func testReplayProducesSamplesForAllHotPaths() throws {
        try requireBenchmarkEnabled()
        let report = try benchmarkReport()

        for hotPath in ZigNiriLatencyHotPath.allCases {
            let stats = try XCTUnwrap(report.metrics[hotPath.rawValue])
            XCTAssertGreaterThan(stats.count, 0, "Expected non-zero samples for \(hotPath.rawValue)")
        }
    }

    func testFixtureRespectsSeedMaxWindowsPerColumn() throws {
        let seed = ZigNiriPhase0Scenario.Seed(
            maxWindowsPerColumn: 1,
            maxVisibleColumns: 3,
            gap: 8,
            scale: 2,
            monitor: .init(
                displayId: 424242,
                width: 1440,
                height: 900,
                visibleInsets: .init(left: 0, right: 0, top: 0, bottom: 0)
            ),
            workspaces: [
                .init(name: "bench-primary-seed-check", windowCount: 4),
                .init(name: "bench-secondary-seed-check", windowCount: 2),
            ]
        )

        let fixture = try ZigNiriPhase0ReplayHarness.makeFixture(seed: seed)
        let view = try XCTUnwrap(fixture.engine.workspaceView(for: fixture.primaryWorkspaceId))
        XCTAssertTrue(
            view.columns.allSatisfy { $0.windowIds.count <= seed.maxWindowsPerColumn },
            "Expected fixture to honor seed.maxWindowsPerColumn when constructing the engine"
        )
    }

    func testReplayReproducibilityForCountsAndSchema() throws {
        try requireBenchmarkEnabled()
        let scenario = try loadScenario()

        let first = try ZigNiriPhase0ReplayHarness.runScenario(scenario)
        let second = try ZigNiriPhase0ReplayHarness.runScenario(scenario)

        XCTAssertEqual(Set(first.metrics.keys), Set(second.metrics.keys))
        XCTAssertEqual(first.sampleCounts, second.sampleCounts)
        XCTAssertEqual(first.expectedSamplesByPath, second.expectedSamplesByPath)
        XCTAssertEqual(first.sampleCounts, first.expectedSamplesByPath)
        XCTAssertEqual(second.sampleCounts, second.expectedSamplesByPath)
    }

    func testBaselineContractDecodes() throws {
        let baselineURL = repoRootURL()
            .appendingPathComponent("benchmarks")
            .appendingPathComponent("niri")
            .appendingPathComponent("phase0-baseline.json")

        let data = try Data(contentsOf: baselineURL)
        let baseline = try JSONDecoder().decode(ZigNiriPhase0BenchmarkReport.self, from: data)

        XCTAssertEqual(baseline.schemaVersion, 1)
        for hotPath in ZigNiriLatencyHotPath.allCases {
            XCTAssertNotNil(baseline.metrics[hotPath.rawValue])
        }
    }

    func testReportIsWrittenWhenPathIsConfigured() throws {
        try requireBenchmarkEnabled()
        _ = try benchmarkReport()

        guard let path = ProcessInfo.processInfo.environment["OMNI_NIRI_PHASE0_REPORT_PATH"],
              !path.isEmpty else {
            throw XCTSkip("OMNI_NIRI_PHASE0_REPORT_PATH not set")
        }

        let reportURL = URL(fileURLWithPath: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportURL.path))

        let data = try Data(contentsOf: reportURL)
        let decoded = try JSONDecoder().decode(ZigNiriPhase0BenchmarkReport.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.scenarioName, try loadScenario().name)
    }

    private func benchmarkReport() throws -> ZigNiriPhase0BenchmarkReport {
        if let cached = Self.cachedReport {
            return cached
        }

        let scenario = try loadScenario()
        let report = try ZigNiriPhase0ReplayHarness.runScenario(scenario)
        Self.cachedScenario = scenario
        Self.cachedReport = report
        return report
    }

    private func loadScenario() throws -> ZigNiriPhase0Scenario {
        if let cached = Self.cachedScenario {
            return cached
        }

        guard let url = Bundle.module.url(forResource: "phase0-replay", withExtension: "json") else {
            throw XCTSkip("Missing phase0-replay.json fixture")
        }
        return try ZigNiriPhase0ReplayHarness.loadScenario(from: url)
    }

    private func requireBenchmarkEnabled() throws {
        if !ZigNiriLatencyProbe.isEnabled {
            throw XCTSkip("Set \(ZigNiriLatencyProbe.environmentKey)=1 to run benchmark replay tests")
        }
    }

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

import ApplicationServices
import Foundation

@testable import OmniWM

struct ZigNiriPhase0Scenario: Codable {
    struct Seed: Codable {
        struct Workspace: Codable {
            let name: String
            let windowCount: Int
        }

        struct MonitorSeed: Codable {
            struct Insets: Codable {
                let left: Double
                let right: Double
                let top: Double
                let bottom: Double
            }

            let displayId: UInt32
            let width: Double
            let height: Double
            let visibleInsets: Insets
        }

        let maxWindowsPerColumn: Int
        let maxVisibleColumns: Int
        let gap: Double
        let scale: Double
        let monitor: MonitorSeed
        let workspaces: [Workspace]
    }

    struct Event: Codable {
        enum Kind: String, Codable {
            case layoutPass
            case windowMove
            case resizeDragUpdate
            case navigationStep
            case workspaceMove
        }

        let kind: Kind
        let count: Int
    }

    let name: String
    let warmupIterations: Int
    let measuredIterations: Int
    let seed: Seed
    let events: [Event]
}

struct ZigNiriPhase0BenchmarkReport: Codable {
    let schemaVersion: Int
    let scenarioName: String
    let generatedAt: String
    let warmupIterations: Int
    let measuredIterations: Int
    let sampleCounts: [String: Int]
    let expectedSamplesByPath: [String: Int]
    let metrics: [String: ZigNiriLatencyStats]
}

@MainActor
enum ZigNiriPhase0ReplayHarness {
    private static let reportSchemaVersion = 1
    private static let reportPathEnvironmentKey = "OMNI_NIRI_PHASE0_REPORT_PATH"

    enum Error: Swift.Error, CustomStringConvertible {
        case invalidScenario(String)
        case missingWindow(String)
        case operationFailed(String)

        var description: String {
            switch self {
            case let .invalidScenario(message):
                return "Invalid scenario: \(message)"
            case let .missingWindow(message):
                return "Missing window: \(message)"
            case let .operationFailed(message):
                return "Operation failed: \(message)"
            }
        }
    }

    struct Fixture {
        let engine: ZigNiriEngine
        let monitorFrame: CGRect
        let workingArea: ZigNiriWorkingAreaContext
        let gaps: ZigNiriGaps
        let primaryWorkspaceId: WorkspaceDescriptor.ID
        let secondaryWorkspaceId: WorkspaceDescriptor.ID
        let trackedHandle: WindowHandle
        let trackedNodeId: NodeId
        var trackedWorkspaceId: WorkspaceDescriptor.ID
    }

    static func loadScenario(from url: URL) throws -> ZigNiriPhase0Scenario {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ZigNiriPhase0Scenario.self, from: data)
    }

    static func runScenario(_ scenario: ZigNiriPhase0Scenario) throws -> ZigNiriPhase0BenchmarkReport {
        guard scenario.workspacesCount >= 2 else {
            throw Error.invalidScenario("at least two workspaces are required")
        }
        guard !scenario.events.isEmpty else {
            throw Error.invalidScenario("events cannot be empty")
        }
        guard scenario.warmupIterations >= 0 else {
            throw Error.invalidScenario("warmupIterations cannot be negative")
        }
        guard scenario.measuredIterations > 0 else {
            throw Error.invalidScenario("measuredIterations must be greater than zero")
        }

        for _ in 0 ..< scenario.warmupIterations {
            var fixture = try makeFixture(seed: scenario.seed)
            try replay(events: scenario.events, fixture: &fixture)
        }

        ZigNiriLatencyProbe.reset()

        for _ in 0 ..< scenario.measuredIterations {
            var fixture = try makeFixture(seed: scenario.seed)
            try replay(events: scenario.events, fixture: &fixture)
        }

        let snapshot = ZigNiriLatencyProbe.snapshot()
        let metrics = metricsByName(from: snapshot)
        let sampleCounts = sampleCountsByName(from: metrics)
        let expectedSamples = expectedSamplesByPath(
            events: scenario.events,
            measuredIterations: scenario.measuredIterations
        )

        let report = ZigNiriPhase0BenchmarkReport(
            schemaVersion: reportSchemaVersion,
            scenarioName: scenario.name,
            generatedAt: timestampNowISO8601(),
            warmupIterations: scenario.warmupIterations,
            measuredIterations: scenario.measuredIterations,
            sampleCounts: sampleCounts,
            expectedSamplesByPath: expectedSamples,
            metrics: metrics
        )

        try writeReportIfRequested(report)
        return report
    }

    static func writeReportIfRequested(_ report: ZigNiriPhase0BenchmarkReport) throws {
        guard let outputPath = ProcessInfo.processInfo.environment[reportPathEnvironmentKey],
              !outputPath.isEmpty else {
            return
        }

        let outputURL = URL(fileURLWithPath: outputPath)
        let directoryURL = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: outputURL, options: .atomic)
    }

    static func makeFixture(seed: ZigNiriPhase0Scenario.Seed) throws -> Fixture {
        let monitorFrame = CGRect(
            x: 0,
            y: 0,
            width: seed.monitor.width,
            height: seed.monitor.height
        )
        let visibleFrame = CGRect(
            x: monitorFrame.minX + seed.monitor.visibleInsets.left,
            y: monitorFrame.minY + seed.monitor.visibleInsets.bottom,
            width: max(1, monitorFrame.width - seed.monitor.visibleInsets.left - seed.monitor.visibleInsets.right),
            height: max(1, monitorFrame.height - seed.monitor.visibleInsets.top - seed.monitor.visibleInsets.bottom)
        )

        let engine = ZigNiriEngine(
            maxWindowsPerColumn: seed.maxWindowsPerColumn,
            maxVisibleColumns: seed.maxVisibleColumns,
            infiniteLoop: false
        )

        let primaryWorkspace = WorkspaceDescriptor(name: seed.workspaces[0].name)
        let secondaryWorkspace = WorkspaceDescriptor(name: seed.workspaces[1].name)

        let primaryHandles = makeWindowHandles(count: max(2, seed.workspaces[0].windowCount))
        let secondaryHandles = makeWindowHandles(count: max(1, seed.workspaces[1].windowCount))

        _ = engine.syncWindows(
            primaryHandles,
            in: primaryWorkspace.id,
            selectedNodeId: nil,
            focusedHandle: primaryHandles.first
        )
        _ = engine.syncWindows(
            secondaryHandles,
            in: secondaryWorkspace.id,
            selectedNodeId: nil,
            focusedHandle: secondaryHandles.first
        )

        guard let trackedHandle = primaryHandles.first,
              let trackedNodeId = engine.nodeId(for: trackedHandle) else {
            throw Error.missingWindow("primary workspace has no tracked node")
        }

        _ = engine.syncWindows(
            primaryHandles,
            in: primaryWorkspace.id,
            selectedNodeId: trackedNodeId,
            focusedHandle: trackedHandle
        )

        let workingArea = ZigNiriWorkingAreaContext(
            workingFrame: visibleFrame,
            viewFrame: monitorFrame,
            scale: CGFloat(seed.scale)
        )
        let gaps = ZigNiriGaps(horizontal: CGFloat(seed.gap), vertical: CGFloat(seed.gap))

        return Fixture(
            engine: engine,
            monitorFrame: monitorFrame,
            workingArea: workingArea,
            gaps: gaps,
            primaryWorkspaceId: primaryWorkspace.id,
            secondaryWorkspaceId: secondaryWorkspace.id,
            trackedHandle: trackedHandle,
            trackedNodeId: trackedNodeId,
            trackedWorkspaceId: primaryWorkspace.id
        )
    }

    private static func makeWindowHandles(count: Int) -> [WindowHandle] {
        let pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        return (0 ..< count).map { _ in
            WindowHandle(
                id: UUID(),
                pid: pid,
                axElement: AXUIElementCreateApplication(pid)
            )
        }
    }

    private static func replay(events: [ZigNiriPhase0Scenario.Event], fixture: inout Fixture) throws {
        for event in events {
            let repetitions = max(1, event.count)
            for _ in 0 ..< repetitions {
                try execute(event: event.kind, fixture: &fixture)
            }
        }
    }

    private static func execute(event: ZigNiriPhase0Scenario.Event.Kind, fixture: inout Fixture) throws {
        switch event {
        case .layoutPass:
            _ = fixture.engine.calculateLayout(
                ZigNiriLayoutRequest(
                    workspaceId: fixture.trackedWorkspaceId,
                    monitorFrame: fixture.monitorFrame,
                    screenFrame: nil,
                    gaps: fixture.gaps,
                    scale: fixture.workingArea.scale,
                    workingArea: fixture.workingArea,
                    orientation: .horizontal,
                    viewportOffset: 0
                )
            )

        case .windowMove:
            let result = fixture.engine.applyMutation(
                .moveWindow(
                    windowId: fixture.trackedNodeId,
                    direction: .up,
                    orientation: .horizontal
                ),
                in: fixture.trackedWorkspaceId
            )
            guard result.applied else {
                throw Error.operationFailed("moveWindow mutation did not apply")
            }

        case .resizeDragUpdate:
            guard fixture.engine.beginInteractiveResize(
                ZigNiriInteractiveResizeState(
                    windowId: fixture.trackedNodeId,
                    workspaceId: fixture.trackedWorkspaceId,
                    edges: [.right],
                    startMouseLocation: CGPoint(x: 100, y: 100)
                )
            ) else {
                throw Error.operationFailed("beginInteractiveResize returned false")
            }

            let updateResult = fixture.engine.updateInteractiveResize(mouseLocation: CGPoint(x: 124, y: 100))
            guard updateResult.applied else {
                throw Error.operationFailed("updateInteractiveResize did not apply")
            }

            _ = fixture.engine.endInteractiveResize(commit: true)

        case .navigationStep:
            let result = fixture.engine.applyNavigation(
                .focusWindow(index: 1),
                in: fixture.trackedWorkspaceId,
                orientation: .horizontal
            )
            guard result.applied else {
                throw Error.operationFailed("navigation request did not apply")
            }

        case .workspaceMove:
            let sourceWorkspaceId = fixture.trackedWorkspaceId
            let targetWorkspaceId = sourceWorkspaceId == fixture.primaryWorkspaceId
                ? fixture.secondaryWorkspaceId
                : fixture.primaryWorkspaceId

            let result = fixture.engine.applyWorkspace(
                .moveWindow(windowId: fixture.trackedNodeId, targetWorkspaceId: targetWorkspaceId),
                in: sourceWorkspaceId
            )
            guard result.applied else {
                throw Error.operationFailed("workspace move did not apply")
            }
            fixture.trackedWorkspaceId = targetWorkspaceId
        }
    }

    private static func metricsByName(
        from snapshot: [ZigNiriLatencyHotPath: ZigNiriLatencyStats]
    ) -> [String: ZigNiriLatencyStats] {
        var metrics: [String: ZigNiriLatencyStats] = [:]
        metrics.reserveCapacity(ZigNiriLatencyHotPath.allCases.count)

        for hotPath in ZigNiriLatencyHotPath.allCases {
            metrics[hotPath.rawValue] = snapshot[hotPath] ?? .empty
        }
        return metrics
    }

    private static func sampleCountsByName(from metrics: [String: ZigNiriLatencyStats]) -> [String: Int] {
        var counts: [String: Int] = [:]
        counts.reserveCapacity(metrics.count)
        for (key, stats) in metrics {
            counts[key] = stats.count
        }
        return counts
    }

    private static func expectedSamplesByPath(
        events: [ZigNiriPhase0Scenario.Event],
        measuredIterations: Int
    ) -> [String: Int] {
        var perIteration: [ZigNiriLatencyHotPath: Int] = Dictionary(
            uniqueKeysWithValues: ZigNiriLatencyHotPath.allCases.map { ($0, 0) }
        )

        for event in events {
            let repetitions = max(1, event.count)
            switch event.kind {
            case .layoutPass:
                perIteration[.layoutPass, default: 0] += repetitions
            case .windowMove:
                perIteration[.windowMove, default: 0] += repetitions
            case .resizeDragUpdate:
                perIteration[.resizeDragUpdate, default: 0] += repetitions
            case .navigationStep:
                perIteration[.navigationStep, default: 0] += repetitions
            case .workspaceMove:
                perIteration[.workspaceMove, default: 0] += repetitions
            }
        }

        var expected: [String: Int] = [:]
        expected.reserveCapacity(ZigNiriLatencyHotPath.allCases.count)
        for hotPath in ZigNiriLatencyHotPath.allCases {
            let count = (perIteration[hotPath] ?? 0) * measuredIterations
            expected[hotPath.rawValue] = count
        }
        return expected
    }

    private static func timestampNowISO8601() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

private extension ZigNiriPhase0Scenario {
    var workspacesCount: Int {
        seed.workspaces.count
    }
}

// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class DiagnosticsTraceCaptureTests: XCTestCase {
    @MainActor
    func testTraceCaptureToggleLifecycle() async throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = WMController(settings: makeSettingsStore(), diagnosticsDirectory: directory)

        XCTAssertFalse(controller.isTraceCaptureActive)

        guard case .started = await controller.toggleTraceCaptureForUI(desiredState: .active) else {
            return XCTFail("expected capture to start")
        }
        XCTAssertTrue(controller.isTraceCaptureActive)
        XCTAssertNotNil(controller.traceCaptureStatus.startedAt)

        guard case .noChange = await controller.toggleTraceCaptureForUI(desiredState: .active) else {
            return XCTFail("expected no change when already active")
        }

        guard case .stopped = await controller.toggleTraceCaptureForUI(desiredState: .inactive) else {
            return XCTFail("expected capture to stop and produce an artifact")
        }
        XCTAssertFalse(controller.isTraceCaptureActive)
        XCTAssertNil(controller.traceCaptureStatus.startedAt)
    }

    @MainActor
    func testTraceCaptureRemovesPartialSidecarOnStop() async throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = WMController(settings: makeSettingsStore(), diagnosticsDirectory: directory)

        _ = await controller.toggleTraceCaptureForUI(desiredState: .active)
        _ = await controller.toggleTraceCaptureForUI(desiredState: .inactive)

        let partials = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasSuffix(".partial.log") } ?? []
        XCTAssertTrue(partials.isEmpty)
    }

    @MainActor
    func testRuntimeDiagnosticsReportBuildsAllSections() throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = WMController(settings: makeSettingsStore(), diagnosticsDirectory: directory)

        let report = RuntimeDiagnosticsReport.build(controller, traceLimit: 50)

        for header in [
            "== OmniWM Diagnostics ==",
            "== Active Issues ==",
            "== Space Topology ==",
            "== AX Frame State ==",
            "== Settings (TOML) =="
        ] {
            XCTAssertTrue(report.contains(header), "missing report section \(header)")
        }
    }

    @MainActor
    func testStartRecordingWipesStaleTracesButPreservesCrashLogsAndUnrelatedFiles() async throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let staleTrace = directory.appendingPathComponent("omniwm-trace-1-2.log", isDirectory: false)
        let unrelated = directory.appendingPathComponent("unrelated.dat", isDirectory: false)
        let crashLog = directory.appendingPathComponent("omniwm-crash-1.log", isDirectory: false)
        try Data("stale".utf8).write(to: staleTrace)
        try Data("stale".utf8).write(to: unrelated)
        try Data("boom".utf8).write(to: crashLog)

        let controller = WMController(settings: makeSettingsStore(), diagnosticsDirectory: directory)

        _ = await controller.toggleTraceCaptureForUI(desiredState: .active)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleTrace.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: crashLog.path))

        guard case let .stopped(artifact) = await controller.toggleTraceCaptureForUI(desiredState: .inactive) else {
            return XCTFail("expected capture to stop")
        }

        let traces = traceLogs(in: directory)
        XCTAssertEqual(traces, [artifact.url.lastPathComponent])
        XCTAssertFalse(traces.contains { $0.hasSuffix(".partial.log") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: crashLog.path))
    }

    @MainActor
    func testStartRecordingFailsCleanlyWhenDirectoryUnusable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMDiagBlock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("blocker", isDirectory: false)
        try Data("x".utf8).write(to: blocker)
        let unusable = blocker.appendingPathComponent("diagnostics", isDirectory: true)

        let controller = WMController(settings: makeSettingsStore(), diagnosticsDirectory: unusable)

        guard case .writeFailed = await controller.toggleTraceCaptureForUI(desiredState: .active) else {
            return XCTFail("expected .writeFailed when the diagnostics directory cannot be created")
        }
        XCTAssertFalse(controller.isTraceCaptureActive)
    }

    @MainActor
    func testReplacementRecordingClearsLastArtifactAfterInitialPartialSucceeds() async throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = RuntimeTraceCaptureCoordinator(diagnosticsDirectory: directory, recorders: [])

        _ = await coordinator.toggle(desiredState: .active, reportProvider: { "report" })
        guard case let .stopped(first) = await coordinator.toggle(
            desiredState: .inactive,
            reportProvider: { "report" }
        ) else {
            return XCTFail("expected first capture artifact")
        }
        XCTAssertEqual(coordinator.status.lastArtifact, first)

        guard case .started = await coordinator.toggle(desiredState: .active, reportProvider: { "report" }) else {
            return XCTFail("expected replacement capture to start")
        }
        XCTAssertNil(coordinator.status.lastArtifact)

        _ = await coordinator.toggle(desiredState: .inactive, reportProvider: { "report" })
    }

    @MainActor
    func testFailedReplacementRecordingPreservesLastArtifact() async throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = RuntimeTraceCaptureCoordinator(diagnosticsDirectory: directory, recorders: [])

        _ = await coordinator.toggle(desiredState: .active, reportProvider: { "report" })
        guard case let .stopped(first) = await coordinator.toggle(
            desiredState: .inactive,
            reportProvider: { "report" }
        ) else {
            return XCTFail("expected first capture artifact")
        }
        try FileManager.default.removeItem(at: directory)
        try Data("blocker".utf8).write(to: directory)

        guard case .writeFailed = await coordinator.toggle(desiredState: .active, reportProvider: { "report" }) else {
            return XCTFail("expected replacement capture to fail")
        }
        XCTAssertEqual(coordinator.status.lastArtifact, first)
    }

    @MainActor
    func testSnapshotReportReplacesPriorReportWithoutCreatingZipOrSidecar() throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = WMController(settings: makeSettingsStore(), diagnosticsDirectory: directory)

        let staleReport = directory.appendingPathComponent("omniwm-diagnostics-stale.log", isDirectory: false)
        let partial = directory.appendingPathComponent("omniwm-trace-1.partial.log", isDirectory: false)
        let trace = directory.appendingPathComponent("omniwm-trace-1-2.log", isDirectory: false)
        try Data("stale-report".utf8).write(to: staleReport)
        try Data("partial".utf8).write(to: partial)
        try Data("trace".utf8).write(to: trace)

        let report = try controller.writeDiagnosticsReport()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleReport.path), "prior report should be replaced")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trace.path), "completed trace should be preserved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path), "partial log should be preserved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.path))
        XCTAssertEqual(report.pathExtension, "log")
        XCTAssertFalse(
            (try FileManager.default.contentsOfDirectory(atPath: directory.path)).contains { $0.hasSuffix(".zip") }
        )
    }

    @MainActor
    func testSnapshotReportIncludesEffectiveSettingsWithoutRedaction() throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettingsStore()
        settings.focusFollowsMouse = true

        let controller = WMController(settings: settings, diagnosticsDirectory: directory)
        let report = try controller.writeDiagnosticsReport()
        let content = try String(contentsOf: report, encoding: .utf8)

        XCTAssertTrue(content.contains("== Settings (TOML) =="))
        XCTAssertTrue(content.contains("followsMouse = true"))
        XCTAssertFalse(content.contains("<redacted>"), "redaction must not sneak back in")
    }

    @MainActor
    func testDiagnosticAttachmentCombinesFreshReportWithExactCrashEvidence() async throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crash = directory.appendingPathComponent("omniwm-crash-1.log", isDirectory: false)
        let unrelated = directory.appendingPathComponent("omniwm-trace-1-2.log", isDirectory: false)
        try "exact-crash-evidence".write(to: crash, atomically: true, encoding: .utf8)
        try "unrelated-trace-evidence".write(to: unrelated, atomically: true, encoding: .utf8)
        let controller = WMController(settings: makeSettingsStore(), diagnosticsDirectory: directory)

        let result = try await controller.prepareDiagnosticAttachment(evidence: .crash(crash))
        let body = try String(contentsOf: result.url, encoding: .utf8)

        XCTAssertTrue(result.includedEvidence)
        XCTAssertNotEqual(result.url, crash)
        XCTAssertTrue(body.hasPrefix("== OmniWM Diagnostics =="))
        XCTAssertTrue(body.contains("evidenceStatus=included"))
        XCTAssertTrue(body.contains("evidenceType=crash"))
        XCTAssertTrue(body.contains("exact-crash-evidence"))
        XCTAssertFalse(body.contains("unrelated-trace-evidence"))
    }

    @MainActor
    func testDiagnosticAttachmentIncludesOnlyExplicitTraceArtifact() async throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selected = directory.appendingPathComponent("omniwm-trace-1-2.log", isDirectory: false)
        let newer = directory.appendingPathComponent("omniwm-trace-3-4.log", isDirectory: false)
        try "selected-trace-evidence".write(to: selected, atomically: true, encoding: .utf8)
        try "newer-unselected-evidence".write(to: newer, atomically: true, encoding: .utf8)
        let controller = WMController(settings: makeSettingsStore(), diagnosticsDirectory: directory)
        let artifact = TraceCaptureArtifact(url: selected, startedAt: Date(timeIntervalSince1970: 1), endedAt: Date())

        let result = try await controller.prepareDiagnosticAttachment(evidence: .trace(artifact))
        let body = try String(contentsOf: result.url, encoding: .utf8)

        XCTAssertTrue(result.includedEvidence)
        XCTAssertTrue(body.contains("evidenceType=trace"))
        XCTAssertTrue(body.contains("selected-trace-evidence"))
        XCTAssertFalse(body.contains("newer-unselected-evidence"))
    }

    @MainActor
    func testMissingSelectedEvidenceProducesFreshOnlyAttachment() async throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unrelated = directory.appendingPathComponent("omniwm-crash-newer.log", isDirectory: false)
        try "unrelated-crash-evidence".write(to: unrelated, atomically: true, encoding: .utf8)
        let controller = WMController(settings: makeSettingsStore(), diagnosticsDirectory: directory)
        let missing = directory.appendingPathComponent("missing.log", isDirectory: false)

        let result = try await controller.prepareDiagnosticAttachment(evidence: .crash(missing))
        let body = try String(contentsOf: result.url, encoding: .utf8)

        XCTAssertFalse(result.includedEvidence)
        XCTAssertTrue(result.url.lastPathComponent.hasPrefix("omniwm-diagnostics-"))
        XCTAssertTrue(body.hasPrefix("== OmniWM Diagnostics =="))
        XCTAssertTrue(body.contains("evidenceStatus=unavailable"))
        XCTAssertFalse(body.contains("unrelated-crash-evidence"))
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(contents.contains { $0.hasSuffix(".zip") || $0.hasSuffix(".tmp") })
    }

    @MainActor
    func testDiagnosticAttachmentWithoutEvidenceContainsFreshSnapshot() async throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = WMController(settings: makeSettingsStore(), diagnosticsDirectory: directory)

        let result = try await controller.prepareDiagnosticAttachment(evidence: nil)
        let body = try String(contentsOf: result.url, encoding: .utf8)

        XCTAssertFalse(result.includedEvidence)
        XCTAssertTrue(body.hasPrefix("== OmniWM Diagnostics =="))
        XCTAssertTrue(body.contains("evidenceStatus=not_selected"))
    }

    @MainActor
    func testDiagnosticAttachmentUsesSubmissionTimeSettingsBeforeSelectedEvidence() async throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettingsStore()
        let controller = WMController(settings: settings, diagnosticsDirectory: directory)
        let trace = directory.appendingPathComponent("omniwm-trace-settings.log", isDirectory: false)
        try "== Evidence Settings ==\nfollowsMouse = false".write(to: trace, atomically: true, encoding: .utf8)
        settings.focusFollowsMouse = true
        let artifact = TraceCaptureArtifact(url: trace, startedAt: Date(timeIntervalSince1970: 1), endedAt: Date())

        let result = try await controller.prepareDiagnosticAttachment(evidence: .trace(artifact))
        let body = try String(contentsOf: result.url, encoding: .utf8)
        let freshSettings = try XCTUnwrap(body.range(of: "followsMouse = true"))
        let evidenceHeader = try XCTUnwrap(body.range(of: "== Selected Diagnostic Evidence =="))
        let evidenceSettings = try XCTUnwrap(body.range(of: "followsMouse = false"))

        XCTAssertLessThan(freshSettings.lowerBound, evidenceHeader.lowerBound)
        XCTAssertLessThan(evidenceHeader.lowerBound, evidenceSettings.lowerBound)
    }

    private func makeDiagnosticsDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMDiagnosticsCapture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func traceLogs(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .map(\.lastPathComponent)
            .filter { $0.hasPrefix("omniwm-trace-") }
            .sorted()
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
        return SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
    }
}

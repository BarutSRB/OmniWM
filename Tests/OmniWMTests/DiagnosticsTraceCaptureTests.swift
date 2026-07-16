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
    func testStartRecordingWipesStaleTracesButPreservesCrashLogsAndBundles() async throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let staleTrace = directory.appendingPathComponent("omniwm-trace-1-2.log", isDirectory: false)
        let staleBundle = directory.appendingPathComponent("omniwm-bundle-1.zip", isDirectory: false)
        let crashLog = directory.appendingPathComponent("omniwm-crash-1.log", isDirectory: false)
        try Data("stale".utf8).write(to: staleTrace)
        try Data("stale".utf8).write(to: staleBundle)
        try Data("boom".utf8).write(to: crashLog)

        let controller = WMController(settings: makeSettingsStore(), diagnosticsDirectory: directory)

        _ = await controller.toggleTraceCaptureForUI(desiredState: .active)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleTrace.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staleBundle.path))
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
    func testBundleReplacesPriorReportAndBundleAndExcludesZipsAndPartials() throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = WMController(settings: makeSettingsStore(), diagnosticsDirectory: directory)

        let staleBundle = directory.appendingPathComponent("omniwm-bundle-stale.zip", isDirectory: false)
        let staleReport = directory.appendingPathComponent("omniwm-diagnostics-stale.log", isDirectory: false)
        let partial = directory.appendingPathComponent("omniwm-trace-1.partial.log", isDirectory: false)
        let trace = directory.appendingPathComponent("omniwm-trace-1-2.log", isDirectory: false)
        try Data("stale-bundle".utf8).write(to: staleBundle)
        try Data("stale-report".utf8).write(to: staleReport)
        try Data("partial".utf8).write(to: partial)
        try Data("trace".utf8).write(to: trace)

        let bundle = try controller.writeDiagnosticsBundle()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleBundle.path), "prior bundle should be replaced")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleReport.path), "prior report should be replaced")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trace.path), "completed trace should be preserved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path), "partial log should be preserved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))

        let entries = zipEntryNames(bundle)
        XCTAssertFalse(entries.isEmpty, "bundle should contain the diagnostics report")
        XCTAssertFalse(entries.contains { $0.hasSuffix(".zip") }, "bundle must not nest any bundle zips")
        XCTAssertFalse(entries.contains { $0.contains(".partial.log") }, "bundle must exclude in-progress partials")
    }

    @MainActor
    func testBundleIncludesUserConfigVerbatim() throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettingsStore()
        let configURL = settings.settingsFileURL
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "# my comment\napiKey = \"super-secret\"\nfocusFollowsMouse = true\n"
            .write(to: configURL, atomically: true, encoding: .utf8)

        let controller = WMController(settings: settings, diagnosticsDirectory: directory)
        let bundle = try controller.writeDiagnosticsBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }

        XCTAssertTrue(
            zipEntryNames(bundle).contains { $0.hasSuffix("settings.toml") },
            "bundle should include settings.toml"
        )
        let content = unzipEntry(bundle, matching: "*settings.toml")
        XCTAssertTrue(content.contains("# my comment"), "raw comment should be preserved")
        XCTAssertTrue(content.contains("focusFollowsMouse"), "config line should be preserved")
        XCTAssertTrue(content.contains("super-secret"), "unknown keys are bundled verbatim (no redaction)")
        XCTAssertFalse(content.contains("<redacted>"), "redaction must not sneak back in")
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

    private func unzipEntry(_ bundle: URL, matching pattern: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", bundle.path, pattern]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func zipEntryNames(_ url: URL) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
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

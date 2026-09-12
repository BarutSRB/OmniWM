// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class TraceCaptureLifecycleTests: XCTestCase {
    func testFinalizationObserversRetainRecordsUntilTheOutcomeReturns() async throws {
        let directory = makeDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = SessionTraceRecorder<String>(sectionTitle: "Lifecycle", capacity: 8) { $0 }
        let coordinator = makeCoordinator(directory: directory, recorder: recorder)
        var events: [String] = []
        coordinator.onStateChange = { [weak coordinator] in
            guard let coordinator else { return XCTFail("Coordinator must survive its callback") }
            events.append("\(coordinator.status.phase):\(recorder.isActive):\(recorder.isStoragePrepared)")
        }
        defer { coordinator.onStateChange = nil }

        guard case .started = await coordinator.toggle(
            desiredState: .active,
            reportProvider: {
                events.append("report:\(recorder.isActive):\(recorder.isStoragePrepared)")
                return "report"
            },
            automaticEvidenceProvider: {
                events.append("evidence:\(recorder.isActive):\(recorder.isStoragePrepared)")
                return "evidence"
            }
        ) else { return XCTFail("Expected capture to start") }
        guard case .stopped = await coordinator.toggle(
            desiredState: .inactive,
            reportProvider: { XCTFail("Must use accepted provider")
                return "unexpected"
            }
        ) else { return XCTFail("Expected capture to stop") }
        events.append("returned:\(recorder.isActive):\(recorder.isStoragePrepared)")

        XCTAssertEqual(events, [
            "starting:false:false", "report:true:true", "recording:true:true",
            "finalizing:true:true", "report:false:true", "evidence:false:true",
            "idle:false:true", "returned:false:false"
        ])
    }

    func testFailedStartReleasesRecordsBeforePublishingIdle() async throws {
        let directory = makeDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appendingPathComponent("blocked")
        try Data("file".utf8).write(to: blocked)
        let recorder = SessionTraceRecorder<String>(sectionTitle: "Lifecycle", capacity: 8) { $0 }
        let coordinator = makeCoordinator(directory: blocked, recorder: recorder)
        var events: [String] = []
        coordinator.onStateChange = { [weak coordinator] in
            guard let coordinator else { return XCTFail("Coordinator must survive its callback") }
            events.append("\(coordinator.status.phase):\(recorder.isActive):\(recorder.isStoragePrepared)")
        }
        defer { coordinator.onStateChange = nil }

        guard case .writeFailed = await coordinator.toggle(
            desiredState: .active,
            reportProvider: {
                events.append("report:\(recorder.isActive):\(recorder.isStoragePrepared)")
                return "report"
            }
        ) else { return XCTFail("Expected initial write to fail") }

        XCTAssertEqual(events, [
            "starting:false:false", "report:true:true", "recording:true:true", "idle:false:false"
        ])
        XCTAssertFalse(recorder.isStoragePrepared)
        XCTAssertFalse(recorder.isSpareStoragePrepared)
    }

    private func makeDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TraceLifecycle-\(UUID().uuidString)")
    }

    private func makeCoordinator(
        directory: URL,
        recorder: SessionTraceRecorder<String>
    ) -> RuntimeTraceCaptureCoordinator {
        RuntimeTraceCaptureCoordinator(
            diagnosticsDirectory: directory,
            recorders: [recorder],
            diagnosticsEventRecorder: DiagnosticsEventRecorder()
        )
    }
}

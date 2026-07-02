// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import Observation

enum TraceCaptureDesiredState {
    case active
    case inactive
    case toggle
}

struct TraceCaptureSession {
    let startedAt: Date
    let startReport: String
}

struct TraceCaptureArtifact: Equatable {
    let url: URL
    let startedAt: Date
    let endedAt: Date
}

struct TraceCaptureStatus: Equatable {
    let isActive: Bool
    let startedAt: Date?
    let lastArtifact: TraceCaptureArtifact?
}

enum TraceCaptureOutcome {
    case started
    case stopped(TraceCaptureArtifact)
    case noChange
    case writeFailed(String)
}

@MainActor @Observable
final class RuntimeTraceCaptureCoordinator {
    private static let flushIntervalSeconds = 15
    private static let maxCaptureSeconds = 600

    private var session: TraceCaptureSession?
    private var reportProvider: (() -> String)?
    private var captureTask: Task<Void, Never>?
    private(set) var lastArtifact: TraceCaptureArtifact?
    var onStateChange: (() -> Void)?
    private let recorders: [any RuntimeTraceRecording]
    private let diagnosticsDirectory: URL

    init(
        diagnosticsDirectory: URL = OmniWMStoragePaths.live.diagnosticsDirectory,
        recorders: [any RuntimeTraceRecording] = [
            RawAXNotificationTrace.shared,
            FrameApplyTrace.shared,
            NiriLayoutTrace.shared,
            AnimationTickTrace.shared,
            ParkVisibilityAudit.shared,
            ScrollTickTrace.shared,
            AXWriteLatencyTrace.shared,
            BorderOpMetricsRecorder.shared,
            MouseTrace.shared,
            InputTrace.shared
        ]
    ) {
        self.diagnosticsDirectory = diagnosticsDirectory
        self.recorders = recorders
    }

    var isActive: Bool {
        session != nil
    }

    var status: TraceCaptureStatus {
        TraceCaptureStatus(isActive: isActive, startedAt: session?.startedAt, lastArtifact: lastArtifact)
    }

    func toggle(desiredState: TraceCaptureDesiredState, reportProvider: @escaping () -> String) -> TraceCaptureOutcome {
        switch desiredState {
        case .active:
            return isActive ? .noChange : start(reportProvider: reportProvider)
        case .inactive:
            return isActive ? finalize() : .noChange
        case .toggle:
            return isActive ? finalize() : start(reportProvider: reportProvider)
        }
    }

    private func start(reportProvider: @escaping () -> String) -> TraceCaptureOutcome {
        DiagnosticsEventRecorder.shared.beginVerboseCapture()
        recorders.forEach { $0.beginCapture() }
        self.reportProvider = reportProvider
        let session = TraceCaptureSession(startedAt: Date(), startReport: reportProvider())
        self.session = session

        let partialURL: URL
        do {
            partialURL = try writePartial(session: session)
        } catch {
            DiagnosticsEventRecorder.shared.endVerboseCapture()
            recorders.forEach { $0.endCapture() }
            self.session = nil
            self.reportProvider = nil
            return .writeFailed(error.localizedDescription)
        }

        DiagnosticsRetention.wipe(directory: diagnosticsDirectory, prefixes: ["omniwm-trace-"], except: [partialURL])
        startCaptureTask()
        onStateChange?()
        return .started
    }

    private func startCaptureTask() {
        let maxFlushes = Self.maxCaptureSeconds / Self.flushIntervalSeconds
        captureTask = Task { [weak self] in
            var flushes = 0
            while flushes < maxFlushes {
                try? await Task.sleep(for: .seconds(Self.flushIntervalSeconds))
                if Task.isCancelled { return }
                guard let self else { return }
                writePartial()
                flushes += 1
            }
            if Task.isCancelled { return }
            self?.captureTask = nil
            self?.finalize()
        }
    }

    @discardableResult
    private func finalize() -> TraceCaptureOutcome {
        guard let session else { return .noChange }
        captureTask?.cancel()
        captureTask = nil

        let endedAt = Date()
        let endReport = reportProvider?() ?? "report unavailable"
        let lifecycleEvents = DiagnosticsEventRecorder.shared.dumpLifecycle()
        let verboseEvents = DiagnosticsEventRecorder.shared.dumpVerbose()
        DiagnosticsEventRecorder.shared.endVerboseCapture()
        recorders.forEach { $0.endCapture() }
        self.session = nil
        reportProvider = nil

        let body = buildBody(
            session: session,
            endedAt: endedAt,
            lifecycleEvents: lifecycleEvents,
            verboseEvents: verboseEvents,
            endReport: endReport
        )

        do {
            let directory = diagnosticsDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let filename = "omniwm-trace-\(milliseconds(session.startedAt))-\(milliseconds(endedAt)).log"
            let url = directory.appendingPathComponent(filename, isDirectory: false)
            try body.write(to: url, atomically: true, encoding: .utf8)
            removePartial(startedAt: session.startedAt)
            let artifact = TraceCaptureArtifact(url: url, startedAt: session.startedAt, endedAt: endedAt)
            lastArtifact = artifact
            onStateChange?()
            return .stopped(artifact)
        } catch {
            onStateChange?()
            return .writeFailed(error.localizedDescription)
        }
    }

    private func writePartial() {
        guard let session else { return }
        _ = try? writePartial(session: session)
    }

    @discardableResult
    private func writePartial(session: TraceCaptureSession) throws -> URL {
        let body = buildBody(
            session: session,
            endedAt: nil,
            lifecycleEvents: DiagnosticsEventRecorder.shared.dumpLifecycle(),
            verboseEvents: DiagnosticsEventRecorder.shared.dumpVerbose(),
            endReport: nil
        )
        let directory = diagnosticsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(partialFilename(startedAt: session.startedAt), isDirectory: false)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func removePartial(startedAt: Date) {
        let url = diagnosticsDirectory
            .appendingPathComponent(partialFilename(startedAt: startedAt), isDirectory: false)
        try? FileManager.default.removeItem(at: url)
    }

    private func buildBody(
        session: TraceCaptureSession,
        endedAt: Date?,
        lifecycleEvents: String,
        verboseEvents: String,
        endReport: String?
    ) -> String {
        var lines = [
            "== OmniWM Trace Capture ==",
            "startedAt=\(session.startedAt.ISO8601Format())",
            endedAt.map { "endedAt=\($0.ISO8601Format())" } ?? "status=in-progress (partial)",
            "",
            "== State At Start ==",
            session.startReport,
            "",
            "== Lifecycle Events (recent, always-on) ==",
            lifecycleEvents,
            "",
            "== Verbose Window Events (capture window) ==",
            verboseEvents
        ]
        for recorder in recorders {
            lines.append(contentsOf: ["", "== \(recorder.sectionTitle) ==", recorder.dump()])
        }
        if let endReport {
            lines.append(contentsOf: ["", "== State At End ==", endReport])
        }
        return lines.joined(separator: "\n")
    }

    private func partialFilename(startedAt: Date) -> String {
        "omniwm-trace-\(milliseconds(startedAt)).partial.log"
    }

    private func milliseconds(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 * 1000)
    }
}

// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import Observation

enum TraceCaptureDesiredState {
    case active
    case inactive
    case toggle
}

enum TraceCapturePhase: Equatable {
    case idle
    case recording
    case finalizing
}

struct TraceCaptureSession: Sendable {
    let startedAt: Date
    let startReport: String
}

struct TraceCaptureArtifact: Equatable, Sendable {
    let url: URL
    let startedAt: Date
    let endedAt: Date
}

struct TraceCaptureStatus: Equatable {
    let phase: TraceCapturePhase
    let startedAt: Date?
    let lastArtifact: TraceCaptureArtifact?

    var isActive: Bool {
        phase != .idle
    }
}

enum TraceCaptureOutcome {
    case started
    case stopped(TraceCaptureArtifact)
    case noChange
    case writeFailed(String)
}

private actor TraceCaptureFileWriter {
    private let diagnosticsDirectory: URL

    init(diagnosticsDirectory: URL) {
        self.diagnosticsDirectory = diagnosticsDirectory
    }

    func writeInitialPartial(
        session: TraceCaptureSession,
        recorders: [any RuntimeTraceRecording]
    ) throws -> URL {
        let url = try writePartial(session: session, recorders: recorders)
        DiagnosticsRetention.wipe(
            directory: diagnosticsDirectory,
            prefixes: ["omniwm-trace-"],
            except: [url]
        )
        return url
    }

    func writePartial(
        session: TraceCaptureSession,
        recorders: [any RuntimeTraceRecording]
    ) throws -> URL {
        let body = buildBody(
            session: session,
            endedAt: nil,
            lifecycleEvents: DiagnosticsEventRecorder.shared.dumpLifecycle(),
            verboseEvents: DiagnosticsEventRecorder.shared.dumpVerbose(),
            recorders: recorders,
            automaticEvidence: nil,
            endReport: nil
        )
        try FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
        let url = diagnosticsDirectory.appendingPathComponent(
            partialFilename(startedAt: session.startedAt),
            isDirectory: false
        )
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func writeFinal(
        session: TraceCaptureSession,
        endedAt: Date,
        recorders: [any RuntimeTraceRecording],
        automaticEvidence: String,
        endReport: String
    ) throws -> URL {
        let lifecycleEvents = DiagnosticsEventRecorder.shared.dumpLifecycle()
        let verboseEvents = DiagnosticsEventRecorder.shared.dumpVerbose()
        let body = buildBody(
            session: session,
            endedAt: endedAt,
            lifecycleEvents: lifecycleEvents,
            verboseEvents: verboseEvents,
            recorders: recorders,
            automaticEvidence: automaticEvidence,
            endReport: endReport
        )
        try FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
        let filename = "omniwm-trace-\(milliseconds(session.startedAt))-\(milliseconds(endedAt)).log"
        let url = diagnosticsDirectory.appendingPathComponent(filename, isDirectory: false)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(
            at: diagnosticsDirectory.appendingPathComponent(
                partialFilename(startedAt: session.startedAt),
                isDirectory: false
            )
        )
        return url
    }

    private func buildBody(
        session: TraceCaptureSession,
        endedAt: Date?,
        lifecycleEvents: String,
        verboseEvents: String,
        recorders: [any RuntimeTraceRecording],
        automaticEvidence: String?,
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
        if let automaticEvidence {
            lines.append(contentsOf: ["", "== Automatic AX Evidence ==", automaticEvidence])
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

@MainActor @Observable
final class RuntimeTraceCaptureCoordinator {
    private static let flushIntervalSeconds = 15
    private static let maxCaptureSeconds = 600

    private var phase: TraceCapturePhase = .idle
    private var session: TraceCaptureSession?
    private var reportProvider: (() -> String)?
    private var automaticEvidenceProvider: (() async -> String)?
    private var captureTask: Task<Void, Never>?
    private(set) var lastArtifact: TraceCaptureArtifact?
    var onStateChange: (() -> Void)?
    private let recorders: [any RuntimeTraceRecording]
    private let writer: TraceCaptureFileWriter

    init(
        diagnosticsDirectory: URL = OmniWMStoragePaths.live.diagnosticsDirectory,
        recorders: [any RuntimeTraceRecording] = [
            WindowAdmissionTrace.shared,
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
        writer = TraceCaptureFileWriter(diagnosticsDirectory: diagnosticsDirectory)
        self.recorders = recorders
    }

    var isActive: Bool {
        phase != .idle
    }

    var status: TraceCaptureStatus {
        TraceCaptureStatus(phase: phase, startedAt: session?.startedAt, lastArtifact: lastArtifact)
    }

    func toggle(
        desiredState: TraceCaptureDesiredState,
        reportProvider: @escaping () -> String,
        automaticEvidenceProvider: @escaping () async -> String = { "none" }
    ) async -> TraceCaptureOutcome {
        switch desiredState {
        case .active:
            return phase == .idle
                ? await start(
                    reportProvider: reportProvider,
                    automaticEvidenceProvider: automaticEvidenceProvider
                )
                : .noChange
        case .inactive:
            return phase == .recording ? await stop() : .noChange
        case .toggle:
            return phase == .idle
                ? await start(
                    reportProvider: reportProvider,
                    automaticEvidenceProvider: automaticEvidenceProvider
                )
                : phase == .recording ? await stop() : .noChange
        }
    }

    private func start(
        reportProvider: @escaping () -> String,
        automaticEvidenceProvider: @escaping () async -> String
    ) async -> TraceCaptureOutcome {
        DiagnosticsEventRecorder.shared.beginVerboseCapture()
        recorders.forEach { $0.beginCapture() }
        self.reportProvider = reportProvider
        self.automaticEvidenceProvider = automaticEvidenceProvider
        let session = TraceCaptureSession(startedAt: Date(), startReport: reportProvider())
        self.session = session
        phase = .recording
        lastArtifact = nil
        onStateChange?()

        do {
            _ = try await writer.writeInitialPartial(session: session, recorders: recorders)
            guard phase == .recording,
                  self.session?.startedAt == session.startedAt
            else { return .noChange }
        } catch {
            guard phase == .recording,
                  self.session?.startedAt == session.startedAt
            else { return .noChange }
            DiagnosticsEventRecorder.shared.endVerboseCapture()
            recorders.forEach { $0.endCapture() }
            self.session = nil
            self.reportProvider = nil
            self.automaticEvidenceProvider = nil
            phase = .idle
            onStateChange?()
            return .writeFailed(error.localizedDescription)
        }

        startCaptureTask()
        return .started
    }

    private func startCaptureTask() {
        captureTask = Task { [weak self] in
            let maxFlushes = Self.maxCaptureSeconds / Self.flushIntervalSeconds
            for _ in 0 ..< maxFlushes {
                do {
                    try await Task.sleep(for: .seconds(Self.flushIntervalSeconds))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                await self.writePartial()
            }
            guard !Task.isCancelled, let self else { return }
            self.captureTask = nil
            _ = await self.finalize()
        }
    }

    private func stop() async -> TraceCaptureOutcome {
        let activeTask = captureTask
        captureTask = nil
        activeTask?.cancel()
        return await finalize()
    }

    private func finalize() async -> TraceCaptureOutcome {
        guard phase == .recording, let session else { return .noChange }
        phase = .finalizing
        onStateChange?()

        let endedAt = Date()
        DiagnosticsEventRecorder.shared.endVerboseCapture()
        recorders.forEach { $0.endCapture() }
        let endReport = reportProvider?() ?? "report unavailable"
        let evidenceProvider = automaticEvidenceProvider
        reportProvider = nil
        automaticEvidenceProvider = nil
        let automaticEvidence = await evidenceProvider?() ?? "none"

        do {
            let url = try await writer.writeFinal(
                session: session,
                endedAt: endedAt,
                recorders: recorders,
                automaticEvidence: automaticEvidence,
                endReport: endReport
            )
            let artifact = TraceCaptureArtifact(url: url, startedAt: session.startedAt, endedAt: endedAt)
            lastArtifact = artifact
            self.session = nil
            phase = .idle
            onStateChange?()
            return .stopped(artifact)
        } catch {
            self.session = nil
            phase = .idle
            onStateChange?()
            return .writeFailed(error.localizedDescription)
        }
    }

    private func writePartial() async {
        guard phase == .recording, let session else { return }
        _ = try? await writer.writePartial(session: session, recorders: recorders)
    }
}

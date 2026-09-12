// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

private struct TraceCaptureFinalReport {
    let endedAt: Date
    let automaticEvidence: String
    let endReport: String

    func tailData() -> Data {
        var data = Data()
        func append(_ string: String) {
            data.append(contentsOf: string.utf8)
        }
        append("\n== Automatic AX Evidence ==\n")
        append(
            RuntimeTraceLimits.boundedString(
                automaticEvidence,
                maxBytes: RuntimeTraceLimits.automaticEvidenceBytes
            )
        )
        append("\n")
        append("\n== State At End ==\n")
        append(RuntimeTraceLimits.boundedString(endReport, maxBytes: RuntimeTraceLimits.stateReportBytes))
        append("\n")
        return data
    }
}

private final class TraceByteSink {
    private let handle: FileHandle
    private(set) var byteCount = 0

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        byteCount += data.count
    }
}

private final class BoundedTraceWriter {
    private static let truncationData = Data("\n== Trace Data Truncated ==\nreason=byte_budget\n".utf8)

    static let incompleteSectionLine = "incomplete=true reason=file_byte_budget"

    static func requiredSectionBytes(for sectionTitles: [String]) -> Int {
        sectionTitles.reduce(into: 0) { total, title in
            total += 1
            total += "== \(title) ==".utf8.count + 1
            total += incompleteSectionLine.utf8.count + 1
        }
    }

    private let sink: TraceByteSink
    private let contentLimit: Int
    private var requiredBytesRemaining: Int
    private(set) var truncated = false
    private var failure: Error?

    init(sink: TraceByteSink, reservedTailBytes: Int, reservedRequiredBytes: Int = 0) {
        self.sink = sink
        requiredBytesRemaining = max(0, reservedRequiredBytes)
        contentLimit = max(
            0,
            RuntimeTraceLimits.captureBytes
                - reservedTailBytes
                - requiredBytesRemaining
                - Self.truncationData.count
        )
    }

    func appendLine(_ line: String) -> Bool {
        guard failure == nil, !truncated else { return false }
        var data = Data(line.utf8)
        data.append(0x0A)
        guard sink.byteCount + data.count <= contentLimit else {
            truncated = true
            return false
        }
        do {
            try sink.write(data)
            return true
        } catch {
            failure = error
            return false
        }
    }

    func appendRequiredLine(_ line: String) -> Bool {
        guard failure == nil else { return false }
        var data = Data(line.utf8)
        data.append(0x0A)
        guard data.count <= requiredBytesRemaining else {
            failure = CocoaError(.fileWriteOutOfSpace)
            return false
        }
        do {
            try sink.write(data)
            requiredBytesRemaining -= data.count
            return true
        } catch {
            failure = error
            return false
        }
    }

    func finish(tail: Data) throws {
        if let failure {
            throw failure
        }
        if truncated {
            try sink.write(Self.truncationData)
        }
        try sink.write(tail)
    }
}

actor TraceCaptureFileWriter {
    static let retainedPerformanceCaptures = 5

    private let diagnosticsDirectory: URL
    private let diagnosticsEventRecorder: DiagnosticsEventRecorder

    init(diagnosticsDirectory: URL, diagnosticsEventRecorder: DiagnosticsEventRecorder) {
        self.diagnosticsDirectory = diagnosticsDirectory
        self.diagnosticsEventRecorder = diagnosticsEventRecorder
    }

    func preparePerformanceCapture() throws {
        try FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
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
        let url = diagnosticsDirectory.appendingPathComponent(
            partialFilename(startedAt: session.startedAt),
            isDirectory: false
        )
        try writeAtomically(to: url) { sink in
            try writeCapture(
                to: sink,
                session: session,
                recorders: recorders,
                finalReport: nil
            )
        }
        return url
    }

    func writeFinal(
        session: TraceCaptureSession,
        endedAt: Date,
        recorders: [any RuntimeTraceRecording],
        automaticEvidence: String,
        endReport: String
    ) throws -> URL {
        let filename = "omniwm-trace-\(milliseconds(session.startedAt))-\(milliseconds(endedAt)).log"
        let url = diagnosticsDirectory.appendingPathComponent(filename, isDirectory: false)
        try writeAtomically(to: url) { sink in
            try writeCapture(
                to: sink,
                session: session,
                recorders: recorders,
                finalReport: TraceCaptureFinalReport(
                    endedAt: endedAt,
                    automaticEvidence: automaticEvidence,
                    endReport: endReport
                )
            )
        }
        try? FileManager.default.removeItem(
            at: diagnosticsDirectory.appendingPathComponent(
                partialFilename(startedAt: session.startedAt),
                isDirectory: false
            )
        )
        return url
    }

    func writePerformanceFinal(
        session: TraceCaptureSession,
        endedAt: Date,
        processResourceDelta: ProcessResourceDelta?,
        endReport: String
    ) throws -> URL {
        let filename = "omniwm-performance-\(milliseconds(session.startedAt))-\(milliseconds(endedAt)).log"
        let url = diagnosticsDirectory.appendingPathComponent(filename, isDirectory: false)
        try writeAtomically(to: url, temporaryPrefix: ".omniwm-performance-") { sink in
            let writer = BoundedTraceWriter(sink: sink, reservedTailBytes: 0)
            _ = writer.appendLine("== OmniWM Performance Capture ==")
            _ = writer.appendLine("startedAt=\(session.startedAt.ISO8601Format())")
            _ = writer.appendLine("endedAt=\(endedAt.ISO8601Format())")
            _ = writer.appendLine("scope=OmniWM process CPU; WindowServer and GPU require external profiling")
            _ = writer.appendLine("detailedRecorders=disabled partialWrites=disabled automaticAXEvidence=disabled")
            _ = writer.appendLine("")
            _ = writer.appendLine("== Process Resource Delta ==")
            _ = writer.appendLine(processResourceDelta?.formatted() ?? "resourceSnapshot=unavailable")
            _ = writer.appendLine("")
            _ = writer.appendLine("== State At Start ==")
            _ = writer.appendLine(
                RuntimeTraceLimits.boundedString(
                    session.startReport,
                    maxBytes: RuntimeTraceLimits.stateReportBytes
                )
            )
            _ = writer.appendLine("")
            _ = writer.appendLine("== State At End ==")
            _ = writer.appendLine(
                RuntimeTraceLimits.boundedString(
                    endReport,
                    maxBytes: RuntimeTraceLimits.stateReportBytes
                )
            )
            try writer.finish(tail: Data())
        }
        DiagnosticsRetention.wipe(
            directory: diagnosticsDirectory,
            prefixes: ["omniwm-performance-"],
            except: [url],
            keepingNewest: Self.retainedPerformanceCaptures
        )
        return url
    }

    private func writeCapture(
        to sink: TraceByteSink,
        session: TraceCaptureSession,
        recorders: [any RuntimeTraceRecording],
        finalReport: TraceCaptureFinalReport?
    ) throws {
        let tail = finalReport?.tailData() ?? Data()
        let sectionTitles = [
            "Lifecycle Events (recent, always-on)",
            "Verbose Window Events (capture window)"
        ] + recorders.map(\.sectionTitle)
        let incompleteSectionLine = BoundedTraceWriter.incompleteSectionLine
        let requiredSectionBytes = BoundedTraceWriter.requiredSectionBytes(for: sectionTitles)
        let writer = BoundedTraceWriter(
            sink: sink,
            reservedTailBytes: tail.count,
            reservedRequiredBytes: requiredSectionBytes
        )
        let append: (String) -> Bool = { writer.appendLine($0) }
        func appendOmittedSection(_ title: String) {
            _ = writer.appendRequiredLine("")
            _ = writer.appendRequiredLine("== \(title) ==")
            _ = writer.appendRequiredLine(incompleteSectionLine)
        }
        func appendSection(_ title: String, records: ((String) -> Bool) -> Void) {
            guard !writer.truncated else {
                appendOmittedSection(title)
                return
            }
            guard append(""), append("== \(title) ==") else {
                appendOmittedSection(title)
                return
            }
            records(append)
            if writer.truncated {
                _ = writer.appendRequiredLine(incompleteSectionLine)
            }
        }

        _ = append("== OmniWM Trace Capture ==")
        _ = append("startedAt=\(session.startedAt.ISO8601Format())")
        _ = append(finalReport.map { "endedAt=\($0.endedAt.ISO8601Format())" } ?? "status=in-progress (partial)")
        _ = append("")
        _ = append("== State At Start ==")
        _ = append(RuntimeTraceLimits.boundedString(session.startReport, maxBytes: RuntimeTraceLimits.stateReportBytes))
        appendSection("Lifecycle Events (recent, always-on)") { body in
            diagnosticsEventRecorder.forEachLifecycleLine(body)
        }
        appendSection("Verbose Window Events (capture window)") { body in
            diagnosticsEventRecorder.forEachVerboseLine(body)
        }
        for recorder in recorders {
            appendSection(recorder.sectionTitle) { body in
                recorder.forEachLine(body)
            }
        }
        try writer.finish(tail: tail)
    }

    private func writeAtomically(
        to destination: URL,
        temporaryPrefix: String = ".omniwm-trace-",
        body: (TraceByteSink) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
        let temporary = diagnosticsDirectory.appendingPathComponent(
            "\(temporaryPrefix)\(UUID().uuidString).tmp",
            isDirectory: false
        )
        var handle: FileHandle?
        do {
            guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let openedHandle = try FileHandle(forWritingTo: temporary)
            handle = openedHandle
            try body(TraceByteSink(handle: openedHandle))
            try openedHandle.synchronize()
            try openedHandle.close()
            handle = nil
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? handle?.close()
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func partialFilename(startedAt: Date) -> String {
        "omniwm-trace-\(milliseconds(startedAt)).partial.log"
    }

    private func milliseconds(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 * 1000)
    }
}

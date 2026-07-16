// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

enum IssueDiagnosticEvidence: Equatable, Sendable {
    case crash(URL)
    case trace(TraceCaptureArtifact)

    var url: URL {
        switch self {
        case let .crash(url):
            url
        case let .trace(artifact):
            artifact.url
        }
    }

    var kind: String {
        switch self {
        case .crash:
            "crash"
        case .trace:
            "trace"
        }
    }
}

struct DiagnosticAttachmentResult: Equatable, Sendable {
    let url: URL
    let includedEvidence: Bool
}

@MainActor
extension WMController {
    func refreshDiagnosticsIssues() {
        diagnosticsIssues = DiagnosticsIssueAggregator.applicableIssues(controller: self)
    }

    func diagnosticsReportText(traceLimit: Int = 200) -> String {
        RuntimeDiagnosticsReport.build(self, traceLimit: traceLimit)
    }

    @discardableResult
    func writeDiagnosticsReport(traceLimit: Int = 200) throws -> URL {
        let directory = diagnosticsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "omniwm-diagnostics-\(Int(Date().timeIntervalSince1970 * 1000)).log"
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        try diagnosticsReportText(traceLimit: traceLimit).write(to: url, atomically: true, encoding: .utf8)
        DiagnosticsRetention.wipe(directory: directory, prefixes: ["omniwm-diagnostics-"], except: [url])
        return url
    }

    func prepareDiagnosticAttachment(evidence: IssueDiagnosticEvidence?) async throws -> DiagnosticAttachmentResult {
        let report = diagnosticsReportText()
        let directory = diagnosticsDirectory
        return try await Task.detached(priority: .utility) {
            try DiagnosticAttachmentWriter.prepare(
                report: report,
                evidence: evidence,
                directory: directory
            )
        }.value
    }
}

private enum SelectedEvidenceReadError: Error {
    case unavailable
}

private enum DiagnosticAttachmentWriter {
    private static let evidenceChunkSize = 64 * 1024

    static func prepare(
        report: String,
        evidence: IssueDiagnosticEvidence?,
        directory: URL
    ) throws -> DiagnosticAttachmentResult {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(
            "omniwm-diagnostics-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString).log",
            isDirectory: false
        )
        let includedEvidence: Bool
        let temporary: URL
        if let evidence {
            let candidate = temporaryURL(in: directory)
            do {
                try write(report: report, evidence: evidence, evidenceStatus: "included", to: candidate)
                temporary = candidate
                includedEvidence = true
            } catch SelectedEvidenceReadError.unavailable {
                try? FileManager.default.removeItem(at: candidate)
                let fallback = temporaryURL(in: directory)
                try write(report: report, evidence: evidence, evidenceStatus: "unavailable", to: fallback)
                temporary = fallback
                includedEvidence = false
            }
        } else {
            let candidate = temporaryURL(in: directory)
            try write(report: report, evidence: nil, evidenceStatus: "not_selected", to: candidate)
            temporary = candidate
            includedEvidence = false
        }
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        DiagnosticsRetention.wipe(
            directory: directory,
            prefixes: ["omniwm-diagnostics-"],
            except: [destination]
        )
        return DiagnosticAttachmentResult(url: destination, includedEvidence: includedEvidence)
    }

    private static func write(
        report: String,
        evidence: IssueDiagnosticEvidence?,
        evidenceStatus: String,
        to url: URL
    ) throws {
        try Data().write(to: url, options: .withoutOverwriting)
        let output: FileHandle
        do {
            output = try FileHandle(forWritingTo: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        do {
            try output.write(contentsOf: Data(report.utf8))
            try output.write(contentsOf: Data(evidenceHeader(for: evidence, status: evidenceStatus).utf8))
            if evidenceStatus == "included", let evidence {
                try stream(evidence.url, to: output)
            }
            try output.close()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func stream(_ url: URL, to output: FileHandle) throws {
        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: url)
        } catch {
            throw SelectedEvidenceReadError.unavailable
        }
        defer { try? input.close() }
        while true {
            let chunk: Data?
            do {
                chunk = try input.read(upToCount: evidenceChunkSize)
            } catch {
                throw SelectedEvidenceReadError.unavailable
            }
            guard let chunk, !chunk.isEmpty else { return }
            try output.write(contentsOf: chunk)
        }
    }

    private static func evidenceHeader(
        for evidence: IssueDiagnosticEvidence?,
        status: String
    ) -> String {
        var lines = ["", "", "== Selected Diagnostic Evidence ==", "evidenceStatus=\(status)"]
        if let evidence {
            lines.append("evidenceType=\(evidence.kind)")
            lines.append("evidenceFile=\(evidence.url.lastPathComponent)")
        }
        lines.append("")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func temporaryURL(in directory: URL) -> URL {
        directory.appendingPathComponent(".omniwm-diagnostics-\(UUID().uuidString).tmp", isDirectory: false)
    }
}

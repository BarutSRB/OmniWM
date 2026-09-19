// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

@MainActor
enum FatalCapture {
    struct PendingCrashReport: Equatable, Sendable {
        let url: URL
        let reason: String
        let detectedAt: Date
    }

    nonisolated(unsafe) static var directory = OmniWMStoragePaths.live.diagnosticsDirectory
    nonisolated(unsafe) static var controllerProvider: (@MainActor () -> WMController?)?

    static func install(
        directory: URL = OmniWMStoragePaths.live.diagnosticsDirectory,
        controllerProvider: @escaping @MainActor () -> WMController?
    ) {
        Self.directory = directory
        Self.controllerProvider = controllerProvider
    }

    static func consumePending(directory: URL = OmniWMStoragePaths.live.diagnosticsDirectory) -> PendingCrashReport? {
        let crashLogs = DiagnosticsFileScanner.scan(directory).filter {
            $0.name.hasPrefix("omniwm-crash-") && $0.url.pathExtension == "log"
        }
        guard let newest = crashLogs.first else { return nil }
        let keep = Set(crashLogs.prefix(retentionLimit).map(\.url))
        DiagnosticsRetention.wipe(directory: directory, prefixes: ["omniwm-crash-"], except: keep)
        return PendingCrashReport(
            url: newest.url,
            reason: reason(in: newest.url),
            detectedAt: newest.modified
        )
    }

    private static let retentionLimit = 5

    private static func reason(in url: URL) -> String {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return "unknown" }
        let line = contents
            .split(separator: "\n")
            .first { $0.hasPrefix("reason=") }
        return line.map { String($0.dropFirst("reason=".count)) } ?? "unknown"
    }
}

enum CrashReportBody {
    static func fatal(reason: String, coordinate: String, stack: String, report: String?) -> String {
        var sections = [
            [
                "== OmniWM Crash ==",
                "kind=fatal",
                "reason=\(reason)",
                "coordinate=\(coordinate)",
                "appVersion=\(OmniWMBuildInfo.version)",
                "build=\(OmniWMBuildInfo.build)",
                "gitHash=\(OmniWMBuildInfo.gitHash)",
                "os=\(ProcessInfo.processInfo.operatingSystemVersionString)",
                "pid=\(ProcessInfo.processInfo.processIdentifier)"
            ].joined(separator: "\n")
        ]
        if let report { sections.append(report) }
        sections.append("== Stacktrace ==\n\(stack)")
        return sections.joined(separator: "\n\n")
    }
}

@MainActor
func fatal(
    _ reason: String = "",
    file: StaticString = #fileID,
    line: UInt = #line,
    function: StaticString = #function
) -> Never {
    let coordinate = "\(file):\(line) \(function)"
    let url = crashReportURL()
    writeCrashReport(reason: reason, coordinate: coordinate, report: nil, to: url)
    if let report = FatalCapture.controllerProvider?().map({ RuntimeDiagnosticsReport.build($0, traceLimit: 200) }) {
        writeCrashReport(reason: reason, coordinate: coordinate, report: report, to: url)
    }
    Log.diagnostics.fault("FATAL \(reason) @ \(coordinate)")
    fatalError("OmniWM fatal: \(reason) @ \(coordinate)")
}

func fatalOffMain(
    _ reason: String = "",
    file: StaticString = #fileID,
    line: UInt = #line,
    function: StaticString = #function
) -> Never {
    let coordinate = "\(file):\(line) \(function)"
    writeCrashReport(reason: reason, coordinate: coordinate, report: nil, to: crashReportURL())
    Log.diagnostics.fault("FATAL \(reason) @ \(coordinate)")
    fatalError("OmniWM fatal: \(reason) @ \(coordinate)")
}

private func crashReportURL() -> URL {
    let directory = FatalCapture.directory
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(
        "omniwm-crash-\(Int(Date().timeIntervalSince1970 * 1000)).log",
        isDirectory: false
    )
}

private func writeCrashReport(reason: String, coordinate: String, report: String?, to url: URL) {
    let stack = Thread.callStackSymbols.joined(separator: "\n")
    let body = CrashReportBody.fatal(reason: reason, coordinate: coordinate, stack: stack, report: report)
    try? body.write(to: url, atomically: true, encoding: .utf8)
}

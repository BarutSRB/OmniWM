// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct DiagnosticsFile: Identifiable, Sendable, Equatable {
    let url: URL
    let name: String
    let sizeBytes: Int64
    let modified: Date

    var id: URL {
        url
    }
}

enum DiagnosticsFileScanner {
    static func scan(_ directory: URL) -> [DiagnosticsFile] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let keySet = Set(keys)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys
        )) ?? []
        return contents
            .compactMap { url -> DiagnosticsFile? in
                guard url.lastPathComponent.hasPrefix("omniwm-") else { return nil }
                let values = try? url.resourceValues(forKeys: keySet)
                guard values?.isRegularFile == true else { return nil }
                return DiagnosticsFile(
                    url: url,
                    name: url.lastPathComponent,
                    sizeBytes: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate ?? .distantPast
                )
            }
            .sorted {
                if $0.modified != $1.modified {
                    return $0.modified > $1.modified
                }
                return $0.name > $1.name
            }
    }

    static func issueEvidence(
        in directory: URL,
        pendingCrashURL: URL?
    ) -> [IssueDiagnosticEvidence] {
        let files = scan(directory)
        var evidence: [IssueDiagnosticEvidence] = []
        if let pendingCrashURL,
           files.contains(where: { $0.url.standardizedFileURL == pendingCrashURL.standardizedFileURL })
        {
            evidence.append(.crash(pendingCrashURL))
        }
        if let trace = files.first(where: { isCompletedTrace($0.name) }) {
            evidence.append(.trace(directory.appendingPathComponent(trace.name, isDirectory: false)))
        }
        return evidence
    }

    private static func isCompletedTrace(_ name: String) -> Bool {
        name.hasPrefix("omniwm-trace-")
            && name.hasSuffix(".log")
            && !name.hasSuffix(".partial.log")
    }
}

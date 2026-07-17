// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

enum DiagnosticsRetention {
    private static let temporaryLifetime: TimeInterval = 60 * 60

    static func wipe(directory: URL, prefixes: [String] = ["omniwm-"], except: Set<URL> = []) {
        removeStaleTemporaryFiles(directory: directory)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }

        let preserved = Set(except.map { $0.standardizedFileURL.path })
        for file in files where prefixes.contains(where: { file.lastPathComponent.hasPrefix($0) }) {
            guard !preserved.contains(file.standardizedFileURL.path) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func removeStaleTemporaryFiles(directory: URL, now: Date = Date()) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys)
        ) else { return }

        let cutoff = now.addingTimeInterval(-temporaryLifetime)
        for file in files {
            let name = file.lastPathComponent
            guard isOwnedTemporaryFile(name),
                  let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff
            else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func isOwnedTemporaryFile(_ name: String) -> Bool {
        (name.hasPrefix(".omniwm-diagnostics-") || name.hasPrefix(".omniwm-trace-"))
            && name.hasSuffix(".tmp")
    }
}

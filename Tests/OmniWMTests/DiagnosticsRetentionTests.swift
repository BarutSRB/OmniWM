// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class DiagnosticsRetentionTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name, isDirectory: false)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func names(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .map(\.lastPathComponent)
            .sorted()
    }

    func testWipeRemovesAllDiagnosticsFilesAndKeepsOthers() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try write("omniwm-trace-1.log", in: dir)
        _ = try write("omniwm-diagnostics-1.log", in: dir)
        _ = try write("omniwm-crash-1.log", in: dir)
        _ = try write("keep.txt", in: dir)

        DiagnosticsRetention.wipe(directory: dir)

        XCTAssertEqual(names(in: dir), ["keep.txt"])
    }

    func testWipeWithPrefixesKeepsTraces() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try write("omniwm-trace-1.log", in: dir)
        _ = try write("omniwm-diagnostics-1.log", in: dir)
        _ = try write("omniwm-crash-1.log", in: dir)

        DiagnosticsRetention.wipe(directory: dir, prefixes: ["omniwm-diagnostics-", "omniwm-crash-"])

        XCTAssertEqual(names(in: dir), ["omniwm-trace-1.log"])
    }

    func testWipeExceptPreservesExcludedURL() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try write("omniwm-diagnostics-old.log", in: dir)
        let keep = try write("omniwm-diagnostics-new.log", in: dir)

        DiagnosticsRetention.wipe(directory: dir, prefixes: ["omniwm-diagnostics-"], except: [keep])

        XCTAssertEqual(names(in: dir), ["omniwm-diagnostics-new.log"])
    }
}

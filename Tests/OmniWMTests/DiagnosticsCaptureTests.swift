// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

final class DiagnosticsCaptureTests: XCTestCase {
    func testCrashReportBodyIncludesContextAndReport() {
        let body = CrashReportBody.fatal(
            reason: "boom",
            coordinate: "Foo.swift:1 bar()",
            stack: "frame0\nframe1",
            report: "== Section ==\nx=1"
        )
        XCTAssertTrue(body.contains("kind=fatal"))
        XCTAssertTrue(body.contains("reason=boom"))
        XCTAssertTrue(body.contains("coordinate=Foo.swift:1 bar()"))
        XCTAssertTrue(body.contains("gitHash=\(OmniWMBuildInfo.gitHash)"))
        XCTAssertTrue(body.contains("== Section =="))
        XCTAssertTrue(body.contains("== Stacktrace =="))
        XCTAssertTrue(body.contains("frame0"))
    }

    func testCrashReportBodyOmitsReportWhenNil() {
        let body = CrashReportBody.fatal(reason: "x", coordinate: "c", stack: "s", report: nil)
        XCTAssertTrue(body.contains("kind=fatal"))
        XCTAssertFalse(body.contains("== Section =="))
    }

    func testBuildInfoGitHashFallsBackToSnapshot() {
        XCTAssertEqual(OmniWMBuildInfo.gitHash, "SNAPSHOT")
    }

    @MainActor
    func testConsumePendingReturnsNewestAndCapsRetention() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omniwm-crash-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 1 ... 7 {
            let url = directory.appendingPathComponent("omniwm-crash-\(index).log", isDirectory: false)
            try "kind=fatal\nreason=boom\(index)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: Double(1000 + index))],
                ofItemAtPath: url.path
            )
        }

        let pending = FatalCapture.consumePending(directory: directory)
        XCTAssertEqual(pending?.reason, "boom7")
        XCTAssertEqual(pending?.url.lastPathComponent, "omniwm-crash-7.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending?.url.path ?? ""))

        let remaining = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "log" }
        XCTAssertEqual(remaining.count, 5)
    }

    func testAXWindowFactsDTORoundTrip() {
        let facts = AXWindowFacts(
            role: "AXWindow",
            subrole: "AXDialog",
            title: "Title",
            hasCloseButton: true,
            hasFullscreenButton: false,
            fullscreenButtonEnabled: nil,
            hasZoomButton: false,
            hasMinimizeButton: true,
            appPolicy: .accessory,
            bundleId: "com.example.app",
            attributeFetchSucceeded: true
        )
        XCTAssertEqual(AXWindowFactsDTO(from: facts).toModel(), facts)
    }
}

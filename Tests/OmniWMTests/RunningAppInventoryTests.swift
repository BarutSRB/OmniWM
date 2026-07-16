// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class RunningAppInventoryTests: XCTestCase {
    func testMergeKeepsSystemOnlyApplication() throws {
        let system = application(
            id: "com.example.system",
            pid: 41,
            bundleId: "com.example.system",
            name: "System"
        )

        let result = RunningAppInventory.merge(systemApplications: [system], trackedApplications: [])

        XCTAssertEqual(result.map(\.id), ["com.example.system"])
        XCTAssertNil(try XCTUnwrap(result.first).trackedWindowSize)
    }

    func testTrackedApplicationOverlaysSystemMetadataWithoutDuplicatingBundle() throws {
        let system = application(
            id: "com.example.app",
            pid: 42,
            bundleId: "com.example.app",
            name: "System Name"
        )
        let tracked = application(
            id: "com.example.app",
            pid: 42,
            bundleId: "com.example.app",
            name: "Tracked Name",
            size: CGSize(width: 800, height: 600)
        )

        let result = RunningAppInventory.merge(systemApplications: [system], trackedApplications: [tracked])
        let merged = try XCTUnwrap(result.first)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(merged.appName, "Tracked Name")
        XCTAssertEqual(merged.trackedWindowSize, CGSize(width: 800, height: 600))
    }

    func testBundlelessTrackedPidOverlaysBundledSystemApplication() throws {
        let system = application(
            id: "com.example.helper",
            pid: 43,
            bundleId: "com.example.helper",
            name: "Helper"
        )
        let tracked = application(
            id: "pid:43",
            pid: 43,
            bundleId: nil,
            name: "Unknown",
            size: CGSize(width: 320, height: 240)
        )

        let result = RunningAppInventory.merge(systemApplications: [system], trackedApplications: [tracked])
        let merged = try XCTUnwrap(result.first)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(merged.id, "com.example.helper")
        XCTAssertEqual(merged.bundleId, "com.example.helper")
        XCTAssertEqual(merged.appName, "Helper")
        XCTAssertEqual(merged.trackedWindowSize, CGSize(width: 320, height: 240))
    }

    func testMergeSortsByLocalizedNameThenIdentity() {
        let applications = [
            application(id: "z", pid: 44, bundleId: nil, name: "Beta"),
            application(id: "b", pid: 45, bundleId: nil, name: "Alpha"),
            application(id: "a", pid: 46, bundleId: nil, name: "Alpha")
        ]

        let result = RunningAppInventory.merge(systemApplications: applications, trackedApplications: [])

        XCTAssertEqual(result.map(\.id), ["a", "b", "z"])
    }

    func testMergeDeduplicatesMultipleProcessesWithSameBundleIdentity() {
        let applications = [
            application(id: "com.example.shared", pid: 47, bundleId: "com.example.shared", name: "First"),
            application(id: "com.example.shared", pid: 48, bundleId: "com.example.shared", name: "Second")
        ]

        let result = RunningAppInventory.merge(systemApplications: applications, trackedApplications: [])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.appName, "First")
    }

    private func application(
        id: String,
        pid: pid_t,
        bundleId: String?,
        name: String,
        size: CGSize = .zero
    ) -> RunningAppInfo {
        RunningAppInfo(
            id: id,
            pid: pid,
            bundleId: bundleId,
            appName: name,
            icon: nil,
            windowSize: size
        )
    }
}

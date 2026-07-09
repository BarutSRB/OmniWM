// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

final class HiddenBarAllowlistTests: XCTestCase {
    private let protectedIDs: Set<String> = ["com.barut.OmniWM"]
    private let hostIDs = HiddenBarAllowlistResolver.systemHostBundleIDs

    func testEmptyHiddenSetConcealsNothing() {
        let result = HiddenBarAllowlistResolver.resolve(
            hiddenBundleIDs: [],
            runningBundleIDs: ["a", "b", "com.barut.OmniWM"],
            protectedBundleIDs: protectedIDs
        )
        XCTAssertTrue(result.concealed.isEmpty)
        XCTAssertEqual(result.allowed, Set(["a", "b", "com.barut.OmniWM"]).union(hostIDs))
    }

    func testHiddenAppsConcealedRegardlessOfRunningState() {
        let result = HiddenBarAllowlistResolver.resolve(
            hiddenBundleIDs: ["a", "notRunning"],
            runningBundleIDs: ["a", "b", "com.barut.OmniWM"],
            protectedBundleIDs: protectedIDs
        )
        XCTAssertEqual(result.concealed, ["a", "notRunning"])
        XCTAssertFalse(result.allowed.contains("a"))
        XCTAssertFalse(result.allowed.contains("notRunning"))
    }

    func testHiddenButNotRunningStaysConcealed() {
        let result = HiddenBarAllowlistResolver.resolve(
            hiddenBundleIDs: ["ghost"],
            runningBundleIDs: ["a", "b"],
            protectedBundleIDs: protectedIDs
        )
        XCTAssertEqual(result.concealed, ["ghost"])
        XCTAssertEqual(result.allowed, Set(["a", "b"]).union(protectedIDs).union(hostIDs))
    }

    func testOwnBundleNeverConcealedEvenIfHidden() {
        let result = HiddenBarAllowlistResolver.resolve(
            hiddenBundleIDs: ["com.barut.OmniWM", "a"],
            runningBundleIDs: ["com.barut.OmniWM", "a", "b"],
            protectedBundleIDs: protectedIDs
        )
        XCTAssertFalse(result.concealed.contains("com.barut.OmniWM"))
        XCTAssertTrue(result.allowed.contains("com.barut.OmniWM"))
        XCTAssertEqual(result.concealed, ["a"])
    }

    func testAllowedIsRunningMinusConcealedUnionProtectedAndHosts() {
        let running: Set<String> = ["a", "b", "c"]
        let result = HiddenBarAllowlistResolver.resolve(
            hiddenBundleIDs: ["b"],
            runningBundleIDs: running,
            protectedBundleIDs: protectedIDs
        )
        XCTAssertEqual(result.allowed, running.subtracting(["b"]).union(protectedIDs).union(hostIDs))
    }

    func testSystemHostsAlwaysAllowedEvenWhenNotRunning() {
        let result = HiddenBarAllowlistResolver.resolve(
            hiddenBundleIDs: ["a"],
            runningBundleIDs: ["a", "b"],
            protectedBundleIDs: protectedIDs
        )
        XCTAssertTrue(result.allowed.isSuperset(of: hostIDs))
    }

    func testSystemUIServerIsProtected() {
        XCTAssertTrue(hostIDs.contains("com.apple.systemuiserver"))
    }

    func testSystemHostsNeverConcealedEvenIfHidden() {
        let result = HiddenBarAllowlistResolver.resolve(
            hiddenBundleIDs: hostIDs.union(["a"]),
            runningBundleIDs: hostIDs.union(["a", "b"]),
            protectedBundleIDs: protectedIDs
        )
        XCTAssertEqual(result.concealed, ["a"])
        XCTAssertTrue(result.allowed.isSuperset(of: hostIDs))
    }

    func testAppexOnlyHiddenStillTriggersConcealment() {
        let result = HiddenBarAllowlistResolver.resolve(
            hiddenBundleIDs: ["com.apple.Passwords.MenuBarExtra"],
            runningBundleIDs: ["a", "b"],
            protectedBundleIDs: protectedIDs
        )
        XCTAssertEqual(result.concealed, ["com.apple.Passwords.MenuBarExtra"])
        XCTAssertFalse(result.allowed.contains("com.apple.Passwords.MenuBarExtra"))
    }

    func testSystemItemIdentifiersAreZeroThroughEight() {
        XCTAssertEqual(HiddenBarAllowlistResolver.allowedSystemItemIdentifiers, Array(0 ... 8))
    }
}

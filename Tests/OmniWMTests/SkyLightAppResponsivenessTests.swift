// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

final class SkyLightAppResponsivenessTests: XCTestCase {
    func testStatusFlagsUseOnlyTheUnresponsiveBit() {
        let status: SkyLight.AppUnresponsiveStatusFunc = { connection, psn, timestamp, flags in
            XCTAssertEqual(connection, 7)
            XCTAssertNil(timestamp)
            flags.pointee = psn.pointee.lowLongOfPSN
            return 0
        }
        for (flags, expected) in [(UInt32(0), false), (1, false), (2, true), (4, false), (7, true)] {
            var processLookups = 0
            let result = SkyLight.appUnresponsiveStatus(42, mainConnectionID: { 7 }, status: status) { pid, psn in
                XCTAssertEqual(pid, 42)
                processLookups += 1
                psn.lowLongOfPSN = flags
                return noErr
            }
            XCTAssertEqual(result, expected)
            XCTAssertEqual(processLookups, 1)
        }
    }

    func testFailedStatusDiscardsPositiveFlags() {
        let result = SkyLight.appUnresponsiveStatus(42, mainConnectionID: { 7 }, status: { _, _, _, flags in
            flags.pointee = 2
            return -1
        }, processForPID: { _, _ in noErr })
        XCTAssertNil(result)
    }

    func testUnavailableBindingsAvoidProcessLookup() {
        let unexpectedStatus: SkyLight.AppUnresponsiveStatusFunc = { _, _, _, _ in
            XCTFail("Unavailable bindings must not query status")
            return 0
        }
        let unexpectedLookup: (pid_t, inout ProcessSerialNumber) -> OSStatus = { _, _ in
            XCTFail("Unavailable bindings must not resolve the process")
            return noErr
        }
        XCTAssertNil(SkyLight.appUnresponsiveStatus(
            42, mainConnectionID: nil, status: unexpectedStatus, processForPID: unexpectedLookup
        ))
        XCTAssertNil(SkyLight.appUnresponsiveStatus(
            42, mainConnectionID: { 7 }, status: nil, processForPID: unexpectedLookup
        ))
    }

    func testUnavailableConnectionOrTerminatedProcessReturnsUnknown() {
        let unexpectedStatus: SkyLight.AppUnresponsiveStatusFunc = { _, _, _, _ in
            XCTFail("Unavailable process or connection must not query status")
            return 0
        }
        XCTAssertNil(SkyLight.appUnresponsiveStatus(
            42, mainConnectionID: { 0 }, status: unexpectedStatus, processForPID: { _, _ in noErr }
        ))
        XCTAssertNil(SkyLight.appUnresponsiveStatus(
            42,
            mainConnectionID: {
                XCTFail("A terminated process must not look up the connection")
                return 7
            },
            status: unexpectedStatus,
            processForPID: { _, _ in OSStatus(procNotFound) }
        ))
    }
}

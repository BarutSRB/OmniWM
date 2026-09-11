// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class IPCQueryValidationTests: XCTestCase {
    func testBooleanSelectorsAcceptOnlyAbsentOrTrue() {
        let flags: [(IPCQueryName, (Bool?) -> IPCQuerySelectors)] = [
            (.windows, { IPCQuerySelectors(focused: $0) }),
            (.windows, { IPCQuerySelectors(visible: $0) }),
            (.windows, { IPCQuerySelectors(floating: $0) }),
            (.windows, { IPCQuerySelectors(scratchpad: $0) }),
            (.workspaces, { IPCQuerySelectors(current: $0) }),
            (.displays, { IPCQuerySelectors(main: $0) })
        ]
        for (name, selectors) in flags {
            for value: Bool? in [nil, true, false] {
                let query = IPCQueryRequest(name: name, selectors: selectors(value))
                XCTAssertEqual(
                    IPCQuerySelection.validate(query, sessionToken: "current"),
                    value == false ? .invalidArguments : nil
                )
            }
        }
    }

    func testSelectorAndFieldValidationPrecedesStaleWindowValidation() {
        let staleID = IPCWindowOpaqueID.encode(pid: 42, windowId: 7, sessionToken: "old")
        let invalidQueries = [
            IPCQueryRequest(name: .windows, selectors: IPCQuerySelectors(window: staleID, main: true)),
            IPCQueryRequest(name: .windows, selectors: IPCQuerySelectors(window: staleID, focused: false)),
            IPCQueryRequest(name: .windows, selectors: IPCQuerySelectors(window: staleID), fields: ["unknown"])
        ]
        for query in invalidQueries {
            XCTAssertEqual(IPCQuerySelection.validate(query, sessionToken: "current"), .invalidArguments)
        }
        let staleQuery = IPCQueryRequest(name: .windows, selectors: IPCQuerySelectors(window: staleID))
        XCTAssertEqual(IPCQuerySelection.validate(staleQuery, sessionToken: "current"), .staleWindowId)
    }

    func testWindowValidationDistinguishesCurrentAndMalformedIdentifiers() {
        let currentID = IPCWindowOpaqueID.encode(pid: 42, windowId: 7, sessionToken: "current")
        let current = IPCQueryRequest(name: .windows, selectors: IPCQuerySelectors(window: currentID), fields: ["id"])
        let malformed = IPCQueryRequest(name: .windows, selectors: IPCQuerySelectors(window: "ow_invalid"))

        XCTAssertNil(IPCQuerySelection.validate(current, sessionToken: "current"))
        XCTAssertEqual(IPCQuerySelection.validate(malformed, sessionToken: "current"), .invalidArguments)
    }
}

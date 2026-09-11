// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import OmniWMIPC
import XCTest

final class IPCQuerySelectorTests: XCTestCase {
    func testSettingChangesOnlyRequestedWireFieldAndPreservesOriginal() throws {
        let original = IPCQuerySelectors(
            window: "window", workspace: "workspace", display: "display", focused: false,
            visible: false, floating: false, scratchpad: false, app: "app", bundleId: "bundle",
            current: false, main: false
        )
        let originalFields = try fields(original)

        for selector in IPCQuerySelectorName.allCases {
            let key = selector == .bundleId ? "bundleId" : selector.rawValue
            var expected = originalFields
            expected[key] = selector.expectsValue ? "replacement" : true

            let updated = original.setting(selector, value: "replacement")

            XCTAssertEqual(try fields(updated) as NSDictionary, expected as NSDictionary, selector.rawValue)
            XCTAssertEqual(try fields(original) as NSDictionary, originalFields as NSDictionary, selector.rawValue)
            XCTAssertEqual(
                try JSONDecoder().decode(IPCQuerySelectors.self, from: JSONEncoder().encode(updated)),
                updated
            )
        }
    }

    func testSettingNilClearsOnlyValueSelector() throws {
        let original = IPCQuerySelectors(window: "window", workspace: "workspace", bundleId: "bundle")
        let updated = original.setting(.workspace)

        XCTAssertEqual(try fields(updated) as NSDictionary, ["window": "window", "bundleId": "bundle"] as NSDictionary)
        XCTAssertEqual(updated.providedSelectorNames, [.window, .bundleId])
        XCTAssertEqual(original.workspace, "workspace")
    }

    private func fields(_ selectors: IPCQuerySelectors) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(selectors)) as? [String: Any])
    }
}

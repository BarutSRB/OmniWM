// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class WindowClassificationRegressionTests: XCTestCase {
    func testAllFixturesMatchEngine() throws {
        let urls = try WindowClassificationFixtureLoader.fixtureURLs()
        XCTAssertFalse(urls.isEmpty, "No window-classification fixtures found")
        for url in urls {
            let name = url.lastPathComponent
            let dump = try WindowClassificationFixtureLoader.load(url)
            let got = WindowClassificationReproducer.recompute(dump.omniwm.input)
            let want = dump.omniwm.expected
            XCTAssertEqual(got.disposition, want.disposition, "\(name): disposition")
            XCTAssertEqual(got.source, want.source, "\(name): source")
            XCTAssertEqual(got.heuristicReasons, want.heuristicReasons, "\(name): heuristicReasons")
            XCTAssertEqual(got.deferredReason, want.deferredReason, "\(name): deferredReason")
            XCTAssertEqual(got.layoutDecisionKind, want.layoutDecisionKind, "\(name): layoutDecisionKind")
            XCTAssertEqual(got.workspaceName, want.workspaceName, "\(name): workspaceName")
            XCTAssertEqual(got.minWidth, want.minWidth, "\(name): minWidth")
            XCTAssertEqual(got.minHeight, want.minHeight, "\(name): minHeight")
            XCTAssertEqual(
                got.initialNiriColumnWidth,
                want.initialNiriColumnWidth,
                "\(name): initialNiriColumnWidth"
            )
        }
    }
}

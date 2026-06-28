// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import OmniWMIPC
import XCTest

final class IPCResizeFocusedCommandTests: XCTestCase {
    func testNameMapsToResizeFocused() {
        XCTAssertEqual(IPCCommandRequest.resizeFocused(operation: .grow).name, .resizeFocused)
    }

    func testConstructionFromArgumentValues() throws {
        let request = try IPCCommandRequest(name: .resizeFocused, argumentValues: [.resizeOperation(.grow)])
        XCTAssertEqual(request, .resizeFocused(operation: .grow))
    }

    func testConstructionRejectsMissingArgument() {
        XCTAssertThrowsError(try IPCCommandRequest(name: .resizeFocused, argumentValues: []))
    }

    func testJSONRoundTrip() throws {
        let original = IPCCommandRequest.resizeFocused(operation: .shrink)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IPCCommandRequest.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testManifestResolvesPublicCommand() throws {
        let descriptors = IPCAutomationManifest.commandDescriptors(matching: ["resize-focused", "grow"])
        let descriptor = try XCTUnwrap(descriptors.first { $0.name == .resizeFocused })
        XCTAssertEqual(descriptor.commandWords, ["resize-focused"])
        XCTAssertEqual(descriptor.arguments.map(\.kind), [.resizeOperation])
        let request = try IPCCommandRequest(name: descriptor.name, argumentValues: [.resizeOperation(.grow)])
        XCTAssertEqual(request, .resizeFocused(operation: .grow))
    }
}

// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class CLIInvocationParsingTests: XCTestCase {
    func testRemoteFamiliesKeepRequestKindOutputFormatAndInvocationFlags() throws {
        let cases: [(arguments: [String], kind: IPCRequestKind)] = [
            (["ping"], .ping),
            (["version"], .version),
            (["command", "focus", "left"], .command),
            (["query", "windows"], .query),
            (["rule", "remove", "B9B137A2-9406-4D68-BD0E-8ED465450413"], .rule),
            (["capture", "status"], .capture),
            (["workspace", "focus-name", "1"], .workspace),
            (["window", "focus", "window-id"], .window)
        ]
        for testCase in cases {
            for formatArguments in [[], ["--format", "json"]] {
                let parsed = try CLIParser.parse(arguments: ["omniwmctl"] + formatArguments + testCase.arguments)

                XCTAssertEqual(parsed.request.kind, testCase.kind)
                XCTAssertEqual(parsed.request.version, 15)
                XCTAssertNotNil(UUID(uuidString: parsed.request.id))
                XCTAssertEqual(parsed.outputFormat, !formatArguments.isEmpty || testCase.kind == .query ? .json : .text)
                XCTAssertFalse(parsed.expectsEventStream)
                XCTAssertNil(parsed.watchConfiguration)
                XCTAssertFalse(parsed.reconnect)
            }
        }
    }

    func testLocalInvocationsKeepTextOutputWithExplicitJSONFlag() throws {
        for help in ["help", "--help", "-h"] {
            let parsed = try CLIParser.parse(arguments: ["omniwmctl", "--format", "json", help])
            XCTAssertEqual(parsed.invocation, .local(.help))
            XCTAssertEqual(parsed.outputFormat, .text)
            XCTAssertFalse(parsed.expectsEventStream)
        }
        for shell in CLIShell.allCases {
            let parsed = try CLIParser.parse(arguments: ["omniwmctl", "completion", shell.rawValue, "--json"])
            XCTAssertEqual(parsed.invocation, .local(.completion(shell)))
            XCTAssertEqual(parsed.outputFormat, .text)
            XCTAssertFalse(parsed.expectsEventStream)
        }
    }

    func testPayloadFreeAndUnknownCommandsKeepUsageFailures() {
        for arguments in [["ping", "extra"], ["version", "extra"], ["unknown"], []] {
            XCTAssertThrowsError(try CLIParser.parse(arguments: ["omniwmctl"] + arguments)) { error in
                XCTAssertEqual(error as? CLIParseError, .usage(CLIParser.usageText))
            }
        }
    }
}

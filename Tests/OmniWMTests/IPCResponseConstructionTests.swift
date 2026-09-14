// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

final class IPCResponseConstructionTests: XCTestCase {
    func testRequestFailuresPreserveCorrelationAndCurrentWireEnvelope() throws {
        let kinds: [IPCRequestKind] = [
            .ping,
            .version,
            .command,
            .capture,
            .query,
            .rule,
            .workspace,
            .window,
            .subscribe
        ]
        for kind in kinds {
            let request = IPCRequest(version: 1, id: "correlation", kind: kind, payload: .none(.init()))
            for code in [IPCErrorCode.unauthorized, .invalidRequest] {
                let response = IPCResponse(failing: request, code: code)
                let expected = """
                {"code":"\(code.rawValue)","id":"correlation","kind":"\(kind.rawValue)","ok":false,"status":"error","version":\(OmniWMIPCProtocol.version)}
                """ + "\n"
                XCTAssertEqual(try IPCWire.encodeResponseLine(response), Data(expected.utf8))
            }
        }
    }

    func testProtocolMismatchPreservesVersionPayloadInFailureEnvelope() throws {
        let request = IPCRequest(version: 1, id: "mismatch", kind: .command, payload: .none(.init()))
        let result = IPCResult(version: IPCVersionResult(appVersion: "fixture"))
        let response = IPCResponse(failing: request, code: .protocolMismatch, result: result)
        let expected = """
        {"code":"protocol_mismatch","id":"mismatch","kind":"command","ok":false,"result":{"kind":"version","payload":{"appVersion":"fixture","protocolVersion":\(OmniWMIPCProtocol.version)}},"status":"error","version":\(OmniWMIPCProtocol.version)}
        """ + "\n"

        XCTAssertEqual(response.result, result)
        XCTAssertEqual(try IPCWire.encodeResponseLine(response), Data(expected.utf8))
    }
}

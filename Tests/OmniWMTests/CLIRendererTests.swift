// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing

import OmniWMIPC
@testable import OmniWMCtl

@Suite struct CLIRendererTests {
    @Test func responseExitCodesMatchWireContract() {
        #expect(CLIRenderer.exitCode(for: .success(id: "ok", kind: .command)) == .success)
        #expect(CLIRenderer.exitCode(for: .failure(id: "rejected", kind: .command, code: .disabled)) == .rejected)
        #expect(
            CLIRenderer.exitCode(for: .failure(id: "args", kind: .command, code: .invalidArguments)) ==
                .rejected
        )
        #expect(
            CLIRenderer.exitCode(for: .failure(id: "internal", kind: .command, code: .internalError)) ==
                .internalError
        )
    }

    @Test func jsonResponseOutputRoundTripsThroughWireFormat() throws {
        let response = IPCResponse.failure(id: "req-1", kind: .command, status: .ignored, code: .disabled)

        let output = try CLIRenderer.responseOutput(response, prefersJSON: true)
        let decoded = try IPCWire.decodeResponse(from: Data(output.data.dropLast()))

        #expect(output.destination == .standardOutput)
        #expect(decoded == response)
    }

    @Test func parseErrorsUseMachineReadableJSONWhenRequested() throws {
        let output = try CLIRenderer.parseErrorOutput(.usage(CLIParser.usageText), prefersJSON: true)
        let decoded = try IPCWire.makeDecoder().decode(
            CLILocalFailureEnvelope.self,
            from: Data(output.data.dropLast())
        )

        #expect(output.destination == .standardOutput)
        #expect(decoded.ok == false)
        #expect(decoded.source == "cli")
        #expect(decoded.status == .error)
        #expect(decoded.code == .invalidArguments)
        #expect(decoded.message == CLIParser.usageText)
        #expect(decoded.exitCode == CLIExitCode.invalidArguments.rawValue)
    }

    @Test func transportErrorsUseMachineReadableJSONWhenRequested() throws {
        let output = try CLIRenderer.transportErrorOutput(POSIXError(.ECONNREFUSED), prefersJSON: true)
        let decoded = try IPCWire.makeDecoder().decode(
            CLILocalFailureEnvelope.self,
            from: Data(output.data.dropLast())
        )

        #expect(output.destination == .standardOutput)
        #expect(decoded.code == .transportFailure)
        #expect(decoded.exitCode == CLIExitCode.transportFailure.rawValue)
        #expect(decoded.message.contains("omniwmctl:"))
    }

    @Test func nonJSONLocalFailuresStayHumanReadableOnStandardError() throws {
        let output = try CLIRenderer.parseErrorOutput(.usage("Usage text"), prefersJSON: false)

        #expect(output.destination == .standardError)
        #expect(String(decoding: output.data, as: UTF8.self) == "Usage text\n")
    }

    @Test func tableOutputRendersWindowsAndCommands() throws {
        let windowsResponse = IPCResponse.success(
            id: "windows-table",
            kind: .query,
            result: IPCResult(
                windows: IPCWindowsQueryResult(
                    windows: [
                        IPCWindowQuerySnapshot(
                            id: "ow_window",
                            pid: 42,
                            workspace: IPCWorkspaceRef(id: "ws-1", rawName: "1", displayName: "One", number: 1),
                            display: IPCDisplayRef(id: "display:1", name: "Main", isMain: true),
                            app: IPCAppRef(name: "Terminal", bundleId: "com.example.terminal"),
                            title: "Shell",
                            mode: .tiling,
                            isFocused: true,
                            isVisible: true,
                            isScratchpad: false
                        )
                    ]
                )
            )
        )
        let commandsResponse = IPCResponse.success(
            id: "commands-table",
            kind: .query,
            result: IPCResult(
                commands: IPCCommandsQueryResult(
                    commands: [IPCAutomationManifest.commandDescriptors[0]],
                    workspaceActions: [],
                    windowActions: []
                )
            )
        )

        let windowsOutput = try CLIRenderer.responseOutput(windowsResponse, format: .table)
        let commandsOutput = try CLIRenderer.responseOutput(commandsResponse, format: .table)

        #expect(String(decoding: windowsOutput.data, as: UTF8.self).contains("SCRATCHPAD"))
        #expect(String(decoding: windowsOutput.data, as: UTF8.self).contains("PID"))
        #expect(String(decoding: windowsOutput.data, as: UTF8.self).contains("42"))
        #expect(String(decoding: windowsOutput.data, as: UTF8.self).contains("ow_window"))
        #expect(String(decoding: commandsOutput.data, as: UTF8.self).contains("PATH"))
        #expect(String(decoding: commandsOutput.data, as: UTF8.self).contains("command focus <left|right|up|down>"))
    }

    @Test func queryRegistryOutputRendersSelectorsAndFields() throws {
        let response = IPCResponse.success(
            id: "queries-table",
            kind: .query,
            result: IPCResult(
                queries: IPCQueriesQueryResult(
                    queries: [
                        IPCAutomationManifest.queryDescriptors.first(where: { $0.name == .windows })!,
                        IPCAutomationManifest.queryDescriptors.first(where: { $0.name == .ruleActions })!,
                    ]
                )
            )
        )

        let tableOutput = try CLIRenderer.responseOutput(response, format: .table)
        let tsvOutput = try CLIRenderer.responseOutput(response, format: .tsv)
        let tableText = String(decoding: tableOutput.data, as: UTF8.self)
        let tsvText = String(decoding: tsvOutput.data, as: UTF8.self)

        #expect(tableText.contains("SELECTORS"))
        #expect(tableText.contains("FIELDS"))
        #expect(tableText.contains("windows"))
        #expect(tableText.contains("--workspace"))
        #expect(tsvText.contains("NAME\tSUMMARY\tSELECTORS\tFIELDS"))
        #expect(tsvText.contains("windows\tReturn managed OmniWM windows only."))
        #expect(tableText.contains("rule-actions"))
        #expect(tableText.contains("Return the public persisted-rule action registry."))
        #expect(tsvText.contains("rule-actions\tReturn the public persisted-rule action registry.\t-\t-"))
    }

    @Test func ruleActionRegistryOutputIncludesStructuredOptions() throws {
        let response = IPCResponse.success(
            id: "rule-actions-table",
            kind: .query,
            result: IPCResult(
                ruleActions: IPCRuleActionsQueryResult(
                    ruleActions: [IPCAutomationManifest.ruleActionDescriptors.first(where: { $0.name == .apply })!]
                )
            )
        )

        let tableOutput = try CLIRenderer.responseOutput(response, format: .table)
        let tsvOutput = try CLIRenderer.responseOutput(response, format: .tsv)
        let tableText = String(decoding: tableOutput.data, as: UTF8.self)
        let tsvText = String(decoding: tsvOutput.data, as: UTF8.self)

        #expect(tableText.contains("OPTIONS"))
        #expect(tableText.contains("--window <opaque-id>"))
        #expect(tableText.contains("--pid <pid>"))
        #expect(tsvText.contains("PATH\tSUMMARY\tARGUMENTS\tOPTIONS"))
    }

    @Test func tsvOutputRendersDisplaysAndRules() throws {
        let displaysResponse = IPCResponse.success(
            id: "displays-tsv",
            kind: .query,
            result: IPCResult(
                displays: IPCDisplaysQueryResult(
                    displays: [
                        IPCDisplayQuerySnapshot(
                            id: "display:1",
                            name: "Main",
                            isMain: true,
                            isCurrent: true,
                            frame: IPCRect(x: 0, y: 0, width: 1440, height: 900),
                            orientation: .horizontal,
                            activeWorkspace: IPCWorkspaceRef(id: "ws-1", rawName: "1", displayName: "One", number: 1)
                        )
                    ]
                )
            )
        )
        let rulesResponse = IPCResponse.success(
            id: "rules-tsv",
            kind: .rule,
            result: IPCResult(
                rules: IPCRulesQueryResult(
                    rules: [
                        IPCRuleSnapshot(
                            id: "rule-1",
                            position: 1,
                            bundleId: "com.example.terminal",
                            layout: .float,
                            assignToWorkspace: "2",
                            specificity: 3,
                            isValid: true
                        )
                    ]
                )
            )
        )

        let displaysOutput = try CLIRenderer.responseOutput(displaysResponse, format: .tsv)
        let rulesOutput = try CLIRenderer.responseOutput(rulesResponse, format: .tsv)

        #expect(String(decoding: displaysOutput.data, as: UTF8.self).contains("ACTIVE WORKSPACE"))
        #expect(String(decoding: displaysOutput.data, as: UTF8.self).contains("display:1\tMain"))
        #expect(String(decoding: rulesOutput.data, as: UTF8.self).contains("BUNDLE ID"))
        #expect(String(decoding: rulesOutput.data, as: UTF8.self).contains("rule-1\tcom.example.terminal"))
    }

    @Test func protocolMismatchTextOutputIncludesServerVersionDetails() throws {
        let response = IPCResponse.failure(
            id: "mismatch",
            kind: .query,
            code: .protocolMismatch,
            result: IPCResult(version: IPCVersionResult(protocolVersion: 3, appVersion: "1.2.3"))
        )

        let output = try CLIRenderer.responseOutput(response, format: .text)
        let text = String(decoding: output.data, as: UTF8.self)

        #expect(text.contains("protocol_mismatch"))
        #expect(text.contains("server protocol 3"))
        #expect(text.contains("1.2.3"))
    }

}

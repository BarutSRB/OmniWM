// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing

import OmniWMIPC
@testable import OmniWMCtl

@Suite struct CLIParserTests {
    @Test func parsesFocusCommand() throws {
        let parsed = try CLIParser.parse(arguments: ["omniwmctl", "command", "focus", "left"])

        #expect(parsed.request.kind == .command)
        #expect(parsed.prefersJSON == false)
        #expect(parsed.expectsEventStream == false)

        guard case let .command(command) = parsed.request.payload else {
            Issue.record("Expected a command payload")
            return
        }

        #expect(command == .focus(direction: .left))
    }

    @Test func parsesGroupedFocusPreviousCommand() throws {
        let parsed = try CLIParser.parse(arguments: ["omniwmctl", "command", "focus", "previous"])

        guard case let .command(command) = parsed.request.payload else {
            Issue.record("Expected a command payload")
            return
        }

        #expect(command == .focusPrevious)
    }

    @Test func parsesResizeCommand() throws {
        let parsed = try CLIParser.parse(arguments: ["omniwmctl", "command", "resize", "left", "grow"])

        guard case let .command(command) = parsed.request.payload else {
            Issue.record("Expected a command payload")
            return
        }

        #expect(command == .resize(direction: .left, operation: .grow))
    }

    @Test func parsesSetWorkspaceLayoutDefaultCommand() throws {
        let parsed = try CLIParser.parse(arguments: ["omniwmctl", "command", "set-workspace-layout", "default"])

        guard case let .command(command) = parsed.request.payload else {
            Issue.record("Expected a command payload")
            return
        }

        #expect(command == .setWorkspaceLayout(layout: .defaultLayout))
    }

    @Test func parsesWorkspaceCommandsWithHighWorkspaceIds() throws {
        let parsed = try CLIParser.parse(arguments: ["omniwmctl", "command", "switch-workspace", "10"])

        guard case let .command(command) = parsed.request.payload else {
            Issue.record("Expected a command payload")
            return
        }

        #expect(command == .switchWorkspace(workspaceNumber: 10))
    }

    @Test func parsesWorkspaceFocusNameNumericInputAsRawWorkspaceIDTarget() throws {
        let parsed = try CLIParser.parse(arguments: ["omniwmctl", "workspace", "focus-name", "10"])

        guard case let .workspace(request) = parsed.request.payload else {
            Issue.record("Expected a workspace payload")
            return
        }

        #expect(request == IPCWorkspaceRequest(name: .focusName, target: .rawID("10")))
    }

    @Test func queriesDefaultToJSONOutput() throws {
        let parsed = try CLIParser.parse(arguments: ["omniwmctl", "query", "workspace-bar"])

        #expect(parsed.request.kind == .query)
        #expect(parsed.prefersJSON)
        guard case let .query(query) = parsed.request.payload else {
            Issue.record("Expected a query payload")
            return
        }
        #expect(query.name == .workspaceBar)
    }

    @Test func parsesSubscribeChannelsAsEventStream() throws {
        let parsed = try CLIParser.parse(arguments: ["omniwmctl", "subscribe", "focus,workspace-bar"])

        #expect(parsed.request.kind == .subscribe)
        #expect(parsed.prefersJSON)
        #expect(parsed.expectsEventStream)

        guard case let .subscribe(subscribe) = parsed.request.payload else {
            Issue.record("Expected a subscribe payload")
            return
        }
        #expect(subscribe.channels == [.focus, .workspaceBar])
    }

    @Test func parsesWindowQuerySelectorsAndFields() throws {
        let parsed = try CLIParser.parse(
            arguments: [
                "omniwmctl",
                "query",
                "windows",
                "--workspace", "2",
                "--visible",
                "--fields", "id,title,workspace",
            ]
        )

        #expect(parsed.request.kind == .query)
        #expect(parsed.prefersJSON)

        guard case let .query(query) = parsed.request.payload else {
            Issue.record("Expected a query payload")
            return
        }

        #expect(query.name == .windows)
        #expect(query.selectors.workspace == "2")
        #expect(query.selectors.visible == true)
        #expect(query.fields == ["id", "title", "workspace"])
    }

    @Test func parsesQueryRegistryDiscoverySurface() throws {
        let parsed = try CLIParser.parse(arguments: ["omniwmctl", "query", "queries", "--format", "table"])

        #expect(parsed.request.kind == .query)
        #expect(parsed.outputFormat == .table)

        guard case let .query(query) = parsed.request.payload else {
            Issue.record("Expected a query payload")
            return
        }

        #expect(query.name == .queries)
        #expect(query.fields.isEmpty)
        #expect(query.selectors == IPCQuerySelectors())
    }

    @Test func parsesRuleActionRegistryQuery() throws {
        let parsed = try CLIParser.parse(arguments: ["omniwmctl", "query", "rule-actions"])

        #expect(parsed.request.kind == .query)
        #expect(parsed.prefersJSON)

        guard case let .query(query) = parsed.request.payload else {
            Issue.record("Expected a query payload")
            return
        }

        #expect(query.name == .ruleActions)
        #expect(query.fields.isEmpty)
        #expect(query.selectors == IPCQuerySelectors())
    }

    @Test func parsesSubscribeAllWithoutInitialSnapshot() throws {
        let parsed = try CLIParser.parse(
            arguments: ["omniwmctl", "subscribe", "--all", "--no-send-initial"]
        )

        #expect(parsed.request.kind == .subscribe)
        #expect(parsed.prefersJSON)
        #expect(parsed.expectsEventStream)

        guard case let .subscribe(subscribe) = parsed.request.payload else {
            Issue.record("Expected a subscribe payload")
            return
        }

        #expect(subscribe.allChannels)
        #expect(subscribe.channels.isEmpty)
        #expect(subscribe.sendInitial == false)
    }

    @Test func parsesWatchCommandAndPreservesChildArguments() throws {
        let parsed = try CLIParser.parse(
            arguments: [
                "omniwmctl",
                "watch",
                "focused-monitor",
                "--no-send-initial",
                "--exec",
                "/bin/echo",
                "--json"
            ]
        )

        #expect(parsed.request.kind == .subscribe)
        #expect(parsed.prefersJSON == false)
        #expect(parsed.expectsEventStream == false)
        #expect(parsed.watchConfiguration?.childArguments == ["/bin/echo", "--json"])

        guard case let .subscribe(subscribe) = parsed.request.payload else {
            Issue.record("Expected a subscribe payload")
            return
        }

        #expect(subscribe.channels == [.focusedMonitor])
        #expect(subscribe.sendInitial == false)
    }

    @Test func parsesWatchAllWithTopLevelJSONFlag() throws {
        let parsed = try CLIParser.parse(
            arguments: [
                "omniwmctl",
                "--json",
                "watch",
                "--all",
                "--exec",
                "/bin/echo"
            ]
        )

        #expect(parsed.request.kind == .subscribe)
        #expect(parsed.prefersJSON)
        #expect(parsed.expectsEventStream == false)
        #expect(parsed.watchConfiguration?.childArguments == ["/bin/echo"])

        guard case let .subscribe(subscribe) = parsed.request.payload else {
            Issue.record("Expected a subscribe payload")
            return
        }

        #expect(subscribe.allChannels)
        #expect(subscribe.channels.isEmpty)
        #expect(subscribe.sendInitial)
    }

    @Test func rejectsWatchWithoutExecCommand() {
        do {
            _ = try CLIParser.parse(arguments: ["omniwmctl", "watch", "focused-monitor", "--exec"])
            Issue.record("Expected parser failure")
        } catch let error as CLIParseError {
            #expect(error == .usage(CLIParser.usageText))
        } catch {
            Issue.record("Unexpected parser error: \(error)")
        }
    }

    @Test func rejectsWatchWithoutChannelsOrAll() {
        do {
            _ = try CLIParser.parse(arguments: ["omniwmctl", "watch", "--exec", "/bin/echo"])
            Issue.record("Expected parser failure")
        } catch let error as CLIParseError {
            #expect(error == .usage(CLIParser.usageText))
        } catch {
            Issue.record("Unexpected parser error: \(error)")
        }
    }

    @Test func rejectsUnknownWindowQueryField() {
        do {
            _ = try CLIParser.parse(
                arguments: ["omniwmctl", "query", "windows", "--fields", "id,unknown"]
            )
            Issue.record("Expected parser failure")
        } catch let error as CLIParseError {
            #expect(error == .usage(CLIParser.usageText))
        } catch {
            Issue.record("Unexpected parser error: \(error)")
        }
    }

    @Test func parsesZeroPaddedWorkspaceNumbersAsCanonicalTargets() throws {
        let parsed = try CLIParser.parse(arguments: ["omniwmctl", "command", "switch-workspace", "01"])

        guard case let .command(command) = parsed.request.payload else {
            Issue.record("Expected a command payload")
            return
        }

        #expect(command == .switchWorkspace(workspaceNumber: 1))
    }

    @Test func rejectsZeroWorkspaceNumber() {
        do {
            _ = try CLIParser.parse(arguments: ["omniwmctl", "command", "switch-workspace", "0"])
            Issue.record("Expected parser failure")
        } catch let error as CLIParseError {
            #expect(error == .usage(CLIParser.usageText))
        } catch {
            Issue.record("Unexpected parser error: \(error)")
        }
    }

    @Test func rejectsInvalidResizeOperation() {
        do {
            _ = try CLIParser.parse(arguments: ["omniwmctl", "command", "resize", "left", "bigger"])
            Issue.record("Expected parser failure")
        } catch let error as CLIParseError {
            #expect(error == .usage(CLIParser.usageText))
        } catch {
            Issue.record("Unexpected parser error: \(error)")
        }
    }

    @Test func rejectsInvalidLayoutValue() {
        do {
            _ = try CLIParser.parse(arguments: ["omniwmctl", "command", "set-workspace-layout", "grid"])
            Issue.record("Expected parser failure")
        } catch let error as CLIParseError {
            #expect(error == .usage(CLIParser.usageText))
        } catch {
            Issue.record("Unexpected parser error: \(error)")
        }
    }

    @Test func parsesQueryMonitorAliasesAndDisplaySelectorAlias() throws {
        let parsed = try CLIParser.parse(
            arguments: ["omniwmctl", "query", "monitors", "--monitor", "Built-in Retina Display"]
        )

        #expect(parsed.outputFormat == .json)
        guard case let .query(query) = parsed.request.payload else {
            Issue.record("Expected a query payload")
            return
        }

        #expect(query.name == .displays)
        #expect(query.selectors.display == "Built-in Retina Display")
    }

    @Test func parsesCommandAliasesForPreviousAndBackAndForth() throws {
        let previous = try CLIParser.parse(arguments: ["omniwmctl", "command", "focus-monitor", "previous"])
        let workspacePrevious = try CLIParser.parse(
            arguments: ["omniwmctl", "command", "switch-workspace", "previous"]
        )
        let back = try CLIParser.parse(arguments: ["omniwmctl", "command", "switch-workspace", "back"])

        guard case let .command(previousCommand) = previous.request.payload else {
            Issue.record("Expected a focus-monitor command payload")
            return
        }
        guard case let .command(workspacePreviousCommand) = workspacePrevious.request.payload else {
            Issue.record("Expected a switch-workspace previous command payload")
            return
        }
        guard case let .command(backCommand) = back.request.payload else {
            Issue.record("Expected a switch-workspace command payload")
            return
        }

        #expect(previousCommand == .focusMonitorPrevious)
        #expect(workspacePreviousCommand == .switchWorkspacePrevious)
        #expect(backCommand == .switchWorkspaceBackAndForth)
    }

    @Test func parsesRuleCommandsAndExplicitOutputFormats() throws {
        let add = try CLIParser.parse(
            arguments: [
                "omniwmctl",
                "--format", "table",
                "rule",
                "add",
                "--bundle-id", "com.example.terminal",
                "--title-substring", "Shell",
                "--layout", "float",
            ]
        )
        let moveId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!.uuidString
        let replace = try CLIParser.parse(
            arguments: [
                "omniwmctl",
                "rule",
                "replace",
                moveId,
                "--bundle-id", "com.example.browser",
                "--title-regex", "Docs.*",
                "--layout", "tile",
            ]
        )
        let remove = try CLIParser.parse(arguments: ["omniwmctl", "rule", "remove", moveId])
        let move = try CLIParser.parse(arguments: ["omniwmctl", "rule", "move", moveId, "2"])

        #expect(add.outputFormat == .table)
        guard case let .rule(addRule) = add.request.payload else {
            Issue.record("Expected a rule payload")
            return
        }
        guard case let .add(definition) = addRule else {
            Issue.record("Expected add rule request")
            return
        }
        #expect(definition.bundleId == "com.example.terminal")
        #expect(definition.titleSubstring == "Shell")
        #expect(definition.layout == .float)

        guard case let .rule(replaceRule) = replace.request.payload else {
            Issue.record("Expected a replace rule payload")
            return
        }
        guard case let .replace(replaceId, replaceDefinition) = replaceRule else {
            Issue.record("Expected replace rule request")
            return
        }
        #expect(replaceId == moveId)
        #expect(replaceDefinition.bundleId == "com.example.browser")
        #expect(replaceDefinition.titleRegex == "Docs.*")
        #expect(replaceDefinition.layout == .tile)

        guard case let .rule(removeRule) = remove.request.payload else {
            Issue.record("Expected a remove rule payload")
            return
        }
        #expect(removeRule == .remove(id: moveId))

        guard case let .rule(moveRule) = move.request.payload else {
            Issue.record("Expected a move rule payload")
            return
        }
        #expect(moveRule == .move(id: moveId, position: 2))
    }

    @Test func parsesRuleApplyTargets() throws {
        let bare = try CLIParser.parse(arguments: ["omniwmctl", "rule", "apply"])
        let focused = try CLIParser.parse(arguments: ["omniwmctl", "rule", "apply", "--focused"])
        let window = try CLIParser.parse(arguments: ["omniwmctl", "rule", "apply", "--window", "ow_window"])
        let pid = try CLIParser.parse(arguments: ["omniwmctl", "rule", "apply", "--pid", "42"])

        guard case let .rule(bareRule) = bare.request.payload else {
            Issue.record("Expected a bare rule payload")
            return
        }
        guard case let .rule(focusedRule) = focused.request.payload else {
            Issue.record("Expected a focused rule payload")
            return
        }
        guard case let .rule(windowRule) = window.request.payload else {
            Issue.record("Expected a window rule payload")
            return
        }
        guard case let .rule(pidRule) = pid.request.payload else {
            Issue.record("Expected a pid rule payload")
            return
        }

        #expect(bareRule == .apply(target: .focused))
        #expect(focusedRule == .apply(target: .focused))
        #expect(windowRule == .apply(target: .window(windowId: "ow_window")))
        #expect(pidRule == .apply(target: .pid(42)))
    }

    @Test func rejectsMixedRuleApplySelectors() {
        do {
            _ = try CLIParser.parse(
                arguments: ["omniwmctl", "rule", "apply", "--focused", "--pid", "42"]
            )
            Issue.record("Expected parser failure")
        } catch let error as CLIParseError {
            #expect(error == .usage(CLIParser.usageText))
        } catch {
            Issue.record("Unexpected parser error: \(error)")
        }
    }

    @Test func parsesCompletionAsLocalInvocation() throws {
        let parsed = try CLIParser.parse(arguments: ["omniwmctl", "completion", "bash"])

        #expect(parsed.outputFormat == .text)
        #expect(parsed.expectsEventStream == false)
        #expect(parsed.watchConfiguration == nil)
        #expect(parsed.invocation == .local(.completion(.bash)))
    }
}

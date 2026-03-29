import Foundation
import Testing

import OmniWMIPC

private func assertRoundTrip<T: Codable & Equatable>(_ value: T) throws {
    let data = try IPCWire.makeEncoder(prettyPrinted: true).encode(value)
    let decoded = try IPCWire.makeDecoder().decode(T.self, from: data)
    #expect(decoded == value)
}

@Suite struct IPCModelsTests {
    @Test func requestRoundTripsThroughNDJSONWireFormat() throws {
        let request = IPCRequest(
            id: "req-1",
            command: .focus(direction: .left),
            authorizationToken: "secret-token"
        )

        let encoded = try IPCWire.encodeRequestLine(request)
        let decoded = try IPCWire.decodeRequest(from: Data(encoded.dropLast()))

        #expect(decoded == request)
    }

    @Test func responseAndEventRoundTripThroughNDJSONWireFormat() throws {
        let response = IPCResponse.success(
            id: "req-2",
            kind: .query,
            result: IPCResult(
                focusedWindow: IPCFocusedWindowQueryResult(
                    window: IPCFocusedWindowSnapshot(
                        id: "ow_test",
                        workspace: IPCWorkspaceRef(id: "ws-1", rawName: "1", displayName: "1", number: 1),
                        display: IPCDisplayRef(id: "display:1", name: "Main", isMain: true),
                        app: IPCAppRef(name: "Terminal", bundleId: "com.example.terminal"),
                        title: "Shell",
                        frame: IPCRect(x: 1, y: 2, width: 3, height: 4)
                    )
                )
            )
        )
        let event = IPCEventEnvelope.success(
            id: "evt-1",
            channel: .focus,
            result: IPCResult(
                focusedWindow: IPCFocusedWindowQueryResult(window: nil)
            )
        )

        let decodedResponse = try IPCWire.decodeResponse(from: Data(IPCWire.encodeResponseLine(response).dropLast()))
        let decodedEvent = try IPCWire.decodeEvent(from: Data(IPCWire.encodeEventLine(event).dropLast()))

        #expect(decodedResponse == response)
        #expect(decodedEvent == event)
    }

    @Test func responseEnvelopeEncodesTopLevelKind() throws {
        let response = IPCResponse.success(
            id: "req-3",
            kind: .query,
            result: IPCResult(
                apps: IPCAppsQueryResult(apps: [])
            )
        )

        let encoded = try IPCWire.encodeResponseLine(response)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(encoded.dropLast())) as? [String: Any]
        )

        #expect(object["kind"] as? String == IPCResponseKind.query.rawValue)
        #expect(object["id"] as? String == "req-3")
    }

    @Test func eventEnvelopeDecodesLegacyShapeWithoutStableResponseFields() throws {
        let legacyJSON = """
        {
          "channel": "focus",
          "kind": "event",
          "result": {
            "kind": "focused-window",
            "payload": {
              "window": null
            }
          },
          "version": 1
        }
        """

        let decoded = try IPCWire.decodeEvent(from: Data(legacyJSON.utf8))

        #expect(decoded.id.isEmpty)
        #expect(decoded.ok)
        #expect(decoded.status == .success)
        #expect(decoded.code == nil)
        #expect(decoded.channel == .focus)
    }

    @Test func publicDTOsRoundTripThroughJSON() throws {
        #expect(OmniWMIPCProtocol.version == 3)
        #expect(IPCErrorCode.protocolMismatch.rawValue == "protocol_mismatch")

        try assertRoundTrip(
            IPCWorkspaceRef(id: "ws-1", rawName: "1", displayName: "Main", number: 1)
        )
        try assertRoundTrip(
            IPCDisplayRef(id: "display:1", name: "Main", isMain: true)
        )
        try assertRoundTrip(
            IPCAppRef(name: "Terminal", bundleId: "com.example.terminal")
        )
        try assertRoundTrip(
            IPCWorkspaceWindowCounts(total: 4, tiled: 2, floating: 1, scratchpad: 1)
        )
        try assertRoundTrip(
            IPCWorkspaceSummary(id: "ws-1", rawName: "1", displayName: "Main", number: 1)
        )
        try assertRoundTrip(
            IPCWorkspaceBarQueryResult(
                interactionMonitorId: "display:1",
                monitors: [
                    IPCWorkspaceBarMonitor(
                        id: "display:1",
                        name: "Main",
                        enabled: true,
                        isVisible: true,
                        showLabels: true,
                        backgroundOpacity: 0.75,
                        barHeight: 28,
                        workspaces: [
                            IPCWorkspaceBarWorkspace(
                                id: "ws-1",
                                rawName: "1",
                                displayName: "One",
                                number: 1,
                                isFocused: true,
                                windows: [
                                    IPCWorkspaceBarApp(
                                        id: "ow_app",
                                        appName: "Terminal",
                                        isFocused: true,
                                        windowCount: 1,
                                        allWindows: [
                                            IPCWorkspaceBarWindow(
                                                id: "ow_window",
                                                title: "Shell",
                                                isFocused: true
                                            )
                                        ]
                                    )
                                ]
                            )
                        ]
                    )
                ]
            )
        )
        try assertRoundTrip(
            IPCActiveWorkspaceQueryResult(
                display: IPCDisplayRef(id: "display:1", name: "Main", isMain: true),
                workspace: IPCWorkspaceRef(id: "ws-1", rawName: "1", displayName: "One", number: 1),
                focusedApp: IPCAppRef(name: "Terminal", bundleId: "com.example.terminal")
            )
        )
        try assertRoundTrip(
            IPCFocusedMonitorQueryResult(
                display: IPCDisplayRef(id: "display:1", name: "Main", isMain: true),
                activeWorkspace: IPCWorkspaceRef(id: "ws-1", rawName: "1", displayName: "One", number: 1)
            )
        )
        try assertRoundTrip(
            IPCAppsQueryResult(
                apps: [
                    IPCManagedAppSummary(
                        bundleId: "com.example.terminal",
                        appName: "Terminal",
                        windowSize: IPCSize(width: 1440, height: 900)
                    )
                ]
            )
        )
        try assertRoundTrip(
            IPCFocusedWindowQueryResult(
                window: IPCFocusedWindowSnapshot(
                    id: "ow_window",
                    pid: 42,
                    workspace: IPCWorkspaceRef(id: "ws-1", rawName: "1", displayName: "One", number: 1),
                    display: IPCDisplayRef(id: "display:1", name: "Main", isMain: true),
                    app: IPCAppRef(name: "Terminal", bundleId: "com.example.terminal"),
                    title: "Shell",
                    frame: IPCRect(x: 0, y: 0, width: 100, height: 100)
                )
            )
        )
        try assertRoundTrip(
            IPCQueriesQueryResult(
                queries: IPCAutomationManifest.queryDescriptors
            )
        )
        try assertRoundTrip(
            IPCWindowsQueryResult(
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
        try assertRoundTrip(
            IPCRuleActionsQueryResult(
                ruleActions: IPCAutomationManifest.ruleActionDescriptors
            )
        )
        try assertRoundTrip(
            IPCQueryRequest(
                name: .windows,
                selectors: IPCQuerySelectors(
                    workspace: "1",
                    visible: true,
                    bundleId: "com.example.terminal"
                ),
                fields: ["id", "workspace", "app", "title"]
            )
        )
        try assertRoundTrip(
            IPCRuleDefinition(
                bundleId: "com.example.terminal",
                appNameSubstring: "Terminal",
                titleSubstring: "Shell",
                titleRegex: "Shell.*",
                axRole: "AXWindow",
                axSubrole: "AXStandardWindow",
                layout: .float,
                assignToWorkspace: "2",
                minWidth: 640,
                minHeight: 480
            )
        )
        try assertRoundTrip(
            IPCRuleRequest.replace(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!.uuidString,
                rule: IPCRuleDefinition(
                    bundleId: "com.example.browser",
                    titleRegex: "Docs.*",
                    layout: .tile
                )
            )
        )
        try assertRoundTrip(IPCRuleApplyTarget.focused)
        try assertRoundTrip(IPCRuleApplyTarget.window(windowId: "ow_window"))
        try assertRoundTrip(IPCRuleApplyTarget.pid(42))
        try assertRoundTrip(
            IPCRuleActionOptionDescriptor(
                flag: "--window",
                summary: "Target a specific window.",
                valuePlaceholder: "<opaque-id>",
                exclusiveGroup: "target"
            )
        )
        try assertRoundTrip(
            IPCRuleRequest.apply(
                target: .window(windowId: "ow_window")
            )
        )
        try assertRoundTrip(
            IPCRulesQueryResult(
                rules: [
                    IPCRuleSnapshot(
                        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!.uuidString,
                        position: 1,
                        bundleId: "com.example.terminal",
                        appNameSubstring: "Terminal",
                        titleSubstring: "Shell",
                        titleRegex: "Shell.*",
                        axRole: "AXWindow",
                        axSubrole: "AXStandardWindow",
                        layout: .float,
                        assignToWorkspace: "2",
                        minWidth: 640,
                        minHeight: 480,
                        specificity: 5,
                        isValid: true
                    )
                ]
            )
        )
        try assertRoundTrip(
            IPCFocusedWindowDecisionQueryResult(
                window: IPCFocusedWindowDecisionSnapshot(
                    id: "ow_window",
                    app: IPCAppRef(name: "Terminal", bundleId: "com.example.terminal"),
                    title: "Shell",
                    axRole: "AXWindow",
                    axSubrole: nil,
                    appFullscreen: false,
                    manualOverride: .forceTile,
                    disposition: .managed,
                    source: "heuristic",
                    layoutDecisionKind: .fallbackLayout,
                    deferredReason: nil,
                    admissionOutcome: .trackedTiling,
                    workspace: IPCWorkspaceRef(id: "ws-1", rawName: "1", displayName: "One", number: 1),
                    minWidth: 200,
                    minHeight: 100,
                    matchedRuleId: nil,
                    heuristicReasons: ["normal-window"],
                    attributeFetchSucceeded: true
                )
            )
        )
        try assertRoundTrip(
            IPCCapabilitiesQueryResult(
                appVersion: "1.2.3",
                authorizationRequired: true,
                windowIdScope: "session",
                queries: IPCAutomationManifest.queryDescriptors,
                commands: IPCAutomationManifest.commandDescriptors,
                ruleActions: IPCAutomationManifest.ruleActionDescriptors,
                workspaceActions: IPCAutomationManifest.workspaceActionDescriptors,
                windowActions: IPCAutomationManifest.windowActionDescriptors,
                subscriptions: IPCAutomationManifest.subscriptionDescriptors
            )
        )
        try assertRoundTrip(IPCSubscribeResult(channels: [.focus, .workspaceBar]))
        try assertRoundTrip(
            IPCCommandRequest.moveToWorkspaceOnMonitor(workspaceNumber: 2, direction: .right)
        )
        try assertRoundTrip(
            IPCResponse.failure(
                id: "protocol-mismatch",
                kind: .query,
                code: .protocolMismatch,
                result: IPCResult(version: IPCVersionResult(protocolVersion: 3, appVersion: "1.2.3"))
            )
        )
    }

    @Test func manifestIncludesFocusedMonitorSurface() {
        #expect(IPCAutomationManifest.queryDescriptors.contains { $0.name == .focusedMonitor })
        #expect(IPCAutomationManifest.subscriptionDescriptors.contains { $0.channel == .focusedMonitor })
    }

    @Test func manifestPublishesPidFieldAndStructuredRuleApplyOptions() {
        #expect(IPCAutomationManifest.windowFieldCatalog.contains("pid"))
        let applyDescriptor = IPCAutomationManifest.ruleActionDescriptor(for: .apply)
        #expect(applyDescriptor?.arguments.isEmpty == true)
        #expect(applyDescriptor?.options.map(\.flag) == ["--focused", "--window", "--pid"])
        #expect(applyDescriptor?.options.allSatisfy { $0.exclusiveGroup == "target" } == true)
    }

    @Test func commandDescriptorsCoverEveryPublicCommandName() {
        let descriptorNames = Set(IPCAutomationManifest.commandDescriptors.map(\.name))

        #expect(descriptorNames == Set(IPCCommandName.allCases))
        #expect(IPCAutomationManifest.commandDescriptors.count == IPCCommandName.allCases.count)
    }

    @Test func queryDescriptorsCoverEveryPublicQueryName() {
        let descriptorNames = Set(IPCAutomationManifest.queryDescriptors.map(\.name))

        #expect(descriptorNames == Set(IPCQueryName.allCases))
        #expect(IPCAutomationManifest.queryDescriptors.count == IPCQueryName.allCases.count)
    }

    @Test func ruleActionDescriptorsCoverEveryPublicRuleActionName() {
        let descriptorNames = Set(IPCAutomationManifest.ruleActionDescriptors.map(\.name))

        #expect(descriptorNames == Set(IPCRuleActionName.allCases))
        #expect(IPCAutomationManifest.ruleActionDescriptors.count == IPCRuleActionName.allCases.count)
    }

    @Test func subscriptionDescriptorsCoverEveryPublicSubscriptionChannel() {
        let descriptorChannels = Set(IPCAutomationManifest.subscriptionDescriptors.map(\.channel))

        #expect(descriptorChannels == Set(IPCSubscriptionChannel.allCases))
        #expect(IPCAutomationManifest.subscriptionDescriptors.count == IPCSubscriptionChannel.allCases.count)
    }

    @Test func opaqueWindowIDSupportsSessionScopedValidation() {
        let encoded = IPCWindowOpaqueID.encode(pid: 4242, windowId: 73, sessionToken: "session-a")
        let decoded = IPCWindowOpaqueID.decode(encoded)
        let sessionDecoded = IPCWindowOpaqueID.decode(encoded, expectingSessionToken: "session-a")
        let legacyEncoded = IPCWindowOpaqueID.encode(pid: 4242, windowId: 73)

        #expect(decoded?.pid == 4242)
        #expect(decoded?.windowId == 73)
        #expect(sessionDecoded?.pid == 4242)
        #expect(sessionDecoded?.windowId == 73)
        #expect(IPCWindowOpaqueID.decode(encoded, expectingSessionToken: "session-b") == nil)
        #expect(IPCWindowOpaqueID.decode(legacyEncoded, expectingSessionToken: "session-a") == nil)
    }
}

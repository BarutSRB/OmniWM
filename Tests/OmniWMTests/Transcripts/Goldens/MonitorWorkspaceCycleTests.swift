// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing

@testable import OmniWM

@Suite(.serialized) struct MonitorWorkspaceCycleTests {
    @Test @MainActor func transcriptIsGoldenStable() {
        let context = makeTranscriptRuntimeContext(
            workspaceNames: ["1", "2"],
            monitorSpecs: [
                MonitorWorkspaceCycleTranscript.primarySpec,
                MonitorWorkspaceCycleTranscript.secondarySpec
            ]
        )
        let lhs = MonitorWorkspaceCycleTranscript.make(in: context)
        let rhs = MonitorWorkspaceCycleTranscript.make(in: context)
        #expect(lhs == rhs)
        #expect(lhs.steps.count == 3)
    }

    @Test @MainActor func transcriptRunsCleanlyEndToEnd() async throws {
        resetSharedControllerStateForTests()
        let platform = RecordingEffectPlatform()
        let settings = SettingsStore(defaults: makeLayoutPlanTestDefaults())
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .secondary)
        ]
        let runtime = WMRuntime(settings: settings, effectPlatform: platform)
        let monitors = [
            VirtualDisplayBoard.materialize(MonitorWorkspaceCycleTranscript.primarySpec),
            VirtualDisplayBoard.materialize(MonitorWorkspaceCycleTranscript.secondarySpec)
        ]
        runtime.controller.workspaceManager.applyMonitorConfigurationChange(monitors)
        let primaryMonitorId = monitors[0].id
        let secondaryMonitorId = monitors[1].id
        let workspaceOneId = try #require(runtime.controller.workspaceManager.workspaceId(
            for: "1",
            createIfMissing: true
        ))
        let workspaceTwoId = try #require(runtime.controller.workspaceManager.workspaceId(
            for: "2",
            createIfMissing: true
        ))
        _ = runtime.controller.workspaceManager.setActiveWorkspace(workspaceOneId, on: primaryMonitorId)
        _ = runtime.controller.workspaceManager.setActiveWorkspace(workspaceTwoId, on: secondaryMonitorId)
        _ = runtime.setInteractionMonitor(primaryMonitorId, source: .command)

        let context = TranscriptRuntimeContext(
            runtime: runtime,
            platform: platform,
            workspaceIdsByName: ["1": workspaceOneId, "2": workspaceTwoId],
            monitorIds: monitors.map(\.id)
        )
        let transcript = MonitorWorkspaceCycleTranscript.make(in: context)

        let driver = TranscriptReplayDriver(
            transcript: transcript,
            runtime: runtime,
            platform: platform
        )

        try await driver.run()
        #expect(platform.events.contains(
            .performLayoutMutationAction(kindForLog: "cycle_monitors", source: .command)
        ))
        #expect(runtime.controller.workspaceManager.activeWorkspace(on: primaryMonitorId)?.id == workspaceOneId)
        #expect(runtime.controller.workspaceManager.activeWorkspace(on: secondaryMonitorId)?.id == workspaceTwoId)
    }
}

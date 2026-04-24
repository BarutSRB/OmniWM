// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing

@testable import OmniWM

@MainActor
private func makeWorkspaceSwitchRuntimeSettings() -> SettingsStore {
    let settings = SettingsStore(defaults: makeLayoutPlanTestDefaults())
    settings.workspaceConfigurations = [
        WorkspaceConfiguration(name: "1", monitorAssignment: .main),
        WorkspaceConfiguration(name: "2", monitorAssignment: .main)
    ]
    return settings
}

@MainActor
private func makeWorkspaceSwitchRuntime(
    platform: RecordingEffectPlatform
) -> WMRuntime {
    resetSharedControllerStateForTests()
    let runtime = WMRuntime(
        settings: makeWorkspaceSwitchRuntimeSettings(),
        effectPlatform: platform
    )
    runtime.controller.workspaceManager.applyMonitorConfigurationChange([
        makeLayoutPlanTestMonitor()
    ])
    // Tests should start with workspace "1" active.
    if let workspaceOne = runtime.controller.workspaceManager.workspaceId(
        for: "1",
        createIfMissing: false
    ) {
        _ = runtime.controller.workspaceManager.setActiveWorkspace(
            workspaceOne,
            on: runtime.controller.workspaceManager.monitors.first!.id
        )
    }
    return runtime
}

@Suite(.serialized) struct WorkspaceSwitchTransactionTests {
    @Test @MainActor func submittingExplicitSwitchAllocatesFreshTransactionEpoch() {
        let platform = RecordingEffectPlatform()
        let runtime = makeWorkspaceSwitchRuntime(platform: platform)

        let result = runtime.submit(
            command: .workspaceSwitch(.explicit(rawWorkspaceID: "2"))
        )

        #expect(result.transactionEpoch.isValid)
        #expect(result.transactionEpoch == TransactionEpoch(value: 1))
        #expect(result.plan.transactionEpoch == result.transactionEpoch)
        #expect(!result.plan.isEmpty)
    }

    @Test @MainActor func successiveSubmissionsAdvanceTransactionEpoch() {
        let platform = RecordingEffectPlatform()
        let runtime = makeWorkspaceSwitchRuntime(platform: platform)

        let first = runtime.submit(
            command: .workspaceSwitch(.explicit(rawWorkspaceID: "2"))
        )
        let second = runtime.submit(
            command: .workspaceSwitch(.explicit(rawWorkspaceID: "1"))
        )

        #expect(first.transactionEpoch < second.transactionEpoch)
        #expect(second.transactionEpoch == TransactionEpoch(value: 2))
    }

    @Test @MainActor func effectEpochsAreMonotonicWithinAndAcrossPlans() {
        let platform = RecordingEffectPlatform()
        let runtime = makeWorkspaceSwitchRuntime(platform: platform)

        let first = runtime.submit(
            command: .workspaceSwitch(.explicit(rawWorkspaceID: "2"))
        )
        let second = runtime.submit(
            command: .workspaceSwitch(.explicit(rawWorkspaceID: "1"))
        )

        let firstEffectEpochs = first.plan.effects.map(\.epoch.value)
        let secondEffectEpochs = second.plan.effects.map(\.epoch.value)

        for pair in zip(firstEffectEpochs, firstEffectEpochs.dropFirst()) {
            #expect(pair.0 < pair.1, "within-plan effect epochs must strictly increase")
        }
        if let lastFirst = firstEffectEpochs.last,
           let firstSecond = secondEffectEpochs.first
        {
            #expect(lastFirst < firstSecond, "effect epochs must be monotonic across plans")
        }
    }

    @Test @MainActor func unknownWorkspaceProducesEmptyPlan() {
        let platform = RecordingEffectPlatform()
        let runtime = makeWorkspaceSwitchRuntime(platform: platform)

        let result = runtime.submit(
            command: .workspaceSwitch(.explicit(rawWorkspaceID: "does-not-exist"))
        )

        #expect(result.plan.isEmpty)
        #expect(result.transactionEpoch.isValid)
        #expect(platform.events.isEmpty, "empty plan must not invoke effects")
    }

    @Test @MainActor func planLeadsWithBorderHideAndEndsWithWorkspaceCommit() {
        let platform = RecordingEffectPlatform()
        let runtime = makeWorkspaceSwitchRuntime(platform: platform)

        let result = runtime.submit(
            command: .workspaceSwitch(.explicit(rawWorkspaceID: "2"))
        )

        #expect(result.plan.effects.first?.kind == "hide_keyboard_focus_border")
        #expect(result.plan.effects.last?.kind == "commit_workspace_transition")
    }

    @Test @MainActor func submitEventAlsoStampsTransactionEpoch() {
        let platform = RecordingEffectPlatform()
        let runtime = makeWorkspaceSwitchRuntime(platform: platform)

        // Observation-flavored path: transactionEpoch stamping must work
        // for `WMRuntime.submit(_ event:)` as well, so reconcile txns
        // produced via either entrypoint carry a valid epoch.
        let txn = runtime.submit(.activeSpaceChanged(source: .workspaceManager))
        #expect(txn.transactionEpoch.isValid)
    }

    @Test @MainActor func recordReconcileEventWithoutRuntimeHasInvalidEpoch() {
        resetSharedControllerStateForTests()
        let settings = makeWorkspaceSwitchRuntimeSettings()
        let manager = WorkspaceManager(settings: settings)
        manager.applyMonitorConfigurationChange([makeLayoutPlanTestMonitor()])

        // Bypassing the transaction entrypoint must produce an unstamped
        // txn. This is the discriminator for direct-mutation paths still
        // awaiting migration.
        let txn = manager.recordReconcileEvent(
            .activeSpaceChanged(source: .workspaceManager)
        )
        #expect(!txn.transactionEpoch.isValid)
    }
}

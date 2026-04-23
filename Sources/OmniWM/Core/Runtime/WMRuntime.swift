// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Observation

@MainActor @Observable
final class WMRuntime {
    let settings: SettingsStore
    let platform: WMPlatform
    let workspaceManager: WorkspaceManager
    let hiddenBarController: HiddenBarController
    let controller: WMController
    private let effectExecutor: any EffectExecutor
    private(set) var snapshot: WMRuntimeSnapshot

    var state: WMState {
        snapshot.reconcile
    }

    var orchestrationSnapshot: OrchestrationSnapshot {
        snapshot.orchestration
    }

    var refreshSnapshot: RefreshOrchestrationSnapshot {
        snapshot.orchestration.refresh
    }

    var configuration: WMRuntimeConfiguration {
        snapshot.configuration
    }

    init(
        settings: SettingsStore,
        platform: WMPlatform = .live,
        hiddenBarController: HiddenBarController? = nil,
        windowFocusOperations: WindowFocusOperations? = nil,
        effectExecutor: (any EffectExecutor)? = nil
    ) {
        self.settings = settings
        self.platform = platform
        let resolvedHiddenBarController = hiddenBarController ?? HiddenBarController(settings: settings)
        self.hiddenBarController = resolvedHiddenBarController
        let workspaceManager = WorkspaceManager(settings: settings)
        self.workspaceManager = workspaceManager
        controller = WMController(
            settings: settings,
            workspaceManager: workspaceManager,
            hiddenBarController: resolvedHiddenBarController,
            platform: platform,
            windowFocusOperations: windowFocusOperations ?? platform.windowFocusOperations
        )
        self.effectExecutor = effectExecutor ?? WMRuntimeEffectExecutor()
        snapshot = WMRuntimeSnapshot(
            reconcile: workspaceManager.reconcileSnapshot(),
            orchestration: .init(
                refresh: .init(),
                focus: Self.makeFocusSnapshot(
                    controller: controller,
                    workspaceManager: workspaceManager
                )
            ),
            configuration: WMRuntimeConfiguration(settings: settings)
        )
        controller.runtime = self
    }

    func start() {
        applyCurrentConfiguration()
    }

    func applyCurrentConfiguration() {
        applyConfiguration(WMRuntimeConfiguration(settings: settings))
    }

    func applyConfiguration(_ configuration: WMRuntimeConfiguration) {
        snapshot.configuration = configuration
        controller.applyConfiguration(configuration)
        refreshSnapshotState()
    }

    func flushState() {
        workspaceManager.flushPersistedWindowRestoreCatalogNow()
        settings.flushNow()
    }

    @discardableResult
    func submit(_ event: WMEvent) -> ReconcileTxn {
        let transaction = workspaceManager.recordReconcileEvent(event)
        refreshSnapshotState()
        return transaction
    }

    func requestManagedFocus(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> OrchestrationResult {
        apply(
            .focusRequested(
                .init(
                    token: token,
                    workspaceId: workspaceId
                )
            ),
            context: .focusRequest
        )
    }

    func observeActivation(
        _ observation: ManagedActivationObservation,
        observedAXRef: AXWindowRef?,
        managedEntry: WindowModel.Entry?,
        confirmRequest: Bool = true
    ) -> OrchestrationResult {
        apply(
            .activationObserved(observation),
            context: .activationObserved(
                observedAXRef: observedAXRef,
                managedEntry: managedEntry,
                source: observation.source,
                confirmRequest: confirmRequest
            )
        )
    }

    func requestRefresh(
        _ request: RefreshRequestEvent
    ) -> OrchestrationResult {
        apply(
            .refreshRequested(request),
            context: .refresh
        )
    }

    func completeRefresh(
        _ completion: RefreshCompletionEvent
    ) -> OrchestrationResult {
        apply(
            .refreshCompleted(completion),
            context: .refresh
        )
    }

    func resetRefreshOrchestration() {
        snapshot.orchestration.refresh = .init()
    }

    private func apply(
        _ event: OrchestrationEvent,
        context: WMRuntimeEffectContext
    ) -> OrchestrationResult {
        synchronizeOrchestrationInputs()

        let result = OrchestrationCore.step(
            snapshot: snapshot.orchestration,
            event: event
        )
        snapshot.orchestration = result.snapshot

        effectExecutor.execute(
            result,
            on: controller,
            context: context
        )

        refreshSnapshotState()
        return result
    }

    private func synchronizeOrchestrationInputs() {
        snapshot.reconcile = workspaceManager.reconcileSnapshot()
        snapshot.orchestration.focus = Self.makeFocusSnapshot(
            controller: controller,
            workspaceManager: workspaceManager
        )
    }

    private func refreshSnapshotState() {
        snapshot.reconcile = workspaceManager.reconcileSnapshot()
        snapshot.orchestration.focus = Self.makeFocusSnapshot(
            controller: controller,
            workspaceManager: workspaceManager
        )
    }

    private static func makeFocusSnapshot(
        controller: WMController,
        workspaceManager: WorkspaceManager
    ) -> FocusOrchestrationSnapshot {
        .init(
            nextManagedRequestId: controller.focusBridge.nextManagedRequestId,
            activeManagedRequest: controller.focusBridge.activeManagedRequest,
            pendingFocusedToken: workspaceManager.pendingFocusedToken,
            pendingFocusedWorkspaceId: workspaceManager.pendingFocusedWorkspaceId,
            isNonManagedFocusActive: workspaceManager.isNonManagedFocusActive,
            isAppFullscreenActive: workspaceManager.isAppFullscreenActive
        )
    }
}

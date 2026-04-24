// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Observation

@MainActor @Observable
final class WMRuntime {
    // Result of submitting a `WMCommand` through the authoritative
    // transaction path. `txn` is present only when the command also
    // produced an observation-shaped reconcile transaction (none today
    // for workspace-switch commands, which flow through downstream
    // reconcile events emitted by the individual effects).
    struct CommandResult {
        let transactionEpoch: TransactionEpoch
        let plan: WMEffectPlan
        let applyOutcome: WMEffectRunner.ApplyOutcome
        let txn: ReconcileTxn?
    }

    let settings: SettingsStore
    let platform: WMPlatform
    let workspaceManager: WorkspaceManager
    let hiddenBarController: HiddenBarController
    let controller: WMController
    @ObservationIgnored private let effectExecutor: any EffectExecutor
    @ObservationIgnored private let effectRunner: WMEffectRunner
    private(set) var snapshot: WMRuntimeSnapshot

    // Monotonic, process-scoped counters owned by the runtime. Kept
    // outside `WMEffectPlan` per Phase 01 decision: the plan carries the
    // committed transactionEpoch and individual effect epochs, but the
    // allocator sits on the runtime so cross-plan uniqueness is
    // guaranteed without having to propagate mutable state through the
    // plan shape.
    @ObservationIgnored private var nextTransactionEpochValue: UInt64 = 1
    @ObservationIgnored private var nextEffectEpochValue: UInt64 = 1

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
        effectExecutor: (any EffectExecutor)? = nil,
        effectPlatform: (any WMEffectPlatform)? = nil
    ) {
        self.settings = settings
        self.platform = platform
        let resolvedHiddenBarController = hiddenBarController ?? HiddenBarController(settings: settings)
        self.hiddenBarController = resolvedHiddenBarController
        let workspaceManager = WorkspaceManager(settings: settings)
        self.workspaceManager = workspaceManager
        let controller = WMController(
            settings: settings,
            workspaceManager: workspaceManager,
            hiddenBarController: resolvedHiddenBarController,
            platform: platform,
            windowFocusOperations: windowFocusOperations ?? platform.windowFocusOperations
        )
        self.controller = controller
        self.effectExecutor = effectExecutor ?? WMRuntimeEffectExecutor()
        let resolvedEffectPlatform = effectPlatform ?? WMLiveEffectPlatform(controller: controller)
        effectRunner = WMEffectRunner(platform: resolvedEffectPlatform)
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
        let epoch = allocateTransactionEpoch()
        let transaction = workspaceManager.recordReconcileEvent(
            event,
            transactionEpoch: epoch
        )
        refreshSnapshotState()
        return transaction
    }

    // Authoritative command entrypoint. Allocates a fresh
    // `TransactionEpoch`, translates the command into a `WMEffectPlan`,
    // and hands the plan to the runtime's effect runner. The runner is
    // responsible for applying effects in order and rejecting stale
    // confirmations by epoch.
    //
    // Phase 01 Milestone A: only `workspaceSwitch` commands are routed
    // through this entrypoint. See `docs/RELIABILITY-MIGRATION.md` for
    // the open migration list.
    @discardableResult
    func submit(command: WMCommand) -> CommandResult {
        let transactionEpoch = allocateTransactionEpoch()
        let plan = buildEffectPlan(
            for: command,
            transactionEpoch: transactionEpoch
        )
        let applyOutcome = effectRunner.apply(plan)
        refreshSnapshotState()
        return CommandResult(
            transactionEpoch: transactionEpoch,
            plan: plan,
            applyOutcome: applyOutcome,
            txn: nil
        )
    }

    private func buildEffectPlan(
        for command: WMCommand,
        transactionEpoch: TransactionEpoch
    ) -> WMEffectPlan {
        switch command {
        case let .workspaceSwitch(switchCommand):
            return WorkspaceSwitchEffectPlanner.makePlan(
                for: switchCommand,
                inputs: .init(
                    controller: controller,
                    transactionEpoch: transactionEpoch,
                    allocateEffectEpoch: { [weak self] in
                        self?.allocateEffectEpoch() ?? .invalid
                    }
                )
            )
        }
    }

    private func allocateTransactionEpoch() -> TransactionEpoch {
        let value = nextTransactionEpochValue
        nextTransactionEpochValue &+= 1
        return TransactionEpoch(value: value)
    }

    private func allocateEffectEpoch() -> EffectEpoch {
        let value = nextEffectEpochValue
        nextEffectEpochValue &+= 1
        return EffectEpoch(value: value)
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

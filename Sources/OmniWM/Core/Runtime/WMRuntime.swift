// SPDX-License-Identifier: GPL-2.0-only
import CoreGraphics
import Foundation
import Observation
import OSLog
import OmniWMIPC

@MainActor @Observable
final class WMRuntime: RuntimeSnapshotPublishing {
    struct CommandResult {
        let transactionEpoch: TransactionEpoch
        let transaction: Transaction
        let applyOutcome: WMEffectRunner.ApplyOutcome
        let externalCommandResult: ExternalCommandResult?
    }

    struct ManagedFocusRequestBeginResult {
        let changed: Bool
        let transactionEpoch: TransactionEpoch
    }

    let settings: SettingsStore
    let platform: WMPlatform
    let workspaceManager: WorkspaceManager
    let hiddenBarController: HiddenBarController
    let controller: WMController
    let capabilityProfileResolver: WindowCapabilityProfileResolver
    @ObservationIgnored private let effectExecutor: any EffectExecutor
    @ObservationIgnored let effectRunner: WMEffectRunner
    @ObservationIgnored let kernel: RuntimeKernel
    @ObservationIgnored let mutationCoordinator: RuntimeMutationCoordinator
    @ObservationIgnored let controllerOperations: RuntimeControllerOperations
    private var intakeLog: Logger { kernel.intakeLog }
    private var intakeSignpost: OSSignposter { kernel.intakeSignpost }
    var currentTopologyEpoch: TopologyEpoch { kernel.currentTopologyEpoch }
    /// Per-domain runtime composition. Domain runtimes own mutation entrypoints
    /// and share `mutationCoordinator` for epoch stamping and snapshot publish.
    @ObservationIgnored let focusRuntime: FocusRuntime
    @ObservationIgnored let frameRuntime: FrameRuntime
    @ObservationIgnored let nativeFullscreenRuntime: NativeFullscreenRuntime
    @ObservationIgnored let workspaceRuntime: WorkspaceRuntime
    @ObservationIgnored let monitorRuntime: MonitorRuntime
    @ObservationIgnored let windowAdmissionRuntime: WindowAdmissionRuntime
    @ObservationIgnored let capabilityRuntime: CapabilityRuntime
    @ObservationIgnored let controllerActionRuntime: ControllerActionRuntime
    @ObservationIgnored let uiActionRuntime: UIActionRuntime
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
        capabilityProfileResolver = WindowCapabilityProfileResolver()
        workspaceManager.capabilityProfileResolverRef = capabilityProfileResolver
        controller.windowRuleEngine.setCapabilityResolver(capabilityProfileResolver)
        self.effectExecutor = effectExecutor ?? WMRuntimeEffectExecutor()
        let resolvedEffectPlatform = effectPlatform ?? WMLiveEffectPlatform(controller: controller)
        let resolvedEffectRunner = WMEffectRunner(platform: resolvedEffectPlatform)
        effectRunner = resolvedEffectRunner
        let resolvedKernel = RuntimeKernel()
        kernel = resolvedKernel
        let resolvedMutationCoordinator = RuntimeMutationCoordinator(
            kernel: resolvedKernel,
            effectRunner: resolvedEffectRunner,
            workspaceManager: workspaceManager
        )
        mutationCoordinator = resolvedMutationCoordinator
        let resolvedControllerOperations = RuntimeControllerOperations(controller: controller)
        controllerOperations = resolvedControllerOperations
        focusRuntime = FocusRuntime(
            kernel: resolvedKernel,
            effectRunner: resolvedEffectRunner,
            mutationCoordinator: resolvedMutationCoordinator,
            controllerOperations: resolvedControllerOperations,
            workspaceManager: workspaceManager
        )
        frameRuntime = FrameRuntime(
            kernel: resolvedKernel,
            effectRunner: resolvedEffectRunner,
            mutationCoordinator: resolvedMutationCoordinator,
            workspaceManager: workspaceManager
        )
        nativeFullscreenRuntime = NativeFullscreenRuntime(
            kernel: resolvedKernel,
            effectRunner: resolvedEffectRunner,
            mutationCoordinator: resolvedMutationCoordinator,
            workspaceManager: workspaceManager
        )
        workspaceRuntime = WorkspaceRuntime(
            kernel: resolvedKernel,
            effectRunner: resolvedEffectRunner,
            mutationCoordinator: resolvedMutationCoordinator,
            controllerOperations: resolvedControllerOperations,
            workspaceManager: workspaceManager
        )
        monitorRuntime = MonitorRuntime(
            kernel: resolvedKernel,
            effectRunner: resolvedEffectRunner,
            mutationCoordinator: resolvedMutationCoordinator,
            workspaceManager: workspaceManager
        )
        windowAdmissionRuntime = WindowAdmissionRuntime(
            kernel: resolvedKernel,
            effectRunner: resolvedEffectRunner,
            mutationCoordinator: resolvedMutationCoordinator,
            controllerOperations: resolvedControllerOperations,
            workspaceManager: workspaceManager
        )
        capabilityRuntime = CapabilityRuntime(
            kernel: resolvedKernel,
            resolver: capabilityProfileResolver
        )
        controllerActionRuntime = ControllerActionRuntime(
            mutationCoordinator: resolvedMutationCoordinator,
            controllerOperations: resolvedControllerOperations
        )
        uiActionRuntime = UIActionRuntime(
            mutationCoordinator: resolvedMutationCoordinator,
            controllerOperations: resolvedControllerOperations
        )
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
        mutationCoordinator.snapshotPublisher = self
    }

    func start() {
        applyCurrentConfiguration()
    }

    func shutdown() {
        controller.serviceLifecycleManager.stop()
        flushState()
    }

    func applyCurrentConfiguration() {
        applyConfiguration(WMRuntimeConfiguration(settings: settings))
    }

    func applyConfiguration(_ configuration: WMRuntimeConfiguration) {
        snapshot.configuration = configuration
        capabilityProfileResolver.applyTOMLOverrides(settings.capabilityOverrides)
        controller.windowRuleEngine.refreshCapabilityRules()
        controller.applyConfiguration(configuration)
        refreshSnapshotState()
    }

    @discardableResult
    func applyWorkspaceSettings(source: WMEventSource = .config) -> Bool {
        workspaceRuntime.applyWorkspaceSettings(source: source)
    }

    @discardableResult
    func materializeWorkspace(
        named rawWorkspaceID: String,
        source: WMEventSource = .command
    ) -> WorkspaceDescriptor.ID? {
        workspaceRuntime.materializeWorkspace(named: rawWorkspaceID, source: source)
    }

    @discardableResult
    func withNiriViewportState<Result>(
        for workspaceId: WorkspaceDescriptor.ID,
        source: WMEventSource = .command,
        _ mutate: (inout ViewportState) -> Result
    ) -> Result {
        workspaceRuntime.withNiriViewportState(for: workspaceId, source: source, mutate)
    }

    func flushState() {
        workspaceManager.flushPersistedWindowRestoreCatalogNow()
        settings.flushNow()
    }

    @discardableResult
    func submit(_ event: WMEvent) -> Transaction {
        let epoch = allocateTransactionEpoch()
        let signpostId = intakeSignpost.makeSignpostID()
        let signpostState = intakeSignpost.beginInterval(
            "submit_event",
            id: signpostId,
            "kind=\(event.kindForLog) source=\(event.source.rawValue) txn=\(epoch.value)"
        )
        let startTime = ContinuousClock.now

        if event.isConfirmationFlavored {
            guard let originating = event.originatingTransactionEpoch,
                  originating.isValid
            else {
                let snapshot = workspaceManager.reconcileSnapshot()
                let rejected = Transaction(
                    event: event,
                    normalizedEvent: event,
                    transactionEpoch: epoch,
                    effects: [],
                    snapshot: snapshot,
                    invariantViolations: []
                ).completedWithValidatedSnapshot(snapshot)
                refreshSnapshotState()
                let durationMicros = Self.elapsedMicros(since: startTime)
                intakeSignpost.endInterval("submit_event", signpostState)
                intakeLog.debug(
                    "event_rejected_unstamped_confirmation kind=\(event.kindForLog, privacy: .public) source=\(event.source.rawValue, privacy: .public) txn=\(epoch.value) us=\(durationMicros)"
                )
                return rejected
            }

            if originating < effectRunner.highestAcceptedTransactionEpoch {
                let snapshot = workspaceManager.reconcileSnapshot()
                let rejected = Transaction(
                    event: event,
                    normalizedEvent: event,
                    transactionEpoch: epoch,
                    effects: [],
                    snapshot: snapshot,
                    invariantViolations: []
                ).completedWithValidatedSnapshot(snapshot)
                refreshSnapshotState()
                let durationMicros = Self.elapsedMicros(since: startTime)
                intakeSignpost.endInterval("submit_event", signpostState)
                let highValue = effectRunner.highestAcceptedTransactionEpoch.value
                intakeLog.debug(
                    "event_rejected_superseded kind=\(event.kindForLog, privacy: .public) source=\(event.source.rawValue, privacy: .public) txn=\(epoch.value) origin_txn=\(originating.value) high=\(highValue) us=\(durationMicros)"
                )
                return rejected
            }
        }

        let preparedTransaction = workspaceManager.prepareTransaction(
            event,
            transactionEpoch: epoch,
            effects: []
        )
        let applyOutcome = effectRunner.apply(
            preparedTransaction,
            postApplySnapshot: { [workspaceManager] in
                workspaceManager.reconcileSnapshot()
            }
        )
        let transaction = workspaceManager.recordTransaction(applyOutcome.transaction)
        refreshSnapshotState()
        let durationMicros = Self.elapsedMicros(since: startTime)
        intakeSignpost.endInterval("submit_event", signpostState)
        intakeLog.debug(
            "event_intake kind=\(event.kindForLog, privacy: .public) source=\(event.source.rawValue, privacy: .public) txn=\(epoch.value) us=\(durationMicros)"
        )
        return transaction
    }

    @discardableResult
    func submit(command: WMCommand) -> CommandResult {
        let transactionEpoch = allocateTransactionEpoch()
        let signpostId = intakeSignpost.makeSignpostID()
        let signpostState = intakeSignpost.beginInterval(
            "submit_command",
            id: signpostId,
            "kind=\(command.kindForLog) source=\(command.sourceForLog.rawValue) txn=\(transactionEpoch.value)"
        )
        let startTime = ContinuousClock.now

        let transaction: Transaction
        let applyOutcome: WMEffectRunner.ApplyOutcome
        var externalCommandResult: ExternalCommandResult?
        // ExecPlan 05 / TX-COL-01: the effect runner owns the post-apply
        // invariant validation step for the command path. The runner calls
        // this provider AFTER its effect loop finishes, so the validated
        // snapshot reflects the state the effects produced (no need for
        // submit(command:) to repeat the work afterwards).
        let postApplySnapshot: () -> ReconcileSnapshot = { [workspaceManager] in
            workspaceManager.reconcileSnapshot()
        }
        switch command {
        case let .workspaceSwitch(switchCommand):
            let effects = WorkspaceSwitchEffectPlanner.makeEffects(
                for: switchCommand,
                inputs: .init(
                    controller: controller,
                    allocateEffectEpoch: { [weak self] in
                        self?.allocateEffectEpoch() ?? .invalid
                    }
                )
            )
            transaction = makeCommandTransaction(
                for: command,
                transactionEpoch: transactionEpoch,
                effects: effects
            )
            applyOutcome = effectRunner.apply(
                transaction,
                postApplySnapshot: postApplySnapshot
            )
            externalCommandResult = .executed
        case let .controllerAction(action):
            transaction = makeCommandTransaction(
                for: command,
                transactionEpoch: transactionEpoch,
                effects: controllerActionEffects(for: action)
            )
            applyOutcome = effectRunner.apply(
                transaction,
                controllerAction: action,
                postApplySnapshot: postApplySnapshot
            )
            externalCommandResult = applyOutcome.externalCommandResult
        case let .focusAction(action):
            transaction = makeCommandTransaction(
                for: command,
                transactionEpoch: transactionEpoch,
                effects: focusActionEffects(for: action)
            )
            applyOutcome = effectRunner.apply(
                transaction,
                focusAction: action,
                postApplySnapshot: postApplySnapshot
            )
            externalCommandResult = applyOutcome.externalCommandResult
        case let .windowMoveAction(action):
            transaction = makeCommandTransaction(
                for: command,
                transactionEpoch: transactionEpoch,
                effects: windowMoveActionEffects(for: action)
            )
            applyOutcome = effectRunner.apply(
                transaction,
                windowMoveAction: action,
                postApplySnapshot: postApplySnapshot
            )
            externalCommandResult = applyOutcome.externalCommandResult
        case let .layoutMutationAction(action):
            transaction = makeCommandTransaction(
                for: command,
                transactionEpoch: transactionEpoch,
                effects: layoutMutationActionEffects(for: action)
            )
            applyOutcome = effectRunner.apply(
                transaction,
                layoutMutationAction: action,
                postApplySnapshot: postApplySnapshot
            )
            externalCommandResult = applyOutcome.externalCommandResult
        case let .workspaceNavigationAction(action):
            transaction = makeCommandTransaction(
                for: command,
                transactionEpoch: transactionEpoch,
                effects: workspaceNavigationActionEffects(for: action)
            )
            applyOutcome = effectRunner.apply(
                transaction,
                workspaceNavigationAction: action,
                postApplySnapshot: postApplySnapshot
            )
            externalCommandResult = applyOutcome.externalCommandResult
        case let .uiAction(action):
            transaction = makeCommandTransaction(
                for: command,
                transactionEpoch: transactionEpoch,
                effects: uiActionEffects(for: action)
            )
            applyOutcome = effectRunner.apply(
                transaction,
                uiAction: action,
                postApplySnapshot: postApplySnapshot
            )
            externalCommandResult = applyOutcome.externalCommandResult
        }

        let recordedTransaction = workspaceManager.recordTransaction(applyOutcome.transaction)
        refreshSnapshotState()
        let durationMicros = Self.elapsedMicros(since: startTime)
        intakeSignpost.endInterval("submit_command", signpostState)
        intakeLog.debug(
            "command_intake kind=\(command.kindForLog, privacy: .public) source=\(command.sourceForLog.rawValue, privacy: .public) txn=\(transactionEpoch.value) effects=\(transaction.effects.count) us=\(durationMicros)"
        )

        return CommandResult(
            transactionEpoch: transactionEpoch,
            transaction: recordedTransaction,
            applyOutcome: applyOutcome,
            externalCommandResult: externalCommandResult
        )
    }


    @discardableResult
    func admitWindow(
        _ ax: AXWindowRef,
        pid: pid_t,
        windowId: Int,
        to workspace: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode = .tiling,
        ruleEffects: ManagedWindowRuleEffects = .none,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil,
        source: WMEventSource = .ax
    ) -> WindowToken {
        windowAdmissionRuntime.admitWindow(
            ax,
            pid: pid,
            windowId: windowId,
            to: workspace,
            mode: mode,
            ruleEffects: ruleEffects,
            managedReplacementMetadata: managedReplacementMetadata,
            source: source
        )
    }

    @discardableResult
    func rekeyWindow(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        newAXRef: AXWindowRef,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil,
        source: WMEventSource = .ax
    ) -> WindowModel.Entry? {
        windowAdmissionRuntime.rekeyWindow(
            from: oldToken,
            to: newToken,
            newAXRef: newAXRef,
            managedReplacementMetadata: managedReplacementMetadata,
            source: source
        )
    }

    @discardableResult
    func reconcileBorderOwnership(
        event: BorderReconcileEvent,
        source: WMEventSource = .ax
    ) -> Bool {
        let epoch = allocateTransactionEpoch()
        let kindForLog: String
        switch event {
        case .invalidate: kindForLog = "invalidate"
        case .cgsClosed: kindForLog = "cgs_closed"
        case .cgsDestroyed: kindForLog = "cgs_destroyed"
        case .managedRekey: kindForLog = "managed_rekey"
        case .cleanup: kindForLog = "cleanup"
        case .renderRequested: kindForLog = "render_requested"
        case .cgsFrameChanged: kindForLog = "cgs_frame_changed"
        }
        let signpostState = intakeSignpost.beginInterval(
            "reconcile_border_ownership",
            id: intakeSignpost.makeSignpostID(),
            "kind=\(kindForLog) source=\(source.rawValue) txn=\(epoch.value)"
        )
        let startTime = ContinuousClock.now
        let changed = controllerOperations.reconcileBorderOwnership(event: event)
        effectRunner.noteTransactionCommitted(epoch)
        refreshSnapshotState()
        let durationMicros = Self.elapsedMicros(since: startTime)
        intakeSignpost.endInterval("reconcile_border_ownership", signpostState)
        intakeLog.debug(
            "border_reconcile_intake kind=\(kindForLog, privacy: .public) source=\(source.rawValue, privacy: .public) txn=\(epoch.value) changed=\(changed) us=\(durationMicros)"
        )
        return changed
    }

    @discardableResult
    func removeWindow(
        pid: pid_t,
        windowId: Int,
        source: WMEventSource = .ax
    ) -> WindowModel.Entry? {
        windowAdmissionRuntime.removeWindow(pid: pid, windowId: windowId, source: source)
    }

    @discardableResult
    func applySessionPatch(
        _ patch: WorkspaceSessionPatch,
        source: WMEventSource = .command
    ) -> Bool {
        workspaceRuntime.applySessionPatch(patch, source: source)
    }

    @discardableResult
    func submit(_ confirmation: WMEffectConfirmation) -> Bool {
        switch confirmation {
        case .targetWorkspaceActivated, .interactionMonitorSet, .workspaceSessionPatched:
            return workspaceRuntime.submit(confirmation)
        case let .observedFrame(token, frame, _, _):
            return frameRuntime.confirmObservedFrame(
                frame: .init(rect: frame, space: .appKit, isVisibleFrame: true),
                for: token,
                originatingTransactionEpoch: confirmation.originatingTransactionEpoch,
                source: confirmation.source
            )
        case let .axFrameWriteOutcome(token, axFailure, _, _):
            return frameRuntime.confirmAXFrameWriteOutcome(
                for: token,
                axFailure: axFailure,
                originatingTransactionEpoch: confirmation.originatingTransactionEpoch,
                source: confirmation.source
            )
        }
    }

    func frameWriteOutcomeOriginEpoch(source: WMEventSource = .ax) -> TransactionEpoch {
        frameRuntime.frameWriteOutcomeOriginEpoch(source: source)
    }

    @discardableResult
    func submitAXFrameWriteOutcome(
        for token: WindowToken,
        axFailure: AXFrameWriteFailureReason?,
        originatingTransactionEpoch: TransactionEpoch,
        source: WMEventSource = .ax
    ) -> Bool {
        frameRuntime.submitAXFrameWriteOutcome(
            for: token,
            axFailure: axFailure,
            originatingTransactionEpoch: originatingTransactionEpoch,
            source: source
        )
    }

    @discardableResult
    func recordStaleCGSDestroy(
        probeToken: WindowToken,
        source: WMEventSource = .ax
    ) -> LogicalWindowId? {
        windowAdmissionRuntime.recordStaleCGSDestroy(probeToken: probeToken, source: source)
    }

    @discardableResult
    func quarantineWindowsForTerminatedApp(
        pid: pid_t,
        source: WMEventSource = .ax
    ) -> [LogicalWindowId] {
        windowAdmissionRuntime.quarantineWindowsForTerminatedApp(pid: pid, source: source)
    }

    @discardableResult
    func setWindowMode(
        _ mode: TrackedWindowMode,
        for token: WindowToken,
        source: WMEventSource = .command
    ) -> Bool {
        windowAdmissionRuntime.setWindowMode(mode, for: token, source: source)
    }

    @discardableResult
    func setActiveWorkspace(
        _ workspaceId: WorkspaceDescriptor.ID,
        on monitorId: Monitor.ID,
        updateInteractionMonitor: Bool = true,
        source: WMEventSource = .command
    ) -> Bool {
        workspaceRuntime.setActiveWorkspace(
            workspaceId,
            on: monitorId,
            updateInteractionMonitor: updateInteractionMonitor,
            source: source
        )
    }

    @discardableResult
    func setInteractionMonitor(
        _ monitorId: Monitor.ID?,
        preservePrevious: Bool = true,
        source: WMEventSource = .command
    ) -> Bool {
        workspaceRuntime.setInteractionMonitor(
            monitorId,
            preservePrevious: preservePrevious,
            source: source
        )
    }

    @discardableResult
    func commitWorkspaceSelection(
        nodeId: NodeId?,
        focusedToken: WindowToken?,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil,
        source: WMEventSource = .command
    ) -> Bool {
        workspaceRuntime.commitWorkspaceSelection(
            nodeId: nodeId,
            focusedToken: focusedToken,
            in: workspaceId,
            onMonitor: monitorId,
            source: source
        )
    }

    @discardableResult
    func applySessionTransfer(
        _ transfer: WorkspaceSessionTransfer,
        source: WMEventSource = .command
    ) -> Bool {
        workspaceRuntime.applySessionTransfer(transfer, source: source)
    }

    @discardableResult
    func resolveAndSetWorkspaceFocusToken(
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil,
        source: WMEventSource = .command
    ) -> WindowToken? {
        workspaceRuntime.resolveAndSetWorkspaceFocusToken(
            in: workspaceId,
            onMonitor: monitorId,
            source: source
        )
    }

    @discardableResult
    func applyOrchestrationFocusState(
        _ focusSnapshot: FocusOrchestrationSnapshot,
        source: WMEventSource = .focusPolicy
    ) -> Bool {
        focusRuntime.applyOrchestrationFocusState(focusSnapshot, source: source)
    }

    func updateFloatingGeometry(
        frame: CGRect,
        for token: WindowToken,
        referenceMonitor: Monitor? = nil,
        restoreToFloating: Bool = true,
        source: WMEventSource = .command
    ) {
        frameRuntime.updateFloatingGeometry(
            frame: frame,
            for: token,
            referenceMonitor: referenceMonitor,
            restoreToFloating: restoreToFloating,
            source: source
        )
    }

    func setFloatingState(
        _ state: WindowModel.FloatingState?,
        for token: WindowToken,
        source: WMEventSource = .command
    ) {
        frameRuntime.setFloatingState(state, for: token, source: source)
    }

    func setHiddenState(
        _ state: WindowModel.HiddenState?,
        for token: WindowToken,
        source: WMEventSource = .command
    ) {
        workspaceRuntime.setHiddenState(state, for: token, source: source)
    }

    @discardableResult
    func setManagedRestoreSnapshot(
        _ snapshot: ManagedWindowRestoreSnapshot,
        for token: WindowToken,
        source: WMEventSource = .command
    ) -> Bool {
        workspaceRuntime.setManagedRestoreSnapshot(snapshot, for: token, source: source)
    }

    @discardableResult
    func clearManagedRestoreSnapshot(
        for token: WindowToken,
        source: WMEventSource = .command
    ) -> Bool {
        workspaceRuntime.clearManagedRestoreSnapshot(for: token, source: source)
    }

    @discardableResult
    func setManagedReplacementMetadata(
        _ metadata: ManagedReplacementMetadata?,
        for token: WindowToken,
        source: WMEventSource = .ax
    ) -> Bool {
        workspaceRuntime.setManagedReplacementMetadata(metadata, for: token, source: source)
    }

    @discardableResult
    func updateManagedReplacementFrame(
        _ frame: CGRect,
        for token: WindowToken,
        source: WMEventSource = .ax
    ) -> Bool {
        workspaceRuntime.updateManagedReplacementFrame(frame, for: token, source: source)
    }

    @discardableResult
    func updateManagedReplacementTitle(
        _ title: String,
        for token: WindowToken,
        source: WMEventSource = .ax
    ) -> Bool {
        workspaceRuntime.updateManagedReplacementTitle(title, for: token, source: source)
    }

    func setWorkspace(
        for token: WindowToken,
        to workspaceId: WorkspaceDescriptor.ID,
        source: WMEventSource = .command
    ) {
        workspaceRuntime.setWorkspace(for: token, to: workspaceId, source: source)
    }

    @discardableResult
    func swapTiledWindowOrder(
        _ lhs: WindowToken,
        _ rhs: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        source: WMEventSource = .command
    ) -> Bool {
        workspaceRuntime.swapTiledWindowOrder(lhs, rhs, in: workspaceId, source: source)
    }

    @discardableResult
    func focusWorkspace(
        named name: String,
        source: WMEventSource = .command
    ) -> (workspace: WorkspaceDescriptor, monitor: Monitor)? {
        workspaceRuntime.focusWorkspace(named: name, source: source)
    }

    func assignWorkspaceToMonitor(
        _ workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID,
        source: WMEventSource = .command
    ) {
        workspaceRuntime.assignWorkspaceToMonitor(workspaceId, monitorId: monitorId, source: source)
    }

    @discardableResult
    func swapWorkspaces(
        _ workspace1Id: WorkspaceDescriptor.ID,
        on monitor1Id: Monitor.ID,
        with workspace2Id: WorkspaceDescriptor.ID,
        on monitor2Id: Monitor.ID,
        source: WMEventSource = .command
    ) -> Bool {
        workspaceRuntime.swapWorkspaces(
            workspace1Id,
            on: monitor1Id,
            with: workspace2Id,
            on: monitor2Id,
            source: source
        )
    }

    func setManualLayoutOverride(
        _ override: ManualWindowOverride?,
        for token: WindowToken,
        source: WMEventSource = .command
    ) {
        workspaceRuntime.setManualLayoutOverride(override, for: token, source: source)
    }

    func setLayoutReason(
        _ reason: LayoutReason,
        for token: WindowToken,
        source: WMEventSource = .ax
    ) {
        workspaceRuntime.setLayoutReason(reason, for: token, source: source)
    }

    // Native-fullscreen mutators forward to `nativeFullscreenRuntime`
    // (ExecPlan 02 surface migration). Public signatures preserved.

    @discardableResult
    func seedNativeFullscreenRestoreSnapshot(
        _ snapshot: WorkspaceManager.NativeFullscreenRecord.RestoreSnapshot,
        for token: WindowToken,
        source: WMEventSource = .command
    ) -> Bool {
        nativeFullscreenRuntime.seedNativeFullscreenRestoreSnapshot(snapshot, for: token, source: source)
    }

    @discardableResult
    func requestNativeFullscreenEnter(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        restoreSnapshot: WorkspaceManager.NativeFullscreenRecord.RestoreSnapshot?,
        restoreFailure: WorkspaceManager.NativeFullscreenRecord.RestoreFailure?,
        source: WMEventSource = .command
    ) -> Bool {
        nativeFullscreenRuntime.requestNativeFullscreenEnter(
            token,
            in: workspaceId,
            restoreSnapshot: restoreSnapshot,
            restoreFailure: restoreFailure,
            source: source
        )
    }

    @discardableResult
    func markNativeFullscreenSuspended(
        _ token: WindowToken,
        restoreSnapshot: WorkspaceManager.NativeFullscreenRecord.RestoreSnapshot?,
        restoreFailure: WorkspaceManager.NativeFullscreenRecord.RestoreFailure?,
        source: WMEventSource = .ax
    ) -> Bool {
        nativeFullscreenRuntime.markNativeFullscreenSuspended(
            token,
            restoreSnapshot: restoreSnapshot,
            restoreFailure: restoreFailure,
            source: source
        )
    }

    @discardableResult
    func requestNativeFullscreenExit(
        _ token: WindowToken,
        initiatedByCommand: Bool,
        source: WMEventSource = .command
    ) -> Bool {
        nativeFullscreenRuntime.requestNativeFullscreenExit(
            token,
            initiatedByCommand: initiatedByCommand,
            source: source
        )
    }

    @discardableResult
    func markNativeFullscreenTemporarilyUnavailable(
        _ token: WindowToken,
        source: WMEventSource = .ax
    ) -> WorkspaceManager.NativeFullscreenRecord? {
        nativeFullscreenRuntime.markNativeFullscreenTemporarilyUnavailable(token, source: source)
    }

    @discardableResult
    func expireStaleTemporarilyUnavailableNativeFullscreenRecords(
        now: Date = Date(),
        staleInterval: TimeInterval = WorkspaceManager.staleUnavailableNativeFullscreenTimeout,
        source: WMEventSource = .ax
    ) -> [WindowModel.Entry] {
        nativeFullscreenRuntime.expireStaleTemporarilyUnavailableNativeFullscreenRecords(
            now: now,
            staleInterval: staleInterval,
            source: source
        )
    }

    @discardableResult
    func restoreFromNativeState(
        for token: WindowToken,
        source: WMEventSource = .ax
    ) -> ParentKind? {
        nativeFullscreenRuntime.restoreFromNativeState(for: token, source: source)
    }

    @discardableResult
    func enterNonManagedFocus(
        appFullscreen: Bool,
        preserveFocusedToken: Bool = false,
        source: WMEventSource = .ax
    ) -> Bool {
        focusRuntime.enterNonManagedFocus(
            appFullscreen: appFullscreen,
            preserveFocusedToken: preserveFocusedToken,
            source: source
        )
    }

    @discardableResult
    func setManagedAppFullscreen(
        _ active: Bool,
        source: WMEventSource = .ax
    ) -> Bool {
        nativeFullscreenRuntime.setManagedAppFullscreen(active, source: source)
    }

    @discardableResult
    func setScratchpadToken(
        _ token: WindowToken?,
        source: WMEventSource = .command
    ) -> Bool {
        workspaceRuntime.setScratchpadToken(token, source: source)
    }

    @discardableResult
    func clearScratchpadIfMatches(
        _ token: WindowToken,
        source: WMEventSource = .command
    ) -> Bool {
        workspaceRuntime.clearScratchpadIfMatches(token, source: source)
    }

    @discardableResult
    func saveWorkspaceViewport(
        for workspaceId: WorkspaceDescriptor.ID,
        originatingTransactionEpoch: TransactionEpoch,
        source: WMEventSource = .command
    ) -> Bool {
        workspaceRuntime.saveWorkspaceViewport(
            for: workspaceId,
            originatingTransactionEpoch: originatingTransactionEpoch,
            source: source
        )
    }

    @discardableResult
    func clearManagedFocusAfterEmptyWorkspaceTransition(
        source: WMEventSource = .command
    ) -> Bool {
        focusRuntime.clearManagedFocusAfterEmptyWorkspaceTransition(source: source)
    }

    @discardableResult
    func clearManagedFocusAfterEmptyWorkspaceTransition(
        originatingTransactionEpoch: TransactionEpoch,
        source: WMEventSource = .command
    ) -> Bool {
        focusRuntime.clearManagedFocusAfterEmptyWorkspaceTransition(
            originatingTransactionEpoch: originatingTransactionEpoch,
            source: source
        )
    }

    @discardableResult
    func removeWindowsForApp(
        pid: pid_t,
        source: WMEventSource = .ax
    ) -> Set<WorkspaceDescriptor.ID> {
        windowAdmissionRuntime.removeWindowsForApp(pid: pid, source: source)
    }


    @discardableResult
    func confirmManagedFocus(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil,
        appFullscreen: Bool,
        activateWorkspaceOnMonitor: Bool,
        originatingTransactionEpoch: TransactionEpoch,
        source: WMEventSource = .ax
    ) -> Bool {
        focusRuntime.confirmManagedFocus(
            token,
            in: workspaceId,
            onMonitor: monitorId,
            appFullscreen: appFullscreen,
            activateWorkspaceOnMonitor: activateWorkspaceOnMonitor,
            originatingTransactionEpoch: originatingTransactionEpoch,
            source: source
        )
    }

    @discardableResult
    func setManagedFocus(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil,
        originatingTransactionEpoch: TransactionEpoch,
        source: WMEventSource = .ax
    ) -> Bool {
        focusRuntime.setManagedFocus(
            token,
            in: workspaceId,
            onMonitor: monitorId,
            originatingTransactionEpoch: originatingTransactionEpoch,
            source: source
        )
    }

    @discardableResult
    func beginManagedFocusRequest(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil,
        source: WMEventSource = .ax
    ) -> Bool {
        focusRuntime.beginManagedFocusRequest(
            token,
            in: workspaceId,
            onMonitor: monitorId,
            source: source
        )
    }

    func beginManagedFocusRequestTransaction(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil,
        source: WMEventSource = .ax
    ) -> ManagedFocusRequestBeginResult {
        focusRuntime.beginManagedFocusRequestTransaction(
            token,
            in: workspaceId,
            onMonitor: monitorId,
            source: source
        )
    }

    @discardableResult
    func cancelManagedFocusRequest(
        matching token: WindowToken? = nil,
        workspaceId: WorkspaceDescriptor.ID? = nil,
        originatingTransactionEpoch: TransactionEpoch,
        source: WMEventSource = .ax
    ) -> Bool {
        focusRuntime.cancelManagedFocusRequest(
            matching: token,
            workspaceId: workspaceId,
            originatingTransactionEpoch: originatingTransactionEpoch,
            source: source
        )
    }


    @discardableResult
    func observeExternalManagedFocus(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil,
        appFullscreen: Bool,
        activateWorkspaceOnMonitor: Bool,
        source: WMEventSource = .ax
    ) -> Bool {
        focusRuntime.observeExternalManagedFocus(
            token,
            in: workspaceId,
            onMonitor: monitorId,
            appFullscreen: appFullscreen,
            activateWorkspaceOnMonitor: activateWorkspaceOnMonitor,
            source: source
        )
    }

    @discardableResult
    func observeExternalManagedFocusSet(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil,
        source: WMEventSource = .ax
    ) -> Bool {
        focusRuntime.observeExternalManagedFocusSet(
            token,
            in: workspaceId,
            onMonitor: monitorId,
            source: source
        )
    }

    @discardableResult
    func observeExternalManagedFocusCancellation(
        matching token: WindowToken? = nil,
        workspaceId: WorkspaceDescriptor.ID? = nil,
        source: WMEventSource = .ax
    ) -> Bool {
        focusRuntime.observeExternalManagedFocusCancellation(
            matching: token,
            workspaceId: workspaceId,
            source: source
        )
    }

    func applyMonitorConfigurationChange(
        _ newMonitors: [Monitor],
        source: WMEventSource = .service
    ) {
        monitorRuntime.applyMonitorConfigurationChange(newMonitors, source: source)
    }

    @discardableResult
    func activateInferredWorkspaceIfNeeded(
        on monitorId: Monitor.ID,
        source: WMEventSource = .workspaceManager
    ) -> Bool {
        workspaceRuntime.activateInferredWorkspaceIfNeeded(on: monitorId, source: source)
    }

    @discardableResult
    func beginNativeFullscreenRestore(
        for token: WindowToken,
        source: WMEventSource = .ax
    ) -> WorkspaceManager.NativeFullscreenRecord? {
        nativeFullscreenRuntime.beginNativeFullscreenRestore(for: token, source: source)
    }

    @discardableResult
    func restoreNativeFullscreenRecord(
        for token: WindowToken,
        source: WMEventSource = .ax
    ) -> ParentKind? {
        nativeFullscreenRuntime.restoreNativeFullscreenRecord(for: token, source: source)
    }

    func finalizeNativeFullscreenRestore(
        for token: WindowToken,
        source: WMEventSource = .ax
    ) -> ParentKind? {
        nativeFullscreenRuntime.finalizeNativeFullscreenRestore(for: token, source: source)
    }

    func removeMissingWindows(
        keys activeKeys: Set<WindowModel.WindowKey>,
        requiredConsecutiveMisses: Int,
        source: WMEventSource = .service
    ) {
        windowAdmissionRuntime.removeMissingWindows(
            keys: activeKeys,
            requiredConsecutiveMisses: requiredConsecutiveMisses,
            source: source
        )
    }

    func garbageCollectUnusedWorkspaces(
        focusedWorkspaceId: WorkspaceDescriptor.ID?,
        source: WMEventSource = .service
    ) {
        windowAdmissionRuntime.garbageCollectUnusedWorkspaces(
            focusedWorkspaceId: focusedWorkspaceId,
            source: source
        )
    }

    private func makeCommandTransaction(
        for command: WMCommand,
        transactionEpoch: TransactionEpoch,
        effects: [WMEffect]
    ) -> Transaction {
        let event = WMEvent.commandIntent(
            kindForLog: command.kindForLog,
            source: command.sourceForLog
        )
        return Transaction(
            event: event,
            normalizedEvent: event,
            transactionEpoch: transactionEpoch,
            effects: effects,
            snapshot: workspaceManager.reconcileSnapshot(),
            invariantViolations: []
        )
    }

    private func controllerActionEffects(
        for action: WMCommand.ControllerActionCommand
    ) -> [WMEffect] {
        [
            .controllerActionDispatch(
                kindForLog: action.kindForLog,
                source: action.source,
                epoch: allocateEffectEpoch()
            )
        ]
    }

    private func focusActionEffects(
        for action: WMCommand.FocusActionCommand
    ) -> [WMEffect] {
        [
            .focusActionDispatch(
                kindForLog: action.kindForLog,
                source: action.source,
                epoch: allocateEffectEpoch()
            )
        ]
    }

    private func windowMoveActionEffects(
        for action: WMCommand.WindowMoveActionCommand
    ) -> [WMEffect] {
        [
            .windowMoveActionDispatch(
                kindForLog: action.kindForLog,
                source: action.source,
                epoch: allocateEffectEpoch()
            )
        ]
    }

    private func layoutMutationActionEffects(
        for action: WMCommand.LayoutMutationActionCommand
    ) -> [WMEffect] {
        [
            .layoutMutationActionDispatch(
                kindForLog: action.kindForLog,
                source: action.source,
                epoch: allocateEffectEpoch()
            )
        ]
    }

    private func workspaceNavigationActionEffects(
        for action: WMCommand.WorkspaceNavigationActionCommand
    ) -> [WMEffect] {
        [
            .workspaceNavigationActionDispatch(
                kindForLog: action.kindForLog,
                source: action.source,
                epoch: allocateEffectEpoch()
            )
        ]
    }

    private func uiActionEffects(
        for action: WMCommand.UIActionCommand
    ) -> [WMEffect] {
        [
            .uiActionDispatch(
                kindForLog: action.kindForLog,
                source: action.source,
                epoch: allocateEffectEpoch()
            )
        ]
    }

    /// Promote a `InputBindingTrigger` to its typed `WMCommand`. The switch is
    /// exhaustive on `InputBindingTrigger` — adding a new case is a compile error
    /// at this single site (ExecPlan 03 TX-CMD-01h follow-on). The seven
    /// per-family `*Command(for:source:)` helpers were retired because each
    /// ended in a silent `default: return nil` that, in combination with the
    /// dispatcher's `guard let ... else { preconditionFailure(...) }`,
    /// turned a missed helper update into a runtime crash at user-press
    /// time instead of a build break. Inlining puts the entire promotion in
    /// one exhaustive switch with no helper-level fallthrough surface.
    ///
    /// `preconditionFailure` here only fires for invalid index inputs to
    /// `WorkspaceIDPolicy.rawID` (negative / wrap), which is a programmer
    /// error in the binding configuration rather than a missed-case bug —
    /// it is reachable only via deliberately malformed input.
    static func typedCommand(
        for hotkey: InputBindingTrigger,
        source: WMEventSource
    ) -> WMCommand {
        switch hotkey {
        // MARK: Workspace switch
        case let .switchWorkspace(index):
            guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else {
                preconditionFailure(
                    "WMRuntime.typedCommand: invalid switchWorkspace index \(index)"
                )
            }
            return .workspaceSwitch(.explicitFrom(rawWorkspaceID: rawWorkspaceID, source: source))
        case .switchWorkspaceNext:
            return .workspaceSwitch(.relativeFrom(isNext: true, wrapAround: true, source: source))
        case .switchWorkspacePrevious:
            return .workspaceSwitch(.relativeFrom(isNext: false, wrapAround: true, source: source))

        // MARK: Controller action
        case let .moveToWorkspace(index):
            guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else {
                preconditionFailure(
                    "WMRuntime.typedCommand: invalid moveToWorkspace index \(index)"
                )
            }
            return .controllerAction(.moveFocusedWindow(rawWorkspaceID: rawWorkspaceID, source: source))
        case let .focusWorkspaceAnywhere(index):
            guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else {
                preconditionFailure(
                    "WMRuntime.typedCommand: invalid focusWorkspaceAnywhere index \(index)"
                )
            }
            return .controllerAction(.focusWorkspaceAnywhere(rawWorkspaceID: rawWorkspaceID, source: source))
        case let .moveWindowToWorkspaceOnMonitor(workspaceIndex, monitorDirection):
            guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, workspaceIndex) + 1) else {
                preconditionFailure(
                    "WMRuntime.typedCommand: invalid moveWindowToWorkspaceOnMonitor workspaceIndex \(workspaceIndex)"
                )
            }
            return .controllerAction(.moveFocusedWindowOnMonitor(
                rawWorkspaceID: rawWorkspaceID,
                monitorDirection: monitorDirection,
                source: source
            ))
        case .rescueOffscreenWindows:
            return .controllerAction(.rescueOffscreenWindows(source: source))

        // MARK: Focus action
        case let .focus(direction):
            return .focusAction(.focusNeighbor(direction, source: source))
        case .focusPrevious:
            return .focusAction(.focusPrevious(source: source))
        case .focusDownOrLeft:
            return .focusAction(.focusDownOrLeft(source: source))
        case .focusUpOrRight:
            return .focusAction(.focusUpOrRight(source: source))
        case .focusColumnFirst:
            return .focusAction(.focusColumnFirst(source: source))
        case .focusColumnLast:
            return .focusAction(.focusColumnLast(source: source))
        case let .focusColumn(index):
            return .focusAction(.focusColumn(index, source: source))
        case .focusMonitorPrevious:
            return .focusAction(.focusMonitorPrevious(source: source))
        case .focusMonitorNext:
            return .focusAction(.focusMonitorNext(source: source))
        case .focusMonitorLast:
            return .focusAction(.focusMonitorLast(source: source))

        // MARK: Window move action
        case let .move(direction):
            return .windowMoveAction(.moveWindow(direction, source: source))
        case let .moveColumn(direction):
            return .windowMoveAction(.moveColumn(direction, source: source))
        case .moveWindowToWorkspaceUp:
            return .windowMoveAction(.moveWindowToWorkspaceUp(source: source))
        case .moveWindowToWorkspaceDown:
            return .windowMoveAction(.moveWindowToWorkspaceDown(source: source))
        case let .moveColumnToWorkspace(index):
            return .windowMoveAction(.moveColumnToWorkspace(index, source: source))
        case .moveColumnToWorkspaceUp:
            return .windowMoveAction(.moveColumnToWorkspaceUp(source: source))
        case .moveColumnToWorkspaceDown:
            return .windowMoveAction(.moveColumnToWorkspaceDown(source: source))

        // MARK: Layout mutation action
        case .toggleFullscreen:
            return .layoutMutationAction(.toggleFullscreen(source: source))
        case .toggleNativeFullscreen:
            return .layoutMutationAction(.toggleNativeFullscreen(source: source))
        case .toggleColumnTabbed:
            return .layoutMutationAction(.toggleColumnTabbed(source: source))
        case .toggleColumnFullWidth:
            return .layoutMutationAction(.toggleColumnFullWidth(source: source))
        case .cycleColumnWidthForward:
            return .layoutMutationAction(.cycleColumnWidthForward(source: source))
        case .cycleColumnWidthBackward:
            return .layoutMutationAction(.cycleColumnWidthBackward(source: source))
        case let .swapWorkspaceWithMonitor(direction):
            return .layoutMutationAction(.swapWorkspaceWithMonitor(direction, source: source))
        case .balanceSizes:
            return .layoutMutationAction(.balanceSizes(source: source))
        case .moveToRoot:
            return .layoutMutationAction(.moveToRoot(source: source))
        case .toggleSplit:
            return .layoutMutationAction(.toggleSplit(source: source))
        case .swapSplit:
            return .layoutMutationAction(.swapSplit(source: source))
        case let .resizeInDirection(direction, grow):
            return .layoutMutationAction(.resizeInDirection(direction, grow: grow, source: source))
        case let .preselect(direction):
            return .layoutMutationAction(.preselect(direction, source: source))
        case .preselectClear:
            return .layoutMutationAction(.preselectClear(source: source))
        case .toggleWorkspaceLayout:
            return .layoutMutationAction(.toggleWorkspaceLayout(source: source))
        case .raiseAllFloatingWindows:
            return .layoutMutationAction(.raiseAllFloatingWindows(source: source))
        case .toggleFocusedWindowFloating:
            return .layoutMutationAction(.toggleFocusedWindowFloating(source: source))
        case .assignFocusedWindowToScratchpad:
            return .layoutMutationAction(.assignFocusedWindowToScratchpad(source: source))
        case .toggleScratchpadWindow:
            return .layoutMutationAction(.toggleScratchpadWindow(source: source))

        // MARK: Workspace navigation action
        case .workspaceBackAndForth:
            return .workspaceNavigationAction(.workspaceBackAndForth(source: source))

        // MARK: UI action
        case .openCommandPalette:
            return .uiAction(.openCommandPalette(source: source))
        case .openMenuAnywhere:
            return .uiAction(.openMenuAnywhere(source: source))
        case .toggleWorkspaceBarVisibility:
            return .uiAction(.toggleWorkspaceBarVisibility(source: source))
        case .toggleHiddenBar:
            return .uiAction(.toggleHiddenBar(source: source))
        case .toggleQuakeTerminal:
            return .uiAction(.toggleQuakeTerminal(source: source))
        case .toggleOverview:
            return .uiAction(.toggleOverview(source: source))
        }
    }

    // Epoch allocators and elapsed-time helper delegate to `RuntimeKernel`
    // (ExecPlan 02, slice WRT-DS-01). The kernel is the single mint for all
    // epoch values; when per-domain runtimes are added in subsequent slices,
    // they will hold a reference to the same kernel instance.
    private static func elapsedMicros(since start: ContinuousClock.Instant) -> Int64 {
        RuntimeKernel.elapsedMicros(since: start)
    }

    private func allocateTransactionEpoch() -> TransactionEpoch {
        kernel.allocateTransactionEpoch()
    }

    private func allocateEffectEpoch() -> EffectEpoch {
        kernel.allocateEffectEpoch()
    }

    var currentEffectRunnerWatermark: TransactionEpoch {
        effectRunner.highestAcceptedTransactionEpoch
    }

    func allocateTopologyEpoch() -> TopologyEpoch {
        kernel.allocateTopologyEpoch()
    }

    /// Public dispatch entry for a `InputBindingTrigger` (the input-binding
    /// trigger). Applies the controller-level gates, promotes the hotkey to
    /// a typed `WMCommand`, and submits through runtime-owned executors.
    /// Returns the
    /// `ExternalCommandResult` mirror so callers (IPC, hotkey input,
    /// tests) can branch on `.executed` / `.ignoredDisabled` /
    /// `.ignoredOverview` / `.ignoredLayoutMismatch` / `.invalidArguments`.
    @discardableResult
    func dispatchHotkey(
        _ command: InputBindingTrigger,
        source: WMEventSource = .keyboard
    ) -> ExternalCommandResult {
        if let rejected = preflightCommand(command) {
            return rejected
        }
        let result = submit(command: WMRuntime.typedCommand(for: command, source: source))
        return result.externalCommandResult ?? .executed
    }

    @discardableResult
    func dispatchCommand(_ command: WMCommand) -> ExternalCommandResult {
        if let rejected = preflightCommand(command) {
            return rejected
        }
        let result = submit(command: command)
        return result.externalCommandResult ?? .executed
    }

    func preflightCommand(_ command: InputBindingTrigger) -> ExternalCommandResult? {
        preflightCommand(
            layoutCompatibility: command.layoutCompatibility,
            allowsOverviewOpen: command == .toggleOverview
        )
    }

    func preflightCommand(_ command: WMCommand) -> ExternalCommandResult? {
        preflightCommand(
            layoutCompatibility: command.layoutCompatibility,
            allowsOverviewOpen: command.allowsOverviewOpen
        )
    }

    func preflightCommand(
        layoutCompatibility: LayoutCompatibility = .shared,
        allowsOverviewOpen: Bool = false
    ) -> ExternalCommandResult? {
        guard controller.isEnabled else { return .ignoredDisabled }
        if controller.isOverviewOpen() && !allowsOverviewOpen {
            return .ignoredOverview
        }
        let layoutType: LayoutType = {
            guard let ws = controller.activeWorkspace() else { return .niri }
            return settings.layoutType(for: ws.name)
        }()
        switch (layoutCompatibility, layoutType) {
        case (.niri, .dwindle), (.dwindle, .niri), (.dwindle, .defaultLayout):
            return .ignoredLayoutMismatch
        default:
            return nil
        }
    }

    func requestManagedFocus(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        source: WMEventSource
    ) -> OrchestrationResult {
        apply(
            .focusRequested(
                .init(
                    token: token,
                    workspaceId: workspaceId
                )
            ),
            context: .focusRequest(source: source)
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

    func refreshSnapshotState() {
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

extension WMRuntime {
    var focusState: FocusState {
        var state = workspaceManager.storedFocusStateSnapshot
        if case let .pending(_, originatingTransactionEpoch) = state.activation,
           let request = controller.focusBridge.activeManagedRequest
        {
            let bridgeOriginEpoch = controller.focusBridge
                .originTransactionEpoch(forRequestId: request.requestId)
                ?? originatingTransactionEpoch
            state.activation = .pending(
                requestId: request.requestId,
                originatingTransactionEpoch: bridgeOriginEpoch
            )
        }
        return state
    }

    func reduceScratchpadHide(
        hiddenLogicalId: LogicalWindowId,
        wasFocused: Bool,
        recoveryCandidate: LogicalWindowId?,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID? = nil
    ) -> FocusReducer.RecommendedAction? {
        focusRuntime.reduceScratchpadHide(
            hiddenLogicalId: hiddenLogicalId,
            wasFocused: wasFocused,
            recoveryCandidate: recoveryCandidate,
            workspaceId: workspaceId,
            monitorId: monitorId
        )
    }

    func recordActivationFailure(
        reason: FocusState.FocusFailureReason,
        requestId: UInt64? = nil,
        token: WindowToken? = nil,
        source: WMEventSource = .ax
    ) {
        focusRuntime.recordActivationFailure(
            reason: reason,
            requestId: requestId,
            token: token,
            source: source
        )
    }

    func recordFocusedManagedWindowRemoved(_ removedLogicalId: LogicalWindowId) {
        focusRuntime.recordFocusedManagedWindowRemoved(removedLogicalId)
    }

    func recordFocusObservationSettled(_ observedToken: WindowToken) {
        focusRuntime.recordFocusObservationSettled(observedToken)
    }

    @discardableResult
    func recordPendingFrameWrite(
        frame: FrameState.Frame,
        requestId: AXFrameRequestId,
        for token: WindowToken
    ) -> Bool {
        frameRuntime.recordPendingFrameWrite(
            frame: frame,
            requestId: requestId,
            for: token
        )
    }

    @discardableResult
    func recordObservedFrame(
        frame: FrameState.Frame,
        for token: WindowToken
    ) -> Bool {
        frameRuntime.recordObservedFrame(frame: frame, for: token)
    }
}

#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Phase 01 closure enforcement artifact for the "no new direct mutation
# callers" policy.
#
# Phase 01 made the runtime/domain runtime surface the authoritative
# transaction entrypoint for durable WM state mutation. Phase closure keeps
# migration-debt and ownership-boundary allowlists empty; owner files are
# excluded structurally rather than counted as compatibility rows.
#
# The script grep's for direct callers and fails CI if any new ones
# appear outside the counted rules. Unlike a whole-file allowlist, each
# entry pins the exact pattern count allowed in one file so
# already-migrated files cannot grow new direct mutation calls invisibly.
#
# Future phases that promote individual `WMCommand`s or replace
# compatibility writes should remove or tighten the matching ownership
# boundary entry as the direct call goes away.

set -euo pipefail

# Phase 07 / GOV-02 — `--budget-report` prints the declared allowlist
# budget (sum of per-rule `max-count` values) so the migration completion
# gate (Phase 07 GOV-03 condition 1) can be observed without running the
# enforcement loop. `--budget-gate` prints the same report and fails if the
# migration-debt budget is non-zero.
BUDGET_REPORT=0
BUDGET_GATE=0
for arg in "$@"; do
    case "$arg" in
        --budget-report) BUDGET_REPORT=1 ;;
        --budget-gate) BUDGET_REPORT=1; BUDGET_GATE=1 ;;
        --help|-h)
            echo "Usage: $0 [--budget-report|--budget-gate]"
            echo "  --budget-report  Print per-rule and total allowlist budget; do not enforce."
            echo "  --budget-gate    Print the budget report and fail if migration debt is non-zero."
            exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")/.."

# Patterns that flag direct-mutation use. Each pattern targets an API whose
# production callers must route through a runtime/domain runtime owner.
PATTERNS=(
    'workspaceManager\.addWindow'
    'workspaceManager\.rekeyWindow'
    'workspaceManager\.removeWindow\b'
    'workspaceManager\.removeWindowsForApp'
    'workspaceManager\.setWindowMode'
    'workspaceManager\.applySessionPatch'
    'workspaceManager\.applySessionTransfer'
    'workspaceManager\.applySettings'
    # Configuration/cache seams are intentionally outside durable workspace
    # session mutation. They are still counted below so any growth is
    # reviewed deliberately.
    'workspaceManager\.setGaps'
    'workspaceManager\.setOuterGaps'
    'workspaceManager\.setCachedConstraints'
    'workspaceManager\.updateAnimationClock'
    'workspaceManager\.setActiveWorkspace'
    'workspaceManager\.setInteractionMonitor'
    'workspaceManager\.commitWorkspaceSelection'
    # Phase 04a (FOC-08 strict closure): the legacy mutating
    # `WorkspaceManager.resolveAndSetWorkspaceFocusToken` is GONE. Its
    # successor is the orchestration in
    # `WMRuntime.resolveAndSetWorkspaceFocusToken` which composes the
    # pure resolver `WorkspaceManager.resolveWorkspaceFocusPlan(in:)`
    # with the named mirror boundary
    # `WorkspaceManager.applyResolvedWorkspaceFocusClearMirror(in:scope:...)`.
    # The mirror is the single allowed direct caller in production
    # (one runtime adapter site).
    'workspaceManager\.applyResolvedWorkspaceFocusClearMirror'
    # Phase 04a (FOC-08 strict closure): `rememberFocus` is workspace
    # memory (the per-workspace last-focused map), NOT durable
    # desired/observed focus. The runtime adapter calls it from the
    # resolved-token branch of `resolveAndSetWorkspaceFocusToken` so
    # the workspace remembers what it just resolved.
    'workspaceManager\.rememberFocus'
    'workspaceManager\.updateFloatingGeometry'
    'workspaceManager\.setFloatingState'
    'workspaceManager\.setHiddenState'
    'workspaceManager\.applyOrchestrationFocusState'
    'workspaceManager\.applyFocusReducerEvent\('
    'workspaceManager\.applyFocusReducerEventReturningAction'
    'workspaceManager\.assignWorkspaceToMonitor'
    'workspaceManager\.setWorkspace'
    'workspaceManager\.setManagedRestoreSnapshot'
    'workspaceManager\.clearManagedRestoreSnapshot'
    'workspaceManager\.setManagedReplacementMetadata'
    'workspaceManager\.updateManagedReplacementFrame'
    'workspaceManager\.updateManagedReplacementTitle'
    'workspaceManager\.setLayoutReason'
    'workspaceManager\.restoreFromNativeState'
    'workspaceManager\.enterNonManagedFocus'
    'workspaceManager\.setManagedAppFullscreen'
    'workspaceManager\.setScratchpadToken'
    'workspaceManager\.clearScratchpadIfMatches'
    'workspaceManager\.setManualLayoutOverride'
    'workspaceManager\.swapTiledWindowOrder'
    'controller\.commandHandler\.performCommand'
    'controller\.windowActionHandler\.focusWorkspaceFromBar'
    'controller\.windowActionHandler\.focusWindowFromBar'
    'controller\.windowActionHandler\.navigateToWindow'
    'controller\.windowActionHandler\.summonWindowRight'
    'controller\.workspaceNavigationHandler\.switchWorkspace\('
    'controller\.workspaceNavigationHandler\.switchWorkspaceRelative'
    'controller\.workspaceNavigationHandler\.focusWorkspaceAnywhere'
    'controller\.workspaceNavigationHandler\.moveFocusedWindow'
    'controller\.workspaceNavigationHandler\.moveWindowToWorkspaceOnMonitor'
    # Phase 01 closing-slice — focus mutators routed through
    # `WMRuntime.confirmManagedFocus / setManagedFocus /
    # beginManagedFocusRequest / cancelManagedFocusRequest`.
    # Phase 04a (FOC-08) confirmation: these four mutators remain the
    # `FocusSession` writers (kernel ABI input shape), with the parallel
    # `FocusState` writer `applyFocusReducerEvent` populating the typed
    # state machine. Production callers MUST go through `WMRuntime`;
    # the allowlist below pins the production adapter call sites.
    'workspaceManager\.confirmManagedFocus'
    'workspaceManager\.setManagedFocus'
    'workspaceManager\.beginManagedFocusRequest'
    'workspaceManager\.cancelManagedFocusRequest'
    # Phase 04b (FRM-09) — frame-state writers. Production callers
    # update `FrameState` via `WorkspaceManager.recordDesiredFrame /
    # recordObservedFrame / recordPendingFrameWrite /
    # recordFailedFrameWrite`. Direct calls from outside the
    # WorkspaceManager seam (e.g., layout engines mutating Entry frame
    # fields directly) must NOT grow.
    'workspaceManager\.recordDesiredFrame'
    'workspaceManager\.recordObservedFrame'
    'workspaceManager\.recordPendingFrameWrite'
    'workspaceManager\.recordFailedFrameWrite'
    # Phase 01 closing-slice — monitor reconfiguration routed through
    # `WMRuntime.applyMonitorConfigurationChange` (TX-MON-01).
    'workspaceManager\.applyMonitorConfigurationChange'
    # Phase 01 closing-slice — native fullscreen restore routed through
    # `WMRuntime.beginNativeFullscreenRestore /
    # restoreNativeFullscreenRecord` (TX-NFR-01).
    'workspaceManager\.beginNativeFullscreenRestore'
    'workspaceManager\.restoreNativeFullscreenRecord'
    'workspaceManager\.finalizeNativeFullscreenRestore'
    'workspaceManager\.seedNativeFullscreenRestoreSnapshot'
    'workspaceManager\.requestNativeFullscreenEnter'
    'workspaceManager\.requestNativeFullscreenExit'
    'workspaceManager\.markNativeFullscreenSuspended'
    'workspaceManager\.markNativeFullscreenTemporarilyUnavailable'
    'workspaceManager\.removeMissing'
    'workspaceManager\.applyAXOutcomeQuarantine'
    'workspaceManager\.quarantineStaleCGSDestroyIfApplicable'
    'workspaceManager\.quarantineWindowsForTerminatedApp'
    'workspaceManager\.garbageCollectUnusedWorkspaces'
    'workspaceManager\.focusWorkspace\('
    'workspaceManager\.swapWorkspaces'
    # Phase 01 closing-slice follow-up — TX-WORKSPACE-02. Bootstrap
    # for "infer-and-persist active workspace" is owned by
    # `WMRuntime.activateInferredWorkspaceIfNeeded(on:source:)`. The
    # production read-shaped helper
    # `WorkspaceManager.activeWorkspaceOrFirst(on:)` is now pure;
    # any production code that wants to commit the inferred answer
    # must go through the runtime adapter, never the manager mutator
    # directly.
    'workspaceManager\.activateInferredWorkspaceIfNeeded'
    # Workspace creation/materialization must be runtime-owned. A direct
    # `createIfMissing: true` lookup creates workspace descriptors and
    # mutates session topology; production callers route through
    # `WMRuntime.materializeWorkspace`.
    'createIfMissing: true'
    # Phase 01 closure — Niri viewport/session state is durable
    # workspace-session state. Production writes route through
    # `WMRuntime.withNiriViewportState` so they are stamped and
    # replay-visible.
    'workspaceManager\.withNiriViewportState'
    'workspaceManager\.updateNiriViewportState'
    # Phase 07 / TX-CONF-03 slice D — keyboard hotkey dispatch routes
    # through `WMRuntime.submit(command: WMRuntime.typedCommand(for:))`.
    # The legacy `commandHandler.handleCommand(...)` entry must not
    # become a production hotkey entrypoint outside the runtime-owned
    # dispatch path.
    'commandHandler\.handleCommand'
    'commandHandler\.setWorkspaceLayout'
    'controller\.rescueOffscreenWindows'
    # Phase 01 closing-slice — TX-AX-05. Layout-engine + focus-bridge
    # identity rekeys are orchestrated by `WMRuntime.rekeyWindow` so
    # the entire managed-replacement identity rebind commits under a
    # single transaction epoch. Direct production callers outside
    # the runtime adapter are forbidden.
    'niriEngine\??\.rekeyWindow'
    'dwindleEngine\??\.rekeyWindow'
    'focusBridge\.rekeyPendingFocus'
    'focusBridge\.rekeyManagedRequest'
    'focusBridge\.rekeyFocusedTarget'
    # Phase 01 closing-slice — TX-BORDER-01. Durable border ownership
    # mutations route through `WMRuntime.reconcileBorderOwnership`.
    # The `.cgsFrameChanged` render-only event is exempt and
    # documented under TX-BORDER-01-DEFER.
    'borderCoordinator\.reconcile'
    # Phase 01 closing-slice — TX-NFR-04. Stale native-fullscreen
    # record expiry routes through
    # `WMRuntime.expireStaleTemporarilyUnavailableNativeFullscreenRecords`
    # so the cleanup commits under a transaction epoch.
    'workspaceManager\.expireStaleTemporarilyUnavailableNativeFullscreenRecords'
    # Phase 04a (FOC-08 strict closure) — open-coded
    # `WorkspaceSessionState.FocusSession` writes are forbidden in
    # production code. The legitimate writers are:
    #   - `applyReconciledFocusSession(...)` in `WorkspaceManager` —
    #     the kernel-driven reconcile mirror.
    #   - the named mirror boundary
    #     `applyResolvedWorkspaceFocusClearMirror(in:scope:)` in
    #     `WorkspaceManager` (FOC-08 successor to the deleted
    #     `resolveAndSetWorkspaceFocusToken` mutator).
    #   - `applyConfirmedManagedFocus(...)` in `WorkspaceManager`,
    #     reached only by sealed managed-focus mutators that go
    #     through `applyFocusReconcileEvent` first.
    # Each `focus.<field> =` write below is allowlisted to its file
    # at its current count; any new occurrence outside the allowlist
    # fails the gate.
    'focus\.focusedToken = '
    'focus\.pendingManagedFocus = '
    'focus\.isAppFullscreenActive = '
    'focus\.isNonManagedFocusActive = '
    # Phase 04a (FOC-08 strict closure) — pending-focus mutators are
    # `WorkspaceManager`-private. The patterns below catch
    # accidental escapes (e.g., a future caller routing through
    # `workspaceManager.clearPendingManagedFocusRequest(...)` from
    # outside the manager). All current call sites are internal and
    # match without the `workspaceManager.` prefix.
    'workspaceManager\.clearPendingManagedFocusRequest'
    'workspaceManager\.updatePendingManagedFocusRequest'
    # Phase 04a (FOC-08 strict closure) — `updateFocusSession(notify:)`
    # is the only function in `WorkspaceManager` that mutates
    # `sessionState.focus` directly outside the kernel reconcile
    # mirror. Every internal call site is in `WorkspaceManager.swift`;
    # this pattern catches any future external caller.
    'workspaceManager\.updateFocusSession\(notify'

    # Phase 02 hardening — `LogicalWindowRegistry` is the authoritative
    # owner of logical-window identity and lifecycle facets. Production
    # code must never construct a parallel mutable registry: the only
    # allowed construction site is the `WorkspaceManager`-owned
    # storage. Tests legitimately instantiate registries and live under
    # `Tests/`, which is outside this `Sources/` scan.
    'LogicalWindowRegistry\(\)'
    # Direct registry-mutator access from outside `WorkspaceManager`.
    # The read-only `LogicalWindowRegistryReading` protocol does not
    # expose these, so a hit here means a caller is reaching the
    # concrete storage. Allowed only as the `WorkspaceManager` storage
    # itself.
    'logicalWindowRegistryStorage\.'
)

# Counted allowlist for production compatibility callers. Format:
#   path|grep-pattern|max-count|rationale
#
# Phase 07 closure: migration-debt allowlist rows must stay empty. The
# remaining counted direct callers are enforced below as ownership
# boundaries, not compatibility budget.
ALLOWLIST_RULES=()

# Intentional non-session seams. These are direct writes, but they are not
# durable workspace/session ownership mutations:
# - gap setters are the controller's configuration-apply phase (runtime-owned
#   when reached from persisted settings, and also used by standalone
#   controller tests);
# - constraint writes are layout cache hints with bounded cache lifetime;
# - animation clock wiring is render/motion plumbing.
#
# Keep this list small and counted. If a row starts to describe durable
# workspace state, route it through a runtime domain instead.
EXEMPT_PATTERNS=(
    'Sources/OmniWM/Core/Controller/WMController.swift|workspaceManager\.setGaps|1|configuration apply phase'
    'Sources/OmniWM/Core/Controller/WMController.swift|workspaceManager\.setOuterGaps|1|configuration apply phase'
    'Sources/OmniWM/Core/Controller/WMController.swift|workspaceManager\.setCachedConstraints|1|window-size constraint cache hint'
    'Sources/OmniWM/Core/Controller/WMController.swift|workspaceManager\.updateAnimationClock|1|animation clock wiring'
    'Sources/OmniWM/Core/Controller/LayoutRefreshController.swift|workspaceManager\.setCachedConstraints|2|layout constraint cache warming'
    'Sources/OmniWM/Core/Controller/AXEventHandler.swift|borderCoordinator\.reconcile|1|render-only cgs frame border reconciliation'
)

# Historical compatibility ownership-boundary rows must stay empty. Active
# owner validation now lives in `OWNER_SURFACE_RULES` below.
OWNERSHIP_BOUNDARY_RULES=()

# Enforced owner-surface rules. These are not migration debt, but they are
# deliberately exact: each runtime/domain owner is allowed only the mutator
# family it owns at the current count. If a domain needs a new durable writer,
# update this matrix with the architectural rationale in the same change.
OWNER_SURFACE_RULES=(
    'Sources/OmniWM/Core/Runtime/FocusRuntime.swift|workspaceManager\.applyOrchestrationFocusState|1|focus runtime adapter'
    'Sources/OmniWM/Core/Runtime/FocusRuntime.swift|workspaceManager\.applyFocusReducerEvent\(|1|focus reducer runtime adapter'
    'Sources/OmniWM/Core/Runtime/FocusRuntime.swift|workspaceManager\.applyFocusReducerEventReturningAction|1|focus reducer runtime adapter'
    'Sources/OmniWM/Core/Runtime/FocusRuntime.swift|workspaceManager\.beginManagedFocusRequest|1|focus runtime adapter'
    'Sources/OmniWM/Core/Runtime/FocusRuntime.swift|workspaceManager\.cancelManagedFocusRequest|2|focus runtime adapter'
    'Sources/OmniWM/Core/Runtime/FocusRuntime.swift|workspaceManager\.confirmManagedFocus|2|focus runtime adapter'
    'Sources/OmniWM/Core/Runtime/FocusRuntime.swift|workspaceManager\.enterNonManagedFocus|3|focus runtime adapter'
    'Sources/OmniWM/Core/Runtime/FocusRuntime.swift|workspaceManager\.setManagedFocus|2|focus runtime adapter'

    'Sources/OmniWM/Core/Runtime/FrameRuntime.swift|workspaceManager\.recordFailedFrameWrite|1|frame runtime adapter'
    'Sources/OmniWM/Core/Runtime/FrameRuntime.swift|workspaceManager\.recordObservedFrame|1|frame runtime adapter'
    'Sources/OmniWM/Core/Runtime/FrameRuntime.swift|workspaceManager\.recordPendingFrameWrite|1|frame runtime adapter'
    'Sources/OmniWM/Core/Runtime/FrameRuntime.swift|workspaceManager\.applyAXOutcomeQuarantine|1|frame runtime quarantine adapter'
    'Sources/OmniWM/Core/Runtime/FrameRuntime.swift|workspaceManager\.setFloatingState|1|frame runtime adapter'
    'Sources/OmniWM/Core/Runtime/FrameRuntime.swift|workspaceManager\.updateFloatingGeometry|1|frame runtime adapter'

    'Sources/OmniWM/Core/Runtime/MonitorRuntime.swift|workspaceManager\.activateInferredWorkspaceIfNeeded|2|monitor runtime topology bootstrap'
    'Sources/OmniWM/Core/Runtime/MonitorRuntime.swift|workspaceManager\.applyMonitorConfigurationChange|1|monitor runtime adapter'

    'Sources/OmniWM/Core/Runtime/NativeFullscreenRuntime.swift|workspaceManager\.beginNativeFullscreenRestore|1|native-fullscreen runtime adapter'
    'Sources/OmniWM/Core/Runtime/NativeFullscreenRuntime.swift|workspaceManager\.expireStaleTemporarilyUnavailableNativeFullscreenRecords|1|native-fullscreen runtime adapter'
    'Sources/OmniWM/Core/Runtime/NativeFullscreenRuntime.swift|workspaceManager\.finalizeNativeFullscreenRestore|1|native-fullscreen runtime adapter'
    'Sources/OmniWM/Core/Runtime/NativeFullscreenRuntime.swift|workspaceManager\.markNativeFullscreenSuspended|1|native-fullscreen runtime adapter'
    'Sources/OmniWM/Core/Runtime/NativeFullscreenRuntime.swift|workspaceManager\.markNativeFullscreenTemporarilyUnavailable|1|native-fullscreen runtime adapter'
    'Sources/OmniWM/Core/Runtime/NativeFullscreenRuntime.swift|workspaceManager\.requestNativeFullscreenEnter|1|native-fullscreen runtime adapter'
    'Sources/OmniWM/Core/Runtime/NativeFullscreenRuntime.swift|workspaceManager\.requestNativeFullscreenExit|1|native-fullscreen runtime adapter'
    'Sources/OmniWM/Core/Runtime/NativeFullscreenRuntime.swift|workspaceManager\.restoreFromNativeState|1|native-fullscreen runtime adapter'
    'Sources/OmniWM/Core/Runtime/NativeFullscreenRuntime.swift|workspaceManager\.restoreNativeFullscreenRecord|1|native-fullscreen runtime adapter'
    'Sources/OmniWM/Core/Runtime/NativeFullscreenRuntime.swift|workspaceManager\.seedNativeFullscreenRestoreSnapshot|1|native-fullscreen runtime adapter'
    'Sources/OmniWM/Core/Runtime/NativeFullscreenRuntime.swift|workspaceManager\.setManagedAppFullscreen|1|native-fullscreen runtime adapter'

    'Sources/OmniWM/Core/Runtime/RuntimeControllerOperations.swift|borderCoordinator\.reconcile|1|runtime controller-operation adapter'
    'Sources/OmniWM/Core/Runtime/RuntimeControllerOperations.swift|controller\.rescueOffscreenWindows|1|runtime controller-operation adapter'
    'Sources/OmniWM/Core/Runtime/RuntimeControllerOperations.swift|controller\.windowActionHandler\.focusWindowFromBar|1|runtime controller-operation adapter'
    'Sources/OmniWM/Core/Runtime/RuntimeControllerOperations.swift|controller\.windowActionHandler\.focusWorkspaceFromBar|1|runtime controller-operation adapter'
    'Sources/OmniWM/Core/Runtime/RuntimeControllerOperations.swift|controller\.windowActionHandler\.navigateToWindow|1|runtime controller-operation adapter'
    'Sources/OmniWM/Core/Runtime/RuntimeControllerOperations.swift|controller\.windowActionHandler\.summonWindowRight|1|runtime controller-operation adapter'
    'Sources/OmniWM/Core/Runtime/RuntimeControllerOperations.swift|controller\.workspaceNavigationHandler\.focusWorkspaceAnywhere|1|runtime controller-operation adapter'
    'Sources/OmniWM/Core/Runtime/RuntimeControllerOperations.swift|controller\.workspaceNavigationHandler\.moveFocusedWindow|1|runtime controller-operation adapter'
    'Sources/OmniWM/Core/Runtime/RuntimeControllerOperations.swift|controller\.workspaceNavigationHandler\.moveWindowToWorkspaceOnMonitor|1|runtime controller-operation adapter'
    'Sources/OmniWM/Core/Runtime/RuntimeControllerOperations.swift|dwindleEngine\??\.rekeyWindow|1|runtime controller-operation adapter'
    'Sources/OmniWM/Core/Runtime/RuntimeControllerOperations.swift|focusBridge\.rekeyFocusedTarget|1|runtime controller-operation adapter'
    'Sources/OmniWM/Core/Runtime/RuntimeControllerOperations.swift|focusBridge\.rekeyManagedRequest|1|runtime controller-operation adapter'
    'Sources/OmniWM/Core/Runtime/RuntimeControllerOperations.swift|focusBridge\.rekeyPendingFocus|1|runtime controller-operation adapter'
    'Sources/OmniWM/Core/Runtime/RuntimeControllerOperations.swift|niriEngine\??\.rekeyWindow|1|runtime controller-operation adapter'

    'Sources/OmniWM/Core/Runtime/WindowAdmissionRuntime.swift|workspaceManager\.addWindow|1|window admission runtime adapter'
    'Sources/OmniWM/Core/Runtime/WindowAdmissionRuntime.swift|workspaceManager\.garbageCollectUnusedWorkspaces|1|window admission runtime adapter'
    'Sources/OmniWM/Core/Runtime/WindowAdmissionRuntime.swift|workspaceManager\.quarantineStaleCGSDestroyIfApplicable|1|window admission quarantine adapter'
    'Sources/OmniWM/Core/Runtime/WindowAdmissionRuntime.swift|workspaceManager\.quarantineWindowsForTerminatedApp|1|window admission quarantine adapter'
    'Sources/OmniWM/Core/Runtime/WindowAdmissionRuntime.swift|workspaceManager\.rekeyWindow|1|window admission runtime adapter'
    'Sources/OmniWM/Core/Runtime/WindowAdmissionRuntime.swift|workspaceManager\.removeMissing|1|window admission runtime adapter'
    'Sources/OmniWM/Core/Runtime/WindowAdmissionRuntime.swift|workspaceManager\.removeWindow\b|1|window admission runtime adapter'
    'Sources/OmniWM/Core/Runtime/WindowAdmissionRuntime.swift|workspaceManager\.removeWindowsForApp|1|window admission runtime adapter'
    'Sources/OmniWM/Core/Runtime/WindowAdmissionRuntime.swift|workspaceManager\.setWindowMode|1|window admission runtime adapter'

    'Sources/OmniWM/Core/Runtime/WorkspaceRuntime.swift|createIfMissing: true|1|workspace runtime materialization adapter'
    'Sources/OmniWM/Core/Runtime/WorkspaceRuntime.swift|workspaceManager\.activateInferredWorkspaceIfNeeded|1|workspace runtime adapter'
    'Sources/OmniWM/Core/Runtime/WorkspaceRuntime.swift|workspaceManager\.applyResolvedWorkspaceFocusClearMirror|1|workspace runtime focus-clear mirror'
    'Sources/OmniWM/Core/Runtime/WorkspaceRuntime.swift|workspaceManager\.applySessionPatch|2|workspace runtime adapter'
    'Sources/OmniWM/Core/Runtime/WorkspaceRuntime.swift|workspaceManager\.applySessionTransfer|1|workspace runtime adapter'
    'Sources/OmniWM/Core/Runtime/WorkspaceRuntime.swift|workspaceManager\.applySettings|1|workspace runtime adapter'
    'Sources/OmniWM/Core/Runtime/WorkspaceRuntime.swift|workspaceManager\.assignWorkspaceToMonitor|1|workspace runtime adapter'
    'Sources/OmniWM/Core/Runtime/WorkspaceRuntime.swift|workspaceManager\.clearManagedRestoreSnapshot|1|workspace runtime adapter'
    'Sources/OmniWM/Core/Runtime/WorkspaceRuntime.swift|workspaceManager\.clearScratchpadIfMatches|1|workspace runtime adapter'
    'Sources/OmniWM/Core/Runtime/WorkspaceRuntime.swift|workspaceManager\.commitWorkspaceSelection|2|workspace runtime adapter'
    'Sources/OmniWM/Core/Runtime/WorkspaceRuntime.swift|workspaceManager\.rememberFocus|1|workspace runtime focus-memory hint'
    'Sources/OmniWM/Core/Runtime/WorkspaceRuntime.swift|workspaceManager\.setActiveWorkspace|3|workspace runtime adapter'
    'Sources/OmniWM/Core/Runtime/WorkspaceRuntime.swift|workspaceManager\.setHiddenState|1|workspace runtime adapter'
    'Sources/OmniWM/Core/Runtime/WorkspaceRuntime.swift|workspaceManager\.setInteractionMonitor|2|workspace runtime adapter'
    'Sources/OmniWM/Core/Runtime/WorkspaceRuntime.swift|workspaceManager\.setLayoutReason|1|workspace runtime adapter'
    'Sources/OmniWM/Core/Runtime/WorkspaceRuntime.swift|workspaceManager\.setManagedReplacementMetadata|1|workspace runtime adapter'
    'Sources/OmniWM/Core/Runtime/WorkspaceRuntime.swift|workspaceManager\.setManagedRestoreSnapshot|1|workspace runtime adapter'
    'Sources/OmniWM/Core/Runtime/WorkspaceRuntime.swift|workspaceManager\.setManualLayoutOverride|1|workspace runtime adapter'
    'Sources/OmniWM/Core/Runtime/WorkspaceRuntime.swift|workspaceManager\.setScratchpadToken|1|workspace runtime adapter'
    'Sources/OmniWM/Core/Runtime/WorkspaceRuntime.swift|workspaceManager\.setWorkspace|1|workspace runtime adapter'
    'Sources/OmniWM/Core/Runtime/WorkspaceRuntime.swift|workspaceManager\.swapTiledWindowOrder|1|workspace runtime adapter'
    'Sources/OmniWM/Core/Runtime/WorkspaceRuntime.swift|workspaceManager\.swapWorkspaces|1|workspace runtime adapter'
    'Sources/OmniWM/Core/Runtime/WorkspaceRuntime.swift|workspaceManager\.updateManagedReplacementFrame|1|workspace runtime adapter'
    'Sources/OmniWM/Core/Runtime/WorkspaceRuntime.swift|workspaceManager\.updateManagedReplacementTitle|1|workspace runtime adapter'
    'Sources/OmniWM/Core/Runtime/WorkspaceRuntime.swift|workspaceManager\.updateNiriViewportState|1|workspace runtime viewport-state adapter'

    'Sources/OmniWM/Core/Workspace/WorkspaceManager.swift|createIfMissing: true|1|internal configured-workspace synchronization'
    'Sources/OmniWM/Core/Workspace/WorkspaceManager.swift|focus\.focusedToken = |3|kernel reconcile mirror + workspace-focus-clear mirror + managed-focus confirm helper'
    'Sources/OmniWM/Core/Workspace/WorkspaceManager.swift|focus\.isAppFullscreenActive = |4|kernel reconcile + topology mirror + clear mirror + managed-focus confirm helper'
    'Sources/OmniWM/Core/Workspace/WorkspaceManager.swift|focus\.isNonManagedFocusActive = |3|kernel reconcile + topology mirror + managed-focus confirm helper'
    'Sources/OmniWM/Core/Workspace/WorkspaceManager.swift|focus\.pendingManagedFocus = |3|kernel reconcile mirror + 2 internal pending-clear helpers'
    'Sources/OmniWM/Core/Workspace/WorkspaceManager.swift|LogicalWindowRegistry\(\)|1|authoritative storage construction'
    'Sources/OmniWM/Core/Workspace/WorkspaceManager.swift|logicalWindowRegistryStorage\.|15|registry mutator seams'
)

# Phase 03 Slice CL-06 layout-handler region. file|pattern|max-count|rationale.
# The budget is intentionally empty; tracked direct reads should be migrated
# to projection-routed lookups (e.g. `WorkspaceGraph.entriesByLogicalId`)
# before landing. Defined here (alongside ALLOWLIST_RULES) so the
# `--budget-report` mode can sum both regions before the enforcement loops
# run.
LAYOUT_CONSUMER_ALLOWLIST=()

# Phase 07 / GOV-02 — read-only budget report. Sums per-rule migration-debt
# `max-count` values across both allowlist regions and prints them. Owner
# surfaces remain enforced exactly, but are reported separately because they
# are not migration debt. The completion gate (Phase 07 GOV-03 condition 1)
# requires the migration-debt total to be 0.
print_budget_report() {
    local total=0 layout_total=0 boundary_total=0 owner_total=0 exempt_total=0
    local rule path pattern count rationale
    echo "Direct-mutation budget report (Phase 07 GOV-02; target: 0)."
    echo
    echo "ALLOWLIST_RULES (per-rule max-count):"
    if (( ${#ALLOWLIST_RULES[@]} == 0 )); then
        echo "  (empty)"
    else
        for rule in "${ALLOWLIST_RULES[@]}"; do
            IFS='|' read -r path pattern count rationale <<< "$rule"
            printf '  %4d  %s  [%s]  %s\n' "$count" "$path" "$pattern" "$rationale"
            total=$((total + count))
        done
    fi
    echo
    echo "OWNERSHIP_BOUNDARY_RULES (enforced, not budget):"
    if (( ${#OWNERSHIP_BOUNDARY_RULES[@]} == 0 )); then
        echo "  (empty)"
    else
        for rule in "${OWNERSHIP_BOUNDARY_RULES[@]}"; do
            IFS='|' read -r path pattern count rationale <<< "$rule"
            printf '  %4d  %s  [%s]  %s\n' "$count" "$path" "$pattern" "$rationale"
            boundary_total=$((boundary_total + count))
        done
    fi
    echo
    echo "OWNER_SURFACE_RULES (enforced, not budget):"
    if (( ${#OWNER_SURFACE_RULES[@]} == 0 )); then
        echo "  (empty)"
    else
        for rule in "${OWNER_SURFACE_RULES[@]}"; do
            IFS='|' read -r path pattern count rationale <<< "$rule"
            printf '  %4d  %s  [%s]  %s\n' "$count" "$path" "$pattern" "$rationale"
            owner_total=$((owner_total + count))
        done
    fi
    echo
    echo "EXEMPT_PATTERNS (intentional non-session writes, not budget):"
    if (( ${#EXEMPT_PATTERNS[@]} == 0 )); then
        echo "  (empty)"
    else
        for rule in "${EXEMPT_PATTERNS[@]}"; do
            IFS='|' read -r path pattern count rationale <<< "$rule"
            printf '  %4d  %s  [%s]  %s\n' "$count" "$path" "$pattern" "$rationale"
            exempt_total=$((exempt_total + count))
        done
    fi
    echo
    echo "Phase 03 CL-06 layout-handler region (LAYOUT_CONSUMER_ALLOWLIST, max-count):"
    if (( ${#LAYOUT_CONSUMER_ALLOWLIST[@]} == 0 )); then
        echo "  (empty — budget is structurally 0 in this region)"
    else
        for rule in "${LAYOUT_CONSUMER_ALLOWLIST[@]}"; do
            IFS='|' read -r path pattern count rationale <<< "$rule"
            printf '  %4d  %s  [%s]  %s\n' "$count" "$path" "$pattern" "$rationale"
            layout_total=$((layout_total + count))
        done
    fi
    echo
    PRINTED_ALLOWLIST_BUDGET=$((total + layout_total))
    echo "Total allowlist budget: $PRINTED_ALLOWLIST_BUDGET (ALLOWLIST_RULES: $total; LAYOUT_CONSUMER_ALLOWLIST: $layout_total)"
    echo "Enforced ownership-boundary count excluded from migration debt: $boundary_total"
    echo "Enforced owner-surface count excluded from migration debt: $owner_total"
    echo "Intentional exempt count excluded from migration debt: $exempt_total"
    echo "Migration completion gate (Phase 07 GOV-03 condition 1) requires this total to remain 0."
}

if (( BUDGET_REPORT == 1 )); then
    print_budget_report
    if (( BUDGET_GATE == 1 )) && (( ${#ALLOWLIST_RULES[@]} != 0
        || ${#LAYOUT_CONSUMER_ALLOWLIST[@]} != 0
        || ${#OWNERSHIP_BOUNDARY_RULES[@]} != 0 )); then
        echo "ERROR: migration allowlist/boundary arrays must remain empty." >&2
        exit 1
    fi
    if (( BUDGET_GATE == 1 && PRINTED_ALLOWLIST_BUDGET != 0 )); then
        echo "ERROR: direct-mutation migration-debt budget is non-zero." >&2
        exit 1
    fi
    exit 0
fi

if (( ${#ALLOWLIST_RULES[@]} != 0
    || ${#LAYOUT_CONSUMER_ALLOWLIST[@]} != 0
    || ${#OWNERSHIP_BOUNDARY_RULES[@]} != 0 )); then
    echo "ERROR: migration allowlist/boundary arrays must remain empty." >&2
    exit 1
fi

allowed_rule_for() {
    local file="$1"
    local pattern="$2"
    local rule path allowed_pattern allowed_count _rationale

    if (( ${#ALLOWLIST_RULES[@]} != 0 )); then
        for rule in "${ALLOWLIST_RULES[@]}"; do
            IFS='|' read -r path allowed_pattern allowed_count _rationale <<< "$rule"
            if [[ "$file" == "$path" && "$pattern" == "$allowed_pattern" ]]; then
                printf 'allowlist|%s' "$allowed_count"
                return
            fi
        done
    fi
    if (( ${#OWNERSHIP_BOUNDARY_RULES[@]} != 0 )); then
        for rule in "${OWNERSHIP_BOUNDARY_RULES[@]}"; do
            IFS='|' read -r path allowed_pattern allowed_count _rationale <<< "$rule"
            if [[ "$file" == "$path" && "$pattern" == "$allowed_pattern" ]]; then
                printf 'boundary|%s' "$allowed_count"
                return
            fi
        done
    fi
    for rule in "${OWNER_SURFACE_RULES[@]}"; do
        IFS='|' read -r path allowed_pattern allowed_count _rationale <<< "$rule"
        if [[ "$file" == "$path" && "$pattern" == "$allowed_pattern" ]]; then
            printf 'owner|%s' "$allowed_count"
            return
        fi
    done
    for rule in "${EXEMPT_PATTERNS[@]}"; do
        IFS='|' read -r path allowed_pattern allowed_count _rationale <<< "$rule"
        if [[ "$file" == "$path" && "$pattern" == "$allowed_pattern" ]]; then
            printf 'exempt|%s' "$allowed_count"
            return
        fi
    done
    printf 'none|0'
}

violations=0

for pattern in "${PATTERNS[@]}"; do
    matches="$(grep -rEn "$pattern" Sources 2>/dev/null || true)"
    [[ -z "$matches" ]] && continue

    files="$(printf '%s\n' "$matches" | cut -d: -f1 | sort -u)"
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        count="$(printf '%s\n' "$matches" | awk -F: -v f="$file" '$1 == f { c++ } END { print c + 0 }')"
        rule_info="$(allowed_rule_for "$file" "$pattern")"
        IFS='|' read -r rule_region allowed <<< "$rule_info"
        if [[ "$rule_region" == "owner" ]]; then
            continue
        fi
        if (( count <= allowed )); then
            continue
        fi

        if (( violations == 0 )); then
            echo "Phase 01 closing-slice enforcement: direct-mutation policy violation."
            echo "New callers must route through WMRuntime or carry an allowlist rationale in this script."
            echo
        fi
        echo "Pattern: $pattern"
        echo "File: $file"
        echo "Allowed: $allowed, found: $count"
        printf '%s\n' "$matches" | awk -F: -v f="$file" '$1 == f { print }'
        echo
        violations=$((violations + 1))
    done <<< "$files"
done

for rule in "${OWNER_SURFACE_RULES[@]}"; do
    IFS='|' read -r path pattern allowed _rationale <<< "$rule"
    if [[ -f "$path" ]]; then
        matches="$(grep -En "$pattern" "$path" 2>/dev/null || true)"
        count="$(printf '%s\n' "$matches" | awk 'NF { c++ } END { print c + 0 }')"
    else
        matches=""
        count=0
    fi
    if (( count == allowed )); then
        continue
    fi

    if (( violations == 0 )); then
        echo "Phase 01 closing-slice enforcement: direct-mutation policy violation."
        echo "New callers must route through WMRuntime or carry an allowlist rationale in this script."
        echo
    fi
    echo "Stale owner-surface rule: $path"
    echo "Pattern: $pattern"
    echo "Expected exact owner count: $allowed, found: $count"
    if [[ -n "$matches" ]]; then
        printf '%s\n' "$matches" | sed "s#^#$path:#"
    fi
    echo
    violations=$((violations + 1))
done

if (( violations > 0 )); then
    echo "Total violation patterns: $violations"
    echo "Durable state callers must route through WMRuntime or a domain runtime."
    echo "Only intentional non-session seams may be counted in EXEMPT_PATTERNS."
    echo "Owner surfaces require an explicit structural exclusion in this script;"
    echo "OWNERSHIP_BOUNDARY_RULES must remain empty."
    exit 1
fi

workspace_membership_indexes="$(
    grep -rEn 'tokensByWorkspace|tokenIndexByWorkspace|tokensByWorkspaceMode|tokenIndexByWorkspaceMode|entriesByWorkspace|tiledEntriesByWorkspace|floatingEntriesByWorkspace|tiledOrderByWorkspace|floatingOrderByWorkspace' \
        Sources/OmniWM/Core 2>/dev/null \
        | grep -v '^Sources/OmniWM/Core/Workspace/WorkspaceGraph.swift:' || true
)"
if [[ -n "$workspace_membership_indexes" ]]; then
    echo "WorkspaceGraph authority violation: production code reintroduced workspace membership/order indexes outside WorkspaceGraph."
    printf '%s\n' "$workspace_membership_indexes"
    exit 1
fi

membership_reader_matches="$(
    grep -rEn '\.(tiledEntries|floatingEntries|allTiledEntries|allFloatingEntries)\(' Sources 2>/dev/null \
        | grep -v '^Sources/OmniWM/Core/Workspace/WorkspaceManager.swift:' || true
)"
if [[ -n "$membership_reader_matches" ]]; then
    echo "WorkspaceGraph authority violation: production code calls manager tiled/floating membership readers."
    printf '%s\n' "$membership_reader_matches"
    exit 1
fi

typed_dispatch_closure_matches="$(
    grep -rEn 'CommandHandler|recordTypedDispatch|typed_dispatch|FocusActionHandler|WindowMoveActionHandler|LayoutMutationActionHandler|WorkspaceNavigationActionHandler|UIActionHandler' \
        Sources Tests 2>/dev/null || true
)"
if [[ -n "$typed_dispatch_closure_matches" ]]; then
    echo "Typed command closure violation: transitional dispatch surface reintroduced."
    printf '%s\n' "$typed_dispatch_closure_matches"
    exit 1
fi

# Phase 03 Slice CL-06 enforcement: production layout-snapshot
# construction must read workspace membership/order through
# `WorkspaceGraph` and `MonitorTopologyState`, not the WGT-10
# compatibility accessors on `WorkspaceManager`. The
# `LayoutRefreshController.buildRefreshInput(...)` cache-warming
# step is OUTSIDE this enforcement scope (it intentionally reads
# `tiledEntries(in:)` to warm `cachedConstraints`); only the two
# layout-handler files are checked. There is no layout-handler
# allowlist: any compatibility-accessor read in either file fails
# this gate.
LAYOUT_CONSUMER_FILES=(
    'Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift'
    'Sources/OmniWM/Core/Controller/DwindleLayoutHandler.swift'
)

LAYOUT_COMPAT_PATTERNS=(
    '\.entries\(in:'
    '\.tiledEntries\('
    '\.floatingEntries\('
    '\.monitorForWorkspace\('
    # Phase 03 hardening: animation/helper paths must look up
    # monitors and active workspaces through `MonitorTopologyState`,
    # not via live `WorkspaceManager` reads. These patterns catch the
    # most common bypasses noted in the post-implementation review.
    'workspaceManager\.monitors\.first\('
    'workspaceManager\.monitors\b'
    'workspaceManager\.activeWorkspaceOrFirst\('
    # Phase 03 hardening (post-review follow-up): command/helper
    # paths in the layout handlers were previously reading the active
    # workspace via `WMController.activeWorkspace()` (which itself
    # falls through to `WorkspaceManager.activeWorkspaceOrFirst`) and
    # workspace-to-monitor lookups via `WorkspaceManager.monitor(for:)`.
    # Both are now routed through `LayoutProjectionContext` so the
    # patterns are forbidden in the layout handler files.
    'controller\.activeWorkspace\(\)'
    'workspaceManager\.monitor\(for:'
)

layout_allowed_count_for() {
    local file="$1"
    local pattern="$2"
    local rule path allowed_pattern allowed_count _rationale

    if (( ${#LAYOUT_CONSUMER_ALLOWLIST[@]} != 0 )); then
        for rule in "${LAYOUT_CONSUMER_ALLOWLIST[@]}"; do
            IFS='|' read -r path allowed_pattern allowed_count _rationale <<< "$rule"
            if [[ "$file" == "$path" && "$pattern" == "$allowed_pattern" ]]; then
                printf '%s' "$allowed_count"
                return
            fi
        done
    fi
    printf '0'
}

layout_violations=0

for file in "${LAYOUT_CONSUMER_FILES[@]}"; do
    [[ -f "$file" ]] || continue
    for pattern in "${LAYOUT_COMPAT_PATTERNS[@]}"; do
        matches="$(grep -En "$pattern" "$file" 2>/dev/null || true)"
        [[ -z "$matches" ]] && continue
        count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
        allowed="$(layout_allowed_count_for "$file" "$pattern")"
        if (( count <= allowed )); then
            continue
        fi

        if (( layout_violations == 0 )); then
            echo "Phase 03 Slice CL-06 enforcement: layout consumer reads WGT-10 compatibility accessor."
            echo "Production layout-snapshot construction must read membership/order through"
            echo "WorkspaceGraph + MonitorTopologyState, not WorkspaceManager.{entries,tiledEntries,"
            echo "floatingEntries,monitorForWorkspace}. Carry any compatibility exception in this script."
            echo
        fi
        echo "Pattern: $pattern"
        echo "File: $file"
        echo "Allowed: $allowed, found: $count"
        printf '%s\n' "$matches"
        echo
        layout_violations=$((layout_violations + 1))
    done
done

if (( layout_violations > 0 )); then
    echo "Total layout-consumer violations: $layout_violations"
    echo "Route layout-handler membership/topology reads through projection state."
    echo "LAYOUT_CONSUMER_ALLOWLIST must remain empty in the sealed migration."
    exit 1
fi

echo "Direct-mutation enforcement OK: no violations outside the allowlist."

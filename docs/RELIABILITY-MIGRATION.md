# OmniWM Reliability Migration Tracker

This document tracks progress against the phased reliability rewrite plan
(see `/Users/barut/Desktop/REWRITE/` during development). It is the
authoritative checklist of remaining direct-mutation paths and their
migration status; every migration PR should update at least one row.

The plan is a strangler migration, not a big-bang rewrite: narrow the
mutation boundary one subsystem at a time, keep rollback adapters local,
and promote tests ahead of behavior where feasible.

## Active Phase

Phase 01 — Authoritative Transaction Path.

Current slice: **Milestone A — transaction skeleton**. Establishes the
typed transaction boundary (`WMCommand`, `WMEffectPlan`, `WMEffectRunner`,
stamped `TransactionEpoch` / `EffectEpoch`), routes one narrow handler
path (`WorkspaceNavigationHandler.switchWorkspace(rawWorkspaceID:)` and
`switchWorkspaceRelative(...)`) through `WMRuntime.submit(command:)`, and
adds the early replay runner.

## Status Legend

| Status | Meaning |
| --- | --- |
| `not-started` | Still calls a durable-state API directly; no migration work done |
| `inventory` | Call sites enumerated; migration strategy not yet written |
| `adapter-added` | New transaction/effect plumbing exists; caller still on legacy path |
| `partially-routed` | Handler routes through `WMRuntime.submit(...)` when runtime is attached; legacy fallback remains |
| `transaction-owned` | Direct durable-state APIs are unreachable from this caller |
| `legacy-sealed` | Legacy fallback removed; transaction path is the only entrypoint |
| `verified` | Coverage includes transcript/replay tests for the migrated path |
| `deferred-with-rationale` | Intentionally out of scope for the current phase |

## Mutation Inventory

Each row names a durable-state mutation surface, the target event/effect
boundary it must move onto, and the current status. Add rows when new
direct paths are identified; edit in place when status advances.

### WorkspaceNavigationHandler

| ID | Phase | Subsystem | Current direct path | Target event/effect | Owner | Status | Tests | Rollback | Verification |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| WNH-01 | 01 | Workspace switch (explicit) | `WorkspaceNavigationHandler.switchWorkspace(rawWorkspaceID:)` | `WMCommand.workspaceSwitch(.explicit)` → `WMEffectPlan` | — | `partially-routed` | `WorkspaceSwitchTransactionTests`, `TransactionReplayRunnerTests`, `WMEffectRunnerTests` | Runtime-nil fallback keeps the legacy path | `make test` |
| WNH-02 | 01 | Workspace switch (relative) | `WorkspaceNavigationHandler.switchWorkspaceRelative(isNext:wrapAround:)` | `WMCommand.workspaceSwitch(.relative)` → `WMEffectPlan` | — | `partially-routed` | `WorkspaceSwitchTransactionTests` (shared) | Runtime-nil fallback keeps the legacy path | `make test` |
| WNH-03 | 01 | Workspace switch by index | `WorkspaceNavigationHandler.switchWorkspace(index:)` | Delegates to WNH-01 | — | `partially-routed` | covered via WNH-01 | same as WNH-01 | `make test` |
| WNH-04 | 01 | Focus monitor cyclic / last | `focusMonitorCyclic`, `focusLastMonitor` | `WMCommand.workspaceFocusMonitor(...)` (TBD) | — | `deferred-with-rationale` | — | — | out of scope for slice 1 |
| WNH-05 | 01 | Swap workspaces across monitors | `swapCurrentWorkspaceWithMonitor(direction:)` | `WMCommand.workspaceSwap(...)` (TBD) | — | `deferred-with-rationale` | — | — | out of scope for slice 1 |
| WNH-06 | 01 | Focus workspace anywhere | `focusWorkspaceAnywhere(...)` | TBD | — | `deferred-with-rationale` | — | — | out of scope for slice 1 |
| WNH-07 | 01 | Workspace back-and-forth | `workspaceBackAndForth()` | TBD | — | `deferred-with-rationale` | — | — | out of scope for slice 1 |
| WNH-08 | 01 | Move window to adjacent workspace | `moveWindowToAdjacentWorkspace(direction:)` | TBD | — | `deferred-with-rationale` | — | — | move-window paths explicitly out of scope for slice 1 |
| WNH-09 | 01 | Move column to adjacent workspace | `moveColumnToAdjacentWorkspace(direction:)` | TBD | — | `deferred-with-rationale` | — | — | column-transfer paths explicitly out of scope for slice 1 |
| WNH-10 | 01 | Move column to explicit workspace | `moveColumnToWorkspace(rawWorkspaceID:)`, `moveColumnToWorkspaceByIndex(index:)` | TBD | — | `deferred-with-rationale` | — | — | column-transfer paths explicitly out of scope for slice 1 |
| WNH-11 | 01 | Move focused window to workspace | `moveFocusedWindow(toRawWorkspaceID:)`, `moveFocusedWindow(toWorkspaceIndex:)` | TBD | — | `deferred-with-rationale` | — | — | move-window paths explicitly out of scope for slice 1 |
| WNH-12 | 01 | Move window handle | `moveWindow(handle:toWorkspaceId:)` | TBD | — | `deferred-with-rationale` | — | — | move-window paths explicitly out of scope for slice 1 |
| WNH-13 | 01 | Move window across monitors | `moveWindowToWorkspaceOnMonitor(...)` | TBD | — | `deferred-with-rationale` | — | — | move-window paths explicitly out of scope for slice 1 |

### Other durable-mutation paths awaiting inventory

The following surfaces are known to call `WorkspaceManager` / focus /
layout APIs directly and still need explicit rows. They are intentionally
not scoped to slice 1; they are listed here so later PRs pick them up
from the same document rather than re-discovering them.

- `WMController.handleRuntimeFocusRequest` and focus-bridge helpers
- `AXEventHandler` window admit / remove / fullscreen paths
- `CommandHandler` CLI / keyboard commands
- `IPCCommandRouter` commands
- `DwindleLayoutHandler` / `NiriLayoutHandler` gesture paths
- Native fullscreen enter/exit correlation (`WMController.handleNativeFullscreenTransition`)
- Monitor reconfiguration (`applyMonitorConfigurationChange`)

Each will get its own row as the corresponding phase slice begins.

## Notes and Conventions

- Any new transaction/effect type must set a non-`invalid`
  `TransactionEpoch` on the resulting `ReconcileTxn`. A txn with
  `transactionEpoch == .invalid` is the canonical signal for "this
  durable mutation did not go through `WMRuntime.submit(...)` yet" —
  `WorkspaceSwitchTransactionTests.recordReconcileEventWithoutRuntimeHasInvalidEpoch`
  enshrines that contract.
- Plans must remain closure-free. Post-effect follow-ups are modeled
  declaratively (see `WMEffect.PostWorkspaceTransitionAction`) so
  transcript tests can serialize them.
- When a handler path keeps a legacy fallback during a slice, the
  fallback must route through the same kernel/planner as the
  transaction path so behavior cannot drift. Fallbacks are removed only
  when the row advances to `legacy-sealed`.

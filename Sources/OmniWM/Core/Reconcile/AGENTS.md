# AGENTS.md — Core/Reconcile

## Purpose

Deterministic state reconciliation engine. Converts raw events into planned state mutations. Follows Redux/Elm pattern: events are immutable, reducers are pure, state transitions are auditable.

## File Map (14 files)

### Event Pipeline
- `WMEvent.swift` — Enum with 20+ event variants (windowAdmitted, windowRemoved, windowModeChanged, focusChanged, topologyChanged, etc.)
- `EventNormalizer.swift` — Cleans/deduplicates raw events before planning

### Planning & Reduction
- `Planner.swift` — Computes ActionPlan given event + current snapshot
- `StateReducer.swift` — Applies action plans to state (pure function: `(event, entry, snapshot) → ActionPlan`)
- `ActionPlan.swift` — Declarative state transition type (move, add, remove, resize, focus)
- `ReconcileSnapshot.swift` — Immutable snapshot of window/workspace state for deterministic reduction

### State Management
- `RuntimeStore.swift` — @MainActor transaction engine; records events, runs planner, applies results
- `FocusPolicyEngine.swift` — Computes next-to-focus window based on layout position + policy rules
- `RestorePlanner.swift` — Plans window restoration on app startup

### Auditing
- `ReconcileTxn.swift` — Transaction record (event + plan + snapshot triple)
- `ReconcileTrace.swift` — Debug trace recording for replay/inspection
- `InvariantChecks.swift` — State invariant validation (assertions for debugging)

### Persistence
- `PersistedWindowRestoreCatalog.swift` — JSON-serialized window positions for session restore

## Key Invariants

1. **StateReducer is pure**: `(event, oldEntry, snapshot) → ActionPlan` — no side effects
2. **Events are immutable**: Once created, WMEvent instances never change
3. **Snapshots capture full state**: ReconcileSnapshot includes all workspace/window/focus state needed for deterministic reduction
4. **Every transaction is recorded**: ReconcileTxn preserves the full audit trail

## Data Flow

```text
Raw Event (AX/CGS/Input)
    ↓
EventNormalizer (dedup, validate, edge-case handling)
    ↓
RuntimeStore.transact()
    ↓
Planner.plan(event, snapshot) → ActionPlan
    ↓
StateReducer.reduce(plan) → state mutations
    ↓
WorkspaceManager applies mutations
    ↓
ReconcileTxn recorded for audit
```

## Adding New Events

1. Add case to `WMEvent` enum
2. Add normalization logic in `EventNormalizer` if needed
3. Add planning logic in `Planner` (how should state change?)
4. Add reduction case in `StateReducer`
5. Update `InvariantChecks` if new invariants apply
6. Add test covering the new event → plan → state flow

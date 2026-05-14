# AGENTS.md — Sources/OmniWM/Core

## Module Purpose

Core window management logic. Contains all subsystems that make OmniWM function: event handling, state reconciliation, layout computation, accessibility bridging, configuration, animation, and input processing.

## Architecture

```
Input Layer (Hotkeys, AX, Mouse, CGS)
    ↓
Controller Layer (handlers route events)
    ↓
Reconcile Layer (WMEvent → ActionPlan, deterministic)
    ↓
State Layer (WorkspaceManager, WindowModel)
    ↓
Layout Engines (Niri, Dwindle — pure geometry)
    ↓
Output Layer (AXManager applies frames, BorderManager renders)
```

## Subdirectory Map

| Directory | Files | Responsibility |
|-----------|-------|----------------|
| `Animation/` | 6 | Spring/cubic/move animations, MotionPolicy, SwipeTracker |
| `Ax/` | 10 | Accessibility API bridge (AXManager, AXWindow, AppAXContext, thread utilities) |
| `Border/` | 3 | Focus border windows (BorderManager, BorderWindow, BorderConfig) |
| `Config/` | 20 | Settings persistence, TOML codec, workspace/monitor/app-rule configs |
| `Controller/` | 17 | Event handlers, command routing, layout refresh orchestration |
| `Input/` | 8 | Hotkey capture (Carbon), action catalog, scroll tracking |
| `Layout/Niri/` | 30 | Scrolling columns layout engine |
| `Layout/Dwindle/` | 5 | BSP layout engine |
| `LockScreen/` | 1 | Lock screen observer |
| `Menu/` | 3 | App menu extraction for command palette |
| `Monitor/` | 5 | Display model, topology observer, restore assignments |
| `Overview/` | 9 | Window thumbnail overview mode |
| `Reconcile/` | 14 | Event normalization, planning, state reduction |
| `Rules/` | 1 | WindowRuleEngine (app matching, float/assign policies) |
| `SkyLight/` | 1 | CGSEventObserver (private CoreGraphics event stream) |
| `Sleep/` | 1 | IOKit sleep prevention |
| `Support/` | 3 | CGGeometry extensions, Bundle extensions, ParseError |
| `Surface/` | 2 | Window rendering surface coordinator |
| `Workspace/` | 6 | WorkspaceManager, WindowModel, ordering, descriptors |

## Key Patterns

### @MainActor Everywhere
All Core types that hold mutable state are `@MainActor`. Exceptions:
- AX callback threads use `ThreadGuardedValue` for safe hand-off
- `CGSEventObserver` uses lock-based synchronization internally

### Lazy Handler Initialization
WMController creates handlers/managers on first access to reduce startup cost.

### Pure Layout Engines
Layout engines receive workspace geometry and window tokens, return `[WindowToken: CGRect]`. They have **zero side effects** — no AX calls, no frame writes.

### Event Normalization
Raw system events pass through `EventNormalizer` before reaching the `Planner`. This handles edge cases (duplicate events, stale tokens, race conditions).

### Coordinator Pattern
Cross-cutting behavior uses coordinators (FocusBridgeCoordinator, BorderCoordinator, SurfaceCoordinator) that observe state changes and trigger side effects.

## Adding New Features

1. **New hotkey action**: Add case to `ActionCatalog`, handle in `CommandHandler`
2. **New window event**: Add `WMEvent` case, handle in `StateReducer`, update `Planner`
3. **New layout operation**: Add to `LayoutCapabilities` protocol, implement in both engines
4. **New setting**: Add to `SettingsStore`, update `SettingsTOMLCodec`, add UI in `Sources/OmniWM/UI/`
5. **New observer**: Model after `DisplayConfigurationObserver` or `LockScreenObserver`

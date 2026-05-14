# AGENTS.md — Core/Controller

## Purpose

Event routing and orchestration layer. Controllers receive events from various sources (accessibility, mouse, keyboard, IPC) and coordinate responses through the reconciliation engine and layout handlers.

## File Map (17 files)

### Central Orchestrator
- `WMController.swift` (2366 lines) — @MainActor @Observable hub; holds all handlers, managers, settings reference; lazy-initializes subsystems

### Event Handlers
- `AXEventHandler.swift` (2462 lines) — Accessibility events: window create/destroy/rekey, app activation, focus changes
- `MouseEventHandler.swift` (1648 lines) — Mouse clicks, movement, scroll wheel, focus-follows-mouse
- `MouseWarpHandler.swift` — Mouse cursor warping on focus change
- `CommandHandler.swift` — Hotkey/IPC command → operation routing

### Layout Handlers
- `NiriLayoutHandler.swift` (1728 lines) — Niri-specific operations (scroll, column ops, animations)
- `DwindleLayoutHandler.swift` — Dwindle-specific operations (split, rotate, preselect)
- `LayoutRefreshController.swift` (2943 lines) — Layout recalculation orchestrator, frame application sequencer, visibility reconciliation

### Navigation & Actions
- `WorkspaceNavigationHandler.swift` (914 lines) — Workspace switching, window transfer between workspaces
- `WindowActionHandler.swift` — Window move/resize/fullscreen/float operations

### Coordinators
- `KeyboardFocusLifecycleCoordinator.swift` — Focus bridge: pending → confirmed pattern, lease system
- `BorderCoordinator.swift` — Updates borders in response to focus/window changes
- `ServiceLifecycleManager.swift` — Startup orchestration of all subsystems

### Support
- `LayoutCapabilities.swift` — Protocols: LayoutFocusable, LayoutSizable (abstract layout operations)
- `Direction.swift` — Direction enum (up/down/left/right)
- `FocusNotifications.swift` — NotificationCenter-based focus event broadcasting

## Patterns

### Handler Constellation
WMController doesn't handle events directly. It delegates to specialized handlers (AXEventHandler, MouseEventHandler, CommandHandler) that each own a specific event domain.

### Layout Refresh Pipeline
LayoutRefreshController has 5 refresh routes with different priorities:
1. `fullRescan` — Complete window discovery + layout
2. `relayout` — Recalculate layout for current state
3. `immediateRelayout` — Skip debouncing
4. `visibilityRefresh` — Update window visibility only
5. `windowRemoval` — Handle window removal + focus recovery

### Focus Bridge (Deferred Focus)
Focus changes go through KeyboardFocusLifecycleCoordinator using a pending → confirmed pattern. This prevents focus races when multiple events arrive simultaneously.

### Layout Capabilities Protocol
`LayoutFocusable` and `LayoutSizable` abstract layout operations so CommandHandler can dispatch without knowing which engine is active.

## Adding New Handlers

1. Create new `*Handler.swift` file
2. Make it `@MainActor final class` with weak reference to WMController
3. Initialize lazily in WMController
4. Wire events from appropriate source (AX, CGS, input, IPC)

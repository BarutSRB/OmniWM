---
title: OmniWM Architecture Guide
---

# OmniWM Architecture Guide

This document is for contributors who want to understand OmniWM's internals. It is not a user guide (see [Documentation Home](index.md)) or IPC/CLI reference (see [IPC-CLI.md](IPC-CLI.md)). For contribution process, see the [Contribution Guide](CONTRIBUTING.md).

**Prerequisites**: Familiarity with Swift, macOS development concepts (AppKit, AXUIElement, CGWindowID), and basic tiling window manager concepts.

---

## Table of Contents

- [1. Project Structure](#1-project-structure)
- [2. Startup & Bootstrap](#2-startup--bootstrap)
- [3. Core Mental Model](#3-core-mental-model)
  - [3.1 The Event-Driven Pipeline](#31-the-event-driven-pipeline)
  - [3.2 Window Identity](#32-window-identity)
  - [3.3 Window Lifecycle](#33-window-lifecycle)
  - [3.4 The Refresh Pipeline](#34-the-refresh-pipeline)
  - [3.5 Layout Engines as Pure State Machines](#35-layout-engines-as-pure-state-machines)
  - [3.6 Thread Safety Model](#36-thread-safety-model)
- [4. Key Subsystems](#4-key-subsystems)
  - [4.1 WMController — The Orchestrator](#41-wmcontroller--the-orchestrator)
  - [4.2 Workspace & Window State](#42-workspace--window-state)
  - [4.3 Niri Layout Engine (Scrolling Columns)](#43-niri-layout-engine-scrolling-columns)
  - [4.4 Dwindle Layout Engine (BSP)](#44-dwindle-layout-engine-bsp)
  - [4.5 Focus Lifecycle](#45-focus-lifecycle)
  - [4.6 Input Handling](#46-input-handling)
  - [4.7 Window Rules Engine](#47-window-rules-engine)
  - [4.8 IPC System](#48-ipc-system)
  - [4.9 Accessibility Layer](#49-accessibility-layer)
  - [4.10 Animation System](#410-animation-system)
  - [4.11 Border System](#411-border-system)
  - [4.12 Additional Features](#412-additional-features)
- [5. Data Flow Diagrams](#5-data-flow-diagrams)
- [6. Common Contribution Patterns](#6-common-contribution-patterns)
- [7. Testing](#7-testing)
- [8. Glossary](#8-glossary)

---

## 1. Project Structure

### SwiftPM Targets

OmniWM is built with Swift Package Manager (Swift 6.2, strict concurrency). There are four targets with a clear dependency graph:

```
OmniWMIPC          (zero dependencies — shared IPC protocol models)
    ^         ^
    |          \
OmniWMCtl      OmniWM + GhosttyKit   (CLI tool)       (main library)
                   ^
                   |
               OmniWMApp              (@main entry point)
```

| Target | Purpose | Dependencies |
|--------|---------|--------------|
| `OmniWMIPC` | Shared IPC data models and wire format | None |
| `OmniWMCtl` | CLI tool (`omniwmctl`) | OmniWMIPC |
| `OmniWM` | Core window manager library | OmniWMIPC, GhosttyKit, system frameworks |
| `OmniWMApp` | Executable wrapper with SwiftUI scene | OmniWM |

### Source Directory Map

```
Sources/
├── OmniWM/                          Main library (~38K LOC)
│   ├── App/                         Application bootstrap, delegate, updater,
│   │                                and owned-window registry (5 files)
│   ├── Core/
│   │   ├── AppInfoCache.swift       App icon/name cache
│   │   ├── CommandPaletteMode.swift Command palette mode enum
│   │   ├── PrivateAPIs.swift        Private API declarations via @_silgen_name
│   │   ├── Animation/               Spring, cubic & workspace-switch animations (6 files)
│   │   ├── Ax/                      Accessibility wrappers, DefaultFloatingApps (10 files)
│   │   ├── Border/                  Focused window border rendering (3 files)
│   │   ├── Config/                  Settings store, migrations, export, per-monitor settings (16 files)
│   │   ├── Controller/              WMController, event handlers, refresh pipeline (17 files)
│   │   ├── Input/                   Hotkey registration, commands, secure input monitoring (6 files)
│   │   ├── Layout/
│   │   │   ├── DNode.swift          Shared types: WindowToken, WindowHandle
│   │   │   ├── LayoutBoundary.swift Layout snapshots & workspace geometry
│   │   │   ├── SideHiding.swift     Side-hiding edge types
│   │   │   ├── Niri/                Scrolling columns layout engine (28 files)
│   │   │   └── Dwindle/             Binary space partition layout engine (5 files)
│   │   ├── LockScreen/              Lock screen detection (1 file)
│   │   ├── Menu/                    Menu extraction for MenuAnywhere (3 files)
│   │   ├── Monitor/                 Display detection, OutputId, restore assignments (5 files)
│   │   ├── Overview/                Bird's-eye workspace overview mode (9 files)
│   │   ├── Rules/                   Window rule evaluation engine (1 file)
│   │   ├── SkyLight/                Private macOS API wrappers (2 files)
│   │   ├── Sleep/                   Sleep prevention manager (1 file)
│   │   ├── Support/                 Utility types & extensions (3 files)
│   │   └── Workspace/               Workspace model, window model, naming, state (5 files)
│   ├── IPC/                         IPC server, connections, routing (9 files)
│   ├── QuakeTerminal/               Drop-down terminal, Ghostty integration (9 files)
│   └── UI/                          SwiftUI settings, status bar, workspace bar,
│                                    command palette, hidden bar, updater popup
│                                    (34 files)
├── OmniWMApp/                       2 files: @main entry + settings redirect
├── OmniWMCtl/                       7 files: CLI parser, IPC client, renderer
└── OmniWMIPC/                       5 files: models, wire format, socket path
```

### External Dependencies

OmniWM has **zero third-party package dependencies**. All functionality is built on:

- **System frameworks**: AppKit, ApplicationServices, Carbon, Metal, MetalKit, QuartzCore
- **SkyLight**: A private Apple framework for low-latency window server access, linked via `-framework SkyLight` unsafe flag
- **GhosttyKit**: A local binary xcframework at `Frameworks/GhosttyKit.xcframework` prepared outside git, providing terminal emulation for the Quake Terminal feature
- **System libraries**: libz, libc++

### Building & Running

```bash
# Debug build
swift build

# Run tests
swift test

# Code quality
make lint          # SwiftLint check
make format        # SwiftFormat
make check         # Verify formatting

# Create distributable app bundle
./Scripts/package-app.sh release true    # Build, sign, notarize
./Scripts/package-app.sh debug false     # Debug build only
```

---

## 2. Startup & Bootstrap

### Entry Point

The application starts in `Sources/OmniWMApp/OmniWMApp.swift`:

```
@main OmniWMApp (SwiftUI App)
  └─ @NSApplicationDelegateAdaptor → AppDelegate
       └─ applicationDidFinishLaunching()
            └─ bootstrapApplication()
```

### Bootstrap Decision Tree

`AppBootstrapPlanner.decision()` evaluates two preconditions before booting:

```
                        ┌─────────────────────────┐
                        │ AppBootstrapPlanner      │
                        │   .decision()            │
                        └────────┬────────────────┘
                                 │
                    ┌────────────┴────────────┐
                    │ "Displays have separate  │
                    │  Spaces" disabled?        │
                    └────────┬───────────┬─────┘
                          NO │           │ YES
                             │           │
              ┌──────────────┘      ┌────┴────────────┐
              │ Show modal:         │ Settings epoch   │
              │ .requireDisplays... │ matches?         │
              └─────────────────┘   └──┬──────────┬───┘
                                    NO │          │ YES
                                       │          │
                          ┌────────────┘     ┌────┴────┐
                          │ Show modal:      │ .boot   │
                          │ .requireSettings │ (normal)│
                          │  Reset           └─────────┘
                          └─────────────────┘
```

### Normal Boot Sequence

When the decision is `.boot`, `finishBootstrap()` runs:

1. **SettingsStore** created — loads settings from UserDefaults
2. **WMController** created — central orchestrator (see [4.1](#41-wmcontroller--the-orchestrator))
3. **`applyPersistedSettings()`** — creates both layout engines, registers hotkeys, configures borders, workspaces, gaps, etc.
4. **AppCLIManager** and **UpdateCoordinator** created — CLI exposure workflow plus GitHub release polling and popup coordination
5. **AppBootstrapState** populated — shares `SettingsStore`, `WMController`, and `UpdateCoordinator` with SwiftUI redirect flows
6. **StatusBarController** created — menu bar UI, settings entry point, and manual `Check for Updates...` action
7. **IPCServer** started (if enabled in settings) — Unix domain socket server
8. **Automatic update checks** started — only after bootstrap succeeds and after the status bar / IPC setup paths have completed

The updater is intentionally bootstrap-gated. Release polling and popup presentation do not run during the settings-reset gate or the Displays Have Separate Spaces gate.

### Service Startup

`WMController.setEnabled(true)` triggers `ServiceLifecycleManager.start()`:

1. Polls for accessibility permissions (blocks until granted)
2. Once trusted: `startServices()` connects all event plumbing:
   - `LayoutRefreshController.setup()` — display links, refresh scheduling
   - `AXEventHandler.setup()` — SkyLight event observation
   - Hotkey registration via `HotkeyCenter`
   - `MouseEventHandler.setup()` — CGEvent taps
   - Display configuration observer
   - App activation/termination/hide/unhide observers
   - Workspace change observation
   - Initial full rescan refresh

---

## 3. Core Mental Model

### 3.1 The Event-Driven Pipeline

OmniWM is fundamentally **reactive**. It responds to two categories of events, processes them through a pipeline, and applies the resulting window frames:

```
┌──────────────────────────────────────────────────────────────────┐
│                        EVENT SOURCES                             │
├──────────────────────────┬───────────────────────────────────────┤
│  System Events           │  User Input                          │
│  (SkyLight/CGS)          │  (Carbon/CGEvent)                    │
│  - Window created        │  - Hotkey pressed                    │
│  - Window destroyed      │  - Mouse moved/dragged              │
│  - Frame changed         │  - Scroll wheel (gestures)          │
│  - Front app changed     │  - IPC command (omniwmctl)          │
│  - Title changed         │                                     │
└──────────┬───────────────┴──────────┬───────────────────────────┘
           │                          │
           v                          v
┌──────────────────┐    ┌────────────────────────┐
│ CGSEventObserver │    │ HotkeyCenter /          │
│                  │    │ MouseEventHandler /     │
│                  │    │ IPCCommandRouter        │
└────────┬─────────┘    └──────────┬─────────────┘
         │                         │
         v                         v
┌──────────────────┐    ┌──────────────────┐
│ AXEventHandler   │    │ CommandHandler   │
│ (window lifecycle│    │ (command routing │
│  & focus)        │    │  & execution)    │
└────────┬─────────┘    └────────┬─────────┘
         │                       │
         └───────────┬───────────┘
                     v
         ┌───────────────────────┐
         │LayoutRefreshController│
         │ (scheduling,          │
         │  coalescing,          │
         │  debouncing)          │
         └───────────┬───────────┘
                     v
         ┌───────────────────────┐
         │ Layout Engine         │
         │ (Niri or Dwindle)     │
         │                       │
         │ Input: window list,   │
         │   workspace geometry  │
         │ Output: [WindowToken: │
         │   CGRect] frame map   │
         └───────────┬───────────┘
                     v
         ┌───────────────────────┐
         │ AXManager             │
         │ .applyFramesParallel()│
         │                       │
         │ Writes frames to      │
         │ windows via AX APIs   │
         └───────────────────────┘
```

### 3.2 Window Identity

Windows are identified at three levels, each serving a different purpose:

```swift
// 1. WindowToken — value type, used as dictionary keys everywhere
struct WindowToken: Hashable, Sendable {
    let pid: pid_t       // Process ID
    let windowId: Int    // SkyLight/CGS window ID
}

// 2. WindowHandle — reference type, identity-compared (===)
final class WindowHandle: Hashable {
    var id: WindowToken
    // hash/equality use ObjectIdentifier (reference identity)
}

// 3. AXWindowRef — accessibility bridge to the actual window
struct AXWindowRef: Hashable, @unchecked Sendable {
    let element: AXUIElement   // Accessibility handle for read/write
    let windowId: Int          // SkyLight window ID
}
```

**Why three layers?**
- `WindowToken` is a lightweight value type that survives across relayouts, is `Sendable`, and works as a dictionary key without holding any reference to the accessibility system.
- `WindowHandle` provides reference identity for layout engine tree nodes — two handles wrapping the same token are NOT equal unless they are the same object.
- `AXWindowRef` is the bridge to macOS accessibility APIs for actually reading/writing window attributes (position, size, title). It holds the `AXUIElement` which is a heavyweight system resource.

### 3.3 Window Lifecycle

From creation to destruction, a window passes through these stages:

**Creation:**
1. `CGSEventObserver` receives `.created(windowId, spaceId)` from SkyLight
2. `AXEventHandler` queries window attributes via accessibility APIs (role, subrole, title, size, buttons)
3. `WindowRuleEngine.evaluate()` produces a `WindowDecision`:
   - `.managed` — tiled in the layout engine
   - `.floating` — tracked but positioned independently
   - `.unmanaged` — ignored entirely (e.g., system UI, panels)
4. If tracked: `WindowModel` creates an `Entry`, layout engine inserts a node
5. `LayoutRefreshController` schedules a refresh to compute and apply frames

**Destruction:**
1. `CGSEventObserver` receives `.destroyed(windowId, spaceId)`
2. `WindowModel` removes the entry
3. Layout engine removes the node from its tree
4. `LayoutRefreshController` schedules a `windowRemoval` refresh
5. Focus recovery runs if the destroyed window was focused

**Managed Replacement:**
Some apps (Ghostty, Safari, browsers) destroy and recreate windows during internal operations. `AXEventHandler` detects these patterns via `ManagedReplacementMetadata` correlation — matching a destroy+create pair within a 150ms grace period to preserve the window's workspace assignment and position.

### 3.4 The Refresh Pipeline

`LayoutRefreshController` is the central coordination point between events and window frame application. It manages scheduling, debouncing, and coalescing of layout refreshes.

**Five Refresh Routes:**

| Route | When Used | What It Does |
|-------|-----------|--------------|
| `fullRescan` | Startup, app launch/termination, space change, display change | Full window enumeration + relayout |
| `relayout` | Config change, window created, window frame changed | Recompute layout from current state |
| `immediateRelayout` | User commands, gestures, workspace switch | Synchronous immediate layout |
| `visibilityRefresh` | App hidden/unhidden | Show/hide windows, no relayout |
| `windowRemoval` | Window destroyed | Remove from layout + relayout + focus recovery |

**RefreshReason → Route Mapping:**

Each `RefreshReason` maps to a route and a scheduling policy:

```
RefreshReason              → Route              → Scheduling
────────────────────────────────────────────────────────────
.startup                   → fullRescan          → plain
.appLaunched               → fullRescan          → plain
.activeSpaceChanged        → fullRescan          → plain
.layoutCommand             → immediateRelayout   → plain
.interactiveGesture        → immediateRelayout   → plain
.workspaceTransition       → immediateRelayout   → plain
.axWindowCreated           → relayout            → debounced(4ms)
.axWindowChanged           → relayout            → debounced(8ms, dropWhileBusy)
.windowDestroyed           → windowRemoval       → plain
.appHidden / .appUnhidden  → visibilityRefresh   → plain
```

**Coalescing:** If a refresh is already in progress, incoming requests are merged into a `pendingRefresh`. When the active refresh completes, the pending refresh fires. This prevents redundant layout calculations during bursts of events.

**DisplayLink Integration:** When animations are active (spring-based viewport scrolling, workspace switch effects), a `CADisplayLink` per display fires at the native refresh rate, driving per-frame layout recalculation.

### 3.5 Layout Engines as Pure State Machines

Both layout engines follow the same contract:

1. They own their own **tree data structures** (columns/windows for Niri, BSP nodes for Dwindle)
2. They receive workspace geometry and gap configuration as input
3. They produce a `[WindowToken: CGRect]` frame dictionary as output
4. They **never touch windows directly** — no accessibility calls, no frame writes

This separation means layout logic can be unit-tested without any macOS UI or accessibility infrastructure. The `LayoutRefreshController` feeds workspace snapshots to the active engine and collects frame outputs, then `AXManager.applyFramesParallel()` writes the frames to actual windows.

### 3.6 Thread Safety Model

**`@MainActor` everywhere.** Nearly all code in OmniWM runs on the main thread, including:
- All UI code (AppKit, SwiftUI)
- All accessibility API calls
- All layout computation
- All event handling

**Exceptions:**
- **Per-app AX threads**: `AppAXContext` runs a dedicated thread per application for accessibility observer callbacks. These callbacks post back to the main actor.
- **IPC actors**: `IPCApplicationBridge` and `IPCEventBroker` are Swift actors handling concurrent client connections. They dispatch to `@MainActor` for any window management operations.
- **Lock-based Sendable types**: `CGSEventObserver` uses `OSAllocatedUnfairLock` for the pending event buffer that bridges between the SkyLight callback thread and the main thread.

---

## 4. Key Subsystems

### 4.1 WMController — The Orchestrator

**File:** `Sources/OmniWM/Core/Controller/WMController.swift`

`WMController` is the central object that owns or references every major subsystem. It does NOT contain business logic itself — it delegates to specialized handlers.

**Handler constellation** (all lazy-initialized, all hold `weak var controller: WMController?`):

| Handler | Responsibility |
|---------|---------------|
| `commandHandler` | Routes `HotkeyCommand` cases to appropriate handler methods |
| `axEventHandler` | Processes window create/destroy events, manages replacement correlation |
| `mouseEventHandler` | CGEvent tap for mouse events, gestures, focus-follows-mouse |
| `mouseWarpHandler` | Warps cursor to focused window when configured |
| `layoutRefreshController` | Refresh scheduling, DisplayLink animation, frame application |
| `workspaceNavigationHandler` | Workspace switching, window-to-workspace moves |
| `windowActionHandler` | Window close, fullscreen toggle, float toggle |
| `serviceLifecycleManager` | App lifecycle, observer setup, permission polling |
| `borderCoordinator` | Orchestrates border updates after layout/focus changes |
| `focusNotificationDispatcher` | Publishes focus change events to IPC subscribers |

**Core managers** (owned directly):

| Manager | Purpose |
|---------|---------|
| `settings: SettingsStore` | Persisted user configuration |
| `workspaceManager: WorkspaceManager` | Workspace definitions, window tracking, session state |
| `axManager: AXManager` | Per-app accessibility contexts, frame application |
| `focusBridge: FocusBridgeCoordinator` | Focus state machine with retry logic |
| `windowRuleEngine: WindowRuleEngine` | Window rule evaluation |
| `hotkeys: HotkeyCenter` | Global hotkey registration via Carbon |
| `borderManager: BorderManager` | Focus border window management |
| `niriEngine: NiriLayoutEngine?` | Niri layout state (nil if not in use) |
| `dwindleEngine: DwindleLayoutEngine?` | Dwindle layout state (nil if not in use) |
| `animationClock: AnimationClock` | Monotonic time source for animations |

### 4.2 Workspace & Window State

**WorkspaceManager** (`Sources/OmniWM/Core/Workspace/WorkspaceManager.swift`)

Owns workspace definitions, the window model, session state, and monitor tracking.

```
WorkspaceManager
├── monitors: [Monitor]                     Display geometry
├── workspacesById: [ID: WorkspaceDescriptor]   Workspace names & monitor assignments
├── windows: WindowModel                    All tracked windows
├── session: SessionState                   Ephemeral runtime state
│   ├── monitorSessions: [MonitorID: MonitorSession]
│   │   ├── visibleWorkspaceId
│   │   └── previousVisibleWorkspaceId
│   ├── workspaceSessions: [WorkspaceID: WorkspaceSession]
│   │   └── niriViewportState: ViewportState?
│   ├── focus: FocusSession
│   │   ├── focusedToken: WindowToken?
│   │   ├── pendingManagedFocus
│   │   ├── lastTiledFocusedByWorkspace
│   │   ├── lastFloatingFocusedByWorkspace
│   │   ├── isNonManagedFocusActive
│   │   └── isAppFullscreenActive
│   ├── scratchpadToken: WindowToken?
│   └── interactionMonitorId: Monitor.ID?
└── nativeFullscreenRecords                 Fullscreen transition tracking
```

**WindowModel** (`Sources/OmniWM/Core/Workspace/WindowModel.swift`)

The single source of truth for all tracked windows. Each `Entry` contains:

```swift
struct Entry {
    let handle: WindowHandle
    let axRef: AXWindowRef
    var workspaceId: WorkspaceDescriptor.ID
    var mode: TrackedWindowMode          // .tiling or .floating
    var ruleEffects: ManagedWindowRuleEffects
    var floatingState: FloatingState?    // Last frame, normalized position
    var hiddenReason: HiddenReason?      // .workspaceInactive, .layoutTransient, .scratchpad
    var manualLayoutOverride: ManualWindowOverride?
    // ... constraints, parent kind, layout reason
}
```

Entries are indexed by both `WindowToken` and raw `windowId` for fast lookup from different event sources.

### 4.3 Niri Layout Engine (Scrolling Columns)

**Directory:** `Sources/OmniWM/Core/Layout/Niri/`

Niri arranges windows in vertical columns that scroll horizontally, inspired by the [Niri](https://github.com/YaLTeR/niri) Wayland compositor.

**Node Tree:**

```
NiriRoot (per workspace)
├── NiriContainer (column 1)
│   ├── NiriWindow (window A)
│   └── NiriWindow (window B)    ← stacked vertically
├── NiriContainer (column 2)
│   └── NiriWindow (window C)
└── NiriContainer (column 3)     ← can be tabbed
    ├── NiriWindow (window D)    ← active tab
    └── NiriWindow (window E)    ← hidden tab
```

All three types inherit from `NiriNode` (base class with `id: NodeId`, `parent`, `children`, `size`, `frame`).

**Key types:**

| Type | Purpose |
|------|---------|
| `NiriRoot` | Per-workspace container. Owns column list and node index. |
| `NiriContainer` | A column. Has `displayMode` (`.normal` or `.tabbed`), `width: ProportionalSize`, `activeTileIdx`. |
| `NiriWindow` | Leaf node. Has `token: WindowToken`, `height: WeightedSize`, `constraints`. |
| `ProportionalSize` | `.proportion(CGFloat)` or `.fixed(CGFloat)` — column width relative to monitor |
| `WeightedSize` | `.auto(weight:)` or `.fixed(CGFloat)` — window height within column |
| `ViewportState` | Horizontal scroll offset: `.static`, `.gesture(ViewGesture)`, or `.spring(SpringAnimation)` |
| `NodeId` | UUID-based identifier for tree nodes |

**Column width presets** cycle through configurable proportions (default: 1/3, 1/2, 2/3). Full-width mode expands a column to fill the monitor.

**Viewport scrolling:** The viewport tracks which columns are visible. User gestures (trackpad swipe) drive the viewport via `ViewGesture` → `SwipeTracker`, which accumulates deltas and produces spring animations that snap to column boundaries.

**File Organization (28 files):**

The Niri directory is the largest subsystem. Files are organized by responsibility:

| Category | Files | Purpose |
|----------|-------|---------|
| Core engine | `NiriLayoutEngine.swift`, `NiriNode.swift`, `NiriLayout.swift` | Engine class, node tree (Root/Container/Window), pixel-rounding utilities |
| Navigation | `NiriNavigation.swift` | Focus movement between columns and windows |
| Constraint solving | `NiriConstraintSolver.swift` | `NiriAxisSolver` distributes space among windows respecting min/max size constraints |
| Monitor model | `NiriMonitor.swift` | Per-monitor state: geometry, workspace roots, workspace switch animation |
| Viewport | `ViewportState.swift`, `+Animation`, `+ColumnTransitions`, `+Geometry`, `+Gestures` | Horizontal scroll offset, spring physics, gesture tracking |
| Interactive move | `InteractiveMove.swift`, `+InteractiveMove`, `DragGhostController.swift`, `DragGhostWindow.swift`, `SwapTargetOverlay.swift` | Mouse-driven window dragging with ghost thumbnail and swap target indicators |
| Interactive resize | `InteractiveResize.swift`, `+InteractiveResize` | Mouse-driven edge resizing with `ResizeEdge` option set |
| Engine extensions | `+Animation`, `+ColumnOps`, `+Monitors`, `+Sizing`, `+TabbedMode`, `+WindowOps`, `+Windows`, `+WorkspaceOps` | Modular engine operations (see [6.4](#64-modifying-layout-behavior)) |
| UI overlays | `TabbedColumnOverlay.swift` | Visual indicator for tabbed columns |
| Overview bridge | `NiriOverviewSnapshot.swift` | Produces layout snapshots for the Overview renderer |

**Interactive Move/Resize:** Users can drag windows between columns using Option+Shift+click. `InteractiveMove` tracks the drag state (origin column, hover target). `DragGhostController` captures a `ScreenCaptureKit` thumbnail of the dragged window and displays it as a semi-transparent ghost. `SwapTargetOverlay` highlights the drop target. On release, the engine performs a column insertion or window swap. Interactive resize (`InteractiveResize`) allows edge-dragging to change column widths or window heights.

**Constraint Solving:** `NiriAxisSolver` (in `NiriConstraintSolver.swift`) distributes available space among windows in a column while respecting per-window min/max size constraints. Windows with `isConstraintFixed` get exact sizes; remaining space is distributed by weight. This runs during every layout calculation and handles edge cases like tabbed columns (all windows share the same height).

### 4.4 Dwindle Layout Engine (BSP)

**Directory:** `Sources/OmniWM/Core/Layout/Dwindle/`

Dwindle recursively divides screen space using binary splits, similar to bspwm.

**BSP Tree:**

```
DwindleNode (split: horizontal, ratio: 0.5)
├── DwindleNode (leaf: window A)
└── DwindleNode (split: vertical, ratio: 0.5)
    ├── DwindleNode (leaf: window B)
    └── DwindleNode (leaf: window C)
```

**Key types:**

```swift
final class DwindleNode {
    let id: DwindleNodeId          // UUID
    var kind: DwindleNodeKind
    var parent: DwindleNode?
    var children: [DwindleNode]    // 0 (leaf) or 2 (split)
    // Animation properties for smooth transitions
}

enum DwindleNodeKind {
    case split(orientation: DwindleOrientation, ratio: CGFloat)
    case leaf(handle: WindowToken?, fullscreen: Bool)
}

enum DwindleOrientation {
    case horizontal   // Left/right split
    case vertical     // Top/bottom split
}
```

**Smart split** chooses orientation based on the available space dimensions. **Preselection** lets users choose where the next window will be inserted.

### 4.5 Focus Lifecycle

**File:** `Sources/OmniWM/Core/Controller/KeyboardFocusLifecycleCoordinator.swift`

Focus management is complex because OmniWM must coordinate its intent with what macOS actually does. The `FocusBridgeCoordinator` manages this:

**The Deferred Focus Pattern:**

```
1. User presses focus-left
2. CommandHandler identifies target window
3. FocusBridgeCoordinator.beginManagedRequest(token, workspaceId)
   → Creates ManagedFocusRequest with status = .pending
4. Private APIs activate the target app + window
   (_SLPSSetFrontProcessWithOptions, makeKeyWindow)
5. macOS confirms focus via AX callback
6. FocusBridgeCoordinator.confirmManagedRequest(token, source)
   → Marks request as .confirmed
   → If no confirmation within retries, re-attempts activation
```

**Key types:**

| Type | Purpose |
|------|---------|
| `KeyboardFocusTarget` | Resolved focus: `token`, `axRef`, `workspaceId`, `isManaged` |
| `ManagedFocusRequest` | In-flight request with `requestId`, `retryCount`, `status` (`.pending`/`.confirmed`) |
| `ActivationEventSource` | How focus was confirmed: `.focusedWindowChanged` (authoritative), `.workspaceDidActivateApplication`, `.cgsFrontAppChanged` |

**Focus serialization:** `focusWindow(_:performFocus:onDeferredFocus:)` serializes focus operations. If a focus request arrives while one is in-flight, it queues as `pendingFocusToken` and fires after the current request completes or times out.

### 4.6 Input Handling

**Hotkeys** (`Sources/OmniWM/Core/Input/`)

`HotkeyCenter` registers global hotkeys via Carbon's `RegisterEventHotKey` API. Each binding maps a key+modifiers combination to a `HotkeyCommand` enum case. There are 67 commands, each tagged with layout compatibility:

- `.shared` — works with any layout (focus, move, workspace switch, float, scratchpad, UI toggles)
- `.niri` — Niri-only (moveColumn, toggleColumnTabbed, focusPrevious, cycleColumnWidth)
- `.dwindle` — Dwindle-only (moveToRoot, toggleSplit, swapSplit, preselect, resizeInDirection)

**Command routing** (`Sources/OmniWM/Core/Controller/CommandHandler.swift`)

`CommandHandler.performCommand()` is a switch statement over all 67 `HotkeyCommand` cases, delegating to the appropriate handler. It first checks layout compatibility — a Niri command is ignored when Dwindle is active, and vice versa.

**Mouse events** (`Sources/OmniWM/Core/Controller/MouseEventHandler.swift`)

Uses `CGEventTap` for system-wide mouse event interception:
- **Focus-follows-mouse**: Debounced (100ms) focus change on mouse hover
- **Trackpad gestures**: Three-phase state machine (`idle` → `armed` → `committed`) for workspace switching via swipe
- **Interactive move/resize**: Option+Shift+drag for window repositioning
- **Event coalescing**: Transient mouse events are batched and drained in coalesced bursts

**SkyLight events** (`Sources/OmniWM/Core/SkyLight/CGSEventObserver.swift`)

Registers for window server notifications via private APIs:

```swift
enum CGSWindowEvent {
    case created(windowId, spaceId)
    case destroyed(windowId, spaceId)
    case frameChanged(windowId)
    case closed(windowId)
    case frontAppChanged(pid)
    case titleChanged(windowId)
}
```

Events are buffered in a lock-protected `PendingCGSEventState` and drained on the main run loop via `CFRunLoopPerformBlock`. Frame change events are coalesced by windowId.

### 4.7 Window Rules Engine

**File:** `Sources/OmniWM/Core/Rules/WindowRuleEngine.swift`

Evaluates windows against rules to produce a `WindowDecision`. Evaluation order (first match wins):

1. **Manual overrides** — user has explicitly toggled float/tile on this window
2. **User-defined rules** — configured in settings, matching on bundle ID, app name, title (literal or regex), AX role/subrole
3. **Built-in rules** — hardcoded rules for known system UI
4. **Heuristics** — size constraints, window role/subrole analysis

**Key types:**

```swift
struct WindowDecision {
    let disposition: WindowDecisionDisposition  // .managed, .floating, .unmanaged, .undecided
    let source: WindowDecisionSource            // .manualOverride, .userRule(UUID), .builtInRule, .heuristic
    let workspaceName: String?                  // Target workspace (if rule specifies)
    let ruleEffects: ManagedWindowRuleEffects   // minWidth, minHeight constraints
}

struct WindowRuleFacts {
    let appName: String?
    let ax: AXWindowFacts           // role, subrole, title, buttons
    let sizeConstraints: WindowSizeConstraints?
    let windowServer: WindowServerInfo?
}
```

### 4.8 IPC System

For the protocol specification, wire format, and CLI command reference, see [IPC-CLI.md](IPC-CLI.md). This section covers the internal code architecture.

```
omniwmctl                         OmniWM process
─────────                         ──────────────
CLIParser                         IPCServer
    │                                 │
CLIRuntime                        acceptConnections() on DispatchQueue
    │                                 │
IPCClient ──── Unix Socket ────► IPCConnection (per client)
  (NDJSON)                            │
                                 IPCApplicationBridge (actor)
                                      │ auth check, protocol version
                                      │
                              ┌───────┼───────┐
                              │       │       │
                     IPCCommand  IPCQuery  IPCRule
                      Router     Router    Router
                              │       │       │
                              └───────┼───────┘
                                      │  @MainActor
                                      v
                                 CommandHandler /
                                 WorkspaceManager /
                                 WindowRuleEngine
```

**Key actors:**
- `IPCApplicationBridge` — Swift actor that receives deserialized requests, checks authorization, and dispatches to the appropriate router on `@MainActor`
- `IPCEventBroker` — Swift actor managing event subscriptions. Uses `AsyncStream` with continuations per channel per connection. `IPCEventDemandTracker` tracks whether any client is subscribed to a channel (so events aren't computed when nobody is listening)

**Public surface registry:** `IPCAutomationManifest` is the source of truth for public IPC commands, queries, rule actions, subscriptions, and CLI discoverability metadata (including completion/help surfaces). The routers execute the behavior; the manifest defines what is exposed.

**Security:** The trust boundary is the local macOS user account, not individual client processes. Each request carries a per-session authorization token stored in plaintext at `<socket-path>.secret`; the server also enforces socket permissions `0o600`, creates new socket directories with `0o700`, and verifies peer UID via `getpeereid()`. If `OMNIWM_SOCKET` points into an existing directory, OmniWM reuses that directory as-is instead of re-permissioning it, so custom socket paths should live in a private directory owned by the same user.

### 4.9 Accessibility Layer

**File:** `Sources/OmniWM/Core/Ax/AXManager.swift`

**Per-app threading model:** `AXManager` maintains an `AppAXContext` per process. Each context runs an AX observer on a dedicated thread to receive accessibility callbacks (focused-window-changed, window-destroyed).

**Frame application pipeline** (`applyFramesParallel()`):

1. Collect requested frames from the layout engine: `[WindowToken: CGRect]`
2. Deduplicate against `lastAppliedFrames` — skip windows whose frame hasn't changed
3. Group frames by PID into `framesByPidBuffer`
4. Dispatch frame writes to per-app contexts in parallel (each with 0.5s timeout)
5. Each context writes size then position (or vice versa) to the `AXUIElement`
6. Collect `AXFrameWriteResult` with any errors
7. Track `recentFrameWriteFailures` for retry budgeting

**Inactive workspace suppression:** Windows on non-visible workspaces are tracked in `inactiveWorkspaceWindowIds`. Frame writes to these windows are skipped, preventing unnecessary AX API calls and visual glitches.

### 4.10 Animation System

**Directory:** `Sources/OmniWM/Core/Animation/`

**SpringAnimation** — critically-damped spring physics for smooth, responsive motion:

```swift
struct SpringConfig {
    // Presets:
    static let snappy   = SpringConfig(response: 0.22, dampingFraction: 0.95)
    static let balanced = SpringConfig(response: 0.30, dampingFraction: 0.88)
    static let gentle   = SpringConfig(response: 0.45, dampingFraction: 0.78)
    static let reducedMotion = SpringConfig(response: 0.18, dampingFraction: 0.98)
}
```

Used for: viewport scrolling (Niri), workspace switch transitions, window movement animations.

**CubicAnimation** — cubic easing for Dwindle node transitions (position and size).

**AnimationClock** — monotonic time wrapper around `CACurrentMediaTime()`.

**DisplayLink integration:** `LayoutRefreshController` manages a `CADisplayLink` per display. On each frame tick, it recalculates animated layouts and applies frames, producing 60/120Hz smooth animations.

**Accessibility:** All animation configs support `resolvedForReduceMotion()`, which returns the `reducedMotion` preset when the user has enabled "Reduce Motion" in macOS accessibility settings.

### 4.11 Border System

**Files:** `Sources/OmniWM/Core/Border/BorderManager.swift`, `BorderWindow.swift`

A lightweight `NSWindow` overlay that draws a rounded rectangle around the focused window:

- `BorderManager` tracks the current focused window's frame and windowId
- `BorderWindow` renders the border using SkyLight private APIs for window ordering (stays above managed windows but below floating panels)
- Deduplication: skips updates if windowId and frame haven't changed (0.5pt tolerance)
- Configurable: enable/disable, width (points), color (RGBA)

### 4.12 Additional Features

| Feature | Key Files | Description |
|---------|-----------|-------------|
| **Overview** | `Core/Overview/OverviewController.swift` | Bird's-eye view of all workspaces with window thumbnails (ScreenCaptureKit), search, drag-to-reorganize |
| **Quake Terminal** | `QuakeTerminal/QuakeTerminalController.swift` | Drop-down terminal using GhosttyKit. Supports tabs and split panes. Toggles with hotkey. |
| **Command Palette** | `UI/CommandPalette/CommandPaletteController.swift` | Fuzzy-search interface for windows, commands, and menu items |
| **Menu Anywhere** | `UI/MenuAnywhere/MenuAnywhereController.swift` | UI controller that uses the Core menu extraction layer to display any app's menu at cursor position |
| **Workspace Bar** | `UI/WorkspaceBar/WorkspaceBarManager.swift` | Visual workspace indicators with window icons per workspace |
| **Hidden Bar** | `UI/HiddenBar/HiddenBarController.swift` | Collapsible menu bar icon management |
| **Scratchpad** | `Core/Workspace/WorkspaceManager.swift` | Tracks the transient scratchpad window via `scratchpadToken()`. Show/hide and focus recovery are coordinated by `WMController`. |
| **Status Bar** | `UI/StatusBar/StatusBarController.swift` | Menu bar icon with settings access, manual update checks, and workspace summary |
| **Release Updater** | `App/UpdateCoordinator.swift`, `UI/UpdateWindowController.swift` | Polls the latest GitHub release once per day on launch, supports manual checks from Settings and the status bar, and shows a manual-action popup with release notes |

OmniWM utility windows such as Settings, App Rules, Sponsors, and the updater popup register with `OwnedWindowRegistry`. That lets focus, hit-testing, and recovery code treat OmniWM-owned UI differently from external app windows.

---

## 5. Data Flow Diagrams

### 5.1 Hotkey Command Flow

User presses a hotkey (e.g., Option+Left to focus left):

```
Carbon EventHandler callback
    │
    v
HotkeyCenter.dispatch(id)
    │ lookup HotkeyCommand by registration ID
    v
CommandHandler.handleCommand(.focus(.left))
    │ check: isEnabled? layout compatible? overview open?
    v
layoutHandler(as: LayoutFocusable.self)?.focusNeighbor(direction: .left)
    │ e.g., NiriLayoutHandler.focusNeighbor()
    │ determines target window in the Niri tree
    v
FocusBridgeCoordinator.focusWindow(targetToken)
    │ activates app + window via private APIs
    v
LayoutRefreshController.scheduleRefresh(.immediateRelayout, reason: .layoutCommand)
    │
    v
NiriLayoutEngine.calculateLayout(...)
    │ produces [WindowToken: CGRect]
    v
AXManager.applyFramesParallel(frames)
    │ writes new positions to windows
    v
BorderCoordinator.updateBorder(for: targetToken)
    │ moves border to newly focused window
    v
FocusNotificationDispatcher.publish(focusEvent)
    │ notifies IPC subscribers
    v
Done
```

### 5.2 External Window Event Flow

An application opens a new window:

```
macOS window server creates window
    │
    v
CGSEventObserver receives .created(windowId, spaceId)
    │ buffered in PendingCGSEventState (lock-protected)
    │ drained via CFRunLoopPerformBlock on main thread
    v
AXEventHandler.handleWindowCreated(windowId)
    │ creates AXWindowRef from AXUIElement
    │ queries: role, subrole, title, buttons, size
    v
WindowRuleEngine.evaluate(facts)
    │ returns WindowDecision (.managed / .floating / .unmanaged)
    v
WindowModel.track(handle, axRef, workspaceId, mode)
    │ creates Entry, indexes by token and windowId
    v
NiriLayoutEngine.insertWindow(token, into: workspaceRoot)
    │ creates NiriWindow node, appends to active column or new column
    v
LayoutRefreshController.scheduleRefresh(.relayout, reason: .axWindowCreated)
    │ debounced: 4ms
    v
Layout calculation → AXManager.applyFramesParallel()
    │
    v
All windows repositioned to accommodate the new one
```

### 5.3 IPC Command Flow

User runs `omniwmctl command focus left`:

```
CLIParser.parse(["command", "focus", "left"])
    │ produces IPCRequest { kind: .command, payload: .command(.focus(direction: .left)) }
    v
IPCClient connects to Unix socket (~/.../ipc.sock)
    │ sends NDJSON: {"version":3,"id":"...","kind":"command","authorizationToken":"...","payload":{"name":"focus","arguments":{"direction":"left"}}}\n
    v
IPCServer accepts connection → IPCConnection reads line
    │ deserializes to IPCRequest
    v
IPCApplicationBridge.response(request) [actor]
    │ verifies authorization token
    │ checks protocol version
    v
IPCCommandRouter.handle(.focus(direction: .left)) [@MainActor]
    │ maps to HotkeyCommand.focus(.left)
    v
CommandHandler.performCommand(.focus(.left))
    │ (same flow as hotkey from here — see 5.1)
    │ returns ExternalCommandResult
    v
IPCResponse { ok: true } → serialized as NDJSON → sent to client
    v
CLIRenderer displays result
```

---

## 6. Common Contribution Patterns

### 6.1 Adding a New Hotkey Command

1. **Add the enum case** in `Sources/OmniWM/Core/Input/HotkeyCommand.swift`:
   ```swift
   case myNewCommand
   ```
   Set `layoutCompatibility` (`.shared`, `.niri`, or `.dwindle`).

2. **Handle it** in `Sources/OmniWM/Core/Controller/CommandHandler.swift`:
   ```swift
   case .myNewCommand:
       // implementation or delegation to a handler
   ```

3. **Add a default binding** (optional) in `Sources/OmniWM/Core/Input/DefaultHotkeyBindings.swift`.

4. **Expose via IPC** in `Sources/OmniWM/IPC/IPCCommandRouter.swift` — add the string mapping.

5. **Add CLI support** in `Sources/OmniWMCtl/CLIParser.swift` — add the command name.

6. **Update the automation manifest** in `Sources/OmniWMIPC/IPCAutomationManifest.swift` — add the command description.

### 6.2 Adding a New IPC Query

1. **Define the response model** in `Sources/OmniWMIPC/IPCModels.swift`.

2. **Implement the query** in `Sources/OmniWM/IPC/IPCQueryRouter.swift`:
   ```swift
   case "my-query":
       let result = // gather data from WorkspaceManager, etc.
       return .success(result)
   ```

3. **Add CLI rendering** in `Sources/OmniWMCtl/CLIRenderer.swift` — format the response for terminal output.

4. **Add CLI parsing** in `Sources/OmniWMCtl/CLIParser.swift` — add the query name.

5. **Update the manifest** in `Sources/OmniWMIPC/IPCAutomationManifest.swift`.

### 6.3 Adding a New Setting

1. **Add the property** to `Sources/OmniWM/Core/Config/SettingsStore.swift` with a UserDefaults key.

2. **Wire the runtime behavior** in `WMController.applyPersistedSettings()` or the relevant handler that consumes the setting.

3. **Add UI** in the appropriate settings tab under `Sources/OmniWM/UI/`.

4. **Update config export/import** in `Sources/OmniWM/Core/Config/SettingsExport.swift` for persisted user preferences that belong in editable config so full export, compact backup, and import all round-trip correctly. Do not export remote payloads or operational cache state such as updater release notes, release URLs, last-check timestamps, or skipped-release markers.

5. **Check config-file touchpoints** when the change affects config discoverability or UX. `Sources/OmniWM/UI/ConfigFileWorkflow.swift` is the generic workflow layer, and the `Config File` section in `Sources/OmniWM/UI/SettingsView.swift` is the main user-facing entry point; most new settings do not need workflow code changes, but contributor-facing config behavior and copy should remain accurate.

6. **Handle migration** if needed in `Sources/OmniWM/Core/Config/SettingsMigration.swift`.

7. **Add round-trip coverage** in tests: verify the setting survives store load/save and config export/import so it cannot silently disappear from `~/.config/omniwm/settings.json`.

### 6.4 Modifying Layout Behavior

1. **Identify the engine**: Niri code is in `Sources/OmniWM/Core/Layout/Niri/`, Dwindle in `Sources/OmniWM/Core/Layout/Dwindle/`.

2. **Find the relevant extension**: Niri splits logic across extensions:
   - `NiriLayoutEngine+Animation.swift` — animation tick and spring updates
   - `NiriLayoutEngine+ColumnOps.swift` — column add/remove/reorder
   - `NiriLayoutEngine+InteractiveMove.swift` — mouse-driven window moving
   - `NiriLayoutEngine+InteractiveResize.swift` — mouse-driven edge resizing
   - `NiriLayoutEngine+Monitors.swift` — multi-monitor layout
   - `NiriLayoutEngine+Sizing.swift` — width/height calculation
   - `NiriLayoutEngine+TabbedMode.swift` — tabbed column logic
   - `NiriLayoutEngine+WindowOps.swift` — window insert/remove/reorder
   - `NiriLayoutEngine+Windows.swift` — window query and lookup
   - `NiriLayoutEngine+WorkspaceOps.swift` — workspace-level operations

   Focus navigation lives in `NiriNavigation.swift`. Constraint solving lives in `NiriConstraintSolver.swift`.

3. **Write tests** using existing helpers. Layout engines can be tested in isolation — create nodes, call `calculateLayout()`, assert frame positions.

### 6.5 Working with Private APIs

OmniWM uses SkyLight (private macOS framework) for low-latency window operations. The wrapper pattern is:

1. **Function declarations** use `@_silgen_name` in `Sources/OmniWM/Core/PrivateAPIs.swift`
2. **Dynamic loading** via `dlopen`/`dlsym` in `Sources/OmniWM/Core/SkyLight/SkyLight.swift` for functions that can't use `@_silgen_name`
3. All private API usage is wrapped in safe Swift functions with fallback behavior

**Risk model:** Private APIs can break across macOS versions. When adding new private API usage, provide a fallback path using public APIs where possible, and test across macOS versions.

---

## 7. Testing

**Runner:** `swift test` via SwiftPM. Requires macOS 15+.

**Test directory:** `Tests/OmniWMTests/` (55 files: 52 test files + 3 support files)

**Test patterns:**

| Pattern | Used For | Example |
|---------|----------|---------|
| Direct unit tests | Layout engines, animation math, rule evaluation | Create nodes, call `calculateLayout()`, assert frames |
| DI via closures | Controllers, handlers | `nativeFullscreenStateProvider`, `frameApplyOverrideForTests` |
| Debug hooks | Refresh pipeline | `RefreshDebugHooks.onFullRescan`, `onRelayout` |
| In-process IPC | IPC protocol, routing | Create socket pair, send/receive in-process |

**Key test support files:**
- `TestSharedStateSupport.swift` — shared test fixtures
- `TokenCompatibilityTestSupport.swift` — window token creation helpers
- `LayoutPlanTestSupport.swift` — layout test utilities

**What's hard to test:** Anything requiring live accessibility permissions or actual window manipulation. These are covered by the override/hook pattern — production code checks for test overrides (closures/hooks) and uses them instead of real system calls.

---

## 8. Glossary

| Term | Definition |
|------|-----------|
| `WindowToken` | Value type (`pid` + `windowId`) identifying a window. Used as dictionary keys throughout. |
| `WindowHandle` | Reference-type wrapper around `WindowToken`. Identity-compared (`===`). Used in layout trees. |
| `AXWindowRef` | Accessibility bridge (`AXUIElement` + `windowId`) for reading/writing window properties. |
| `TrackedWindowMode` | `.tiling` or `.floating` — whether a window is managed by the layout engine. |
| `WorkspaceDescriptor` | A workspace definition: `id` (UUID), `name`, optional `assignedMonitorPoint`. |
| `SessionState` | Ephemeral runtime state in `WorkspaceManager`: focused window, visible workspace per monitor, viewport states. |
| `NiriRoot` / `NiriContainer` / `NiriWindow` | The three-level Niri layout tree: root → columns → windows. |
| `DwindleNode` | BSP tree node. Kind is either `.split(orientation, ratio)` or `.leaf(handle, fullscreen)`. |
| `ViewportState` | Niri's horizontal scroll state: `.static`, `.gesture`, or `.spring`. |
| `LayoutRefreshController` | Central refresh coordinator. Schedules, debounces, and coalesces layout recalculations. |
| `RefreshReason` | Why a refresh was requested (e.g., `.axWindowCreated`, `.layoutCommand`). Maps to a refresh route. |
| `RefreshRoute` | How the refresh executes: `fullRescan`, `relayout`, `immediateRelayout`, `visibilityRefresh`, `windowRemoval`. |
| `ManagedFocusRequest` | In-flight focus request with status (`.pending`/`.confirmed`) and retry tracking. |
| `FocusBridgeCoordinator` | Focus state machine coordinating OmniWM's focus intent with macOS confirmation. |
| `CGSEventObserver` | SkyLight event listener for window create/destroy/frame-change/front-app-change. |
| `HotkeyCommand` | Enum of all 67 commands that can be triggered by hotkeys or IPC. |
| `IPCApplicationBridge` | Swift actor routing IPC requests to `@MainActor` command/query/rule handlers. |
| `IPCEventBroker` | Swift actor managing real-time event subscriptions for IPC clients. |
| `ProportionalSize` | `.proportion(CGFloat)` or `.fixed(CGFloat)` — Niri column width specification. |
| `WeightedSize` | `.auto(weight:)` or `.fixed(CGFloat)` — Niri window height within a column. |
| `NodeId` | UUID-based identifier for Niri layout tree nodes. |
| `SpringConfig` | Animation parameters: `response`, `dampingFraction`. Presets: `.snappy`, `.balanced`, `.gentle`. |
| `WindowDecision` | Result of rule evaluation: `disposition`, `source`, `workspaceName`, `ruleEffects`. |
| `WindowRuleFacts` | Input for rule evaluation: app name, AX facts (role, subrole, title), size constraints. |
| `LayoutType` | `.defaultLayout`, `.niri`, or `.dwindle` — per-workspace layout selection. |
| `Scratchpad` | A special slot for a single transient window that can be toggled in/out of view. |

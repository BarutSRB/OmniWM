# AGENTS.md — Core/Layout/Niri

## Purpose

Scrolling columns layout engine. Implements a Niri-inspired tiling layout where windows are organized in columns that scroll horizontally within a viewport.

## Critical Rule

**This is a pure state machine.** Layout engines never touch windows directly — no accessibility calls, no frame writes. Input: workspace geometry + window tokens. Output: `[WindowToken: CGRect]`.

## File Organization (30 files)

### Core Engine
- `NiriLayoutEngine.swift` — Main engine: column management, focus, viewport
- `NiriLayout.swift` (950 lines) — Frame calculation, container visibility, pixel rounding
- `NiriNode.swift` (912 lines) — Data structures: ProportionalSize, SizingMode, ColumnDisplay, node tree

### Operations (Extensions)
- `NiriLayoutEngine+ColumnOps.swift` — Column transfers, insertion, width state copying
- `NiriLayoutEngine+Sizing.swift` — Column width resolution, preset cycling, height adjustments
- `NiriLayoutEngine+Focus.swift` — Focus navigation within/across columns
- `NiriLayoutEngine+Movement.swift` — Window/column movement operations
- `NiriLayoutEngine+Insertion.swift` — Window admission into layout

### State
- `ViewportState.swift` — Per-workspace scroll position, zoom, tab state
- `NiriMonitor.swift` — Monitor-specific Niri configuration
- `NiriConstraintSolver.swift` — Column width constraint resolution

### Interaction
- `InteractiveMove.swift` — Drag-to-move gesture handling
- `InteractiveResize.swift` — Drag-to-resize gesture handling
- `TabbedColumnOverlay.swift` — Tabbed column UI rendering

### Configuration
- `NiriPresetWidth.swift` — Width preset definitions
- `NiriGapCalculator.swift` — Gap/padding computation

## Key Abstractions

- **Column**: Vertical stack of windows with a proportional width
- **ViewportState**: Scroll offset + focused column index per workspace
- **NiriNode**: Tree structure representing column → window hierarchy
- **ProportionalSize**: Relative sizing (fraction of available space)
- **SizingMode**: How column width is determined (preset, proportional, fixed)

## Conventions

- Extension files use `+OperationCategory` naming
- All operations return new state (functional style within the engine)
- Column indices are 0-based
- Window positions are in workspace-local coordinates (viewport handles scroll offset)
- Pixel rounding applied at final frame calculation to prevent subpixel gaps

## Adding New Operations

1. Add method to appropriate extension file (or create new `+Category.swift`)
2. Expose via `LayoutCapabilities` protocol if it should work across engines
3. Wire through `NiriLayoutHandler` in the Controller layer
4. Add test in `Tests/OmniWMTests/` with factory helpers from `LayoutPlanTestSupport.swift`

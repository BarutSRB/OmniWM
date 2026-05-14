# AGENTS.md — OmniWM

## Project Identity

OmniWM is a native macOS tiling window manager written in Swift 6.2 with strict concurrency. It targets macOS 15+ (Sequoia) on arm64 and x86_64.

## Architecture Overview

Event-driven reconciliation pattern (Redux/Elm-like):

```
Input (Hotkeys, AX, Mouse, CGS) → WMEvent → Reconcile (Planner → StateReducer → ActionPlan) → State (WorkspaceManager) → Layout Engine (Niri/Dwindle) → Rendering (AXManager, BorderManager, Animation)
```

- **WMController** is the central orchestrator holding all handlers and managers.
- Layout engines are **pure state machines** — they never touch windows directly.
- @MainActor enforces thread safety for all UI/state code.

## SwiftPM Targets

| Target | Type | Purpose |
|--------|------|---------|
| `OmniWMIPC` | Library | Shared IPC protocol models (public, zero deps) |
| `OmniWM` | Library | Core window manager logic + UI |
| `OmniWMApp` | Executable | App entry point (@main SwiftUI App) |
| `OmniWMCtl` | Executable | CLI tool (`omniwmctl`) |

## Build & Verification

```zsh
make format       # SwiftFormat 0.61.1
make lint         # SwiftLint 0.63.2
make build        # ghostty-preflight + swift build
make test         # swift test
make verify       # format-check + lint + no-zig-audit + build + test
```

Tool versions are **pinned** — build fails on mismatch.

### Ghostty Dependency

`GhosttyKit.xcframework` is a pre-built binary. `Scripts/ghostty-preflight.sh` validates architecture (universal) and SHA256 before every build.

### Zig Audit

`Scripts/audit-no-zig.sh` prevents Zig/kernel code contamination in Swift-only branches. Part of `make verify`.

## Code Style

### Formatting (SwiftFormat)
- Swift 6.2, indent 4, max width 120
- Arguments/parameters wrap `before-first`
- Imports sorted alphabetically (no semantic grouping)
- `--header strip` (no file headers)
- `--disable all` then selectively enables 24 rules

### Linting (SwiftLint)
- SwiftLint owns diagnostics; SwiftFormat owns visual formatting
- All formatting-related SwiftLint rules disabled to avoid conflicts
- Limits: `cyclomatic_complexity` 10, `function_body_length` 50, `file_length` 500, `type_body_length` 300, `function_parameter_count` 5
- Identifier names: min 2, max 60; excluded: `id`, `x`, `y`, `i`, `j`
- Opt-in concurrency rules: `async_without_await`, `incompatible_concurrency_annotation`

### Naming
- Variables/properties: `camelCase`
- Types/protocols: `PascalCase`
- Enum cases: `lowerCamelCase`
- Files: `PascalCase` + semantic role (e.g., `BorderManager.swift`, `NiriLayoutEngine+ColumnOps.swift`)

## Concurrency Model

- **@MainActor** on all state-holding types (WMController, SettingsStore, WorkspaceManager, etc.)
- **Actors** for IPC (IPCConnection, IPCApplicationBridge, IPCConnectionRegistry)
- **ThreadGuardedValue** for cross-thread AX callback data
- All public models must conform to `Sendable`
- Swift 6 strict concurrency mode enabled

## Critical Constraints

- Layout engines **never touch windows directly** — pure geometry computation only
- **Never** require SIP disable
- **Never** suppress type errors with `as any` / `@ts-ignore` equivalents
- **Do not** persist remote/operational state in settings.toml (only user preferences)
- Settings export must not include updater cache, release notes, or timestamps

## Dependency Injection

Constructor injection + lazy initialization in WMController. No DI container. Tests use closure-based factories (`ipcServerFactoryForTests`, `updateCoordinatorFactoryForTests`).

## IPC Protocol

Unix domain socket at `~/Library/Caches/com.barut.OmniWM/ipc.sock`. NDJSON wire format, token-based auth, protocol version 4. See `Sources/OmniWMIPC/AGENTS.md`.

## Testing

Apple's native `Testing` framework (not XCTest). `@Suite @MainActor struct`. Factory functions for test state. See `Tests/OmniWMTests/AGENTS.md`.

## Subdirectory Guides

- `Sources/OmniWM/Core/AGENTS.md` — Core architecture
- `Sources/OmniWM/Core/Layout/Niri/AGENTS.md` — Niri layout engine
- `Sources/OmniWM/Core/Controller/AGENTS.md` — Controller layer
- `Sources/OmniWM/Core/Reconcile/AGENTS.md` — Reconciliation engine
- `Sources/OmniWMIPC/AGENTS.md` — IPC protocol
- `Tests/OmniWMTests/AGENTS.md` — Testing conventions

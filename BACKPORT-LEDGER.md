# Swift-Only Backport Ledger

Base: `6fde9b910a6dd531eeaf3892499729120ae75f49`
Source head: `ea732a35960ab2a899ecef393a37582d103d093e`
Source range: `6fde9b9..ea732a35960ab2a899ecef393a37582d103d093e`

This branch is a selective Swift-only backport. It must not import Zig source,
`COmniWMKernels`, Zig build plumbing, kernel ABI tests, or current-main kernel
adapter code.

## Prerequisites

- Create this work in an isolated worktree rooted at the base commit.
- Keep `Frameworks/GhosttyKit.xcframework/macos-arm64_x86_64/libghostty.a`
  available locally.
- `Scripts/ghostty-preflight.sh verify` must pass before `make build`,
  `make test`, or `make verify`.

## Buckets

- `direct-dry-run`: eligible for `merge-tree`/`cherry-pick --no-commit`, then audit.
- `swift-contextual`: Swift-only file list, but likely needs semantic review.
- `settings-final-state`: manual TOML/config port, not a JSON-then-TOML cherry-pick.
- `mixed-investigate-only`: only write a targeted Swift-native patch if the bug reproduces.
- `zig-build-skip`: Zig/kernel/build surface; skip.
- `merge-release-doc-skip`: merge, release, or nonessential docs/media churn.

## Record Template

```text
Commit:
Original subject:
Touched Swift files:
Touched Zig/build files:
Bug reproducible on 6fde9b9? yes/no/unknown
Tests added or updated:
Action: direct-dry-run / swift-contextual / settings-final-state / mixed-investigate-only / zig-build-skip / merge-release-doc-skip
Reason:
Backport commit:
```

## Records

Records are added as commits are accepted, skipped, or manually translated.

### `6b39ba9e95006860ec0b5b855bb46c90fc251872`

```text
Commit: 6b39ba9e95006860ec0b5b855bb46c90fc251872
Original subject: Fix cross-workspace hidden window reveals
Touched Swift files:
- Sources/OmniWM/Core/Controller/LayoutRefreshController.swift
- Tests/OmniWMTests/AXEventHandlerTests.swift
- Tests/OmniWMTests/LayoutRefreshControllerTests.swift
- Tests/OmniWMTests/RefreshRoutingTests.swift
Touched Zig/build files: none
Bug reproducible on 6fde9b9? unknown; source commit adds focused regression coverage for the reveal behavior
Tests added or updated:
- AXEventHandlerTests
- LayoutRefreshControllerTests
- RefreshRoutingTests
Action: direct-dry-run
Reason: Applies without manual edits, touches only Swift/test files, and passes the staged no-Zig audit.
Backport commit: this commit
```

### `5475c44a32e899beacdd97d150af389dd7e2cbc1`

```text
Commit: 5475c44a32e899beacdd97d150af389dd7e2cbc1
Original subject: Fix quake terminal focus restoration
Touched Swift files:
- Sources/OmniWM/Core/Controller/WMController.swift
- Sources/OmniWM/QuakeTerminal/QuakeTerminalController.swift
- Tests/OmniWMTests/QuakeTerminalControllerTests.swift
- Tests/OmniWMTests/WMControllerFocusTests.swift
Touched Zig/build files: none
Bug reproducible on 6fde9b9? unknown; source commit adds focused regression coverage for Quake restore targets
Tests added or updated:
- QuakeTerminalControllerTests
- WMControllerFocusTests
Action: direct-dry-run
Reason: Cherry-pick applies without manual edits, touches only Swift/test files, and passes the staged no-Zig audit.
Backport commit: this commit
```

### `8a48b368e79c2366da692e6a2d2517f81dd39026`

```text
Commit: 8a48b368e79c2366da692e6a2d2517f81dd39026
Original subject: Fix Emacs full-rescan eviction
Touched Swift files:
- Sources/OmniWM/Core/Ax/AXWindow.swift
- Sources/OmniWM/Core/Ax/AppAXContext.swift
- Tests/OmniWMTests/AXWindowServiceTests.swift
- Tests/OmniWMTests/RefreshRoutingTests.swift
Touched Zig/build files: none
Bug reproducible on 6fde9b9? unknown; source commit adds focused regression coverage for top-level AX window admission
Tests added or updated:
- AXWindowServiceTests
- RefreshRoutingTests
Action: direct-dry-run
Reason: Cherry-pick applies without manual edits, touches only Swift/test files, and passes the staged no-Zig audit.
Backport commit: this commit
```

### `349247c73bf3f5b1cd84fab5cde8baa25fdb7651`

```text
Commit: 349247c73bf3f5b1cd84fab5cde8baa25fdb7651
Original subject: Apply global Niri settings without restart
Touched Swift files:
- Sources/OmniWM/Core/Controller/NiriLayoutHandler.swift
- Sources/OmniWM/Core/Controller/WMController.swift
- Tests/OmniWMTests/NiriLayoutEngineTests.swift
Touched Zig/build files: none
Bug reproducible on 6fde9b9? unknown; source commit adds focused regression coverage for live Niri settings updates
Tests added or updated:
- NiriLayoutEngineTests
Action: direct-dry-run
Reason: Cherry-pick applies without manual edits, touches only Swift/test files, and passes the staged no-Zig audit.
Backport commit: this commit
```

### `de13d4ccdb0aa683c79fe2fb4badec96bf362a80`

```text
Commit: de13d4ccdb0aa683c79fe2fb4badec96bf362a80
Original subject: Fix command hotkey capture on non-QWERTY keyboards
Touched Swift files:
- Sources/OmniWM/UI/KeyRecorderView.swift
- Tests/OmniWMTests/KeyRecorderViewTests.swift
Touched Zig/build files: none
Bug reproducible on 6fde9b9? unknown; source commit adds focused regression coverage for non-QWERTY capture
Tests added or updated:
- KeyRecorderViewTests
Action: direct-dry-run
Reason: Clean dry-run and cherry-pick, touches only Swift/test files, and passes the staged no-Zig audit.
Backport commit: this commit
```

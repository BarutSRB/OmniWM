# AGENTS.md — Tests/OmniWMTests

## Framework

Apple's native `Testing` framework (Swift 5.9+). **Not XCTest.**

```swift
import Testing
@testable import OmniWM

@Suite @MainActor struct MyFeatureTests {
    @Test func behaviorDescription() {
        #expect(result == expected)
    }
}
```

## Conventions

### File Naming
- Test files: `{Feature}Tests.swift`
- Support files: `{Domain}TestSupport.swift`

### Structure
- All test structs are `@MainActor` (required for WM state access)
- Use `#expect()` macro for assertions
- Use `Issue.record()` for non-fatal failures
- No XCTest, no XCTAssert

### Test Isolation
- Each test gets isolated `UserDefaults` via UUID-based suite names
- `resetSharedControllerStateForTests()` resets global singletons
- Synthetic display IDs avoid collision with real displays

## Support Infrastructure

### Factory Functions (LayoutPlanTestSupport.swift)
```swift
func makeLayoutPlanTestMonitor(displayId:, name:, x:, y:, width:, height:) -> Monitor
func makeLayoutPlanTestWindow(windowId:) -> AXWindowRef
func makeLayoutPlanTestController(monitors:, workspaceConfigurations:) -> WMController
```

### State Helpers (TestSharedStateSupport.swift)
- `configurationDirectoryForTests()` — Temp per-test config dir
- `runtimeStateStoreForTests()` — Isolated RuntimeStateStore
- `installSynchronousFrameApplySuccessOverride()` — Mock AX frame application

### Motion Helpers (MotionTestSupport.swift)
- Convenience wrappers that inject `.motion = .enabled` for animation tests

### Async Utilities
- `waitForLayoutPlanRefreshWork()` — Waits for layout refresh cycle
- `waitForConditionForTests(timeout:condition:)` — Polling wait

## Fixtures

Located in `Fixtures/` (processed as SwiftPM resources):
- `canonical-settings.toml` (829 lines) — Complete reference settings file for codec testing

## Dependencies

Test target imports: `OmniWM`, `OmniWMIPC`, `OmniWMCtl` (all `@testable`)

## Writing New Tests

1. Create `{Feature}Tests.swift`
2. Use `@Suite @MainActor struct`
3. Use factory functions from support files for state setup
4. Call `resetSharedControllerStateForTests()` if touching global state
5. Prefer `#expect()` over complex assertion helpers
6. For layout tests, use `makeLayoutPlanTestController` + `waitForLayoutPlanRefreshWork()`

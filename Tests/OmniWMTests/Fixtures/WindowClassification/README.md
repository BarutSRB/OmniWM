# Window classification fixtures

Each `*.json` file is a `WindowClassificationRegressionFixture`.
`WindowClassificationRegressionTests` feeds `observation.input` through
`WindowClassificationReproducer.recompute` and asserts the result matches the independently
authored `expectedDecision`. The captured `observedDecision` is evidence only and never defines
correct behavior.

## Adding a fixture

1. Find the relevant `WindowClassificationObservation` in the submitted runtime trace.
2. Add it as the fixture's `observation` with a descriptive filename (`<app>-<case>.json`).
3. Independently determine the correct behavior and author `expectedDecision`; do not copy it
   from `observedDecision` without reviewing the reported problem.
4. Run `swift test --filter WindowClassificationRegressionTests`.

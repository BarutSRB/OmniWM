# Contributing

Thanks for wanting to help with OmniWM.

Bug fixes, documentation improvements, performance work, focused cleanups, features, and thoughtful ideas are all welcome.

## What Makes a Good Contribution

- Fix bugs or regressions
- Improve documentation or onboarding
- Add useful features or workflow improvements
- Improve performance or reduce latency
- Clean up code when it clearly improves maintainability
- Share demos, examples, or tutorials

## Project Direction

- Refactors are fine when they solve a real problem, but they should come with a detailed reason. Explain what is not working well today, why the refactor is needed, and what it improves.
- Low-level rewrites in **C** or **Zig** are **very welcome** when there is a strong technical reason they fit the problem better, especially for macOS specific or performance sensitive work.
- Otherwise, please keep contributions in Swift so the codebase stays cohesive.
- Rust rewrites are not a project direction for OmniWM. For this project on macOS, C or Zig is a better fit when Swift is not the right tool.

## Before Opening a Pull Request

- For larger changes, open an issue or start a discussion first so we can align on direction.
- Keep changes focused. Smaller, well-explained pull requests are much easier to review and merge.
- If your change affects behavior, config, tests, docs, or CLI output, call that out clearly in the pull request description.

## Pull Request Expectations

- Explain the problem you are solving and why this approach makes sense.
- Include testing notes **if possible**. Mention what you ran, checked, or verified.
- Add screenshots, recordings, or CLI examples when they help explain the change.
- Update documentation when behavior, workflows, or interfaces change.
- Run `make verify` before opening a pull request.
- When touching `Zig/omniwm_kernels`, run `make kernels-test`.

## Basic Workflow

1. Fork the repository.
2. Create a branch for your change.
3. Use `make build` while iterating on local changes.
4. Use `make test` to run the Swift test suite against the pinned Zig and Ghostty build inputs.
5. Use `make release-check` before packaging or release-oriented work.
6. Run `make kernels-test` when your change touches the kernel library.
7. Open a pull request with clear context, reasoning, and the commands you ran.

## Questions and Ideas

If you are unsure about something, open an issue or ask in the pull request. Thoughtful questions are always welcome.

Thanks again for helping improve OmniWM.

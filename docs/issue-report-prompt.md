# Improving the AI issue-report prompt

OmniWM's **Report Issue** flow (Settings → Report Issue) can rewrite a user's rough bug
report into a clean, structured GitHub issue. The rewrite runs on-device through Apple
Intelligence (with Apple Intelligence enabled); without it, a deterministic fallback
formats the report without AI.

The instructions that steer that model — the prompt — live in plain Markdown so you can
improve them without touching Swift.

## Files you edit

- `Sources/OmniWM/Core/IssueReporter/Prompts/issue-rewrite-prompt.md` — the main
  instructions that turn the rough report into the structured issue.
- `Sources/OmniWM/Core/IssueReporter/Prompts/issue-hotkey-context-preamble.md` — extra
  instructions used **only** when the user mentions a keyboard shortcut.

Each file's raw text is sent to the model verbatim. Write plain prose, no front-matter or
YAML, and wrap lines however you like — line wrapping inside a paragraph does not change
the result. Do **not** put editing notes inside these files; they would be sent to the
model. Put notes in this guide instead.

## Constraints you must preserve

- **Only stated facts.** The model must use only what the user wrote and never invent an
  app version, settings, logs, steps, or expected behavior.
- **Keep the exact phrase `Not provided`.** It's the literal value the app writes for any
  section the user didn't supply — don't reword it.
- **Keep reproduction steps numbered.**
- **Don't rename the five sections.** The output is parsed into **Summary**, **Steps to
  Reproduce**, **Expected Behavior**, **Actual Behavior**, and **Additional Context**.
  These names are tied to code (`GeneratedIssue` and `IssueTemplate.assemble` in
  `Sources/OmniWM/Core/IssueReporter/`); renaming a section requires a matching code
  change, so leave the section names alone unless you're also editing the Swift.
- **The hotkey preamble is conditional.** The live `KNOWN SHORTCUTS` list is built from
  the user's current config and appended by the app at runtime — don't hardcode specific
  shortcuts in the file.

## Model limits to keep in mind

The rewrite runs on Apple's small on-device foundation model
(`LanguageModelSession` in `Sources/OmniWM/Core/IssueReporter/FoundationModelsIssueEngine.swift`),
which has a **fixed 4096-token context window**. That budget is shared across *everything*
in one request: your prompt instructions, the conditional hotkey preamble plus the
runtime-resolved `KNOWN SHORTCUTS` list, the user's message, and the model's generated
issue. If the total exceeds 4096 tokens the framework throws `.exceededContextWindowSize`,
the rewrite fails, and the app falls back to the deterministic (no-AI) formatter.

- **Every word you add to the prompt files is permanent overhead** — it subtracts from the
  room left for the user's report and the generated output on every single request. Keep
  the instructions tight.
- **Write for a small model.** Plain, direct, imperative prose works best; long explanations
  or clever phrasing waste budget and reduce reliability.
- **Mind the output length too.** The finished GitHub issue URL is capped at 8000 characters
  (`maxURLLength` in `GitHubIssueURLBuilder.swift`); a longer body is copied to the clipboard
  instead of opening the browser, so steering the model toward verbose output quietly
  degrades the one-click submit flow.

## How to test your edit

- Run the focused tests: `swift test --filter IssueReporterTests`. These confirm the
  prompt still loads and still carries its required sections and safety constraints.
- Optionally try it live (macOS 26+ with Apple Intelligence): launch the app, open
  Settings → Report Issue, type a rough report — mention a shortcut to exercise the
  preamble — and press **Rewrite with AI**.

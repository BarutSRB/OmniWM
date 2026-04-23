// SPDX-License-Identifier: GPL-2.0-only
import Testing

@testable import OmniWMCtl

@Suite struct CLICompletionGeneratorTests {
    @Test func zshScriptIncludesNestedManifestBackedSuggestions() {
        let script = CLICompletionGenerator.script(for: .zsh)

        #expect(script.contains("query_name"))
        #expect(script.contains("rule-actions"))
        #expect(script.contains("--fields"))
        #expect(script.contains("--monitor"))
        #expect(script.contains("down left right up"))
        #expect(script.contains("default"))
        #expect(script.contains("niri"))
        #expect(script.contains("dwindle"))
        #expect(script.contains("grow"))
        #expect(script.contains("shrink"))
        #expect(script.contains("--focused --pid --window") || script.contains("--focused --window --pid"))
        #expect(script.contains("switch-workspace"))
        #expect(script.contains("previous"))
        #expect(script.contains("back"))
    }

    @Test func bashScriptIncludesRuleApplyQueryAndSubscriptionFlags() {
        let script = CLICompletionGenerator.script(for: .bash)

        #expect(script.contains("complete -F _omniwmctl omniwmctl"))
        #expect(script.contains("query_name"))
        #expect(script.contains("rule-actions"))
        #expect(script.contains("--pid"))
        #expect(script.contains("--window"))
        #expect(script.contains("--all"))
        #expect(script.contains("--no-send-initial"))
        #expect(script.contains("--exec"))
        #expect(script.contains("focused-monitor"))
    }

    @Test func fishScriptIncludesQueryFieldsAndCommandValueHints() {
        let script = CLICompletionGenerator.script(for: .fish)

        #expect(script.contains("__omniwmctl_prev_arg_is"))
        #expect(script.contains("rule-actions"))
        #expect(script.contains("--fields"))
        #expect(script.contains("pid"))
        #expect(script.contains("dwindle"))
        #expect(script.contains("grow"))
        #expect(script.contains("shrink"))
        #expect(script.contains("--monitor"))
        #expect(script.contains("--window"))
        #expect(script.contains("--pid"))
    }
}

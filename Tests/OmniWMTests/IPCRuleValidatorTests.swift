// SPDX-License-Identifier: GPL-2.0-only
import Testing

import OmniWMIPC

@Suite struct IPCRuleValidatorTests {
    @Test func titleRegexValidationRejectsLongPatternsAndNestedRepetition() {
        let tooLong = String(
            repeating: "a",
            count: IPCRuleValidator.maximumTitleRegexLength + 1
        )

        #expect(IPCRuleValidator.invalidRegexMessage(for: tooLong) == "Title regex is too long")
        #expect(IPCRuleValidator.invalidRegexMessage(for: "(a+)+") == "Title regex contains nested repetition")
        #expect(IPCRuleValidator.invalidRegexMessage(for: "^(Project|Preview)$") == nil)
    }
}

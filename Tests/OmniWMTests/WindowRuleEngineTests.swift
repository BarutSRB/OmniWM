import AppKit
import ApplicationServices
import Testing

@testable import OmniWM

private func makeWindowRuleFacts(
    bundleId: String = "com.example.app",
    appName: String? = nil,
    title: String? = nil,
    role: String? = kAXWindowRole as String,
    subrole: String? = kAXStandardWindowSubrole as String,
    hasCloseButton: Bool = true,
    hasFullscreenButton: Bool = true,
    fullscreenButtonEnabled: Bool? = true,
    hasZoomButton: Bool = true,
    hasMinimizeButton: Bool = true,
    appPolicy: NSApplication.ActivationPolicy? = .regular,
    attributeFetchSucceeded: Bool = true,
    sizeConstraints: WindowSizeConstraints? = nil
) -> WindowRuleFacts {
    WindowRuleFacts(
        appName: appName,
        ax: AXWindowFacts(
            role: role,
            subrole: subrole,
            title: title,
            hasCloseButton: hasCloseButton,
            hasFullscreenButton: hasFullscreenButton,
            fullscreenButtonEnabled: fullscreenButtonEnabled,
            hasZoomButton: hasZoomButton,
            hasMinimizeButton: hasMinimizeButton,
            appPolicy: appPolicy,
            bundleId: bundleId,
            attributeFetchSucceeded: attributeFetchSucceeded
        ),
        sizeConstraints: sizeConstraints
    )
}

@Suite @MainActor struct WindowRuleEngineTests {
    @Test func titleMatchersRequireTitleAndEnableReevaluation() {
        let engine = WindowRuleEngine()
        engine.rebuild(
            rules: [
                AppRule(
                    bundleId: "com.example.app",
                    titleSubstring: "Chooser",
                    layout: .float
                )
            ]
        )

        #expect(engine.requiresTitle)
        #expect(engine.requiresTitle(for: "com.example.app"))
        #expect(engine.requiresTitle(for: "com.unmatched.app") == false)
        #expect(engine.hasDynamicReevaluationRules)
        #expect(engine.needsWindowReevaluation)
    }

    @Test func legacyAlwaysFloatStillProducesFloatingDecision() {
        let engine = WindowRuleEngine()
        let rule = AppRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
            bundleId: "com.example.legacy",
            alwaysFloat: true
        )
        engine.rebuild(rules: [rule])

        let decision = engine.decision(
            for: makeWindowRuleFacts(bundleId: "com.example.legacy"),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == WindowDecisionDisposition.floating)
        #expect(decision.heuristicReasons.isEmpty)
        if case .userRule(rule.id) = decision.source {
        } else {
            Issue.record("Expected legacy always-float rule to remain a user rule decision")
        }
    }

    @Test func forceTileRuleOverridesMissingFullscreenButtonHeuristic() {
        let engine = WindowRuleEngine()
        engine.rebuild(
            rules: [
                AppRule(
                    bundleId: "com.adobe.illustrator",
                    layout: .tile
                )
            ]
        )

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: "com.adobe.illustrator",
                appName: "Adobe Illustrator",
                title: "Untitled-1",
                hasFullscreenButton: false,
                fullscreenButtonEnabled: nil
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .managed)
        #expect(decision.heuristicReasons.isEmpty)
    }

    @Test func moreSpecificTitleRuleBeatsGenericBundleRule() {
        let engine = WindowRuleEngine()
        let genericRule = AppRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000121")!,
            bundleId: "com.adobe.illustrator",
            layout: .float,
            assignToWorkspace: "1"
        )
        let specificRule = AppRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000122")!,
            bundleId: "com.adobe.illustrator",
            titleSubstring: "Document",
            layout: .tile,
            assignToWorkspace: "2",
            minWidth: 900
        )
        engine.rebuild(rules: [genericRule, specificRule])

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: "com.adobe.illustrator",
                appName: "Adobe Illustrator",
                title: "Document 1"
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .managed)
        #expect(decision.workspaceName == "2")
        #expect(decision.ruleEffects.minWidth == 900)
        #expect(decision.ruleEffects.matchedRuleId == specificRule.id)
    }

    @Test func attributeFetchFailureReturnsUndecided() {
        let engine = WindowRuleEngine()

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: "com.example.partial-ax",
                attributeFetchSucceeded: false
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .undecided)
        #expect(decision.heuristicReasons == [.attributeFetchFailed])
    }

    @Test func missingFullscreenButtonAloneDoesNotFloat() {
        let engine = WindowRuleEngine()

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: "com.example.standard",
                hasFullscreenButton: false,
                fullscreenButtonEnabled: nil
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .managed)
        #expect(decision.heuristicReasons == [.missingFullscreenButton])
    }

    @Test func fixedSizeStandardWindowDefaultsToFloating() {
        let engine = WindowRuleEngine()

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: "com.example.dialog",
                sizeConstraints: .fixed(size: CGSize(width: 420, height: 320))
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .floating)
        #expect(decision.heuristicReasons == [.fixedSizeWindow])
    }

    @Test func untrustedNonStandardSubroleDefaultsToUnmanaged() {
        let engine = WindowRuleEngine()

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: "com.example.weird",
                subrole: "AXWeirdTransientWindow"
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .unmanaged)
        #expect(decision.heuristicReasons == [.nonStandardSubrole])
    }

    @Test func builtInPictureInPictureRuleEnablesTitleReevaluation() {
        let engine = WindowRuleEngine()

        #expect(engine.requiresTitle)
        #expect(engine.requiresTitle(for: "org.mozilla.firefox"))
        #expect(engine.hasDynamicReevaluationRules)
        #expect(engine.needsWindowReevaluation)

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: "org.mozilla.firefox",
                title: "Picture-in-Picture"
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .floating)
        if case .builtInRule("browserPictureInPicture") = decision.source {
        } else {
            Issue.record("Expected built-in browser PiP rule to classify the window")
        }
    }

    @Test func invalidRegexIsTrackedAndExcludedFromCompiledRules() {
        let engine = WindowRuleEngine()
        let rule = AppRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000131")!,
            bundleId: "com.example.invalid-regex",
            titleRegex: "(",
            layout: .float
        )
        engine.rebuild(rules: [rule])

        #expect(engine.invalidRegexMessagesByRuleId[rule.id] != nil)

        let decision = engine.decision(
            for: makeWindowRuleFacts(bundleId: "com.example.invalid-regex"),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .managed)
        #expect(decision.source == .heuristic)
    }

    @Test func advancedOnlyRuleCompilesAndMatchesWithoutExplicitLayout() {
        let engine = WindowRuleEngine()
        let rule = AppRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000141")!,
            bundleId: "com.example.chooser",
            titleSubstring: "Chooser",
            axRole: kAXWindowRole as String,
            axSubrole: kAXStandardWindowSubrole as String
        )
        engine.rebuild(rules: [rule])

        #expect(engine.requiresTitle)
        #expect(engine.requiresTitle(for: "com.example.chooser"))
        #expect(engine.hasDynamicReevaluationRules)
        #expect(engine.needsWindowReevaluation)

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: "com.example.chooser",
                appName: "Chooser App",
                title: "Project Chooser",
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .managed)
        #expect(decision.source == .userRule(rule.id))
        #expect(decision.ruleEffects.matchedRuleId == rule.id)
    }

    @Test func invalidRegexOnlyRuleIsTrackedAndExcludedFromCompiledRules() {
        let engine = WindowRuleEngine()
        let rule = AppRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000151")!,
            bundleId: "com.example.invalid-regex-only",
            titleRegex: "("
        )
        engine.rebuild(rules: [rule])

        #expect(engine.invalidRegexMessagesByRuleId[rule.id] != nil)
        #expect(engine.requiresTitle(for: "com.example.invalid-regex-only") == false)

        let decision = engine.decision(
            for: makeWindowRuleFacts(
                bundleId: "com.example.invalid-regex-only",
                title: "Anything"
            ),
            token: nil,
            appFullscreen: false
        )

        #expect(decision.disposition == .managed)
        #expect(decision.source == .heuristic)
    }
}

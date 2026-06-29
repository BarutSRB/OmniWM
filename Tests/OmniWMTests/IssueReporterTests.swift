// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class IssueReporterTests: XCTestCase {
    func testRewritePromptResourceLoadsWithRequiredAnchors() {
        let prompt = IssueTemplate.rewriteInstructions
        XCTAssertFalse(prompt.isEmpty)
        XCTAssertTrue(prompt.contains(IssueTemplate.notProvided))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("numbered"))
        for header in IssueTemplate.requiredHeaders {
            let section = header.replacingOccurrences(of: "## ", with: "")
            XCTAssertTrue(prompt.contains(section), "rewrite prompt missing section: \(section)")
        }
    }

    func testRewritePromptContainsNoCopyableShortcutArtifacts() {
        let prompt = IssueTemplate.rewriteInstructions
        for artifact in ["Alt+Enter", "Toggle Fullscreen", "Press Alt+Enter", "KNOWN SHORTCUTS"] {
            XCTAssertFalse(
                prompt.localizedCaseInsensitiveContains(artifact),
                "base rewrite prompt must not contain copyable artifact: \(artifact)"
            )
        }
    }

    func testHotkeyPreambleResourceLoadsWithKnownShortcutsAnchor() {
        let preamble = IssueTemplate.hotkeyContextPreamble
        XCTAssertFalse(preamble.isEmpty)
        XCTAssertTrue(preamble.contains("KNOWN SHORTCUTS"))
    }

    func testEnvironmentBlockContainsVersions() {
        let builder = GitHubIssueURLBuilder(appVersion: "9.9.9", osVersion: "Version 26.1 (Build X)")
        let block = builder.environmentBlock()
        XCTAssertTrue(block.contains("9.9.9"))
        XCTAssertTrue(block.contains("26.1"))
    }

    func testSubmissionEncodesSpacesAndPlus() {
        let builder = GitHubIssueURLBuilder(appVersion: "1.0", osVersion: "26.0")
        guard case let .url(url) = builder.submission(title: "Bug report", body: "Crash in C++ now") else {
            return XCTFail("expected a url submission")
        }
        let string = url.absoluteString
        XCTAssertTrue(string.contains("Bug%20report"))
        XCTAssertTrue(string.contains("C%2B%2B"))
        XCTAssertFalse(string.contains("+"))
    }

    func testLongBodyFallsBackToClipboard() {
        let builder = GitHubIssueURLBuilder(appVersion: "1.0", osVersion: "26.0", maxURLLength: 60)
        let long = String(repeating: "x", count: 500)
        guard case let .clipboard(markdown, fallbackURL) = builder.submission(title: "Bug", body: long) else {
            return XCTFail("expected a clipboard submission")
        }
        XCTAssertTrue(markdown.contains("## Environment"))
        XCTAssertTrue(markdown.contains(long))
        let fallback = fallbackURL.absoluteString
        XCTAssertTrue(fallback.contains("title=Bug"))
        XCTAssertFalse(fallback.contains("body="))
    }

    func testRequestRewriteSuggestsWithoutMutatingFields() async {
        let engine = FakeIssueEngine(rewriteResult: .success(RewrittenIssue(title: "Clean title", body: "Clean body")))
        let model = makeModel(engine: engine)
        model.title = "rough title"
        model.actual = "rough body"
        await model.requestRewrite()
        XCTAssertEqual(model.suggestion, RewrittenIssue(title: "Clean title", body: "Clean body"))
        XCTAssertEqual(model.title, "rough title")
        XCTAssertEqual(model.actual, "rough body")
        XCTAssertNil(model.polishedBody)
        XCTAssertEqual(model.phase, .editing)
        XCTAssertNil(model.errorMessage)
    }

    func testApplyRewriteSetsTitleAndPolishedBody() async {
        let engine = FakeIssueEngine(rewriteResult: .success(RewrittenIssue(title: "Clean title", body: "Clean body")))
        let model = makeModel(engine: engine)
        model.title = "rough title"
        model.actual = "rough body"
        await model.requestRewrite()
        model.applyRewrite()
        XCTAssertEqual(model.title, "Clean title")
        XCTAssertEqual(model.polishedBody, "Clean body")
        XCTAssertEqual(model.submissionBody, "Clean body")
        XCTAssertNil(model.suggestion)
    }

    func testRequestRewriteForwardsHotkeyContextToEngine() async {
        let engine = FakeIssueEngine()
        let context = "KNOWN SHORTCUTS:\n- \"shift+o\" is bound to: Toggle Overview"
        let model = makeModel(engine: engine, hotkeyContextProvider: { _ in context })
        model.title = "rough title"
        model.actual = "rough body"
        await model.requestRewrite()
        XCTAssertEqual(engine.lastHotkeyContext, context)
    }

    func testResolveBindsMentionedShortcutToCommand() {
        let resolved = IssueHotkeyContext.resolve(
            text: "When I press alt+shift+right nothing happens",
            bindings: HotkeyBindingRegistry.defaults()
        )
        XCTAssertTrue(
            resolved.contains("\"alt+shift+right\" is bound to: Move Right"),
            "expected Move Right, got: \(resolved)"
        )
    }

    func testResolveReportsUnboundShortcut() {
        let resolved = IssueHotkeyContext.resolve(text: "alt+shift+right does nothing", bindings: [])
        XCTAssertTrue(resolved.contains("\"alt+shift+right\" is not bound to any command"))
    }

    func testResolveIgnoresNonChordText() {
        let resolved = IssueHotkeyContext.resolve(
            text: "windows flicker sometimes",
            bindings: HotkeyBindingRegistry.defaults()
        )
        XCTAssertTrue(resolved.isEmpty)
    }

    func testRequestRewriteErrorSetsMessage() async {
        let engine = FakeIssueEngine(rewriteResult: .failure(IssueReportError.generationFailed("nope")))
        let model = makeModel(engine: engine)
        model.title = "rough title"
        model.actual = "rough body"
        await model.requestRewrite()
        XCTAssertEqual(model.errorMessage, "nope")
        XCTAssertNil(model.suggestion)
        XCTAssertEqual(model.phase, .editing)
        XCTAssertTrue(model.canSubmit)
    }

    func testRequestRewriteIsNoOpWhenAIUnavailable() async {
        let model = makeModel(engine: nil, availability: .unsupportedOS)
        model.title = "Crash on launch"
        model.actual = "It crashes every time I open it."
        XCTAssertFalse(model.canRequestRewrite)
        await model.requestRewrite()
        XCTAssertNil(model.suggestion)
        XCTAssertNil(model.polishedBody)
    }

    func testCanRequestRewriteRequiresTitleAndActual() {
        let model = makeModel(engine: FakeIssueEngine())
        XCTAssertFalse(model.canRequestRewrite)
        model.title = "Title"
        XCTAssertFalse(model.canRequestRewrite)
        model.actual = "Message"
        XCTAssertTrue(model.canRequestRewrite)
    }

    func testEditingFieldsClearsSuggestion() async {
        let engine = FakeIssueEngine(rewriteResult: .success(RewrittenIssue(title: "Clean title", body: "Clean body")))
        let model = makeModel(engine: engine)
        model.title = "rough title"
        model.actual = "rough body"
        await model.requestRewrite()
        XCTAssertNotNil(model.suggestion)
        model.actual += " more detail"
        XCTAssertNil(model.suggestion)
    }

    func testComposeIncludesFilledFieldsAndOmitsEmptyOptional() {
        let model = makeModel(engine: FakeIssueEngine())
        model.title = "Bug"
        model.actual = "It crashed"
        model.category = .crash
        model.layout = .dwindle
        model.regression = .yes
        model.regressionVersion = "0.4.6"
        let composed = model.submissionBody
        XCTAssertTrue(composed.contains("## What happened\nIt crashed"))
        XCTAssertTrue(composed.contains("Crash"))
        XCTAssertTrue(composed.contains("Dwindle"))
        XCTAssertTrue(composed.contains("0.4.6"))
        XCTAssertFalse(composed.contains("## Expected behavior"))
    }

    func testStartOverClearsFields() {
        let model = makeModel(engine: FakeIssueEngine())
        model.title = "Bug"
        model.actual = "It crashed"
        model.category = .crash
        XCTAssertTrue(model.hasDraftContent)
        model.startOver()
        XCTAssertTrue(model.title.isEmpty)
        XCTAssertTrue(model.actual.isEmpty)
        XCTAssertEqual(model.category, .unspecified)
        XCTAssertFalse(model.hasDraftContent)
    }

    func testAssembleSubstitutesNotProvidedForEmptyFields() {
        let body = IssueTemplate.assemble(
            summary: "It crashed on launch",
            stepsToReproduce: "",
            expectedBehavior: "   ",
            actualBehavior: "Crash",
            additionalContext: ""
        )
        XCTAssertTrue(body.contains("## Summary\nIt crashed on launch"))
        XCTAssertTrue(body.contains("## Steps to Reproduce\nNot provided"))
        XCTAssertTrue(body.contains("## Expected Behavior\nNot provided"))
        XCTAssertTrue(body.contains("## Actual Behavior\nCrash"))
        XCTAssertTrue(body.contains("## Additional Context\nNot provided"))
    }

    func testSubmitOpensBrowser() {
        var opened: [URL] = []
        let model = makeModel(engine: FakeIssueEngine(), openURL: { opened.append($0) })
        model.title = "Bug"
        model.actual = "Body"
        model.submit()
        XCTAssertEqual(model.phase, .submitted(.openedBrowser))
        XCTAssertEqual(opened.count, 1)
    }

    func testSubmitLongBodyCopiesToClipboard() {
        var opened: [URL] = []
        var copied: [String] = []
        let builder = GitHubIssueURLBuilder(appVersion: "1.0", osVersion: "26.0", maxURLLength: 60)
        let model = makeModel(
            engine: FakeIssueEngine(),
            urlBuilder: builder,
            openURL: { opened.append($0) },
            copyToClipboard: { copied.append($0) }
        )
        model.title = "Bug"
        model.actual = String(repeating: "x", count: 500)
        model.submit()
        XCTAssertEqual(model.phase, .submitted(.copiedToClipboard))
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(copied.count, 1)
        XCTAssertTrue(copied.first?.contains("## Environment") ?? false)
    }

    func testSubmitWithDiagnosticsBundleRevealsAndRecords() {
        var revealed: [URL] = []
        let bundle = URL(fileURLWithPath: "/tmp/omniwm-bundle.zip")
        let model = makeModel(
            engine: FakeIssueEngine(),
            makeDiagnosticsBundle: { bundle },
            revealInFinder: { revealed.append($0) }
        )
        model.title = "Bug"
        model.actual = "Body"
        model.submit()
        XCTAssertEqual(model.phase, .submitted(.openedBrowser))
        XCTAssertEqual(model.lastBundleURL, bundle)
        XCTAssertNil(model.lastBundleError)
        XCTAssertEqual(revealed, [bundle])
    }

    func testSubmitDiagnosticsFailureStillSubmits() {
        var opened: [URL] = []
        let model = makeModel(
            engine: FakeIssueEngine(),
            makeDiagnosticsBundle: { throw IssueReportError.generationFailed("disk full") },
            openURL: { opened.append($0) }
        )
        model.title = "Bug"
        model.actual = "Body"
        model.submit()
        XCTAssertEqual(model.phase, .submitted(.openedBrowser))
        XCTAssertNil(model.lastBundleURL)
        XCTAssertEqual(model.lastBundleError, "disk full")
        XCTAssertEqual(opened.count, 1)
    }

    private func makeModel(
        engine: (any IssueRewriting)?,
        availability: IssueAIAvailability? = nil,
        urlBuilder: GitHubIssueURLBuilder = GitHubIssueURLBuilder(appVersion: "1.0", osVersion: "26.0"),
        makeDiagnosticsBundle: @MainActor @escaping () throws -> URL = { throw IssueReportError.unavailable },
        hotkeyContextProvider: @MainActor @escaping (String) -> String = { _ in "" },
        revealInFinder: @MainActor @escaping (URL) -> Void = { _ in },
        openURL: @MainActor @escaping (URL) -> Void = { _ in },
        copyToClipboard: @MainActor @escaping (String) -> Void = { _ in }
    ) -> ReportIssueViewModel {
        ReportIssueViewModel(
            engine: engine,
            availability: availability,
            urlBuilder: urlBuilder,
            makeDiagnosticsBundle: makeDiagnosticsBundle,
            hotkeyContextProvider: hotkeyContextProvider,
            revealInFinder: revealInFinder,
            openURL: openURL,
            copyToClipboard: copyToClipboard
        )
    }
}

@MainActor
private final class FakeIssueEngine: IssueRewriting {
    let availability: IssueAIAvailability
    let rewriteResult: Result<RewrittenIssue, Error>
    private(set) var lastHotkeyContext: String?

    init(
        availability: IssueAIAvailability = .available,
        rewriteResult: Result<RewrittenIssue, Error> = .success(RewrittenIssue(title: "title", body: "body"))
    ) {
        self.availability = availability
        self.rewriteResult = rewriteResult
    }

    func rewrite(_ freeform: String, hotkeyContext: String) async throws -> RewrittenIssue {
        lastHotkeyContext = hotkeyContext
        return try rewriteResult.get()
    }
}

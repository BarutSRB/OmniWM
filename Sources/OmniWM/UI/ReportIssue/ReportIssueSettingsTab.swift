// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import SwiftUI

struct ReportIssueSettingsTab: View {
    @State private var model: ReportIssueViewModel
    @State private var showWalkthrough = false
    @State private var hasRecentTrace = false
    @State private var traceReloadToken = 0
    @State private var showDiscardConfirm = false
    @State private var traceStatus: DiagnosticsActionStatus = .idle
    @FocusState private var titleFocused: Bool

    let controller: WMController
    private let crashPrefill: FatalCapture.PendingCrashReport?

    init(controller: WMController) {
        self.controller = controller
        crashPrefill = controller.pendingCrashReport
        let settings = controller.settings
        _model = State(initialValue: ReportIssueViewModel(
            defaultLayout: controller.activeWorkspace().map { settings.layoutType(for: $0.name) }
                ?? settings.defaultLayoutType,
            makeDiagnosticsBundle: { try controller.writeDiagnosticsBundle() },
            hotkeyContextProvider: { text in
                IssueHotkeyContext.resolve(text: text, bindings: settings.hotkeyBindings)
            },
            loadDraft: { settings.issueDraft },
            saveDraft: { settings.issueDraft = $0 }
        ))
    }

    var body: some View {
        Form {
            switch model.phase {
            case let .submitted(outcome):
                submittedSection(outcome)
            default:
                contentSections
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: handleAppear)
        .task(id: traceReloadToken) { await refreshTraceState() }
        .onChange(of: controller.traceCaptureStatus.lastArtifact) { _, artifact in
            if artifact != nil { hasRecentTrace = true }
        }
    }

    @ViewBuilder
    private var contentSections: some View {
        if showWalkthrough {
            IssueWalkthroughCard(onDismiss: dismissWalkthrough)
        }
        traceSection
        issueSection
        contextSection
        rewriteSection
        submitSection
    }

    @ViewBuilder
    private var traceSection: some View {
        Section("Diagnostics recording") {
            if controller.isTraceCaptureActive {
                recordingLabel
                Button("Stop & Save Recording") { stopRecording() }
                SettingsCaption(
                    "Stop & Save before submitting — an in-progress recording isn't attached to the bundle."
                )
            } else if hasRecentTrace {
                Label("Trace captured — it'll be attached to your report.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Record Again") { startRecording() }
                    .controlSize(.small)
            } else {
                Label("No trace recorded yet.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Record a Trace") { startRecording() }
                    .buttonStyle(.borderedProminent)
                SettingsCaption(
                    "Reproduce the bug while recording, then come back — your draft is saved. "
                        + "A trace makes bugs far easier to fix, but it's optional."
                )
            }
            statusLabel(traceStatus)
        }
    }

    @ViewBuilder
    private var recordingLabel: some View {
        if let startedAt = controller.traceCaptureStatus.startedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let text = elapsed(since: startedAt, now: context.date)
                HStack(spacing: 8) {
                    Image(systemName: "record.circle")
                        .foregroundStyle(.red)
                    Text("Recording \(text)")
                        .font(.callout.monospacedDigit())
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Recording in progress")
                .accessibilityValue(text)
            }
        }
    }

    @ViewBuilder
    private var issueSection: some View {
        Section("Issue") {
            TextField("Title", text: $model.title)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
            Picker("Category", selection: $model.category) {
                ForEach(IssueCategory.allCases) { category in
                    Text(category.displayName).tag(category)
                }
            }
            labeledEditor("What happened", text: $model.actual)
            labeledEditor("What did you expect? (optional)", text: $model.expected, minHeight: 70)
            labeledEditor("Steps to reproduce (optional)", text: $model.repro, minHeight: 70)
            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var contextSection: some View {
        Section("Context (optional)") {
            TextField("Affected app(s)", text: $model.affectedApps)
                .textFieldStyle(.roundedBorder)
            Picker("Active layout", selection: $model.layout) {
                ForEach(LayoutType.reportChoices) { layout in
                    Text(layout.displayName).tag(layout)
                }
            }
            Picker("Worked in an earlier version?", selection: $model.regression) {
                ForEach(IssueRegression.allCases) { regression in
                    Text(regression.displayName).tag(regression)
                }
            }
            if model.regression == .yes {
                TextField("Last working version/build", text: $model.regressionVersion)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsCaption(
                "OmniWM version, macOS, your settings, and any trace are captured automatically in the "
                    + "diagnostics bundle — no need to type them."
            )
        }
    }

    @ViewBuilder
    private var rewriteSection: some View {
        if model.availability == .available {
            Section {
                HStack {
                    Button("Rewrite & Format with AI") {
                        Task { await model.requestRewrite() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canRequestRewrite)
                    if model.phase == .rewriting {
                        ProgressView().controlSize(.small)
                    }
                }
                if let suggestion = model.suggestion {
                    suggestionPreview(suggestion)
                }
                SettingsCaption(
                    "On-device AI polishes your report into a clear, well-structured issue. "
                        + "Review it, then apply. Nothing leaves your Mac."
                )
            }
        }
    }

    @ViewBuilder
    private func suggestionPreview(_ suggestion: RewrittenIssue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suggested rewrite")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(suggestion.title)
                .font(.callout.weight(.semibold))
                .textSelection(.enabled)
            Text(suggestion.body)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Button("Apply") { model.applyRewrite() }
                    .buttonStyle(.borderedProminent)
                Button("Dismiss") { model.dismissSuggestion() }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var submitSection: some View {
        Section {
            SettingsCaption(
                "A diagnostics .zip (logs, your settings, system info, and any trace) is created automatically "
                    + "and revealed in Finder. Review it before dragging it into a public issue."
            )
            Button("Submit to GitHub") { model.submit() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSubmit)
            if let hint = model.submitRequirementHint {
                SettingsCaption(hint)
            }
            SettingsCaption(
                "Opens a pre-filled new-issue page in your browser; you review and post it with your own "
                    + "GitHub account. OmniWM never sees your GitHub login."
            )
            draftFooter
        }
        .confirmationDialog(
            "Discard this draft?",
            isPresented: $showDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button("Discard Draft", role: .destructive) { model.startOver() }
            Button("Keep Editing", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var draftFooter: some View {
        HStack {
            if model.hasDraftContent {
                Label("Draft saved", systemImage: "tray.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !showWalkthrough {
                Button("Show guide") { showWalkthrough = true }
                    .controlSize(.small)
            }
            if model.hasDraftContent {
                Button("Discard Draft", role: .destructive) { showDiscardConfirm = true }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func submittedSection(_ outcome: ReportIssueViewModel.SubmissionOutcome) -> some View {
        Section {
            switch outcome {
            case .openedBrowser:
                Label(
                    "Opened GitHub in your browser. Review it, then click \"Submit new issue\".",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            case .copiedToClipboard:
                Label(
                    "The issue was too long for a link, so it was copied to your clipboard. "
                        + "Paste it into the GitHub page that just opened.",
                    systemImage: "doc.on.clipboard"
                )
                .foregroundStyle(.secondary)
            }
            bundleStatus
            Button("Report another issue") { model.startOver() }
        }
    }

    @ViewBuilder
    private var bundleStatus: some View {
        if let url = model.lastBundleURL {
            Label(
                "Diagnostics bundle revealed in Finder — drag \(url.lastPathComponent) into the issue to attach it.",
                systemImage: "paperclip"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Button("Reveal Bundle Again") { model.revealLastBundle() }
                .controlSize(.small)
        }
        if let bundleError = model.lastBundleError {
            Label(
                "Couldn't create the diagnostics bundle: \(bundleError). Your issue still opened.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func labeledEditor(_ label: String, text: Binding<String>, minHeight: CGFloat = 90) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.callout)
            TextEditor(text: text)
                .frame(minHeight: minHeight)
                .font(.body)
                .accessibilityLabel(label)
        }
    }
}

extension ReportIssueSettingsTab {
    private func handleAppear() {
        applyCrashPrefillIfNeeded()
        if !controller.settings.hasSeenIssueWalkthrough {
            showWalkthrough = true
        }
        titleFocused = model.title.isEmpty
    }

    private func applyCrashPrefillIfNeeded() {
        guard let crashPrefill, !model.hasDraftContent else { return }
        model.title = "Crash: \(crashPrefill.reason)"
        model.category = .crash
        model.actual = "OmniWM recovered from a crash (log: \(crashPrefill.url.lastPathComponent)).\n\n"
            + "Reason: \(crashPrefill.reason)"
    }

    private func dismissWalkthrough() {
        controller.settings.hasSeenIssueWalkthrough = true
        showWalkthrough = false
    }

    private func startRecording() {
        Task {
            switch await controller.toggleTraceCaptureForUI(desiredState: .active) {
            case .started:
                traceStatus = .success("Recording started")
            case .noChange:
                traceStatus = .failure("A recording is already running")
            case .stopped,
                 .writeFailed:
                traceStatus = .failure("Unexpected recording state")
            }
        }
    }

    private func stopRecording() {
        Task {
            switch await controller.toggleTraceCaptureForUI(desiredState: .inactive) {
            case .stopped:
                traceStatus = .idle
            case let .writeFailed(reason):
                traceStatus = .failure("Failed to write the recording: \(reason)")
            case .noChange:
                traceStatus = .failure("No recording is running")
            case .started:
                traceStatus = .failure("Unexpected recording state")
            }
            traceReloadToken += 1
        }
    }

    @ViewBuilder
    private func statusLabel(_ status: DiagnosticsActionStatus) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case let .success(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case let .failure(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func refreshTraceState() async {
        let directory = controller.diagnosticsDirectory
        let files = await Task.detached { DiagnosticsFileScanner.scan(directory) }.value
        hasRecentTrace = files.contains {
            $0.name.hasPrefix("omniwm-trace-") && !$0.name.hasSuffix(".partial.log")
        }
    }

    private func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

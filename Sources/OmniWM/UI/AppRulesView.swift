// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI

struct RunningAppInfo: Identifiable {
    let id: String
    let bundleId: String
    let appName: String
    let icon: NSImage?
    let windowSize: CGSize
}

struct AppRulesView: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    @State private var selectedRuleId: AppRule.ID?
    @State private var addDraft: AppRuleDraft?

    var body: some View {
        NavigationSplitView {
            AppRulesSidebar(
                rules: settings.appRules,
                selection: $selectedRuleId,
                onAdd: { presentNewRule() },
                onDelete: deleteRule
            )
        } detail: {
            if let ruleId = selectedRuleId,
               let ruleIndex = settings.appRules.firstIndex(where: { $0.id == ruleId })
            {
                AppRuleDetailView(
                    rule: $settings.appRules[ruleIndex],
                    workspaceNames: workspaceNames,
                    controller: controller,
                    onCreateRuleFromSnapshot: presentNewRule(from:),
                    onDelete: {
                        deleteRule(settings.appRules[ruleIndex])
                        selectedRuleId = nil
                    }
                )
                .id(ruleId)
                .omniBackgroundExtensionEffect()
            } else {
                AppRulesEmptyState(
                    controller: controller,
                    onAdd: { presentNewRule() },
                    onCreateRuleFromSnapshot: presentNewRule(from:)
                )
                .omniBackgroundExtensionEffect()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(item: $addDraft) { draft in
            AppRuleAddSheet(
                initialDraft: draft,
                workspaceNames: workspaceNames,
                controller: controller,
                onSave: { newRule in
                    settings.appRules.append(newRule)
                    controller.updateAppRules()
                    selectedRuleId = newRule.id
                    addDraft = nil
                },
                onCancel: { addDraft = nil }
            )
        }
        .frame(minWidth: 580, minHeight: 400)
    }

    private var workspaceNames: [String] {
        settings.workspaceConfigurations.map(\.name)
    }

    private func deleteRule(_ rule: AppRule) {
        settings.appRules.removeAll { $0.id == rule.id }
        controller.updateAppRules()
        if selectedRuleId == rule.id {
            selectedRuleId = nil
        }
    }

    private func presentNewRule(_ draft: AppRuleDraft = AppRuleDraft()) {
        addDraft = draft
    }

    private func presentNewRule(from snapshot: WindowDecisionDebugSnapshot) {
        guard let draft = AppRuleDraft.guided(from: snapshot) else { return }
        addDraft = draft
    }
}

struct AppRulesSidebar: View {
    let rules: [AppRule]
    @Binding var selection: AppRule.ID?
    let onAdd: () -> Void
    let onDelete: (AppRule) -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(rules) { rule in
                AppRuleSidebarRow(rule: rule)
                    .tag(rule.id)
                    .contextMenu {
                        Button(role: .destructive) {
                            onDelete(rule)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("App Rules")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                }
                .help("Add app rule")
            }
        }
    }
}

struct AppRuleSidebarRow: View {
    let rule: AppRule

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(rule.bundleId)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)

            HStack(spacing: 4) {
                switch rule.effectiveLayoutAction {
                case .float:
                    RuleBadge(text: "Float", color: .blue)
                case .tile:
                    RuleBadge(text: "Tile", color: .teal)
                case .auto:
                    EmptyView()
                }
                if rule.assignToWorkspace != nil {
                    RuleBadge(text: "WS", color: .green)
                }
                if rule.minWidth != nil || rule.minHeight != nil {
                    RuleBadge(text: "Size", color: .orange)
                }
                if rule.hasAdvancedMatchers {
                    RuleBadge(text: "Advanced", color: .purple)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct AppRulesEmptyState: View {
    let controller: WMController
    let onAdd: () -> Void
    let onCreateRuleFromSnapshot: (WindowDecisionDebugSnapshot) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "app.badge.checkmark")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text("No App Rule Selected")
                    .font(.headline)
                Text("Select an app rule from the sidebar to edit it,\nor add a new rule to get started.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("Add Rule", action: onAdd)
                    .buttonStyle(.borderedProminent)

                FocusedWindowInspectorView(
                    controller: controller,
                    onCreateRuleFromSnapshot: onCreateRuleFromSnapshot
                )
                .frame(maxWidth: 560)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct AppRuleDetailView: View {
    @Binding var rule: AppRule
    let workspaceNames: [String]
    let controller: WMController
    let onCreateRuleFromSnapshot: (WindowDecisionDebugSnapshot) -> Void
    let onDelete: () -> Void

    @State private var draft: AppRuleDraft
    @State private var isAdvancedMatchersExpanded: Bool

    init(
        rule: Binding<AppRule>,
        workspaceNames: [String],
        controller: WMController,
        onCreateRuleFromSnapshot: @escaping (WindowDecisionDebugSnapshot) -> Void,
        onDelete: @escaping () -> Void
    ) {
        _rule = rule
        self.workspaceNames = workspaceNames
        self.controller = controller
        self.onCreateRuleFromSnapshot = onCreateRuleFromSnapshot
        self.onDelete = onDelete

        let initialRule = rule.wrappedValue
        _draft = State(initialValue: AppRuleDraft(rule: initialRule))
        _isAdvancedMatchersExpanded = State(
            initialValue: initialRule.hasAdvancedMatchers ||
                controller.windowRuleEngine.invalidRegexMessagesByRuleId[initialRule.id] != nil
        )
    }

    var body: some View {
        ScrollView {
            Form {
                Section("Application") {
                    LabeledContent("Bundle ID") {
                        Text(draft.bundleId)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                Section("Window Behavior") {
                    Picker("Layout", selection: $draft.layoutAction) {
                        ForEach(WindowRuleLayoutAction.allCases) { action in
                            Text(action.displayName).tag(action)
                        }
                    }

                    Toggle("Assign to Workspace", isOn: $draft.assignToWorkspaceEnabled)
                        .onChange(of: draft.assignToWorkspaceEnabled) { _, enabled in
                            guard enabled else { return }
                            seedWorkspaceIfNeeded()
                        }

                    if draft.assignToWorkspaceEnabled {
                        Picker("Workspace", selection: $draft.assignToWorkspace) {
                            ForEach(workspaceNames, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .disabled(workspaceNames.isEmpty)

                        if workspaceNames.isEmpty {
                            Text("No workspaces configured. Add workspaces in Settings.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("Minimum Size (Layout Constraint)") {
                    Toggle("Minimum Width", isOn: $draft.minWidthEnabled)

                    if draft.minWidthEnabled {
                        HStack {
                            TextField("Width", value: $draft.minWidth, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Text("px")
                                .foregroundColor(.secondary)
                        }
                    }

                    Toggle("Minimum Height", isOn: $draft.minHeightEnabled)

                    if draft.minHeightEnabled {
                        HStack {
                            TextField("Height", value: $draft.minHeight, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Text("px")
                                .foregroundColor(.secondary)
                        }
                    }

                    Text("Prevents layout engine from sizing window smaller than these values.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    DisclosureGroup("Advanced Matchers", isExpanded: $isAdvancedMatchersExpanded) {
                        AdvancedMatchersEditor(
                            draft: $draft,
                            regexError: titleRegexError
                        )
                    }
                }

                Section {
                    FocusedWindowInspectorView(
                        controller: controller,
                        onCreateRuleFromSnapshot: onCreateRuleFromSnapshot
                    )
                }

                Section {
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete Rule", systemImage: "trash")
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
        }
        .onChange(of: draft) { _, newValue in
            rule = newValue.makeRule(id: rule.id)
            controller.updateAppRules()
        }
    }

    private var titleRegexError: String? {
        guard draft.titleMatcherMode == .regex else { return nil }
        return controller.windowRuleEngine.invalidRegexMessagesByRuleId[rule.id]
            ?? AppRuleDraftValidation.titleRegexError(for: draft.titleRegex)
    }

    private func seedWorkspaceIfNeeded() {
        if draft.assignToWorkspace.isEmpty, let first = workspaceNames.first {
            draft.assignToWorkspace = first
        }
    }
}

struct AppRuleAddSheet: View {
    let workspaceNames: [String]
    let controller: WMController
    let onSave: (AppRule) -> Void
    let onCancel: () -> Void

    @State private var draft: AppRuleDraft
    @State private var runningApps: [RunningAppInfo] = []
    @State private var isPickerExpanded = true
    @State private var isAdvancedMatchersExpanded: Bool
    @State private var selectedAppInfo: RunningAppInfo?

    init(
        initialDraft: AppRuleDraft,
        workspaceNames: [String],
        controller: WMController,
        onSave: @escaping (AppRule) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.workspaceNames = workspaceNames
        self.controller = controller
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: initialDraft)
        _isAdvancedMatchersExpanded = State(initialValue: initialDraft.hasActiveAdvancedMatchers)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Add App Rule")
                .font(.headline)

            Form {
                Section("Application") {
                    TextField("Bundle ID", text: $draft.bundleId)
                        .textFieldStyle(.roundedBorder)
                    if let error = bundleIdError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    DisclosureGroup("Pick from running apps", isExpanded: $isPickerExpanded) {
                        if runningApps.isEmpty {
                            Text("No apps with windows found")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 4) {
                                    ForEach(runningApps) { app in
                                        RunningAppRow(
                                            app: app,
                                            isSelected: draft.bundleId == app.bundleId,
                                            onSelect: { selectApp(app) }
                                        )
                                    }
                                }
                            }
                            .frame(maxHeight: 200)
                        }
                    }
                    .onAppear {
                        runningApps = controller.runningAppsWithWindows()
                    }

                    if let appInfo = selectedAppInfo {
                        Button {
                            useCurrentWindowSize(appInfo.windowSize)
                        } label: {
                            HStack {
                                Image(systemName: "arrow.down.doc")
                                Text(
                                    "Use current size: \(Int(appInfo.windowSize.width)) x " +
                                    "\(Int(appInfo.windowSize.height)) px"
                                )
                            }
                        }
                        .buttonStyle(.bordered)
                    }

                    Text("Examples: com.apple.finder or dentalplus-air")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Window Behavior") {
                    Picker("Layout", selection: $draft.layoutAction) {
                        ForEach(WindowRuleLayoutAction.allCases) { action in
                            Text(action.displayName).tag(action)
                        }
                    }

                    Toggle("Assign to Workspace", isOn: $draft.assignToWorkspaceEnabled)
                        .onChange(of: draft.assignToWorkspaceEnabled) { _, enabled in
                            guard enabled else { return }
                            seedWorkspaceIfNeeded()
                        }

                    if draft.assignToWorkspaceEnabled {
                        Picker("Workspace", selection: $draft.assignToWorkspace) {
                            ForEach(workspaceNames, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .disabled(workspaceNames.isEmpty)

                        if workspaceNames.isEmpty {
                            Text("No workspaces configured. Add workspaces in Settings.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("Minimum Size (Layout Constraint)") {
                    Toggle("Minimum Width", isOn: $draft.minWidthEnabled)

                    if draft.minWidthEnabled {
                        HStack {
                            TextField("Width", value: $draft.minWidth, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Text("px")
                                .foregroundColor(.secondary)
                        }
                    }

                    Toggle("Minimum Height", isOn: $draft.minHeightEnabled)

                    if draft.minHeightEnabled {
                        HStack {
                            TextField("Height", value: $draft.minHeight, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Text("px")
                                .foregroundColor(.secondary)
                        }
                    }

                    Text("Prevents layout engine from sizing window smaller than these values.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    DisclosureGroup("Advanced Matchers", isExpanded: $isAdvancedMatchersExpanded) {
                        AdvancedMatchersEditor(
                            draft: $draft,
                            regexError: titleRegexError
                        )
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add") {
                    onSave(draft.makeRule())
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding()
        .frame(minWidth: 440)
    }

    private var bundleIdError: String? {
        AppRuleDraftValidation.bundleIdError(for: draft.bundleId)
    }

    private var titleRegexError: String? {
        guard draft.titleMatcherMode == .regex else { return nil }
        return AppRuleDraftValidation.titleRegexError(for: draft.titleRegex)
    }

    private var isValid: Bool {
        let trimmedBundleId = draft.bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedBundleId.isEmpty &&
            bundleIdError == nil &&
            titleRegexError == nil &&
            draft.hasAnyRule
    }

    private func seedWorkspaceIfNeeded() {
        if draft.assignToWorkspace.isEmpty, let first = workspaceNames.first {
            draft.assignToWorkspace = first
        }
    }

    private func selectApp(_ app: RunningAppInfo) {
        draft.bundleId = app.bundleId
        selectedAppInfo = app
        isPickerExpanded = false
    }

    private func useCurrentWindowSize(_ size: CGSize) {
        draft.minWidth = size.width
        draft.minHeight = size.height
        draft.minWidthEnabled = true
        draft.minHeightEnabled = true
    }
}

struct AdvancedMatchersEditor: View {
    @Binding var draft: AppRuleDraft
    let regexError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Use advanced matchers when bundle-level rules are too broad.")
                .font(.caption)
                .foregroundColor(.secondary)

            Toggle("App Name Contains", isOn: $draft.appNameMatcherEnabled)
            if draft.appNameMatcherEnabled {
                TextField("e.g. Preview", text: $draft.appNameSubstring)
                    .textFieldStyle(.roundedBorder)
            }

            Picker("Title Match", selection: $draft.titleMatcherMode) {
                ForEach(TitleMatcherMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            switch draft.titleMatcherMode {
            case .none:
                EmptyView()
            case .substring:
                TextField("Title contains", text: $draft.titleSubstring)
                    .textFieldStyle(.roundedBorder)
            case .regex:
                TextField("Title regex", text: $draft.titleRegex)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                if let regexError {
                    Text("Title regex is invalid: \(regexError)")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Toggle("AX Role", isOn: $draft.axRoleEnabled)
            if draft.axRoleEnabled {
                TextField("e.g. AXWindow", text: $draft.axRole)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            Toggle("AX Subrole", isOn: $draft.axSubroleEnabled)
            if draft.axSubroleEnabled {
                TextField("e.g. AXStandardWindow", text: $draft.axSubrole)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
        }
        .padding(.vertical, 4)
    }
}

struct FocusedWindowInspectorView: View {
    let controller: WMController
    let onCreateRuleFromSnapshot: (WindowDecisionDebugSnapshot) -> Void

    @State private var snapshot: WindowDecisionDebugSnapshot?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Focused Window Inspector")
                        .font(.headline)
                    Spacer()
                    Button("Refresh") {
                        refreshSnapshot()
                    }
                }

                if let snapshot {
                    ScrollView(.vertical) {
                        Text(snapshot.formattedDump())
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 140, maxHeight: 220)

                    HStack {
                        Button("New Rule from Focused Window") {
                            onCreateRuleFromSnapshot(snapshot)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(AppRuleDraft.guided(from: snapshot) == nil)

                        Button("Copy Debug Dump") {
                            controller.copyDebugDump(snapshot)
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    Text("No focused window is available for inspection.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                refreshSnapshot()
            }
        }
    }

    private func refreshSnapshot() {
        snapshot = controller.focusedWindowDecisionDebugSnapshot()
    }
}

struct RuleBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct RunningAppRow: View {
    let app: RunningAppInfo
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "app")
                        .frame(width: 20, height: 20)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.appName)
                        .font(.body)
                        .foregroundColor(.primary)
                    Text(app.bundleId)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text("\(Int(app.windowSize.width))x\(Int(app.windowSize.height))")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
